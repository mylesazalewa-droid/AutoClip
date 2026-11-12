import Foundation
import AppKit

/// Keeps two Macs' AutoClip libraries in step through a folder they share (iCloud Drive, Dropbox,
/// Google Drive). When AutoClip quits it leaves its library there, with any sermon videos the folder
/// doesn't have yet. When the other Mac opens AutoClip and finds a newer library, it asks before
/// bringing it in, and what it replaces goes to the Trash.
///
/// One Mac at a time: the newest library wins. It's for a pastor's laptop and the office Mac, or
/// a pastor and a media volunteer taking turns, not two people editing at the same moment.
@MainActor
final class LibrarySync: ObservableObject {
    static let shared = LibrarySync()

    static let folderKey = "sync_folder"
    static let videosKey = "sync_videos"
    private static let macKey = "sync_mac_id"
    private static let sentKey = "sync_last_sent"
    private static let receivedKey = "sync_last_received"
    private static let skippedKey = "sync_skipped"
    /// Settings that belong to this Mac and never travel
    static let localSettings: Set<String> = [folderKey, videosKey, macKey, sentKey, receivedKey, skippedKey, "data_location", "owner_mac", "sidebar_more_open"]

    @Published var status: String?
    @Published var lastError: String?

    /// Set while a received library is being put in place, so quitting doesn't send it straight back
    var holdSending = false

    struct Stamp: Codable {
        var mac: String
        var macName: String
        var date: Date
        var version: String
    }

    var folder: URL? {
        guard let p = UserDefaults.standard.string(forKey: Self.folderKey), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }
    private var syncDir: URL? { folder?.appendingPathComponent("AutoClip Sync", isDirectory: true) }
    private var libraryZip: URL? { syncDir?.appendingPathComponent("AutoClip Library.zip") }
    private var stampFile: URL? { syncDir?.appendingPathComponent("latest.json") }
    private var videosDir: URL? { syncDir?.appendingPathComponent("Videos", isDirectory: true) }

    var shareVideos: Bool {
        UserDefaults.standard.object(forKey: Self.videosKey) as? Bool ?? true
    }

    private var macID: String {
        if let id = UserDefaults.standard.string(forKey: Self.macKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.macKey)
        return id
    }

    static var macName: String { Host.current().localizedName ?? "another Mac" }

    var lastSent: Date? { UserDefaults.standard.object(forKey: Self.sentKey) as? Date }

