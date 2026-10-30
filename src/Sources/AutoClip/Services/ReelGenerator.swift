import Foundation

/// Transcripts are cached per source video so reels can be generated again later
/// ("Generate more", 🔥 Fire Short) without re-transcribing.
enum TranscriptCache {
    private static var dir: URL {
        let d = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Transcripts")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(for videoPath: String) -> URL {
        let name = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        // Path hash keeps two videos with the same name apart
        let h = String(UInt(bitPattern: videoPath.hashValue) % 1_000_000_007)
        return dir.appendingPathComponent("\(name.prefix(60))-\(h).json")
    }

    static func save(_ words: [Word], for videoPath: String) {
        if let data = try? JSONEncoder().encode(words) { try? data.write(to: file(for: videoPath)) }
    }

    /// Cached words, if the cache is newer than the video file.
    static func load(for videoPath: String) -> [Word]? {
        let f = file(for: videoPath)
        guard let data = try? Data(contentsOf: f),
              let words = try? JSONDecoder().decode([Word].self, from: data), !words.isEmpty else { return nil }
        let vAttr = try? FileManager.default.attributesOfItem(atPath: videoPath)
        let tAttr = try? FileManager.default.attributesOfItem(atPath: f.path)
        if let v = vAttr?[.modificationDate] as? Date, let t = tAttr?[.modificationDate] as? Date, v > t { return nil }
        return words
    }

    static func transcript(for videoPath: String, progress: @escaping (String) -> Void) async throws -> [Word] {
        if let cached = load(for: videoPath) { return cached }
        let whisper = WhisperService.shared
        if !whisper.modelExists {
            progress("Downloading speech model…")
            try await whisper.downloadModel { _, _ in }
        } else if !whisper.isModelLoaded {
            progress("Loading speech model…")
            try await whisper.loadModel()
        }
        progress("Transcribing…")
        let words = try await whisper.transcribe(audioURL: URL(fileURLWithPath: videoPath))
        save(words, for: videoPath)
        return words
    }
}

/// Makes new drafts for an existing Auto Reels record.
enum ReelGenerator {
    struct Settings {
        var targetDuration: Double
        var topic: String
        var formatRaw: String
        var captions: Bool
        var look: CaptionLook?
        var crossDissolve: Bool
        var emojiOverlays: Bool
        var provider: LLMClipService.AIProvider
        var useAI: Bool
    }

    static func settings(for record: AutoReelRecord) -> Settings {
        let p = record.genParams
        let d = record.drafts?.first
        let providerRaw = p?.providerRaw ?? UserDefaults.standard.string(forKey: "ar_provider") ?? ""
        return Settings(
            targetDuration: p?.targetDuration ?? 90,
            topic: p?.topic ?? "",
            formatRaw: d?.formatRaw ?? p?.formatRaw ?? VideoExportService.ExportFormat.vertical9x16.rawValue,
            captions: d?.captions ?? p?.captions ?? true,
            look: d?.look ?? CaptionLook.load(),
            crossDissolve: d?.crossDissolve ?? p?.crossDissolve ?? false,
            emojiOverlays: d?.emojiOverlays ?? p?.emojiOverlays ?? false,
            provider: LLMClipService.AIProvider(rawValue: providerRaw) ?? .google,
            useAI: p?.useAI ?? true)
    }

    static func sourceVideoPath(for record: AutoReelRecord) -> String? {
        record.sourceVideoPath ?? record.drafts?.first?.pieces.first?.sourceVideoPath
    }

    /// Clips for runs of whole sentences (one clip per run).
    static func clips(for ranges: [ClosedRange<Int>], in sentences: [ReelDraft.Sentence], source: String) -> [Clip] {
        ranges.map { r in
            let ws = sentences[r].flatMap(\.words)
            var c = Clip(id: UUID(), title: ws.prefix(8).map(\.word).joined(separator: " "),
                         startTime: max(0, (ws.first?.startTime ?? 0) - 0.1),
                         endTime: (ws.last?.endTime ?? 0) + 0.25,
                         score: 0, scoreReason: "AI story", words: ws, isLiked: false,
                         starRating: 0, captionStyleName: "Karaoke", aspectRatio: "9:16",
                         notes: "", thumbnailData: nil)
            c.sourceVideoPath = source
            return c
        }
    }

