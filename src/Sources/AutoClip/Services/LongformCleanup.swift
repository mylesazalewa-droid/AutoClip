import Foundation
import AVFoundation

/// Tightens a whole video, not just a reel: cuts ums and uhs, stutters and false starts
/// ("I was going I was going to say…" keeps only the second try), and shortens long pauses.
/// Cuts only ever fall between words, so nothing anyone says is clipped.
enum LongformCleanup {
    struct Options: Equatable {
        var fillers = true
        var falseStarts = true
        var pauses = true
        /// Pauses longer than this are shortened…
        var maxPause = 0.8
        /// …to this
        var keepPause = 0.35
    }

    struct Plan {
        /// Parts of the source to keep, in order (seconds)
        var keep: [ClosedRange<Double>]
        var fillers = 0
        var falseStarts = 0
        var pauses = 0
        var duration: Double
        var removedSeconds: Double { duration - keep.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
        var cutCount: Int { max(0, keep.count - 1) }
    }

    private static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "mm", "ah", "ahh"]

    /// Little words people restart on ("I was— I was", "and the— and the")
    private static let restartWords: Set<String> = [
        "i", "i'm", "i've", "i'll", "you", "you're", "we", "we're", "he", "she", "it", "it's", "they", "they're",
        "the", "a", "an", "to", "and", "but", "or", "so", "in", "on", "of", "for", "at", "is", "was", "are", "were",
        "that", "that's", "this", "there", "there's", "if", "my", "your", "our", "his", "her", "their", "what", "when",
        "can", "will", "would", "do", "don't", "be", "have", "had", "just", "like", "because", "with", "not"]
    /// Doubled on purpose ("very very", "no no", "yes yes")
    private static let emphasisWords: Set<String> = ["very", "no", "yes", "so", "really", "many", "more", "now", "go", "come", "ha", "bye", "well"]

    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
    private static func endsClause(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).last.map { ",.!?;:—".contains($0) } ?? false
    }

    /// Which words to drop, and why.
    static func removals(_ words: [Word], _ o: Options) -> (ids: Set<UUID>, fillers: Int, falseStarts: Int) {
        var drop = Set<UUID>()
        var fillers = 0, falseStarts = 0
        let c = words.map { clean($0.word) }
        if o.fillers {
            for (i, w) in c.enumerated() where fillerWords.contains(w) { drop.insert(words[i].id); fillers += 1 }
        }
        if o.falseStarts {
            var i = 0
            while i < words.count {
                var matched = false
                // Said again straight away: keep the second try. Only short restarts made of
                // little words ("I was I was going", "it's it's") or a single stuttered word count,
                // so repetition for effect ("hurting her and hurting her", "over and over") stays.
                for len in stride(from: 3, through: 1, by: -1) where i + 2 * len <= words.count {
                    let a = Array(c[i..<(i + len)]), b = Array(c[(i + len)..<(i + 2 * len)])
                    guard a == b, !a.contains(""), !(a.count == 1 && fillerWords.contains(a[0])) else { continue }
                    if len > 1 && !a.allSatisfy({ restartWords.contains($0) }) { continue }
                    if len == 1 && emphasisWords.contains(a[0]) { continue }
                    // A third time is rhetoric, not a slip
                    if i + 3 * len <= words.count, Array(c[(i + 2 * len)..<(i + 3 * len)]) == a { continue }
                    if i >= len, Array(c[(i - len)..<i]) == a { continue }
                    // Punctuation anywhere inside means two separate phrases ("what do we do? We…")
                    if (i..<(i + 2 * len - 1)).contains(where: { endsClause(words[$0].word) }) { continue }
                    guard words[i + len].startTime - words[i + len - 1].endTime < (len == 1 ? 0.5 : 0.8) else { continue }
                    for k in i..<(i + len) where !drop.contains(words[k].id) { drop.insert(words[k].id) }
                    falseStarts += 1
                    i += len; matched = true
                    break
                }
                if !matched { i += 1 }
            }
        }
        return (drop, fillers, falseStarts)
    }

    static func plan(words: [Word], duration: Double, options o: Options) -> Plan {
        let sorted = words.sorted { $0.startTime < $1.startTime }
        let r = removals(sorted, o)
        var cuts: [ClosedRange<Double>] = []
        var pauses = 0
        var prevIndex = -1
        for (i, w) in sorted.enumerated() where !r.ids.contains(w.id) {
            defer { prevIndex = i }
            guard prevIndex >= 0 else { continue }
            let a = sorted[prevIndex]
            let removedBetween = i - prevIndex > 1
            let gap = w.startTime - a.endTime
            let target: Double
            if removedBetween { target = min(max(0.2, o.keepPause * 0.6), gap) }
            else if o.pauses && gap > o.maxPause { target = o.keepPause; pauses += 1 }
            else { continue }
            guard gap - target > 0.12 else { continue }
            cuts.append((a.endTime + target / 2)...(w.startTime - target / 2))
        }
        var keep: [ClosedRange<Double>] = []
        var t = 0.0
        for cut in cuts where cut.lowerBound > t {
            keep.append(t...cut.lowerBound)
            t = cut.upperBound
        }
        if duration > t { keep.append(t...duration) }
        return Plan(keep: keep.filter { $0.upperBound - $0.lowerBound > 0.04 }, fillers: r.fillers,
                    falseStarts: r.falseStarts, pauses: pauses, duration: duration)
    }

    /// Writes the cleaned video. Short audio fades at every cut stop clicks.
    static func export(source: URL, plan: Plan, to output: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let comp = AVMutableComposition()
        let vSrc = try await asset.loadTracks(withMediaType: .video).first
        let aSrc = try await asset.loadTracks(withMediaType: .audio).first
        let vTrack = vSrc == nil ? nil : comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTrack = aSrc == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        if let vSrc, let vTrack { vTrack.preferredTransform = try await vSrc.load(.preferredTransform) }
        var at = CMTime.zero
        var joints: [CMTime] = []
        for (i, r) in plan.keep.enumerated() {
            let range = CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600),
                                    end: CMTime(seconds: r.upperBound, preferredTimescale: 600))
            if let vSrc, let vTrack { try vTrack.insertTimeRange(range, of: vSrc, at: at) }
            if let aSrc, let aTrack { try aTrack.insertTimeRange(range, of: aSrc, at: at) }
            at = at + range.duration
            if i < plan.keep.count - 1 { joints.append(at) }
            if i % 50 == 0 { progress(0.05 * Double(i) / Double(max(1, plan.keep.count))) }
        }
        var mix: AVMutableAudioMix?
        if let aTrack, !joints.isEmpty {
            let p = AVMutableAudioMixInputParameters(track: aTrack)
            let fade = CMTime(seconds: 0.012, preferredTimescale: 600)
            for j in joints {
                p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: j - fade, duration: fade))
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: j, duration: fade))
            }
            let m = AVMutableAudioMix(); m.inputParameters = [p]; mix = m
        }
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "AutoClip", code: 60, userInfo: [NSLocalizedDescriptionKey: "Couldn't start the export."])
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.audioMix = mix
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in progress(0.05 + Double(session.progress) * 0.95) }
        RunLoop.main.add(timer, forMode: .common)
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        timer.invalidate()
        if let e = session.error { throw e }
        guard session.status == .completed else {
            throw NSError(domain: "AutoClip", code: 61, userInfo: [NSLocalizedDescriptionKey: "Export stopped."])
        }
        progress(1)
    }

    /// The cut list as text (source timestamps), saved next to the video.
    static func cutList(_ plan: Plan) -> String {
        func ts(_ t: Double) -> String {
            let i = Int(t); return String(format: "%d:%02d:%02d.%02d", i / 3600, i / 60 % 60, i % 60, Int((t - Double(i)) * 100))
        }
        var lines = ["Cuts made (times in the original video):"]
        for (a, b) in zip(plan.keep, plan.keep.dropFirst()) {
            lines.append("\(ts(a.upperBound)) – \(ts(b.lowerBound))  (\(String(format: "%.2f", b.lowerBound - a.upperBound))s)")
        }
        return lines.joined(separator: "\n")
    }
}