    // MARK: Choosing the folder

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use This Folder"
        p.message = "Choose a folder both Macs can see, such as one in iCloud Drive or Dropbox"
        let icloud = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloud.path) { p.directoryURL = icloud }
        guard p.runModal() == .OK, let url = p.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        lastError = nil
        objectWillChange.send()
        AppLog.write("Sync folder set")
        Task { await checkForNewer() }
    }

    func stop() {
        UserDefaults.standard.removeObject(forKey: Self.folderKey)
        objectWillChange.send()
    }

    // MARK: Sending

    /// Leaves this Mac's library in the shared folder.
    func send() async {
        guard let syncDir, let libraryZip, let stampFile, let videosDir, !holdSending, status == nil else { return }
        let fm = FileManager.default
        status = "Sharing your library…"
        defer { status = nil }
        do {
            try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
            // Each sermon video goes into the folder once. On the same disk this is an instant copy.
            var shared: [String: String] = [:]
            if shareVideos {
                for v in Self.sermonVideos() {
                    let src = URL(fileURLWithPath: v)
                    let size = (try? fm.attributesOfItem(atPath: v)[.size] as? Int64) ?? 0
                    var name = src.lastPathComponent
                    var dest = videosDir.appendingPathComponent(name)
                    let there = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
                    if let there, there != size {
                        // A different video with the same name
                        name = String(UUID().uuidString.prefix(6)) + " " + name
                        dest = videosDir.appendingPathComponent(name)
                    }
                    if !fm.fileExists(atPath: dest.path) {
                        status = "Sharing \(src.deletingPathExtension().lastPathComponent)…"
                        try fm.copyItem(at: src, to: dest)
                    }
                    shared[v] = "Videos/" + name
                }
            }
            let temp = syncDir.appendingPathComponent(".AutoClip Library \(UUID().uuidString.prefix(6)).zip")
            try await Backup.make(to: temp, includeVideos: false,
                                  alsoSkip: ["Tools", "Cache", "Moved from Documents", "Logs"],
                                  sharedMedia: shared) { _ in }
            if fm.fileExists(atPath: libraryZip.path) { _ = try fm.replaceItemAt(libraryZip, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: libraryZip) }
            let now = Date()
            let stamp = Stamp(mac: macID, macName: Self.macName, date: now, version: AppInfo.version)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(stamp).write(to: stampFile, options: .atomic)
            UserDefaults.standard.set(now, forKey: Self.sentKey)
            lastError = nil
            AppLog.write("Sync: library shared (\(shared.count) videos)")
        } catch {
            lastError = "Couldn't share the library: \(error.localizedDescription)"
            AppLog.write("Sync: sharing failed: \(error.localizedDescription)")
        }
    }

    /// The videos this library's sermons come from.
    private static func sermonVideos() -> [String] {
        let paths = AutoReelsStore.shared.reels.compactMap { ReelGenerator.sourceVideoPath(for: $0) }
        return Array(Set(paths)).filter { FileManager.default.fileExists(atPath: $0) }.sorted()
    }

    // MARK: Receiving

    /// At launch: asks to bring in a newer library from the other Mac.
    func checkForNewer() async {
        guard let stampFile, let libraryZip, folder != nil else { return }
        guard let data = await Self.download(stampFile), let stamp = try? Self.decoder.decode(Stamp.self, from: data) else { return }
        let d = UserDefaults.standard
        let mine = [d.object(forKey: Self.sentKey) as? Date, d.object(forKey: Self.receivedKey) as? Date].compactMap { $0 }.max() ?? .distantPast
        guard stamp.mac != macID, stamp.date > mine.addingTimeInterval(1) else { return }
        if let skipped = d.object(forKey: Self.skippedKey) as? Date, abs(skipped.timeIntervalSince(stamp.date)) < 1 { return }

        let a = NSAlert()
        a.messageText = "Bring in your library from \(stamp.macName)?"
        let when = stamp.date.formatted(date: .abbreviated, time: .shortened)
        var info = "AutoClip on \(stamp.macName) shared its sermons, clips and settings on \(when)."
        if let sent = d.object(forKey: Self.sentKey) as? Date {
            info += " This Mac last shared on \(sent.formatted(date: .abbreviated, time: .shortened)); anything changed here since then is replaced."
        }
        info += " What's replaced goes to the Trash, and AutoClip restarts."
        a.informativeText = info
        a.addButton(withTitle: "Bring It In")
        a.addButton(withTitle: "Not Now")
        // Replacing is never one stray Return away
        a.buttons[0].keyEquivalent = ""
        a.buttons[1].keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else {
            d.set(stamp.date, forKey: Self.skippedKey)
            return
        }
        await receive(libraryZip, stamp: stamp)
    }

    private func receive(_ zip: URL, stamp: Stamp) async {
        holdSending = true
        status = "Getting the library from \(stamp.macName)…"
        AppLog.write("Sync: bringing in library from \(stamp.macName)")
        do {
            guard await Self.download(zip) != nil || FileManager.default.fileExists(atPath: zip.path) else {
                throw NSError(domain: "Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "The library hasn't finished downloading to this Mac yet. Try again in a few minutes."])
            }
            if let videosDir { await Self.downloadAll(in: videosDir) { [weak self] s in self?.status = s } }
            UserDefaults.standard.set(stamp.date, forKey: Self.receivedKey)
            try await Backup.restore(from: zip, mediaBase: syncDir, keepSettings: Self.localSettings) { msg in
                Task { @MainActor in LibrarySync.shared.status = msg }
            }
            UserDefaults.standard.set(stamp.date, forKey: Self.receivedKey)
            status = "Restarting…"
            Relaunch.quitAndReopen()
        } catch {
            holdSending = false
            status = nil
            lastError = error.localizedDescription
            AppLog.write("Sync: bringing in failed: \(error.localizedDescription)")
            let a = NSAlert(error: error)
            a.runModal()
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    // MARK: Cloud folders

    /// Reads a file, asking iCloud Drive to download it first when it's only in the cloud.
    private static func download(_ url: URL, wait seconds: Double = 120) async -> Data? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            let end = Date().addingTimeInterval(seconds)
            while !fm.fileExists(atPath: url.path), Date() < end {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Videos still only in iCloud: start them all downloading and wait for them.
    private static func downloadAll(in dir: URL, status: @escaping @MainActor (String) -> Void) async {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        // iCloud keeps a not-yet-downloaded "Name.mp4" as ".Name.mp4.icloud"
        let waiting = items.filter { $0.hasPrefix(".") && $0.hasSuffix(".icloud") }
            .map { dir.appendingPathComponent(String($0.dropFirst().dropLast(".icloud".count))) }
        guard !waiting.isEmpty else { return }
        for f in waiting { try? fm.startDownloadingUbiquitousItem(at: f) }
        let end = Date().addingTimeInterval(30 * 60)
        while Date() < end {
            let left = waiting.filter { !fm.fileExists(atPath: $0.path) }.count
            if left == 0 { return }
            await status("Downloading \(left) sermon video\(left == 1 ? "" : "s") from iCloud…")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

/// Opens AutoClip again a moment after it quits (after a restore or a library from the other Mac).
enum Relaunch {
    /// Quits and opens again. Open sheets and dialogs are closed first: macOS won't quit an app
    /// while one is showing (the first-run setup on a new Mac, for one).
    @MainActor
    static func quitAndReopen() {
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        afterQuit()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    static func afterQuit() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // A copy run with its own home folder (CFFIXED_USER_HOME) comes back in that same folder
        var args: [String] = []
        if let h = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { args += ["--env", "CFFIXED_USER_HOME=" + h] }
        args += ["-n", Bundle.main.bundleURL.path]
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this copy to close first, so the new one doesn't find it still running
        wait.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done; exec \"$0\" \"$@\"", task.executableURL!.path] + args
        try? wait.run()
    }
}
