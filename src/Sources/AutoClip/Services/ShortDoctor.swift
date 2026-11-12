import Foundation
import AVFoundation
import AppKit
import QuartzCore
import SoundAnalysis
import Vision

/// A review of one finished short, with fixes the user can switch on and off.
struct ShortReview: Codable, Equatable, Identifiable {
    var id: String { path }
    var path: String
    var title: String
    var duration: Double
    var createdAt = Date()
    var words: [Word]
    /// "cloud", "local" or "rules": what wrote the suggestions
    var engine = "rules"
    var summary = ""
    var hook: Hook?
    var order: [Int]?
    var orderWhy = ""
    var drops: [Drop] = []
    var ending: Ending?
    var hookScore = 0
    var clarityScore = 0
    var endingScore = 0
    var hasMusic = false
    var hasBurnedText = false
    var choices = Choices()
    /// Loudness every 0.1 second (dB), so only real silence gets cut
    var levels: [Float] = []
    /// Below this counts as silence
    var quietBelow: Float = -60
    /// Seconds with sound but no recognised words: singing, music or speech it couldn't make out
    var unheardSeconds = 0.0
    /// What happens in the picture. Reviews from before this existed get it when they're opened.
    var picture: ShortPicture?
    /// Other openings the AI liked
    var hookOptions: [Hook]?

    struct Hook: Codable, Equatable {
        var line: Int
        var why: String
        var text: String
        var scoreAfter: Int
    }
    struct Drop: Codable, Equatable, Identifiable {
        var id: Int { line }
        var line: Int
        var why: String
    }
    struct Ending: Codable, Equatable {
        /// A better last line, when one exists
        var line: Int?
        var note: String
    }
    struct Choices: Codable, Equatable {
        var useHook = true
        /// Play the hook up front and again where it was said
        var keepHookInPlace = false
        var useHookText = false
        var hookText = ""
        var useOrder = false
        var useEnding = false
        var dropped: Set<Int> = []
        var removeSilences = true
        var removeFillers = true
        var removeStutters = true
        /// Where stale stretches of picture get punch-in zooms
        var punchIns: [Double]?
    }

    var lines: [ReelDraft.Sentence] { ReelDraft.sentences(from: words) }

    /// True when nothing above the quiet level happens in this stretch.
    func isQuiet(_ from: Double, _ to: Double) -> Bool {
        guard !levels.isEmpty, to > from else { return levels.isEmpty ? false : true }
        let a = Int(from * 10), b = Int(to * 10)
        guard a < levels.count else { return true }
        let slice = levels[max(0, a)..<min(levels.count, max(a + 1, b))]
        // A stray click is fine, so it's most of the stretch that has to be quiet
        let loud = slice.filter { $0 > quietBelow }.count
        return Double(loud) / Double(max(1, slice.count)) < 0.12
    }
}

enum ShortDoctor {
    static let maxLength = 600.0
    private static let tightPause = 0.3
    private static func fail(_ m: String) -> NSError { NSError(domain: "AutoClip", code: 90, userInfo: [NSLocalizedDescriptionKey: m]) }

    // MARK: The edit

    /// The lines to play, in order, after the switched-on suggestions.
    static func lineOrder(_ r: ShortReview) -> [Int] {
        let c = r.choices
        let all = Array(r.lines.indices)
        var list = c.useOrder ? (r.order ?? all) : all
        list = list.filter { !c.dropped.contains($0) }
        if c.useEnding, let last = r.ending?.line, list.contains(last) {
            list.removeAll { $0 == last }
            list.append(last)
        }
        if c.useHook, let h = r.hook?.line, !c.dropped.contains(h) {
            if !c.keepHookInPlace { list.removeAll { $0 == h } }
            list.insert(h, at: 0)
        }
        return list
    }

