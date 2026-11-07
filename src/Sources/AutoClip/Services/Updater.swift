import Foundation
import AppKit
import CryptoKit

/// Checks for a newer AutoClip and installs it: download, check it's intact, swap the app,
/// reopen. The old copy goes to the Trash only once the new one is in place.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        var version: String
        var notes: String
        var dmg: URL
        var checksum: URL?
        var page: URL?
    }

    @Published private(set) var available: Release?
    @Published private(set) var status: String?
    @Published private(set) var progress: Double?
    @Published var error: String?
    @Published var lastChecked: Date?
    @Published var showSheet = false

    private static let autoKey = "updates_auto", lastKey = "updates_last"
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }

    /// "3.10.0" is newer than "3.9.2"
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Once a day at most, unless asked.
    func checkAtLaunch() {
        guard automatic else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        error = nil
        if manual { status = "Checking for updates…" }
        defer { if status == "Checking for updates…" { status = nil } }
        guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.releasesRepo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AutoClip/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = o["tag_name"] as? String else {
                if manual { error = "Couldn't reach the update server. Try again later." }
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastKey)
            lastChecked = Date()
            let assets = (o["assets"] as? [[String: Any]]) ?? []
            func asset(_ name: String) -> URL? {
                (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
            }
            guard Self.isNewer(tag, than: AppInfo.version), let dmg = asset("AutoClip.dmg") else {
                available = nil
                if manual { status = "You have the latest version (\(AppInfo.version))."; showSheet = true }
                return
            }
            available = Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), notes: o["body"] as? String ?? "",
                                dmg: dmg, checksum: asset("AutoClip.dmg.sha256"), page: (o["html_url"] as? String).flatMap(URL.init(string:)))
            if manual { showSheet = true }
        } catch {
            if manual { self.error = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    /// Why installing has to wait, if it does.
    var blocker: String? {
        if AutoReelsStore.shared.activeJobs.contains(where: { !$0.isFinished }) { return "Wait for the reels being made to finish." }
        if AutoImport.shared.status != nil { return "Wait for Autopilot to finish what it's doing." }
        if NSApp.windows.contains(where: { $0.attachedSheet != nil && $0.isVisible && $0.attachedSheet?.title != "Update" }) {
            return "Save and close anything you're editing first."
        }
        return nil
    }

    /// Where AutoClip is installed, if it can be replaced in place.
    private var installedApp: URL? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else { return nil }
        return app
    }

    func install() async {
        guard let r = available else { return }
        error = nil
        if let b = blocker { error = b; return }
        guard let app = installedApp else {
            error = "AutoClip can't replace itself where it is. Download the update and drag it into Applications."
            if let p = r.page { NSWorkspace.shared.open(p) }
            return
        }
        guard r.checksum != nil else {
            error = "This update has no checksum, so it can't be checked. Download it from the release page instead."
            if let p = r.page { NSWorkspace.shared.open(p) }
            return
        }
        do {
            let staged = try await prepare(r)
            status = "Installing…"
            let work = staged.deletingLastPathComponent()
            // Old copy aside, new one in, and back again if anything goes wrong
            let backup = work.appendingPathComponent("AutoClip \(AppInfo.version).app")
            try FileManager.default.moveItem(at: app, to: backup)
            do { try FileManager.default.moveItem(at: staged, to: app) }
            catch { try? FileManager.default.moveItem(at: backup, to: app); throw error }
            NSWorkspace.shared.recycle([backup]) { _, _ in }

            status = "Reopening…"
            let pid = ProcessInfo.processInfo.processIdentifier
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; /usr/bin/open \"$0\"", app.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            self.error = error.localizedDescription
            status = nil; progress = nil
        }
    }

    /// Downloads, checks and unpacks an update. Changes nothing that's installed.
    func prepare(_ r: Release) async throws -> URL {
        guard let sumURL = r.checksum else { throw Problem("This update has no checksum, so it can't be checked.") }
        let work = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AutoClip Update")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        status = "Downloading \(r.version)…"; progress = 0
        let dmg = work.appendingPathComponent("AutoClip.dmg")
        try await download(r.dmg, to: dmg)
        status = "Checking the download…"
        let (sumData, _) = try await URLSession.shared.data(from: sumURL)
        let expected = String(decoding: sumData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        let actual = try await Task.detached { SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined() }.value
        guard !expected.isEmpty, expected == actual else { throw Problem("The download didn't match its checksum, so it wasn't installed.") }
        status = "Unpacking…"
        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-quiet", "-mountpoint", mount.path, dmg.path])
        let staged = work.appendingPathComponent("AutoClip.app")
        do { try await run("/usr/bin/ditto", [mount.appendingPathComponent("AutoClip.app").path, staged.path]) }
        catch { try? await run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]); throw error }
        try? await run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
        guard let v = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, v == r.version else {
            throw Problem("The download wasn't the expected version, so it wasn't installed.")
        }
        return staged
    }

    struct Problem: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

    private func download(_ url: URL, to dest: URL) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Problem("The download failed. Try again later.") }
        let total = Double(resp.expectedContentLength)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let h = try FileHandle(forWritingTo: dest)
        defer { try? h.close() }
        var buf = Data(); buf.reserveCapacity(1 << 20)
        var got = 0.0
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 20 {
                try h.write(contentsOf: buf); got += Double(buf.count); buf.removeAll(keepingCapacity: true)
                if total > 0 { progress = got / total }
            }
        }
        try h.write(contentsOf: buf)
        progress = 1
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw Problem("Installing failed (\(URL(fileURLWithPath: tool).lastPathComponent)). Nothing was changed.") }
        }.value
    }
}
