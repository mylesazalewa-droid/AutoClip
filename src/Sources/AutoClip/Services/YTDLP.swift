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
}