    /// The parts of the source to play, in order. Cuts only fall between words.
    static func ranges(_ r: ShortReview) -> [ClosedRange<Double>] {
        let c = r.choices
        let lines = r.lines
        let cut = LongformCleanup.removals(r.words.sorted { $0.startTime < $1.startTime },
                                           .init(fillers: c.removeFillers, falseStarts: c.removeStutters, pauses: false)).ids
        let order = lineOrder(r).filter { lines.indices.contains($0) }
        let identity = order == Array(lines.indices)
        var out: [ClosedRange<Double>] = []
        var start: Double?, end = 0.0
        var previous: Word?
        func close() {
            if let s = start, end > s { out.append(s...end) }
            start = nil
        }
        for index in order {
            let spoken = lines[index].words.filter { !cut.contains($0.id) }
            for w in spoken {
                if let p = previous, start != nil, w.startTime >= p.endTime - 0.01,
                   wordsAdjacent(p, w, in: r.words, cut: cut), (!c.removeSilences || w.startTime - p.endTime <= tightPause || !r.isQuiet(p.endTime, w.startTime)) {
                    end = max(w.endTime + 0.06, end)
                } else {
                    close()
                    start = max(0, w.startTime - 0.05)
                    end = w.endTime + 0.06
                }
                previous = w
            }
        }
        close()
        // Nothing moved: the start and tail stay unless they're really silent
        if identity, c.dropped.isEmpty, let first = out.first, let last = out.last {
            if !c.removeSilences || !r.isQuiet(0, first.lowerBound) { out[0] = 0...out[0].upperBound }
            if !c.removeSilences || !r.isQuiet(last.upperBound, r.duration) { out[out.count - 1] = out[out.count - 1].lowerBound...max(last.upperBound, r.duration) }
        }
        return out.map { min($0.lowerBound, r.duration)...min($0.upperBound, r.duration) }.filter { $0.upperBound - $0.lowerBound > 0.05 }
    }

    private static func wordsAdjacent(_ a: Word, _ b: Word, in words: [Word], cut: Set<UUID>) -> Bool {
        // Nothing kept between them in the source. Words cut on purpose don't count; they force a cut.
        !words.contains { $0.startTime > a.startTime && $0.startTime < b.startTime }
    }

