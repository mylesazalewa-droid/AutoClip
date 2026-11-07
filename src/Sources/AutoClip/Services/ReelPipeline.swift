import Foundation
import AVFoundation

/// Turns one video into a project of editable reel drafts: transcribe, pick the moments
/// (with AI or the local scorer), and save the drafts. Used by Auto Reels and auto-import.
enum ReelPipeline {
    static func run(jobID: UUID = UUID(),
                                    videoURL: URL, format: VideoExportService.ExportFormat,
                                    captions: Bool, styleIdx: Int, targetDur: Double,
                                    useAI: Bool = false,
                                    provider: LLMClipService.AIProvider = .anthropic,
                                    apiKey: String = "",
                                    desiredReelCount: Int = 0,
                                    storylineMode: StorylineMode? = nil,
                                    topic: String = "",
                                    crossDissolve: Bool = true,
                                    emojiOverlays: Bool = false,
                                    outputDir: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!,
                                    retryParams: AutoReelJobParams? = nil) async {
        let title = retryParams?.sourceTitle ?? videoURL.deletingPathExtension().lastPathComponent
        await CostTag.$video.withValue(title) {
            await make(jobID: jobID, videoURL: videoURL, format: format, captions: captions,
                       styleIdx: styleIdx, targetDur: targetDur, useAI: useAI, provider: provider,
                       apiKey: apiKey, desiredReelCount: desiredReelCount, storylineMode: storylineMode,
                       topic: topic, crossDissolve: crossDissolve, emojiOverlays: emojiOverlays,
                       outputDir: outputDir, retryParams: retryParams)
        }
    }

