import Foundation
import AVFoundation
import AppKit

/// An editable Auto Reel: the clips it's stitched from, split into sentences that can be
/// switched off, plus its export settings. Reels are created as drafts and only rendered
/// when the user exports them, and can be re-edited and re-exported any time.
struct ReelDraft: Identifiable, Codable, Equatable {
    struct Sentence: Identifiable, Codable, Equatable {
        var id = UUID()
        var words: [Word]
        var included = true
        /// Fine-tune (seconds) applied when this sentence starts / ends a stitched run.
        /// Negative start = begin earlier, positive end = run longer. Optional so 2.61 drafts decode.
        var startNudge: Double?
        var endNudge: Double?
        var text: String { words.map(\.word).joined(separator: " ") }
        var start: Double { words.first?.startTime ?? 0 }
        var end: Double { words.last?.endTime ?? 0 }
    }

    /// One stitched moment from the source video (in reel order).
    struct Piece: Identifiable, Codable, Equatable {
        var id = UUID()
        var sourceVideoPath: String
        var sentences: [Sentence]
    }

    var id = UUID()
    var title: String
    var pieces: [Piece]
    var formatRaw: String
    var captions: Bool
    var look: CaptionLook?
    var crossDissolve: Bool
    var emojiOverlays: Bool
    var topicKeywords: [String]
    var exportedPath: String?
    var editedSinceExport = false

    // MARK: Building

    init(title: String, clips: [Clip], sourceVideoPath: String, formatRaw: String, captions: Bool,
         look: CaptionLook?, crossDissolve: Bool, emojiOverlays: Bool, topicKeywords: [String]) {
        self.title = title
        self.pieces = clips.map { clip in
            Piece(sourceVideoPath: clip.sourceVideoPath.isEmpty ? sourceVideoPath : clip.sourceVideoPath,
                  sentences: Self.sentences(from: clip.words))
        }
        self.formatRaw = formatRaw; self.captions = captions; self.look = look
        self.crossDissolve = crossDissolve; self.emojiOverlays = emojiOverlays
        self.topicKeywords = topicKeywords
    }

    static func sentences(from words: [Word]) -> [Sentence] {
        var out: [Sentence] = []
        var cur: [Word] = []
        for w in words.sorted(by: { $0.startTime < $1.startTime }) {
            cur.append(w)
            if w.word.last.map({ ".!?\"”".contains($0) }) ?? false {
                out.append(Sentence(words: cur)); cur = []
            }
        }
        if !cur.isEmpty { out.append(Sentence(words: cur)) }
        return out
    }

    // MARK: Rendering

    /// One stitched run: the clip to render plus the sentences that bound it.
    struct Run {
        var clip: Clip
        var firstSentenceID: UUID
        var lastSentenceID: UUID
    }

    /// Clips to stitch: each piece's included sentences, merged where they're back-to-back
    /// in the source, so removing a sentence mid-piece cuts it out cleanly.
    var renderRuns: [Run] {
        var runs: [Run] = []
        for piece in pieces {
            var run: [Sentence] = []
            func flush() {
                guard let firstS = run.first, let lastS = run.last,
                      let first = firstS.words.first, let last = lastS.words.last else { run = []; return }
                let words = run.flatMap(\.words)
                let start = max(0, first.startTime - 0.1 + (firstS.startNudge ?? 0))
                let end = max(start + 0.3, last.endTime + 0.25 + (lastS.endNudge ?? 0))
                var c = Clip(id: UUID(), title: words.prefix(8).map(\.word).joined(separator: " "),
                             startTime: start, endTime: end,
                             score: 0, scoreReason: "", words: words, isLiked: false, starRating: 0,
                             captionStyleName: "Karaoke", aspectRatio: "9:16", notes: "", thumbnailData: nil)
                c.sourceVideoPath = piece.sourceVideoPath
                runs.append(Run(clip: c, firstSentenceID: firstS.id, lastSentenceID: lastS.id))
                run = []
            }
            for s in piece.sentences {
                if s.included { run.append(s) } else { flush() }
            }
            flush()
        }
        // Don't let default padding overlap the next clip from the same source (avoids repeated
        // syllables) — unless the user deliberately nudged that cut.
        let nudged = Set(pieces.flatMap(\.sentences).filter { $0.startNudge != nil || $0.endNudge != nil }.map(\.id))
        for i in runs.indices.dropLast() where runs[i].clip.sourceVideoPath == runs[i + 1].clip.sourceVideoPath {
            guard !nudged.contains(runs[i].lastSentenceID), !nudged.contains(runs[i + 1].firstSentenceID) else { continue }
            let next = runs[i + 1].clip
            if next.startTime > runs[i].clip.startTime && runs[i].clip.endTime > next.startTime {
                let mid = ((runs[i].clip.words.last?.endTime ?? runs[i].clip.endTime) + (next.words.first?.startTime ?? next.startTime)) / 2
                runs[i].clip.endTime = mid; runs[i + 1].clip.startTime = mid
            }
        }
        return runs
    }

