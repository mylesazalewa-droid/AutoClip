import Foundation
import AVFoundation

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

    /// Environment with AutoClip's tools and Homebrew on PATH, so yt-dlp finds deno (for YouTube's checks) and ffmpeg.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = YouTubeTools.folder.path + ":/opt/homebrew/bin:/usr/local/bin"
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
        AppPaths.folder("Videos")
    }

    /// The yt-dlp to run: AutoClip's own (kept up to date) first, then a bundled or Homebrew one.
    static func executablePath() -> String? {
        if FileManager.default.isExecutableFile(atPath: YouTubeTools.ytdlp.path) { return YouTubeTools.ytdlp.path }
        if let b = Bundle.main.path(forResource: "yt-dlp", ofType: nil), FileManager.default.fileExists(atPath: b) { return b }
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/opt/homebrew/opt/yt-dlp/bin/yt-dlp"]
        where FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    /// Gets AutoClip's own downloader ready (fetching it the first time) and returns it.
    /// Falls back to a Homebrew copy if the fetch fails.
    static func ready(forceUpdate: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        do { try await YouTubeTools.shared.ensure(force: forceUpdate, progress: progress) }
        catch {
            if let other = executablePath() { return other }
            throw Failure(message: "AutoClip couldn't get its YouTube downloader: \(error.localizedDescription)")
        }
        guard let path = executablePath() else { throw Failure(message: "The YouTube downloader isn't ready. Check the internet connection and try again.") }
        return path
    }

    /// Errors that mean YouTube changed and a newer yt-dlp is needed.
    static func looksOutdated(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["page needs to be reloaded", "sign in to confirm", "nsig", "signature", "unable to extract",
                "http error 403", "precondition", "po token", "requested format is not available",
                "player response", "javascript runtime", "js runtime"].contains { t.contains($0) }
    }

    /// yt-dlp's raw error, in words someone can act on.
    static func friendly(_ raw: String) -> String {
        let t = raw.lowercased()
        if t.contains("private video") { return "That video is private. Make it Public or Unlisted on YouTube, or download it and add the file." }
        if t.contains("members-only") || t.contains("join this channel") { return "That video is for channel members only, so it can't be downloaded." }
        if t.contains("video unavailable") { return "YouTube says that video isn't available. Check the link." }
        if t.contains("live event will begin") || t.contains("is live") { return "That's a live stream that hasn't finished. Try again once it's over." }
        if looksOutdated(raw) {
            return "YouTube turned the download away. AutoClip updated its downloader and tried again, but YouTube still said no. Try again in a few minutes, or download the video and add the file.\n\nDetails: \(raw.suffix(160))"
        }
        return String(raw.suffix(250))
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Downloads a YouTube video into `videosDir` and returns the finished file (picture and sound together).
    /// `progress` gets 0…1 and a status line. Gets the downloader ready first, and if YouTube turns it
    /// away, updates it and tries once more.
    static func download(_ url: String, progress: @escaping (Double, String) -> Void) async throws -> URL {
        // A full service in good quality can be a couple of gigabytes
        try DiskSpace.check(2_500_000_000, for: "downloading a video", at: AppPaths.root)
        var ytdlp = try await ready { msg in progress(0, msg) }
        do {
            return try await downloadOnce(url, ytdlp: ytdlp, progress: progress)
        } catch let f as Failure where looksOutdated(f.message) {
            progress(0, "YouTube changed something. Updating the downloader and trying again…")
            ytdlp = try await ready(forceUpdate: true) { msg in progress(0, msg) }
            do { return try await downloadOnce(url, ytdlp: ytdlp, progress: progress) }
            catch let again as Failure { throw Failure(message: friendly(again.message)) }
        } catch let f as Failure {
            throw Failure(message: friendly(f.message))
        }
    }

    private static func downloadOnce(_ url: String, ytdlp: String, progress: @escaping (Double, String) -> Void) async throws -> URL {
        let dir = videosDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if ffmpegPath() == nil { return try await downloadAndJoin(url, ytdlp: ytdlp, into: dir, progress: progress) }
        let printed = try await runYTDLP(ytdlp, arguments(url: url, outTemplate: dir.appendingPathComponent("%(title)s.%(ext)s").path),
                                         in: dir, progress: { p, m in progress(min(0.95, p), m) })
        let path = printed.split(separator: "\n").last.map(String.init) ?? printed
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path), !isPartialStream(URL(fileURLWithPath: path)) else {
            throw Failure(message: "Download finished but the video and audio couldn't be combined.")
        }
        progress(1, "Downloaded")
        return URL(fileURLWithPath: path)
    }

    /// Without ffmpeg: fetch the picture and the sound separately, then put them together here.
    private static func downloadAndJoin(_ url: String, ytdlp: String, into dir: URL, progress: @escaping (Double, String) -> Void) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("autoclip-yt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let common = ["--no-playlist", "--no-warnings", "--force-overwrites", "--concurrent-fragments", "4"]
        let info = try await runYTDLP(ytdlp, common + [
            "--format", "bestvideo[ext=mp4][vcodec^=avc1][height<=1080]/bestvideo[ext=mp4][height<=1080]/best[ext=mp4]",
            "--output", work.appendingPathComponent("picture.%(ext)s").path,
            "--print", "after_move:%(title)s\t%(upload_date)s\t%(filepath)s", link
        ], in: work, progress: { p, _ in progress(min(0.8, p * 0.8), "Downloading the video: \(Int(p * 100))%") })
        let fields = (info.split(separator: "\n").last.map(String.init) ?? "").components(separatedBy: "\t")
        guard fields.count >= 3, FileManager.default.fileExists(atPath: fields[2]) else {
            throw Failure(message: "The video downloaded but its file couldn't be found.")
        }
        let picture = URL(fileURLWithPath: fields[2])
        let soundOut = try await runYTDLP(ytdlp, common + [
            "--format", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]",
            "--output", work.appendingPathComponent("sound.%(ext)s").path,
            "--print", "after_move:filepath", link
        ], in: work, progress: { p, _ in progress(0.8 + min(0.15, p * 0.15), "Downloading the sound: \(Int(p * 100))%") })
        let sound = (soundOut.split(separator: "\n").last.map(String.init)).map(URL.init(fileURLWithPath:))

        progress(0.96, "Putting the video and sound together…")
        let dest = dir.appendingPathComponent(safeFileName(fields[0].isEmpty ? "YouTube video" : fields[0]) + ".mp4")
        try await join(picture: picture, sound: sound.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }, to: dest)
        // The file's date is the upload date, as yt-dlp's --mtime would set it
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        if let d = f.date(from: fields[1]) { try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: dest.path) }
        progress(1, "Downloaded")
        return dest
    }

    /// Picture and sound into one .mp4, copied as they are (no re-encoding).
    /// YouTube's separate video part marks its last frame as lasting as long as the whole video,
    /// so players read it as twice its length. Each frame is copied with its own timing and the
    /// last one is given a normal frame's length.
    static func join(picture: URL, sound: URL?, to dest: URL) async throws {
        let v = AVURLAsset(url: picture)
        guard let vt = try await v.loadTracks(withMediaType: .video).first else {
            throw Failure(message: "The downloaded video couldn't be read.")
        }
        let audioAsset = sound.map(AVURLAsset.init(url:)) ?? v
        let at = try await audioAsset.loadTracks(withMediaType: .audio).first
        let temp = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                     sourceFormatHint: try await vt.load(.formatDescriptions).first)
        vIn.transform = try await vt.load(.preferredTransform)
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        let vReader = try AVAssetReader(asset: v)
        let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        vReader.add(vOut)

        var aIn: AVAssetWriterInput?, aReader: AVAssetReader?, aOut: AVAssetReaderTrackOutput?
        if let at {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                       sourceFormatHint: try await at.load(.formatDescriptions).first)
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            let r = try AVAssetReader(asset: audioAsset)
            let o = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            o.alwaysCopiesSampleData = false
            r.add(o)
            aIn = i; aReader = r; aOut = o
        }
        let frame = CMTime(seconds: 1 / Double(max(1, try await vt.load(.nominalFrameRate))), preferredTimescale: 60000)

        guard writer.startWriting(), vReader.startReading(), aReader?.startReading() ?? true else {
            throw Failure(message: "The video and sound couldn't be put together: \(writer.error?.localizedDescription ?? vReader.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        let ends = await withTaskGroup(of: (Bool, CMTime).self) { group -> [Bool: CMTime] in
            group.addTask { (true, await Self.pump(vIn, from: vOut, queue: "autoclip.join.video", fixLast: frame)) }
            if let aIn, let aOut {
                group.addTask { (false, await Self.pump(aIn, from: aOut, queue: "autoclip.join.audio", fixLast: nil)) }
            }
            var out: [Bool: CMTime] = [:]
            for await (isVideo, end) in group { out[isVideo] = end }
            return out
        }
        // End where the picture really ends (the file's own length is wrong), never past the sound
        if var end = ends[true], end > .zero {
            if let a = ends[false], a > .zero { end = CMTimeMinimum(end, a) }
            writer.endSession(atSourceTime: end)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure(message: "The video and sound couldn't be put together: \(writer.error?.localizedDescription ?? "unknown")")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
    }

    /// Copies every sample from a reader output into a writer input and returns where the
    /// samples really end. With `fixLast`, every frame counts as that long when finding the end,
    /// and the final one is given that duration.
    private static func pump(_ input: AVAssetWriterInput, from output: AVAssetReaderTrackOutput,
                             queue name: String, fixLast: CMTime?) async -> CMTime {
        final class Box: @unchecked Sendable { var held: CMSampleBuffer?; var done = false; var end = CMTime.zero }
        let box = Box()
        func note(_ b: CMSampleBuffer) {
            guard CMSampleBufferGetNumSamples(b) > 0 else { return }
            let pts = CMSampleBufferGetOutputPresentationTimeStamp(b)
            let len = fixLast ?? CMSampleBufferGetOutputDuration(b)
            if pts.isNumeric, len.isNumeric { box.end = CMTimeMaximum(box.end, pts + len) }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: name)) {
                guard !box.done else { return }
                while input.isReadyForMoreMediaData {
                    guard let next = output.copyNextSampleBuffer() else {
                        if let last = box.held {
                            input.append(fixLast.flatMap { Self.retimed(last, duration: $0) } ?? last)
                        }
                        box.done = true
                        input.markAsFinished()
                        c.resume()
                        return
                    }
                    note(next)
                    if fixLast == nil { input.append(next); continue }
                    if CMSampleBufferGetNumSamples(next) == 0 { continue }
                    if let prev = box.held { input.append(prev) }
                    box.held = next
                }
            }
        }
        return box.end
    }

    /// The same sample with its last entry's duration changed.
    private static func retimed(_ buffer: CMSampleBuffer, duration: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        timing[count - 1].duration = duration
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// A title as a file name, with the same look-alike characters yt-dlp uses (so `title(fromFile:)` reads it back).
    static func safeFileName(_ title: String) -> String {
        let swaps: [Character: String] = ["/": "⧸", "\\": "⧹", ":": "：", "|": "｜", "?": "？", "*": "＊",
                                          "\"": "＂", "<": "＜", ">": "＞", "#": "＃"]
        let out = title.map { swaps[$0] ?? String($0) }.joined()
        return String(out.prefix(150)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// Runs yt-dlp and returns what it printed. Reads its progress lines as it goes.
    private static func runYTDLP(_ ytdlp: String, _ args: [String], in dir: URL,
                                 progress: @escaping (Double, String) -> Void) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = dir
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        let errLog = ErrLog(), outLog = ErrLog()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            if let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty { outLog.append(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            guard let line = String(data: h.availableData, encoding: .utf8), !line.isEmpty else { return }
            errLog.append(line)
            if line.contains("%"),
               let n = line.split(separator: "%").first?.split(separator: " ").compactMap({ Double($0) }).last {
                progress(n / 100, "Downloading: \(Int(n))%")
            } else if line.contains("Merger") {
                progress(0.97, "Combining video and audio…")
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try process.run(); process.waitUntilExit(); c.resume() } catch { c.resume(throwing: error) }
                }
            }
        } onCancel: { process.terminate() }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), let s = String(data: rest, encoding: .utf8) { outLog.append(s) }
        guard process.terminationStatus == 0 else {
            let detail = errLog.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "Download failed (exit \(process.terminationStatus))" : String(detail.suffix(400)))
        }
        return outLog.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let ytdlp = try await ready()
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
