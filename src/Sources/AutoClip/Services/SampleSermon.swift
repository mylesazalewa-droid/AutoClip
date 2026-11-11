import Foundation

/// A short built-in message with finished clips, so someone can see what AutoClip does before
/// any setup: no speech model, no API key and no waiting. Video and timings ship inside the app
/// (see src/Sample/make-sample.sh).
@MainActor
enum SampleSermon {
    struct Manifest: Codable {
        struct Reel: Codable {
            var title: String
            var hook: String?
            var keywords: [String]?
            /// First and last sentence of each stitched clip
            var ranges: [[Int]]
        }
        var title: String
        var words: [ManifestWord]
        var reels: [Reel]
    }

    struct ManifestWord: Codable { var w: String; var s: Double; var e: Double }

    static var folder: URL {
        AppPaths.folder("Samples")
    }

    static var videoPath: String { folder.appendingPathComponent("Sample Sermon.mp4").path }

    static func isSample(path: String) -> Bool { path.hasPrefix(folder.path + "/") }

    static var available: Bool {
        Bundle.main.path(forResource: "sample-sermon", ofType: "mp4") != nil
            && Bundle.main.path(forResource: "sample-sermon", ofType: "json") != nil
    }

    /// Reels for a manifest. Separate from opening them, so the build can be checked by itself.
    static func drafts(from m: Manifest, source: String, format: String, look: CaptionLook?) -> (words: [Word], drafts: [ReelDraft]) {
        let words = m.words.map { Word(id: UUID(), word: $0.w, startTime: $0.s, endTime: $0.e, confidence: 1) }
        let sentences = ReelDraft.sentences(from: words)
        let list: [ReelDraft] = m.reels.compactMap { r in
            let ranges = r.ranges.compactMap { pair -> ClosedRange<Int>? in
                guard pair.count == 2, sentences.indices.contains(pair[0]), sentences.indices.contains(pair[1]), pair[0] <= pair[1] else { return nil }
                return pair[0]...pair[1]
            }
            guard !ranges.isEmpty else { return nil }
            var d = ReelDraft(title: r.title, clips: ReelGenerator.clips(for: ranges, in: sentences, source: source),
                              sourceVideoPath: source, formatRaw: format, captions: true, look: look,
                              crossDissolve: false, emojiOverlays: false, topicKeywords: [])
            d.hookText = r.hook
            d.keywords = r.keywords
            return d
        }
        return (words, list)
    }

    /// Opens the sample, building it the first time.
    static func open() {
        let store = AutoReelsStore.shared
        if let existing = store.reels.first(where: { ($0.sourceVideoPath).map(isSample(path:)) ?? false }) {
            show(existing.id)
            return
        }
        guard let video = Bundle.main.path(forResource: "sample-sermon", ofType: "mp4"),
              let json = Bundle.main.path(forResource: "sample-sermon", ofType: "json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: json)),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            AppState.shared.errorMessage = "The sample sermon isn't in this copy of AutoClip."
            AppState.shared.showError = true
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: videoPath) {
            try? FileManager.default.copyItem(atPath: video, toPath: videoPath)
        }
        let format = VideoExportService.ExportFormat.vertical9x16
        let look = CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0])
        let built = drafts(from: m, source: videoPath, format: format.rawValue, look: look)
        TranscriptCache.save(built.words, for: videoPath)
        var rec = AutoReelRecord(id: UUID(), title: m.title, path: videoPath, format: format.rawValue,
                                 duration: built.drafts.first?.duration ?? 0, clipCount: built.drafts.count,
                                 dateCreated: Date().timeIntervalSince1970, reelTitles: built.drafts.map(\.title), drafts: built.drafts)
        rec.sourceVideoPath = videoPath
        rec.contentKind = ContentKind.sermon.rawValue
        store.add(rec)
        show(rec.id)
    }

    private static func show(_ id: UUID) {
        if let open = CommandBar.shared.openReel { open(id); return }
        AutoReelsStore.shared.navigateToReelID = id
        HomeNav.shared.open(.autoReels)
    }
}
