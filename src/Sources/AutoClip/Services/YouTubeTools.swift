import Foundation
import CryptoKit

/// AutoClip's own copy of the YouTube downloader (yt-dlp) and the small JavaScript runtime it needs
/// for YouTube's checks (deno), so YouTube links work on a new Mac with nothing installed first.
/// Both come from their official GitHub releases and are checked against the published checksums.
/// yt-dlp is kept current, since YouTube changes often and old copies stop working.
actor YouTubeTools {
    static let shared = YouTubeTools()

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoClip/Tools", isDirectory: true)
    }
    nonisolated static var ytdlp: URL { folder.appendingPathComponent("yt-dlp") }
    nonisolated static var deno: URL { folder.appendingPathComponent("deno") }

    nonisolated static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: ytdlp.path) && FileManager.default.isExecutableFile(atPath: deno.path)
    }

    private static let checkedKey = "yt_tools_checked"
    private var working: Task<Void, Error>?

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Makes sure both tools are here and yt-dlp was checked for updates in the last day.
    /// `force` checks for a yt-dlp update now (after a download failed).
    func ensure(force: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async throws {
        if let working { try await working.value; return }
        let last = UserDefaults.standard.double(forKey: Self.checkedKey)
        let stale = force || Date().timeIntervalSince1970 - last > 24 * 3600
        guard !Self.installed || stale else { return }
        let task = Task {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if !FileManager.default.isExecutableFile(atPath: Self.deno.path) {
                progress?("Getting the YouTube helper (one time, about 40 MB)…")
                try await Self.installDeno()
            }
            if !FileManager.default.isExecutableFile(atPath: Self.ytdlp.path) {
                progress?("Getting the YouTube downloader (one time, about 40 MB)…")
                try await Self.installYTDLP()
            } else if stale {
                progress?("Checking the YouTube downloader is up to date…")
                if let latest = try? await Self.latestTag(), latest != Self.version(of: Self.ytdlp) {
                    progress?("Updating the YouTube downloader…")
                    try await Self.installYTDLP()
                }
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkedKey)
        }
        working = task
        defer { working = nil }
        try await task.value
    }

    // MARK: - Installing

    private static let ytBase = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"

    private static func installYTDLP() async throws {
        let sums = try await text(URL(string: ytBase + "SHA2-256SUMS")!)
        guard let want = sums.split(separator: "\n").first(where: { $0.hasSuffix(" yt-dlp_macos") })?
            .split(separator: " ").first.map({ String($0).lowercased() }) else {
            throw Failure(errorDescription: "Couldn't read the YouTube downloader's checksum.")
        }
        let file = try await fetch(URL(string: ytBase + "yt-dlp_macos")!)
        defer { try? FileManager.default.removeItem(at: file) }
        guard try sha256(file) == want else { throw Failure(errorDescription: "The YouTube downloader didn't match its checksum, so it wasn't used.") }
        try place(file, at: ytdlp)
    }

    private static func installDeno() async throws {
        #if arch(arm64)
        let name = "deno-aarch64-apple-darwin.zip"
        #else
        let name = "deno-x86_64-apple-darwin.zip"
        #endif
        let base = "https://github.com/denoland/deno/releases/latest/download/"
        let want = try await text(URL(string: base + name + ".sha256sum")!)
            .split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() } ?? ""
        let zip = try await fetch(URL(string: base + name)!)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard !want.isEmpty, try sha256(zip) == want else {
            throw Failure(errorDescription: "The YouTube helper didn't match its checksum, so it wasn't used.")
        }
        let unpack = FileManager.default.temporaryDirectory.appendingPathComponent("autoclip-deno-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unpack) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])
        try place(unpack.appendingPathComponent("deno"), at: deno)
    }

    /// Swaps a new tool in only once it's complete and runs.
    private static func place(_ file: URL, at dest: URL) throws {
        let fm = FileManager.default
        let temp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).new")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: file, to: temp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        guard version(of: temp) != nil else {
            try? fm.removeItem(at: temp)
            throw Failure(errorDescription: "The downloaded \(dest.lastPathComponent) wouldn't start on this Mac.")
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: temp, to: dest)
    }

    // MARK: - Helpers

    private static func latestTag() async throws -> String? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AutoClip", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String
    }

    /// The tool's version line, or nil when it doesn't run.
    nonisolated static func version(of tool: URL) -> String? {
        let p = Process()
        p.executableURL = tool
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        // "deno 2.5.6 (stable, …)" → "2.5.6"; yt-dlp prints just the version
        let parts = line.split(separator: " ")
        return parts.count > 1 && parts[0] == "deno" ? String(parts[1]) : line.trimmingCharacters(in: .whitespaces)
    }

    private static func fetch(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(errorDescription: "Couldn't download \(url.lastPathComponent). Check the internet connection.")
        }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("autoclip-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: tmp, to: keep)
        return keep
    }

    private static func text(_ url: URL) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(errorDescription: "Couldn't reach GitHub to get the YouTube downloader.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func sha256(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(errorDescription: "Couldn't unpack the YouTube helper.") }
    }
}
