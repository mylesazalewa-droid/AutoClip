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
        /// Individual words cut out of an otherwise-kept sentence
        var cutWordIDs: [UUID]?
        func isCut(_ w: Word) -> Bool { cutWordIDs?.contains(w.id) ?? false }
        var keptWords: [Word] { included ? words.filter { !isCut($0) } : [] }
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
    /// SEO copy for Fire Shorts (title, description, hashtags, on-screen hook)
    struct SEO: Codable, Equatable {
        var title: String
        var description: String
        var hashtags: [String]
        var hookText: String
        var asText: String {
            [title, "", description, "", hashtags.joined(separator: " "), "", "On-screen hook: \(hookText)"]
                .joined(separator: "\n")
        }
    }
    var seo: SEO?
    /// Voice clean-up / music for this reel (nil = the user's default settings)
    var audio: AudioSettings?
    var audioSettings: AudioSettings { audio ?? AudioSettings.load() ?? AudioSettings() }

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

    // MARK: Caption text editing

    /// Replace a sentence's caption text (fixing transcription mistakes). Timing stays the same:
    /// with the same number of words each word keeps its own timing; otherwise the new words are
    /// spread evenly across the sentence's original time span.
    mutating func setText(_ newText: String, piece i: Int, sentence j: Int) {
        var s = pieces[i].sentences[j]
        let tokens = newText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, let first = s.words.first, let last = s.words.last else { return }
        if tokens.count == s.words.count {
            for k in s.words.indices { s.words[k].word = tokens[k] }
        } else {
            let span = max(0.1, last.endTime - first.startTime)
            let step = span / Double(tokens.count)
            s.words = tokens.enumerated().map { k, t in
                Word(id: UUID(), word: t,
                     startTime: first.startTime + Double(k) * step,
                     endTime: first.startTime + Double(k + 1) * step - 0.02,
                     confidence: 1)
            }
            s.cutWordIDs = nil   // old word ids no longer exist
        }
        pieces[i].sentences[j] = s
    }

    // MARK: Rendering

    /// One stitched run: the clip to render plus the sentences that bound it.
    struct Run {
        var clip: Clip
        var firstSentenceID: UUID
        var lastSentenceID: UUID
        /// false when the run starts/ends at a word cut inside a sentence (nudges don't apply there)
        var startsAtSentence: Bool
        var endsAtSentence: Bool
    }

    /// Clips to stitch: kept words grouped into runs. A run breaks wherever a sentence is
    /// switched off (normal padding + nudges) or a word is cut (tight cut around that word).
    var renderRuns: [Run] {
        enum Token { case word(Word, sentence: Sentence, firstInSentence: Bool, lastInSentence: Bool)
                     case sentenceBreak
                     case wordCut(Word) }
        var runs: [Run] = []
        for piece in pieces {
            var tokens: [Token] = []
            for s in piece.sentences {
                guard s.included else { tokens.append(.sentenceBreak); continue }
                for (k, w) in s.words.enumerated() {
                    if s.isCut(w) { tokens.append(.wordCut(w)) }
                    else { tokens.append(.word(w, sentence: s, firstInSentence: k == 0, lastInSentence: k == s.words.count - 1)) }
                }
            }
            var cur: [(Word, Sentence, Bool, Bool)] = []
            var cutBefore: Word?        // last cut word right before this run
            func flush(cutAfter: Word?) {
                defer { cur = [] }
                guard let (first, firstS, firstIsSentStart, _) = cur.first,
                      let (last, lastS, _, lastIsSentEnd) = cur.last else { return }
                let startsAtSentence = cutBefore == nil
                let endsAtSentence = cutAfter == nil
                var start: Double
                if let cut = cutBefore { start = max(first.startTime - 0.03, cut.endTime) }
                else { start = first.startTime - 0.1 + (firstIsSentStart ? (firstS.startNudge ?? 0) : 0) }
                var end: Double
                if let cut = cutAfter { end = min(last.endTime + 0.05, cut.startTime) }
                else { end = last.endTime + 0.25 + (lastIsSentEnd ? (lastS.endNudge ?? 0) : 0) }
                start = max(0, start); end = max(start + 0.15, end)
                let words = cur.map(\.0)
                var c = Clip(id: UUID(), title: words.prefix(8).map(\.word).joined(separator: " "),
                             startTime: start, endTime: end,
                             score: 0, scoreReason: "", words: words, isLiked: false, starRating: 0,
                             captionStyleName: "Karaoke", aspectRatio: "9:16", notes: "", thumbnailData: nil)
                c.sourceVideoPath = piece.sourceVideoPath
                runs.append(Run(clip: c, firstSentenceID: firstS.id, lastSentenceID: lastS.id,
                                startsAtSentence: startsAtSentence && firstIsSentStart,
                                endsAtSentence: endsAtSentence && lastIsSentEnd))
            }
            for tok in tokens {
                switch tok {
                case let .word(w, s, f, l):
                    cur.append((w, s, f, l))
                case .sentenceBreak:
                    flush(cutAfter: nil); cutBefore = nil
                case let .wordCut(w):
                    if !cur.isEmpty { flush(cutAfter: w) }
                    cutBefore = w
                }
            }
            flush(cutAfter: nil)
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

    /// Where each kept sentence (and its words) plays on the reel timeline — lets the editor
    /// highlight what's being said and jump the preview to any sentence.
    struct TimedSentence {
        var id: UUID
        var start: Double
        var end: Double
        var wordStarts: [Double]
    }

    var sentenceTimeline: [TimedSentence] {
        // Reel start time of every kept word
        var wordTime: [UUID: (start: Double, end: Double)] = [:]
        var t = 0.0
        for r in renderRuns {
            let offset = t - r.clip.startTime
            for w in r.clip.words { wordTime[w.id] = (w.startTime + offset, w.endTime + offset) }
            t += r.clip.duration
        }
        var out: [TimedSentence] = []
        for s in pieces.flatMap(\.sentences) {
            let times = s.words.map { wordTime[$0.id] }
            let kept = times.compactMap { $0 }
            guard let first = kept.first, let last = kept.last else { continue }
            out.append(TimedSentence(id: s.id, start: first.start, end: last.end,
                                     wordStarts: times.map { $0?.start ?? -1 }))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Where a run begins / ends on the reel timeline (for previewing a cut).
    func reelTime(runStartingWith sentenceID: UUID) -> Double? {
        var t = 0.0
        for r in renderRuns {
            if r.firstSentenceID == sentenceID && r.startsAtSentence { return t }
            t += r.clip.duration
        }
        return nil
    }

    func reelTime(runEndingWith sentenceID: UUID) -> Double? {
        var t = 0.0
        for r in renderRuns {
            t += r.clip.duration
            if r.lastSentenceID == sentenceID && r.endsAtSentence { return t }
        }
        return nil
    }

    var duration: Double { renderClips.reduce(0) { $0 + $1.duration } }
    var includedSentenceCount: Int { pieces.reduce(0) { $0 + $1.sentences.filter { !$0.keptWords.isEmpty }.count } }

    var exportOptions: VideoExportService.ExportOptions {
        var o = VideoExportService.ExportOptions()
        o.format = VideoExportService.ExportFormat(rawValue: formatRaw) ?? .vertical9x16
        o.burnCaptions = captions
        if captions { o.captionLook = look ?? CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0]) }
        o.crossDissolve = crossDissolve
        o.emojiOverlays = emojiOverlays
        o.topicKeywords = topicKeywords
        o.audio = audioSettings
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
        // Fire Shorts: save the SEO title/description/hashtags next to the video
        if let seo {
            try? seo.asText.write(to: url.deletingPathExtension().appendingPathExtension("txt"),
                                  atomically: true, encoding: .utf8)
        }
    }

    /// Speaker-following crop for an item made by `previewItem()` — the same tracking the export
    /// uses (and caches), so the preview frames the reel the way it will be rendered.
    func followComposition(for item: AVPlayerItem) async -> AVVideoComposition? {
        guard let format = VideoExportService.ExportFormat(rawValue: formatRaw) else { return nil }
        return await VideoExportService.shared.followComposition(for: renderClips, asset: item.asset, format: format)
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