    static func length(of ranges: [ClosedRange<Double>]) -> Double { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    /// Pacing out of 100: how much of the time someone is talking, less filler words.
    static func pacingScore(words: [Word], ranges: [ClosedRange<Double>]) -> Int {
        let total = length(of: ranges)
        guard total > 0 else { return 0 }
        var speech = 0.0
        for w in words {
            for range in ranges where w.startTime < range.upperBound && w.endTime > range.lowerBound {
                speech += min(w.endTime, range.upperBound) - max(w.startTime, range.lowerBound)
            }
        }
        let kept = words.filter { w in ranges.contains { w.startTime >= $0.lowerBound && w.endTime <= $0.upperBound } }
        let fillers = FillerReport.find(in: kept).count
        let share = speech / total
        let score = 100 - max(0, 0.9 - share) * 220 - Double(fillers) / max(0.25, total / 60) * 4
        return Int(min(100, max(0, score)).rounded())
    }

    static func cuts(_ r: ShortReview) -> (fillers: Int, stutters: Int, silence: Double) {
        let sorted = r.words.sorted { $0.startTime < $1.startTime }
        let found = LongformCleanup.removals(sorted, .init(fillers: true, falseStarts: true, pauses: false))
        var silence = 0.0
        if let first = sorted.first, r.isQuiet(0, first.startTime) { silence += first.startTime }
        if let last = sorted.last, r.isQuiet(last.endTime, r.duration) { silence += max(0, r.duration - last.endTime) }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.startTime - a.endTime > tightPause && r.isQuiet(a.endTime, b.startTime) {
            silence += b.startTime - a.endTime - tightPause
        }
        return (found.fillers, found.falseStarts, silence)
    }

    /// Loudness every 0.1 second.
    private static func measureLevels(_ asset: AVAsset) async -> [Float] {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return [] }
        var levels: [Float] = []
        var sum: Float = 0, n = 0
        while let buffer = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for i in 0..<(length / 4) {
                    sum += samples[i] * samples[i]; n += 1
                    if n == 800 { levels.append(10 * log10(max(sum / 800, 1e-10))); sum = 0; n = 0 }
                }
            }
        }
        return levels
    }

    /// Sets the quiet level from how loud the speech is, removes "words" that land on silence
    /// (the speech model sometimes invents them), and finds sound with no words.
    static func applyLevels(_ levels: [Float], to r: inout ShortReview) {
        r.levels = levels
        guard !levels.isEmpty else { return }
        func level(_ w: Word) -> Float {
            let a = Int(w.startTime * 10), b = max(a + 1, Int(w.endTime * 10))
            guard a < levels.count else { return -100 }
            let slice = levels[max(0, a)..<min(levels.count, b)]
            return slice.max() ?? -100
        }
        let spoken = r.words.map(level).sorted()
        let speech = spoken.isEmpty ? -30 : spoken[spoken.count / 2]
        // Pauses sit well under speech; anything far below it can't be a spoken word at all
        r.quietBelow = max(-65, speech - 10)
        var kept = r.words.filter { level($0) > speech - 24 }
        // The speech model likes to invent these sign-offs at the very end of a recording
        let invented = ["see you next time", "thanks for watching", "thank you for watching", "please subscribe", "subscribe to"]
        if let last = ReelDraft.sentences(from: kept).last, last.words.count <= 8 {
            let text = spokenText(last).lowercased()
            if invented.contains(where: { text.contains($0) }) {
                let ids = Set(last.words.map(\.id))
                kept.removeAll { ids.contains($0.id) }
            }
        }
        if kept.count >= 4 { r.words = kept }
        var covered = Array(repeating: false, count: levels.count)
        for w in r.words {
            let a = max(0, Int(w.startTime * 10) - 3), b = min(levels.count, Int(w.endTime * 10) + 3)
            if a < b { for i in a..<b { covered[i] = true } }
        }
        r.unheardSeconds = Double(levels.indices.filter { !covered[$0] && levels[$0] > r.quietBelow }.count) / 10
    }

    /// Much of the video has sound that isn't recognised speech, so moving lines would lose it.
    static func mostlyUnheard(_ r: ShortReview) -> Bool { r.unheardSeconds > max(8, r.duration * 0.25) }

    // MARK: Reviewing

    static func review(path: String, allowCloud: Bool, progress: @escaping (Double, String) -> Void) async throws -> ShortReview {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 3 else { throw fail("This video is too short to review.") }
        guard duration <= maxLength else { throw fail("This is built for shorts of up to 10 minutes. Use Clips to cut shorts from longer videos.") }
        progress(0.08, "Listening to what's said…")
        let words = try await TranscriptCache.transcript(for: path) { _ in }
        guard words.count >= 4 else { throw fail("No speech found. This looks at what's said, so it needs someone talking.") }
        var r = ShortReview(path: path, title: YTDLP.title(fromFile: url), duration: duration, words: words)
        applyLevels(await measureLevels(asset), to: &r)
        guard r.lines.count >= 1 else { throw fail("No speech found. This looks at what's said, so it needs someone talking.") }
        progress(0.45, "Checking for music and burned-in captions…")
        r.hasMusic = await hasMusic(url)
        r.hasBurnedText = await hasBurnedCaptions(asset, duration: duration, words: words)
        progress(0.52, "Watching the picture…")
        r.picture = await ShortPicture.read(path: path, duration: duration)
        try Task.checkCancellation()
        progress(0.6, "Looking for a better hook…")
        applyRules(&r)

        // The written review: the user's cloud AI if they have a key, or on-device AI if it's on
        let provider = LLMClipService.chosenProvider
        var key = ""
        if allowCloud { key = await LLMClipService.shared.loadAPIKey(for: provider) ?? "" }
        let local = await LocalAI.ready()
        if !key.isEmpty || local {
            let plain = r.lines.enumerated().map { (index: $0, start: $1.start, text: spokenText($1)) }
            do {
                let idea = try await CostTag.$video.withValue(r.title) {
                    try await LLMClipService.shared.shortReview(lines: plain, duration: duration, provider: provider, apiKey: key)
                }
                apply(idea, to: &r, engine: key.isEmpty ? "local" : "cloud")
            } catch {
                if key.isEmpty == false { throw error }   // a cloud failure should be seen; local just falls back to the rules
            }
        }
        progress(1, "Done")
        return r
    }

    static func spokenText(_ s: ReelDraft.Sentence) -> String {
        s.text.replacingOccurrences(of: #"[♪♫♩♬]+|>>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Without AI: simple checks. These can suggest a hook and flag an ending, but never reorder.
    static func applyRules(_ r: inout ShortReview) {
        let lines = r.lines
        guard !lines.isEmpty else { return }
        func strength(_ s: ReelDraft.Sentence) -> Int { HookLab.strength(spokenText(s)) }
        let scores = lines.map(strength)
        let first = scores[0]
        let delay = lines[0].start
        r.hookScore = Int(min(100, max(10, 55 + Double(first) * 7 - delay * 12)).rounded())
        if let best = scores.indices.dropFirst().max(by: { scores[$0] < scores[$1] }), scores[best] >= first + 3 {
            let text = spokenText(lines[best])
            r.hook = .init(line: best, why: "This line stands on its own and grabs attention more than the current opening.",
                           text: text.split(separator: " ").prefix(8).joined(separator: " "),
                           scoreAfter: min(95, 55 + scores[best] * 7))
        }
        let minutes = max(0.25, r.duration / 60)
        let fillers = Double(FillerReport.find(in: r.words).count) / minutes
        let wpm = Double(r.words.count) / minutes
        r.clarityScore = Int(min(100, max(20, 88 - fillers * 5 - (wpm > 190 ? 10 : 0) - (wpm < 100 ? 10 : 0))).rounded())
        let last = spokenText(lines[lines.count - 1]).lowercased()
        let weak = ["thanks for watching", "so yeah", "anyway", "that's it", "okay", "thank you", "see you"].contains { last.contains($0) }
        r.endingScore = weak ? 45 : 65
        if weak {
            r.ending = .init(line: nil, note: "The last line trails off. Finish on your strongest thought, or link back to your opening.")
            if lines.count > 2 { r.drops = [.init(line: lines.count - 1, why: "It winds down rather than finishing strong.")] }
        }
        r.summary = "Checked the pacing and the opening with simple rules. Add an AI key or turn on on-device AI for a fuller review, including a better order."
        r.choices.useHook = r.hook != nil && !mostlyUnheard(r)
        r.choices.dropped = mostlyUnheard(r) ? [] : Set(r.drops.map(\.line))
    }

    /// Fills the review from what the AI said, keeping only what fits this video.
    static func apply(_ idea: LLMClipService.ShortIdea, to r: inout ShortReview, engine: String) {
        let count = r.lines.count
        r.engine = engine
        if !idea.summary.isEmpty { r.summary = idea.summary }
        r.hookScore = idea.hookScore ?? r.hookScore
        r.clarityScore = idea.clarityScore ?? r.clarityScore
        r.endingScore = idea.endingScore ?? r.endingScore
        r.hook = nil
        if let h = idea.hookLine, (1..<max(1, count)).contains(h) {
            let fallback = spokenText(r.lines[h]).split(separator: " ").prefix(8).joined(separator: " ")
            r.hook = .init(line: h, why: idea.hookWhy, text: idea.hookText.isEmpty ? fallback : idea.hookText, scoreAfter: idea.hookScoreAfter ?? min(95, r.hookScore + 15))
        }
        r.hookOptions = idea.hookOptions.filter { (1..<max(1, count)).contains($0.line) && $0.line != r.hook?.line }.map { o in
            .init(line: o.line, why: o.why, text: o.text.isEmpty ? spokenText(r.lines[o.line]).split(separator: " ").prefix(8).joined(separator: " ") : o.text, scoreAfter: o.scoreAfter ?? HookLab.wordScore(spokenText(r.lines[o.line])))
        }
        r.drops = idea.drops.filter { (0..<count).contains($0.line) }.map { .init(line: $0.line, why: $0.why) }
        // Only keep a new order that's really different, and never lose a line by accident
        r.order = nil
        var order: [Int] = []
        for i in idea.order where (0..<count).contains(i) && !order.contains(i) { order.append(i) }
        if !order.isEmpty {
            let dropped = Set(r.drops.map(\.line))
            for missing in 0..<count where !order.contains(missing) && !dropped.contains(missing) {
                if let at = order.firstIndex(of: missing - 1) { order.insert(missing, at: at + 1) } else { order.insert(missing, at: 0) }
            }
            let natural = (0..<count).filter { order.contains($0) }
            if order != natural { r.order = order; r.orderWhy = idea.orderWhy }
        }
        // "Finish on the line it already finishes on" isn't a change
        r.ending = idea.endingNote.isEmpty ? r.ending : .init(line: idea.endingLine.flatMap { (0..<(count - 1)).contains($0) ? $0 : nil }, note: idea.endingNote)
        // Suggestions start switched on, so "After" shows the full idea straight away
        var c = ShortReview.Choices()
        // The small on-device model is a rougher judge, and moving lines loses any sound without
        // words, so in those cases the bigger changes wait until they're switched on.
        let confident = engine == "cloud" && !mostlyUnheard(r)
        // A model that rates its own suggestion lower doesn't really believe in it
        let hookHelps = (r.hook?.scoreAfter ?? 0) > r.hookScore
        c.useHook = r.hook != nil && !mostlyUnheard(r) && hookHelps
        c.useOrder = r.order != nil && confident
        c.useEnding = r.ending?.line != nil && confident
        c.dropped = confident ? Set(r.drops.map(\.line)) : []
        r.choices = c
    }

    // MARK: Warnings

    private final class MusicListener: NSObject, SNResultsObserving {
        var total: Float = 0, count = 0
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let c = result as? SNClassificationResult else { return }
            total += Float(c.classification(forIdentifier: "music")?.confidence ?? 0)
            count += 1
        }
    }

    private static func hasMusic(_ url: URL) async -> Bool {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let listener = MusicListener()
                guard let analyzer = try? SNAudioFileAnalyzer(url: url), let request = try? SNClassifySoundRequest(classifierIdentifier: .version1),
                      (try? analyzer.add(request, withObserver: listener)) != nil else { c.resume(returning: false); return }
                analyzer.analyze()
                c.resume(returning: listener.count > 0 && listener.total / Float(listener.count) > 0.35)
            }
        }
    }

    /// Text on screen that matches what's being said at that moment.
    private static func hasBurnedCaptions(_ asset: AVAsset, duration: Double, words: [Word]) async -> Bool {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1080)
        func clean(_ s: String) -> String { s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
        var matches = 0
        let samples = 8
        for k in 0..<samples {
            let t = duration * (Double(k) + 0.5) / Double(samples)
            guard let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let found: [String] = await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .fast
                    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    c.resume(returning: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
                }
            }
            let shown = Set(found.flatMap { $0.split(separator: " ") }.map { clean(String($0)) }.filter { $0.count >= 3 })
            let said = Set(words.filter { abs($0.startTime - t) < 2 }.map { clean($0.word) })
            if shown.intersection(said).count >= 2 { matches += 1 }
        }
        return matches >= 3
    }

    // MARK: Playing and saving

    static func composition(_ r: ShortReview) async throws -> (AVComposition, AVAudioMix?, CGAffineTransform, CGSize) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: r.path))
        let comp = AVMutableComposition()
        guard let source = try await asset.loadTracks(withMediaType: .video).first,
              let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw fail("This file has no picture.")
        }
        let audioSource = try await asset.loadTracks(withMediaType: .audio).first
        let audio = audioSource == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let transform = try await source.load(.preferredTransform)
        video.preferredTransform = transform
        var at = CMTime.zero
        var joints: [CMTime] = []
        let list = ranges(r)
        guard !list.isEmpty else { throw fail("Every line is switched off.") }
        for (i, range) in list.enumerated() {
            let span = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600), end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
            try video.insertTimeRange(span, of: source, at: at)
            if let audio, let audioSource { try audio.insertTimeRange(span, of: audioSource, at: at) }
            at = at + span.duration
            if i < list.count - 1 { joints.append(at) }
        }
        var mix: AVMutableAudioMix?
        if let audio, !joints.isEmpty {
            // Short fades at each join stop clicks
            let p = AVMutableAudioMixInputParameters(track: audio)
            let fade = CMTime(seconds: 0.012, preferredTimescale: 600)
            for j in joints {
                p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: j - fade, duration: fade))
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: j, duration: fade))
            }
            let m = AVMutableAudioMix(); m.inputParameters = [p]; mix = m
        }
        return (comp, mix, transform, try await source.load(.naturalSize))
    }

    /// Saves the improved video. The original isn't touched.
    static func export(_ r: ShortReview, to url: URL, progress: @escaping (Double) -> Void) async throws {
        let (comp, mix, transform, natural) = try await composition(r)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw fail("Couldn't start saving.") }
        let zooms = try await zoomComposition(r, comp: comp, transform: transform, natural: natural)
        session.videoComposition = zooms
        let text = r.choices.hookText.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.choices.useHookText, !text.isEmpty, let track = try await comp.loadTracks(withMediaType: .video).first {
            let box = CGRect(origin: .zero, size: natural).applying(transform)
            let size = CGSize(width: abs(box.width), height: abs(box.height))
            let vc: AVMutableVideoComposition
            if let zooms { vc = zooms } else {
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layerInstruction.setTransform(transform.concatenating(.init(translationX: -box.minX, y: -box.minY)), at: .zero)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
                instruction.layerInstructions = [layerInstruction]
                vc = AVMutableVideoComposition()
                vc.renderSize = size
                vc.frameDuration = CMTime(value: 1, timescale: 30)
                vc.instructions = [instruction]
            }
            let parent = CALayer(), videoLayer = CALayer()
            parent.frame = CGRect(origin: .zero, size: size)
            parent.isGeometryFlipped = true
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            if let image = WorshipClips.captionImage(text, width: size.width * 0.88, fontSize: min(size.width, size.height) * 0.06) {
                let note = CALayer()
                note.contents = image
                note.contentsGravity = .resize
                let w = CGFloat(image.width) / 2, h = CGFloat(image.height) / 2
                note.frame = CGRect(x: (size.width - w) / 2, y: size.height * 0.14, width: w, height: h)
                note.opacity = 0
                // The first three seconds
                let overall = max(comp.duration.seconds, 0.1)
                let end = min(1, 3 / overall)
                let show = CAKeyframeAnimation(keyPath: "opacity")
                show.keyTimes = [0, NSNumber(value: max(0, end - 0.0001)), NSNumber(value: end), 1]
                show.values = [1.0, 1.0, 0.0, 0.0]
                show.duration = overall
                show.beginTime = AVCoreAnimationBeginTimeAtZero
                show.isRemovedOnCompletion = false
                show.fillMode = .both
                note.add(show, forKey: "opacity")
                parent.addSublayer(note)
            }
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
            session.videoComposition = vc
        }
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mp4
        session.audioMix = mix
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in progress(Double(session.progress)) }
        RunLoop.main.add(timer, forMode: .common)
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        timer.invalidate()
        if let e = session.error { throw e }
        guard session.status == .completed else { throw CancellationError() }
    }
}

