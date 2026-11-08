import Foundation
import Network
import Darwin

/// A small web server on this Mac so a reviewer can open a review link on their phone, on the
/// same Wi-Fi. It only answers for links that are still shared, and only serves those links' files.
final class ReviewServer: @unchecked Sendable {
    static let shared = ReviewServer()
    private let queue = DispatchQueue(label: "autoclip.review-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var requests: [String: ReviewRequest] = [:]
    private(set) var port: UInt16 = 0
    private static let preferredPort: UInt16 = 8777

    // MARK: State from the app

    func publish(_ all: [ReviewRequest]) {
        lock.lock()
        requests = Dictionary(all.filter { !$0.closed }.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()
    }

    private func lookup(_ token: String) -> ReviewRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests[token]
    }

    var running: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil && port != 0 }

    func url(for token: String) -> URL? {
        guard port != 0, let ip = Self.lanAddress() else { return nil }
        return URL(string: "http://\(ip):\(port)/r/\(token)")
    }

    // MARK: Starting and stopping

    func start() {
        lock.lock()
        guard listener == nil else { lock.unlock(); return }
        lock.unlock()
        let l = (try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.preferredPort)!)) ?? (try? NWListener(using: .tcp))
        guard let l else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock(); self.port = l.port?.rawValue ?? 0; self.lock.unlock()
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
            case .failed:
                // Port taken: try any free port
                l.cancel()
                self.lock.lock(); self.listener = nil; self.port = 0; self.lock.unlock()
                if let any = try? NWListener(using: .tcp) {
                    any.newConnectionHandler = { [weak self] c in self?.accept(c) }
                    any.stateUpdateHandler = { [weak self] s in
                        if case .ready = s, let self {
                            self.lock.lock(); self.port = any.port?.rawValue ?? 0; self.lock.unlock()
                            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
                        }
                    }
                    self.lock.lock(); self.listener = any; self.lock.unlock()
                    any.start(queue: self.queue)
                }
            default: break
            }
        }
        lock.lock(); listener = l; lock.unlock()
        l.start(queue: queue)
    }

    func stop() {
        lock.lock(); listener?.cancel(); listener = nil; port = 0; lock.unlock()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static let changed = Notification.Name("ReviewServer.changed")

    /// This Mac's address on the local network (Wi-Fi or Ethernet).
    static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(String, String)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") { found.append((name, ip)) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.first?.1
    }

    // MARK: Connections

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
        // Drop connections that hang about
        queue.asyncAfter(deadline: .now() + 120) { if c.state != .cancelled { c.cancel() } }
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 256 * 1024 { c.cancel(); return }
            if let req = Self.parse(buf) {
                self.handle(req, on: c)
            } else if done || err != nil {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    /// A complete request, or nil when more is still to come.
    private static func parse(_ d: Data) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: d[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[end.upperBound...]
        guard body.count >= len else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(len)))
    }

    private func handle(_ req: Request, on c: NWConnection) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        let parts = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        guard parts.count >= 2, parts[0] == "r", let r = lookup(parts[1]) else {
            return send(c, status: "404 Not Found", type: "text/html; charset=utf-8",
                        body: Data(Self.notFoundPage.utf8))
        }
        switch (req.method, parts.count) {
        case ("GET", 2):
            send(c, status: "200 OK", type: "text/html; charset=utf-8", body: Data(ReviewPage.html(r).utf8))
        case ("GET", _) where parts.count >= 4 && parts[2] == "img":
            let rel = parts[3...].joined(separator: "/")
            // Only pictures this request lists
            guard r.items.contains(where: { $0.images.contains(rel) }) else { return notFound(c) }
            sendFile(c, url: r.folder.appendingPathComponent(rel), range: nil, type: "image/png")
        case ("GET", 4) where parts[2] == "v":
            guard let i = Int(parts[3].split(separator: ".").first ?? ""), r.videos.indices.contains(i) else { return notFound(c) }
            let url = URL(fileURLWithPath: r.videos[i])
            let type = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
            sendFile(c, url: url, range: req.headers["range"], type: type)
        case ("POST", 3) where parts[2] == "answer":
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let item = (obj["item"] as? String).flatMap(UUID.init(uuidString:)),
                  let raw = obj["decision"] as? String, let decision = ReviewItem.Decision(rawValue: raw),
                  r.items.contains(where: { $0.id == item }) else {
                return send(c, status: "400 Bad Request", type: "text/plain", body: Data("bad".utf8))
            }
            let note = obj["note"] as? String ?? "", by = obj["by"] as? String ?? ""
            let token = r.token
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ReviewStore.shared.record(token: token, item: item, decision: decision, note: note, by: by)
                }
            }
            send(c, status: "200 OK", type: "application/json", body: Data("{\"ok\":true}".utf8))
        default:
            notFound(c)
        }
    }

    private func notFound(_ c: NWConnection) {
        send(c, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
    }

    private func send(_ c: NWConnection, status: String, type: String, body: Data, extra: [String] = []) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n"
        for e in extra { head += e + "\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    /// A file, or the byte range a video player asks for, streamed in pieces.
    private func sendFile(_ c: NWConnection, url: URL, range: String?, type: String) {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return notFound(c)
        }
        var start: Int64 = 0, end: Int64 = size - 1, partial = false
        if let range, range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: ",").first ?? ""
            let ab = spec.split(separator: "-", omittingEmptySubsequences: false)
            if ab.count == 2 {
                if ab[0].isEmpty, let n = Int64(ab[1]) { start = max(0, size - n) }
                else if let a = Int64(ab[0]) {
                    start = a
                    end = Int64(ab[1]) ?? (size - 1)
                    // An open-ended range gets a sensible slice; the player asks for more
                    if ab[1].isEmpty { end = min(size - 1, a + 8 * 1024 * 1024 - 1) }
                }
                end = min(end, size - 1)
                partial = true
            }
        }
        guard start <= end, start < size else {
            try? fh.close()
            return send(c, status: "416 Range Not Satisfiable", type: "text/plain", body: Data(),
                        extra: ["Content-Range: bytes */\(size)"])
        }
        let length = end - start + 1
        var head = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(type)\r\n"
        head += "Content-Length: \(length)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "\r\n"
        try? fh.seek(toOffset: UInt64(start))
        c.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            guard err == nil else { try? fh.close(); c.cancel(); return }
            self?.pump(c, fh, remaining: length)
        })
    }

    private func pump(_ c: NWConnection, _ fh: FileHandle, remaining: Int64) {
        guard remaining > 0 else { try? fh.close(); c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let n = Int(min(remaining, 512 * 1024))
        guard let chunk = try? fh.read(upToCount: n), !chunk.isEmpty else { try? fh.close(); c.cancel(); return }
        c.send(content: chunk, completion: .contentProcessed { [weak self] err in
            guard err == nil else { try? fh.close(); c.cancel(); return }
            self?.pump(c, fh, remaining: remaining - Int64(chunk.count))
        })
    }

    private static let notFoundPage = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>AutoClip</title>
    <body style="font:17px -apple-system,system-ui;background:#141517;color:#F1E9DC;padding:40px 24px;text-align:center">
    <h2 style="font-weight:600">This review link isn't shared any more</h2>
    <p style="opacity:.7">Ask whoever sent it for a new one. The Mac it came from also needs AutoClip open and to be on the same Wi-Fi as you.</p></body>
    """
}