    var renderClips: [Clip] { renderRuns.map(\.clip) }

    /// Where a run begins / ends on the reel timeline (for previewing a cut).
    func reelTime(runStartingWith sentenceID: UUID) -> Double? {
        var t = 0.0
        for r in renderRuns {
            if r.firstSentenceID == sentenceID { return t }
            t += r.clip.duration
        }
        return nil
    }

    func reelTime(runEndingWith sentenceID: UUID) -> Double? {
        var t = 0.0
        for r in renderRuns {
            t += r.clip.duration
            if r.lastSentenceID == sentenceID { return t }
        }
        return nil
    }

    var duration: Double { renderClips.reduce(0) { $0 + $1.duration } }
    var includedSentenceCount: Int { pieces.reduce(0) { $0 + $1.sentences.filter(\.included).count } }

    var exportOptions: VideoExportService.ExportOptions {
        var o = VideoExportService.ExportOptions()
        o.format = VideoExportService.ExportFormat(rawValue: formatRaw) ?? .vertical9x16
        o.burnCaptions = captions
        if captions { o.captionLook = look ?? CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0]) }
        o.crossDissolve = crossDissolve
        o.emojiOverlays = emojiOverlays
        o.topicKeywords = topicKeywords
        return o
    }

    func render(to url: URL, progress: @escaping (Double, String) -> Void) async throws {
        let clips = renderClips
        guard let first = clips.first else {
            throw NSError(domain: "AutoClip", code: 5, userInfo: [NSLocalizedDescriptionKey: "This reel has no sentences switched on."])
        }
        try await VideoExportService.shared.createHighlightReel(
            clips: clips, sourceVideoURL: URL(fileURLWithPath: first.sourceVideoPath),
            outputURL: url, options: exportOptions, progress: progress)
    }

    /// Instant, un-rendered preview of the current edit (no captions burned in).
    func previewItem() async -> (AVPlayerItem, [Word])? {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var at = CMTime.zero
        var words: [Word] = []
        var assets: [String: AVURLAsset] = [:]
        for clip in renderClips {
            let asset = assets[clip.sourceVideoPath] ?? AVURLAsset(url: URL(fileURLWithPath: clip.sourceVideoPath))
            assets[clip.sourceVideoPath] = asset
            guard let sv = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            if at == .zero, let t = try? await sv.load(.preferredTransform) { vTrack.preferredTransform = t }
            let range = CMTimeRange(start: CMTime(seconds: clip.startTime, preferredTimescale: 600),
                                    end: CMTime(seconds: clip.endTime, preferredTimescale: 600))
            guard (try? vTrack.insertTimeRange(range, of: sv, at: at)) != nil else { continue }
            if let sa = try? await asset.loadTracks(withMediaType: .audio).first {
                try? aTrack.insertTimeRange(range, of: sa, at: at)
            }
            let offset = CMTimeGetSeconds(at) - clip.startTime
            words += clip.words.map { var w = $0; w.startTime += offset; w.endTime += offset; return w }
            at = CMTimeAdd(at, range.duration)
        }
        return (AVPlayerItem(asset: comp), words)
    }
}

enum ReelExportLocation {
    /// Folder picker that starts in the last folder used (shared with Auto Reels creation).
    @MainActor
    static func pick(title: String = "Choose where to save your reel") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if let last = UserDefaults.standard.string(forKey: "ar_lastOutputDir"),
           FileManager.default.fileExists(atPath: last) {
            panel.directoryURL = URL(fileURLWithPath: last)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: "ar_lastOutputDir")
        return url
    }

    static func fileURL(in folder: URL, title: String) -> URL {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent(String(safe.prefix(80)) + ".mp4")
    }
}