    private static func make(jobID: UUID = UUID(),
                                    videoURL: URL, format: VideoExportService.ExportFormat,
                                    captions: Bool, styleIdx: Int, targetDur: Double,
                                    useAI: Bool = false,
                                    provider: LLMClipService.AIProvider = .anthropic,
                                    apiKey: String = "",
                                    desiredReelCount: Int = 0,
                                    storylineMode: StorylineMode? = nil,
                                    topic: String = "",
                                    crossDissolve: Bool = true,
                                    emojiOverlays: Bool = false,
                                    outputDir: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!,
                                    retryParams: AutoReelJobParams? = nil) async {
        let store = AutoReelsStore.shared
        let title = retryParams?.sourceTitle ?? videoURL.deletingPathExtension().lastPathComponent
        let single = retryParams?.singleClip ?? false

        let srcPath = videoURL.path
        func upd(_ progress: Double, _ msg: String, finished: Bool = false, error: String? = nil, out: URL? = nil) async {
            await MainActor.run {
                store.updateJob(AutoReelJob(id: jobID, title: title, progress: progress,
                                           statusMsg: msg, isFinished: finished, error: error, outputURL: out,
                                           sourceVideoPath: srcPath, retryParams: retryParams))
            }
        }

        // The free trial covers a set number of sermons
        let allowed = await MainActor.run { License.shared.allowSermon(srcPath) }
        guard allowed else { await upd(0, "Free trial used", finished: true, error: License.trialMessage); return }

        await upd(0.01, "Loading AI model…")

        do {
            let whisper = WhisperService.shared
            if !whisper.modelExists {
                await upd(0.01, "Downloading speech model (first time only, ~75 MB)…")
                try await whisper.downloadModel { p, msg in
                    Task { await upd(0.01 + p * 0.08, "Downloading model: \(Int(p * 100))%") }
                }
            } else if !whisper.isModelLoaded {
                await upd(0.02, "Loading speech model…")
                try await whisper.loadModel()
            }

            let svc = VideoExportService.shared

            // Audio-only files get a companion video, then go through the same steps as any video
            var sourceURL = videoURL
            if await AudioSource.needsVideo(videoURL) {
                await upd(0.03, "Preparing your audio…")
                sourceURL = try await AudioSource.video(for: videoURL) { p in
                    Task { await upd(0.03 + p * 0.07, "Preparing your audio: \(Int(p * 100))%") }
                }
            }

            let workingURL = await svc.convertHEVCIfNeeded(sourceURL) { msg in
                Task { await upd(0.10, msg) }
            }

            let allWords: [Word]
            if let cached = TranscriptCache.load(for: workingURL.path) {
                await upd(0.44, "Using saved transcript…")
                allWords = cached
            } else {
                await upd(0.12, "Transcribing audio…")
                allWords = try await whisper.transcribe(audioURL: workingURL) { p in
                    Task { await upd(0.12 + p * 0.33, "Transcribing: \(Int(p * 100))%") }
                }
                TranscriptCache.save(allWords, for: workingURL.path)
            }
            // A whole service: keep to the sermon
            var words = allWords
            if ContentKind.current == .sermon, SermonFinder.enabled {
                await upd(0.45, "Finding the sermon in the service…")
                let found = await SermonFinder.find(workingURL.path) { p in Task { await upd(0.45, "Finding the sermon in the service: \(Int(p * 100))%") } }
                words = SermonFinder.trim(allWords, to: found)
                if let found { await upd(0.45, "Sermon found at \(SermonFinder.label(found))") }
            }
            guard !words.isEmpty else {
                throw NSError(domain: "AutoClip", code: 3, userInfo: [NSLocalizedDescriptionKey: "No speech detected in video."])
            }

            try Task.checkCancellation()

            await upd(0.45, "Finding best moments…")
            let segments = svc.autoSegmentsFromWords(words)
            guard !segments.isEmpty else {
                throw NSError(domain: "AutoClip", code: 4, userInfo: [NSLocalizedDescriptionKey: "Not enough speech segments to build a clip."])
            }

            let totalSpeechDur = words.last.map { $0.endTime } ?? 0
            let autoReels: Int
            if desiredReelCount > 0 {
                autoReels = desiredReelCount
            } else {
                autoReels = max(1, min(10, Int((totalSpeechDur / max(15.0, targetDur * 0.8)).rounded())))
            }

            let hookPreview = segments.first.map {
                $0.words.prefix(7).map { $0.word }.joined(separator: " ")
            } ?? ""
            let finalReelTitle = hookPreview.count > 4 ? hookPreview : title

            await upd(0.49, "Preparing export…")


            var opts = VideoExportService.ExportOptions()
            opts.format = format; opts.burnCaptions = captions
            if captions && styleIdx < CaptionStyle.all.count { opts.captionStyle = CaptionStyle.all[styleIdx] }
            if captions {
                opts.captionLook = CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[min(styleIdx, CaptionStyle.all.count - 1)])
            }
            opts.topicKeywords = topic.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).lowercased() }
            opts.crossDissolve = crossDissolve
            opts.emojiOverlays = emojiOverlays

            // Always create multiple reels — count is user-specified or auto from video length
            let baseVariation = await MainActor.run { store.rerollVariation }
            var reelGroups: [[Clip]] = []
            var aiTitles: [String] = []
            var aiHooks: [String] = []
            var aiKeywords: [[String]] = []
            let kind = ContentKind.current
            // Story mode works on the full transcript, one sentence per line
            let storySentences = ReelDraft.sentences(from: words)
            var usedSentences = Set<Int>()
            var usedClipIDs: Set<UUID> = []
            for i in 0..<autoReels {
                await upd(0.40 + Double(i) / Double(autoReels) * 0.10,
                          "Selecting clips for clip \(i + 1) of \(autoReels)…")
                let localVariation = baseVariation + i + 1
                var reelClips: [Clip]
                if useAI && !apiKey.isEmpty {
                    await upd(0.40 + Double(i) / Double(autoReels) * 0.10,
                              "AI is writing the story for clip \(i + 1)…")
                    do {
                        let plan = try await LLMClipService.shared.composeStory(
                            sentences: storySentences.map { ($0.start, $0.end, $0.text) },
                            targetDuration: targetDur, topic: topic.isEmpty ? nil : topic,
                            avoid: usedSentences, reelNumber: i + 1, otherTitles: aiTitles,
                            single: single, kind: kind, provider: provider, apiKey: apiKey)
                        // Keep it near the target if the model overshoots
                        let ranges = ReelGenerator.fit(plan.ranges, to: targetDur, sentences: storySentences)
                        usedSentences.formUnion(ranges.flatMap { Array($0) })
                        reelClips = ranges.map { r in
                            let ws = storySentences[r].flatMap(\.words)
                            return Clip(id: UUID(), title: ws.prefix(8).map(\.word).joined(separator: " "),
                                        startTime: max(0, (ws.first?.startTime ?? 0) - 0.1),
                                        endTime: (ws.last?.endTime ?? 0) + 0.25,
                                        score: 0, scoreReason: "AI story", words: ws, isLiked: false,
                                        starRating: 0, captionStyleName: "Karaoke", aspectRatio: "9:16",
                                        notes: "", thumbnailData: nil)
                        }
                        aiTitles.append(plan.title)
                        aiHooks.append(plan.hook)
                        aiKeywords.append(plan.keywords)
                        await upd(0.40 + Double(i) / Double(autoReels) * 0.10,
                                  "AI built clip \(i + 1) ✓")
                    } catch {
                        // Surface the real error — don't silently fall back
                        throw NSError(domain: "AutoClip", code: 99, userInfo: [
                            NSLocalizedDescriptionKey: "AI clip selection failed for clip \(i + 1): \(error.localizedDescription)"
                        ])
                    }
                } else if single {
                    // One continuous moment, the best one the scorer finds that isn't used yet
                    guard let r = ReelGenerator.singleWindow(storySentences, segments: segments, target: targetDur,
                                                             avoid: usedSentences, rank: i == 0 ? baseVariation % 3 : 0)
                    else { break }
                    usedSentences.formUnion(r)
                    reelClips = ReelGenerator.clips(for: [r], in: storySentences, source: workingURL.path)
                } else {
                    let (hook, rest) = svc.selectHookAndClips(from: segments, targetDuration: targetDur,
                                                               variation: localVariation,
                                                               previouslyUsedIDs: usedClipIDs)
                    reelClips = hook.map { [$0] + rest } ?? rest
                }
                // AI story mode already decides the order (hook first, then the story)
                if let smode = storylineMode, !(useAI && !apiKey.isEmpty) { reelClips = smode.order(reelClips) }
                if !reelClips.isEmpty {
                    reelGroups.append(reelClips)
                    usedClipIDs.formUnion(reelClips.map { $0.id })
                }
            }
            guard !reelGroups.isEmpty else {
                throw NSError(domain: "AutoClip", code: 4, userInfo: [NSLocalizedDescriptionKey: "No clips could be selected."])
            }

            // Reels are saved as editable drafts — nothing is rendered until the user
            // picks which ones to export (and can trim / restyle them first).
            await upd(0.95, "Preparing \(reelGroups.count) clip\(reelGroups.count == 1 ? "" : "s") for review…")
            func snippetFrom(_ words: [Word], range: Range<Int>) -> String {
                let slice = Array(words)[range.clamped(to: 0..<words.count)]
                return slice.map { $0.word }.joined(separator: " ")
            }
            var perReelTitles: [String] = reelGroups.map { snippetFrom($0.first?.words ?? [], range: 0..<6) }
            for startOffset in [3, 6, 9] where Set(perReelTitles).count < perReelTitles.count {
                perReelTitles = reelGroups.enumerated().map { i, group in
                    let s = snippetFrom(group.first?.words ?? [], range: startOffset..<(startOffset + 6))
                    return s.isEmpty ? "Clip \(i + 1)" : s
                }
            }
            if Set(perReelTitles).count < perReelTitles.count {
                perReelTitles = perReelTitles.enumerated().map { "\($1) #\($0 + 1)" }
            }
            // Prefer the AI's titles when it wrote the story
            if aiTitles.count == perReelTitles.count {
                perReelTitles = zip(aiTitles, perReelTitles).map { $0.isEmpty ? $1 : $0 }
            }
            let look = captions ? (opts.captionLook ?? CaptionLook.load()) : nil
            let series = await MainActor.run {
                SeriesStore.shared.series(containing: workingURL.path) ?? SeriesStore.shared.series(containing: videoURL.path)
            }
            let motionDefault = UserDefaults.standard.string(forKey: "ar_motion") ?? ReelMotion.Style.both.rawValue
            let drafts = reelGroups.enumerated().map { i, group in
                var d = ReelDraft(title: perReelTitles[i], clips: group, sourceVideoPath: workingURL.path,
                                  formatRaw: format.rawValue, captions: captions, look: look,
                                  crossDissolve: crossDissolve, emojiOverlays: emojiOverlays,
                                  topicKeywords: opts.topicKeywords)
                if aiHooks.count == reelGroups.count, !aiHooks[i].isEmpty { d.hookText = aiHooks[i] }
                if aiKeywords.count == reelGroups.count, !aiKeywords[i].isEmpty { d.keywords = aiKeywords[i] }
                if !kind.usesScripture { d.verseCards = false }
                d.motion = motionDefault
                d.hookStyle = UserDefaults.standard.string(forKey: "ar_hookStyle")
                if let series { d.applySeries(series) }
                return d
            }
            let firstReelDur = drafts.first?.duration ?? 0
            let transcriptText = reelGroups.flatMap { $0.flatMap { $0.words.map(\.word) } }.joined(separator: " ")
            // Named after the video (its YouTube title, or the file's name); the card shows how many reels
            let reelLabel = retryParams?.sourceTitle ?? YTDLP.title(fromFile: videoURL)
            let record = AutoReelRecord(id: UUID(), title: reelLabel,
                                        path: workingURL.path, paths: [workingURL.path],
                                        format: fmtLabel(format), duration: firstReelDur,
                                        clipCount: reelGroups.reduce(0) { $0 + $1.count },
                                        dateCreated: Date().timeIntervalSince1970,
                                        transcript: transcriptText, reelTitles: perReelTitles,
                                        drafts: drafts)
            var rec = record
            rec.genParams = retryParams
            rec.sourceVideoPath = workingURL.path
            rec.contentKind = kind.rawValue
            let finalRecord = rec
            await MainActor.run {
                AutoReelsStore.shared.add(finalRecord)
                Task { await Notifier.reelsReady(finalRecord) }
                store.updateJob(AutoReelJob(id: jobID, title: retryParams?.sourceTitle ?? finalReelTitle, progress: 1.0,
                                           statusMsg: "\(drafts.count) clip\(drafts.count == 1 ? "" : "s") ready — open to review & export",
                                           isFinished: true, error: nil))
            }

        } catch is CancellationError {
            await upd(0, "Cancelled", finished: true, error: "Cancelled")
        } catch {
            await upd(0, "", finished: true, error: error.localizedDescription)
        }
    }

    static func fmtLabel(_ f: VideoExportService.ExportFormat) -> String {
        switch f {
        case .vertical9x16: return "9:16"
        case .square1x1:    return "1:1"
        case .portrait4x5:  return "4:5"
        case .original:     return "Original"
        case .horizontal16x9: return "16:9"
        }
    }
}
