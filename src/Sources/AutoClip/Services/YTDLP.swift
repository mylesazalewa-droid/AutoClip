import Foundation

/// Shared yt-dlp invocation for Auto Clips and Auto Reels YouTube imports.
///
/// HD YouTube streams are separate video + audio files that yt-dlp merges with ffmpeg.
/// A GUI app's PATH doesn't include Homebrew, so without an explicit ffmpeg location
/// yt-dlp silently leaves the two parts unmerged (a silent .fNNN.mp4 + .m4a) and
/// transcription fails on the video-only file.
enum YTDLP {
    static func ffmpegPath() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil) { candidates.append(bundled) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Environment with Homebrew on PATH so yt-dlp also finds ffprobe / JS runtimes.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }

    static func arguments(url: String, outTemplate: String) -> [String] {
        var args: [String]
        if let ffmpeg = ffmpegPath() {
            args = [
                "--ffmpeg-location", ffmpeg,
                // Priority:
                //  1. Native H.264 mp4 ≥1080p + m4a audio — zero transcoding, best compatibility
                //  2. Any mp4 video + m4a audio
                //  3. Best available (yt-dlp picks codec, ffmpeg merges)
                "--format", "bestvideo[ext=mp4][vcodec^=avc1][height>=1080]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
                "--merge-output-format", "mp4",
            ]
        } else {
            // No ffmpeg: only single-file (video+audio together) formats are usable
            args = ["--format", "best[ext=mp4][acodec!=none][vcodec!=none]/best[acodec!=none][vcodec!=none]"]
        }
        args += [
            "--force-overwrites",              // never reuse an old (possibly low-res) download
            "--mtime",                         // file date = upload date (used to chart progress)
            "--concurrent-fragments", "4",
            "--output", outTemplate,
            "--print", "after_move:filepath",
            "--no-playlist",
            "--no-warnings",
            url.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return args
    }

    /// True for yt-dlp's intermediate per-stream files, e.g. "Title.f299.mp4" / "Title.f140-7.m4a".
    static func isPartialStream(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent
            .range(of: #"\.f\d+(-\d+)?$"#, options: .regularExpression) != nil
    }

    /// The video title from a downloaded file's name. yt-dlp swaps characters that aren't allowed
    /// in file names for look-alikes ("｜", "？", "⧸"…); this turns them back.
    static func title(fromFile url: URL) -> String {
        var t = url.deletingPathExtension().lastPathComponent
        t = t.replacingOccurrences(of: #"\.f\d+(-\d+)?$"#, with: "", options: .regularExpression)
        let swaps: [String: String] = ["｜": "|", "？": "?", "：": ":", "＂": "\"", "⧸": "/", "⧹": "\\",
                                       "＊": "*", "＜": "<", "＞": ">", "＃": "#"]
        for (a, b) in swaps { t = t.replacingOccurrences(of: a, with: b) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Where YouTube downloads are saved (shared by Auto Reels and Assess).
    static var videosDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Videos")
    }

    /// The yt-dlp to run: bundled copy first, then Homebrew / PATH.
    static func executablePath() -> String? {
        if let b = Bundle.main.path(forResource: "yt-dlp", ofType: nil), FileManager.default.fileExists(atPath: b) { return b }
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/opt/homebrew/opt/yt-dlp/bin/yt-dlp"]
        where FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads a YouTube video into `videosDir` and returns the merged file.
    /// `progress` gets 0…1 and a status line.
    static func download(_ url: String, progress: @escaping (Double, String) -> Void) async throws -> URL {
        guard let ytdlp = executablePath() else {
            throw Failure(message: "yt-dlp not found. Install with: brew install yt-dlp")
        }
        let dir = videosDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = arguments(url: url, outTemplate: dir.appendingPathComponent("%(title)s.%(ext)s").path)
        process.environment = environment
        process.currentDirectoryURL = dir
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        let errLog = ErrLog()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            guard let line = String(data: h.availableData, encoding: .utf8), !line.isEmpty else { return }
            errLog.append(line)
            if line.contains("%"),
               let n = line.split(separator: "%").first?.split(separator: " ").compactMap({ Double($0) }).last {
                progress(min(0.95, n / 100), "Downloading: \(Int(n))%")
            } else if line.contains("Merger") {
                progress(0.97, "Combining video and audio…")
            }
        }
        try await withTaskCancellationHandler {
            try process.run(); process.waitUntilExit()
        } onCancel: { process.terminate() }
        errPipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            let detail = errLog.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "Download failed (exit \(process.terminationStatus))" : String(detail.suffix(250)))
        }
        let printed = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = printed.split(separator: "\n").last.map(String.init) ?? printed
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path), !isPartialStream(URL(fileURLWithPath: path)) else {
            throw Failure(message: "Download finished but the video and audio couldn't be combined. Make sure ffmpeg is installed (brew install ffmpeg).")
        }
        progress(1, "Downloaded")
        return URL(fileURLWithPath: path)
    }

    /// What a post shows publicly. Retention and watch time are private to the account.
    struct PublicStats: Equatable {
        var title: String?
        var duration: Double?
        var views: Int?
        var likes: Int?
        var comments: Int?
        var shares: Int?
        var postedAt: Date?

        static func parse(_ data: Data) -> PublicStats? {
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            func int(_ key: String) -> Int? { (o[key] as? Int) ?? (o[key] as? Double).map { Int($0) } }
            var s = PublicStats()
            s.title = o["title"] as? String
            s.duration = (o["duration"] as? Double) ?? (o["duration"] as? Int).map(Double.init)
            s.views = int("view_count")
            s.likes = int("like_count")
            s.comments = int("comment_count")
            s.shares = int("repost_count")
            if let d = o["upload_date"] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd"
                f.locale = Locale(identifier: "en_US_POSIX")
                s.postedAt = f.date(from: d)
            }
            return s
        }

        /// Only overwrites with numbers the post actually showed.
        static func apply(_ stats: PublicStats, to short: inout PostedShort) {
            if short.title.isEmpty, let t = stats.title { short.title = t }
            if short.length == nil { short.length = stats.duration }
            short.views = stats.views ?? short.views
            short.likes = stats.likes ?? short.likes
            short.comments = stats.comments ?? short.comments
            short.shares = stats.shares ?? short.shares
            short.updatedAt = Date()
        }
    }

    /// Reads a post's public numbers without downloading the video.
    static func publicStats(_ link: String) async throws -> PublicStats {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw Failure(message: "That doesn't look like a link.")
        }
        guard let ytdlp = executablePath() else { throw Failure(message: "yt-dlp not found. Install with: brew install yt-dlp") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = ["-J", "--skip-download", "--no-playlist", "--no-warnings", "--socket-timeout", "20", "--", trimmed]
        process.environment = environment
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: stop)
                        let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        stop.cancel()
                        c.resume(returning: process.terminationStatus == 0 ? d : Data())
                    } catch { c.resume(throwing: error) }
                }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
        guard let stats = PublicStats.parse(data) else {
            throw Failure(message: "Couldn't read that post. It may be private or need a sign-in, so enter its numbers yourself.")
        }
        return stats
    }

    private final class ErrLog: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = ""
        func append(_ s: String) { lock.withLock { buf += s } }
        var text: String { lock.withLock { buf } }
    }
}
