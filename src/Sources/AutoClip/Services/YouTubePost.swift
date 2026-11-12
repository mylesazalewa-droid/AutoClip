import Foundation
import AppKit
import Network
import CryptoKit
import Security
import SwiftUI

/// Posts finished clips to the church's YouTube channel as Shorts, now or at a set time.
///
/// Sign-in is Google's own page in the browser (OAuth for desktop apps, with PKCE): AutoClip never
/// sees the password, only a token that can upload videos, kept in the Keychain. Switched on by
/// filling in `AppInfo.youtubeClientID` / `youtubeClientSecret` from a Google Cloud "Desktop app"
/// client (Google treats a desktop app's secret as not secret).
@MainActor
final class YouTubePost: ObservableObject {
    static let shared = YouTubePost()

    static var available: Bool { !AppInfo.youtubeClientID.isEmpty }

    @Published private(set) var connected = false
    @Published var connecting = false

    private static let keychainService = "com.autoclip.youtube"
    private static let scope = "https://www.googleapis.com/auth/youtube.upload"

    private var accessToken: String?
    private var accessExpires = Date.distantPast

    private init() { connected = Self.loadRefreshToken() != nil }

    // MARK: Signing in

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Opens Google's sign-in in the browser and waits for it to come back to AutoClip.
    func connect() async throws {
        guard Self.available else { throw Failure(message: "YouTube posting isn't set up in this copy of AutoClip.") }
        connecting = true
        defer { connecting = false }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.port)"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: AppInfo.youtubeClientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(c.url!)
        let query = try await server.waitForRedirect(timeout: 300)
        guard query["state"] == state else { throw Failure(message: "The sign-in didn't match. Please try again.") }
        guard let code = query["code"] else {
            throw Failure(message: query["error"] == "access_denied" ? "YouTube access wasn't allowed." : "Google didn't finish the sign-in. Please try again.")
        }
        let token = try await Self.tokenRequest([
            "client_id": AppInfo.youtubeClientID, "client_secret": AppInfo.youtubeClientSecret,
            "code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        guard let refresh = token["refresh_token"] as? String else { throw Failure(message: "Google didn't give AutoClip lasting access. Please try again.") }
        Self.saveRefreshToken(refresh)
        remember(token)
        connected = true
        AppLog.write("YouTube connected")
    }

    func disconnect() {
        if let t = Self.loadRefreshToken() {
            // Tell Google too, so the access is really gone
            var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(t)")!)
            r.httpMethod = "POST"
            URLSession.shared.dataTask(with: r).resume()
        }
        Self.saveRefreshToken(nil)
        accessToken = nil
        connected = false
    }

    private func remember(_ token: [String: Any]) {
        accessToken = token["access_token"] as? String
        accessExpires = Date().addingTimeInterval((token["expires_in"] as? Double ?? 3000) - 60)
    }

    private func validToken() async throws -> String {
        if let accessToken, Date() < accessExpires { return accessToken }
        guard let refresh = Self.loadRefreshToken() else {
            connected = false
            throw Failure(message: "Connect YouTube first.")
        }
        do {
            let token = try await Self.tokenRequest([
                "client_id": AppInfo.youtubeClientID, "client_secret": AppInfo.youtubeClientSecret,
                "refresh_token": refresh, "grant_type": "refresh_token",
            ])
            remember(token)
            guard let t = accessToken else { throw Failure(message: "YouTube didn't answer. Please try again.") }
            return t
        } catch {
            if "\(error)".contains("invalid_grant") {
                Self.saveRefreshToken(nil); connected = false
                throw Failure(message: "YouTube needs you to connect again (the access was removed or expired).")
            }
            throw error
        }
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "Google sign-in failed: \(json["error"] as? String ?? "unknown")")
        }
        return json
    }

    // MARK: Uploading

    struct Post {
        var file: URL
        var title: String
        var description: String
        var tags: [String]
        /// nil = public now; a date = private until then, then public
        var publishAt: Date?
        var madeForKids = false
    }

    /// Uploads a clip. Returns the video's address.
    func upload(_ post: Post, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let token = try await validToken()
        var title = post.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = post.file.deletingPathExtension().lastPathComponent }
        // YouTube's limits: 100 characters for the title, no < or >
        title = String(title.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "").prefix(100))
        var description = post.description.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        if !description.localizedCaseInsensitiveContains("#shorts") { description += (description.isEmpty ? "" : "\n\n") + "#Shorts" }

        var status: [String: Any] = ["selfDeclaredMadeForKids": post.madeForKids]
        if let at = post.publishAt, at > Date().addingTimeInterval(60) {
            status["privacyStatus"] = "private"
            status["publishAt"] = ISO8601DateFormatter().string(from: at)
        } else {
            status["privacyStatus"] = "public"
        }
        let meta: [String: Any] = [
            "snippet": ["title": title, "description": String(description.prefix(5000)),
                        "tags": Array(post.tags.map { $0.replacingOccurrences(of: "#", with: "") }.prefix(15)), "categoryId": "29"],
            "status": status,
        ]
        let size = (try? FileManager.default.attributesOfItem(atPath: post.file.path)[.size] as? Int64) ?? 0

        // 1. Start a resumable upload
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("video/*", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: meta)
        let (startData, startResp) = try await URLSession.shared.data(for: start)
        guard let http = startResp as? HTTPURLResponse, http.statusCode == 200,
              let loc = http.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: loc) else {
            throw Failure(message: Self.explain(startData, fallback: "YouTube didn't accept the upload."))
        }

        // 2. Send the video
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue("video/*", forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 60 * 30
        let watcher = UploadWatcher { f in Task { @MainActor in progress(f) } }
        let session = URLSession(configuration: .default, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.upload(for: put, fromFile: post.file)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, code == 200 || code == 201,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? String else {
            throw Failure(message: Self.explain(data, fallback: "The upload didn't finish. Please try again."))
        }
        AppLog.write("YouTube: uploaded a clip")
        return URL(string: "https://youtube.com/shorts/\(id)")!
    }

    /// YouTube's reason, in plain words where it's a common one.
    private static func explain(_ data: Data, fallback: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any] else { return fallback }
        let reason = ((err["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
        switch reason {
        case "quotaExceeded": return "YouTube's daily upload limit for AutoClip has been reached. Please try again tomorrow."
        case "uploadLimitExceeded": return "This YouTube channel has reached its upload limit for today."
        case "youtubeSignupRequired": return "This Google account doesn't have a YouTube channel yet. Create one on youtube.com, then try again."
        case "forbidden", "insufficientPermissions": return "YouTube didn't allow this upload. Try connecting YouTube again."
        default: return (err["message"] as? String) ?? fallback
        }
    }

    // MARK: Keychain

    private static func saveRefreshToken(_ token: String?) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService as CFString]
        SecItemDelete(q as CFDictionary)
        guard let token else { return }
        var add = q
        add[kSecValueData] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadRefreshToken() -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService as CFString,
                                  kSecReturnData: kCFBooleanTrue!, kSecMatchLimit: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func randomString(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }
}

/// Reports how much of an upload has gone.
private final class UploadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// Google's sign-in comes back to http://127.0.0.1:<port>/?code=…; this waits for that one visit.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()
    let port: UInt16

    private init(_ l: NWListener, port: UInt16) { listener = l; self.port = port }

    static func start() async throws -> LoopbackServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            l.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready:
                    done = true
                    cont.resume(returning: LoopbackServer(l, port: l.port?.rawValue ?? 0))
                case .failed(let e):
                    done = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            l.newConnectionHandler = { _ in }
            l.start(queue: .global())
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(YouTubePost.Failure(message: "The YouTube sign-in timed out. Please try again.")))
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
            var query: [String: String] = [:]
            for i in items { query[i.name] = i.value ?? "" }
            let page = """
            <html><head><meta charset="utf-8"><title>AutoClip</title></head>
            <body style="font-family:-apple-system;text-align:center;padding-top:80px">
            <h2>\(query["code"] != nil ? "YouTube is connected" : "YouTube wasn't connected")</h2>
            <p>You can close this tab and go back to AutoClip.</p></body></html>
            """
            let body = Data(page.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            // Browsers also ask for /favicon.ico: only the visit with the answer counts
            if query["code"] != nil || query["error"] != nil { self?.finish(.success(query)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }

    func stop() { listener.cancel() }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

// MARK: - Posting a clip

/// The sheet for posting one finished clip to YouTube.
struct YouTubePostSheet: View {
    let draft: ReelDraft
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var yt = YouTubePost.shared
    @State private var title = ""
    @State private var description = ""
    @State private var schedule = false
    @State private var when = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
    @State private var progress: Double?
    @State private var posted: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Post to YouTube Shorts").font(.ui(size: 18, weight: .semibold))
            if !yt.connected {
                Text("Connect the church's YouTube channel once. Google's own sign-in opens in your browser, and AutoClip can then only upload videos.")
                    .font(.ui(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button(yt.connecting ? "Waiting for Google…" : "Connect YouTube") {
                    error = nil
                    Task { do { try await yt.connect() } catch { self.error = error.localizedDescription } }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(yt.connecting)
            } else if let posted {
                Label(schedule ? "Scheduled. It goes public \(when.formatted(date: .abbreviated, time: .shortened))." : "Posted.", systemImage: "checkmark.circle.fill")
                    .foregroundColor(Theme.good)
                Link(posted.absoluteString, destination: posted).font(.ui(size: 13))
            } else {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Text("\(title.count)/100").font(.ui(size: 11)).foregroundColor(title.count > 100 ? Theme.danger : Theme.muted)
                TextEditor(text: $description).font(.ui(size: 13)).frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.ink.opacity(0.15)))
                Toggle("Schedule it", isOn: $schedule).toggleStyle(.checkbox)
                if schedule {
                    DatePicker("Goes public", selection: $when, in: Date().addingTimeInterval(15 * 60)...)
                }
                if let progress {
                    HStack(spacing: 8) {
                        LoadingBar(fraction: progress, width: 260)
                        Text("Uploading… \(Int(progress * 100))%").font(.ui(size: 12)).foregroundColor(Theme.muted)
                    }
                }
            }
            if let error { Text(error).font(.ui(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if yt.connected && posted == nil {
                    Button("Disconnect YouTube") { yt.disconnect() }.buttonStyle(.link).font(.ui(size: 12))
                }
                Spacer()
                Button(posted == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if yt.connected && posted == nil {
                    Button(schedule ? "Schedule" : "Post") { post() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(progress != nil || title.isEmpty || title.count > 100)
                }
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            title = draft.seo?.title ?? draft.title
            var d = draft.seo?.description ?? ""
            if let tags = draft.seo?.hashtags, !tags.isEmpty { d += (d.isEmpty ? "" : "\n\n") + tags.joined(separator: " ") }
            description = d
        }
    }

    private func post() {
        error = nil; progress = 0
        let p = YouTubePost.Post(file: file, title: title, description: description,
                                 tags: draft.seo?.hashtags ?? [], publishAt: schedule ? when : nil)
        Task {
            do { posted = try await yt.upload(p) { progress = $0 } }
            catch { self.error = error.localizedDescription }
            progress = nil
        }
    }
}