// MARK: - Keeping reviews, and work that survives changing tabs

@MainActor
final class ShortDoctorModel: ObservableObject {
    static let shared = ShortDoctorModel()
    @Published var reviews: [ShortReview] = []
    @Published var currentPath: String?
    @Published var status: String?
    @Published var progress = 0.0
    @Published var error: String?
    private var job: Task<Void, Never>?

    private var dir: URL { AppPaths.folder("Shorts") }
    private func file(_ path: String) -> URL {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent(String(name.prefix(120)) + ".json")
    }

    var current: ShortReview? { reviews.first { $0.path == currentPath } }

    init() { load() }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        reviews = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(ShortReview.self, from: $0) } }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ r: ShortReview) {
        if let i = reviews.firstIndex(where: { $0.path == r.path }) { reviews[i] = r } else { reviews.insert(r, at: 0) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: file(r.path)) }
    }

    func delete(_ r: ShortReview) {
        try? FileManager.default.removeItem(at: file(r.path))
        reviews.removeAll { $0.path == r.path }
        if currentPath == r.path { currentPath = nil }
    }

    func start(_ url: URL) {
        error = nil
        if reviews.contains(where: { $0.path == url.path }) { currentPath = url.path; return }
        status = "Getting started…"; progress = 0
        job = Task {
            do {
                let r = try await ShortDoctor.review(path: url.path, allowCloud: true) { p, msg in
                    Task { @MainActor in self.progress = p; self.status = msg }
                }
                try Task.checkCancellation()
                save(r)
                currentPath = r.path
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
            }
            status = nil
        }
    }

    func cancel() { job?.cancel(); job = nil; status = nil }
}