    /// Keep an AI story near the target: drop trailing runs, then trim the last run sentence
    /// by sentence (a single long passage can otherwise come back at several minutes).
    static func fit(_ ranges: [ClosedRange<Int>], to target: Double, sentences: [ReelDraft.Sentence]) -> [ClosedRange<Int>] {
        var rs = ranges
        func total() -> Double { rs.reduce(0) { $0 + (sentences[$1.upperBound].end - sentences[$1.lowerBound].start) } }
        while rs.count > 1 && total() > target * 1.3 { rs.removeLast() }
        while total() > target * 1.2, let last = rs.last, last.upperBound > last.lowerBound {
            rs[rs.count - 1] = last.lowerBound...(last.upperBound - 1)
        }
        return rs
    }

    /// Indices of transcript sentences already used by this record's reels.
    static func usedSentenceIndices(_ sentences: [ReelDraft.Sentence], record: AutoReelRecord) -> Set<Int> {
        let usedWords = Set((record.drafts ?? []).flatMap { $0.pieces.flatMap { $0.sentences.flatMap { $0.words.map(\.id) } } })
        var used = Set<Int>()
        for (i, s) in sentences.enumerated() where s.words.contains(where: { usedWords.contains($0.id) }) { used.insert(i) }
        return used
    }

    static func draft(title: String, clips: [Clip], source: String, settings st: Settings) -> ReelDraft {
        ReelDraft(title: title, clips: clips, sourceVideoPath: source, formatRaw: st.formatRaw,
                  captions: st.captions, look: st.captions ? st.look : nil,
                  crossDissolve: st.crossDissolve, emojiOverlays: st.emojiOverlays,
                  topicKeywords: st.topic.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).lowercased() })
    }

    /// `count` more reels from parts of the talk the existing reels haven't used.
    static func moreDrafts(for record: AutoReelRecord, count: Int,
                           progress: @escaping (String) -> Void) async throws -> [ReelDraft] {
        guard let source = sourceVideoPath(for: record) else { throw err("Can't find this reel's source video.") }
        let st = settings(for: record)
        let words = try await TranscriptCache.transcript(for: source, progress: progress)
        let sentences = ReelDraft.sentences(from: words)
        var used = usedSentenceIndices(sentences, record: record)
        let key = await LLMClipService.shared.loadAPIKey(for: st.provider) ?? ""
        var out: [ReelDraft] = []
        for n in 0..<count {
            progress("Building reel \(n + 1) of \(count)…")
            if st.useAI && !key.isEmpty {
                let plan = try await LLMClipService.shared.composeStory(
                    sentences: sentences.map { ($0.start, $0.end, $0.text) },
                    targetDuration: st.targetDuration, topic: st.topic.isEmpty ? nil : st.topic,
                    avoid: used, reelNumber: (record.drafts?.count ?? 0) + n + 1,
                    otherTitles: (record.drafts ?? []).map(\.title) + out.map(\.title),
                    provider: st.provider, apiKey: key)
                let ranges = fit(plan.ranges, to: st.targetDuration, sentences: sentences)
                used.formUnion(ranges.flatMap { Array($0) })
                let title = plan.title.isEmpty ? "Reel \((record.drafts?.count ?? 0) + n + 1)" : plan.title
                out.append(draft(title: title, clips: clips(for: ranges, in: sentences, source: source), source: source, settings: st))
            } else {
                // No AI: best unused moments by the built-in scorer
                let svc = VideoExportService.shared
                let usedWordIDs = Set(used.flatMap { sentences[$0].words.map(\.id) })
                let fresh = svc.autoSegmentsFromWords(words, sourceVideoPath: source)
                    .filter { !$0.words.contains { usedWordIDs.contains($0.id) } }
                guard !fresh.isEmpty else { break }
                let (hook, rest) = svc.selectHookAndClips(from: fresh, targetDuration: st.targetDuration,
                                                          variation: Int.random(in: 1...1000))
                let picked = hook.map { [$0] + rest } ?? rest
                guard !picked.isEmpty else { break }
                let pickedWords = Set(picked.flatMap { $0.words.map(\.id) })
                for (i, s) in sentences.enumerated() where s.words.contains(where: { pickedWords.contains($0.id) }) { used.insert(i) }
                let title = picked.first?.words.prefix(6).map(\.word).joined(separator: " ") ?? "Reel"
                out.append(draft(title: title, clips: picked, source: source, settings: st))
            }
        }
        guard !out.isEmpty else { throw err("No unused moments left in this video.") }
        return out
    }

    /// One 🔥 Fire Short: a hook-rollercoaster teaser with SEO copy. Needs an AI key.
    static func fireShort(for record: AutoReelRecord, progress: @escaping (String) -> Void) async throws -> ReelDraft {
        guard let source = sourceVideoPath(for: record) else { throw err("Can't find this reel's source video.") }
        let st = settings(for: record)
        guard let key = await LLMClipService.shared.loadAPIKey(for: st.provider), !key.isEmpty else {
            throw err("The Fire Short is written by AI — add an API key for \(st.provider.rawValue) in Auto Reels → AI settings.")
        }
        let words = try await TranscriptCache.transcript(for: source, progress: progress)
        let sentences = ReelDraft.sentences(from: words)
        progress("AI is building the Fire Short…")
        let target = min(60, max(30, st.targetDuration * 0.6))
        let plan = try await LLMClipService.shared.composeFireShort(
            sentences: sentences.map { ($0.start, $0.end, $0.text) },
            targetDuration: target, topic: st.topic.isEmpty ? nil : st.topic,
            provider: st.provider, apiKey: key)
        var d = draft(title: "🔥 " + (plan.title.isEmpty ? "Fire Short" : plan.title),
                      clips: clips(for: fit(plan.ranges, to: target, sentences: sentences), in: sentences, source: source),
                      source: source, settings: st)
        d.seo = .init(title: plan.title, description: plan.description, hashtags: plan.hashtags, hookText: plan.hookText)
        return d
    }

    private static func aiContext(_ record: AutoReelRecord, progress: @escaping (String) -> Void)
        async throws -> (source: String, st: Settings, key: String, sentences: [ReelDraft.Sentence]) {
        guard let source = sourceVideoPath(for: record) else { throw err("Can't find this reel's source video.") }
        let st = settings(for: record)
        guard let key = await LLMClipService.shared.loadAPIKey(for: st.provider), !key.isEmpty else {
            throw err("This needs AI — add an API key for \(st.provider.rawValue) in Auto Reels → AI settings.")
        }
        let words = try await TranscriptCache.transcript(for: source, progress: progress)
        return (source, st, key, ReelDraft.sentences(from: words))
    }

    /// A short about whatever the user asked for ("a short about forgiveness").
    static func requestedShort(_ request: String, for record: AutoReelRecord,
                               progress: @escaping (String) -> Void) async throws -> ReelDraft {
        let c = try await aiContext(record, progress: progress)
        progress("AI is building your short…")
        let plan = try await LLMClipService.shared.composeRequested(
            request, sentences: c.sentences.map { ($0.start, $0.end, $0.text) },
            targetDuration: c.st.targetDuration, provider: c.st.provider, apiKey: c.key)
        // A length named in the request ("a 30-second short") wins over the default target
        let asked = request.range(of: #"(\d{2,3})\s*(-|\s)?\s*(s|sec|second)"#, options: .regularExpression)
            .flatMap { Double(request[$0].prefix { $0.isNumber }) }
        return draft(title: plan.title.isEmpty ? request : plan.title,
                     clips: clips(for: fit(plan.ranges, to: asked ?? c.st.targetDuration, sentences: c.sentences),
                                  in: c.sentences, source: c.source),
                     source: c.source, settings: c.st)
    }

    /// Topics the talk covers, as one-click requests.
    static func topics(for record: AutoReelRecord, progress: @escaping (String) -> Void) async throws -> [String] {
        let c = try await aiContext(record, progress: progress)
        progress("AI is reading the talk…")
        return try await LLMClipService.shared.listTopics(
            sentences: c.sentences.map { ($0.start, $0.end, $0.text) }, provider: c.st.provider, apiKey: c.key)
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "AutoClip", code: 7, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
