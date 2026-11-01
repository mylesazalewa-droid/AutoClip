import AVFoundation
import Vision
import AppKit

/// Reading a recording: lining camera angles up by their sound, finding faces and who is talking,
/// the pauses and filler words to cut, and the camera plan.
enum PodcastAnalysis {

    // MARK: Faces

    /// One face in one frame, 0…1 with a top-left origin; `mouth` = how open (relative to face height).
    struct Face: Codable { var x: Float; var y: Float; var w: Float; var h: Float; var mouth: Float? }
    /// Faces sampled every `step` seconds on that file's own clock.
    struct FaceTrack: Codable { var step: Double; var frames: [[Face]] }

    static let faceStep = 0.4

    /// Samples the whole video for faces (cached in the episode folder).
    static func faces(path: String, cache: URL, progress: @escaping (Double) -> Void) async throws -> FaceTrack {
        if let data = try? Data(contentsOf: cache), let t = try? JSONDecoder().decode(FaceTrack.self, from: data) { return t }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let dur = CMTimeGetSeconds(try await asset.load(.duration))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 540)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        let n = max(1, Int(dur / faceStep))
        let times = (0..<n).map { CMTime(seconds: Double($0) * faceStep, preferredTimescale: 600) }
        var frames = [[Face]](repeating: [], count: n)
        var done = 0
        for await result in gen.images(for: times) {
            let i = Int((CMTimeGetSeconds(result.requestedTime) / faceStep).rounded())
            if let img = try? result.image, frames.indices.contains(i) { frames[i] = detect(img) }
            done += 1
            if done % 25 == 0 { progress(Double(done) / Double(n)) }
            try Task.checkCancellation()
        }
        let track = FaceTrack(step: faceStep, frames: frames)
        if let data = try? JSONEncoder().encode(track) { try? data.write(to: cache) }
        return track
    }

    private static func detect(_ image: CGImage) -> [Face] {
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return (req.results ?? []).compactMap { f in
            let b = f.boundingBox
            guard b.height > 0.06 else { return nil }     // the back of the room, a screen or a false hit
            var mouth: Float?
            if let lips = f.landmarks?.innerLips?.normalizedPoints, lips.count > 2 {
                let ys = lips.map { Float($0.y) }
                mouth = ys.max()! - ys.min()!
            }
            return Face(x: Float(b.minX), y: Float(1 - b.maxY), w: Float(b.width), h: Float(b.height), mouth: mouth)
        }
    }

    // MARK: People and who is talking

    struct Cluster {
        var cx: Double
        var boxes: [[Double]] = []          // x, y, w, h
        var mouth: [Float?]
        var seen = 0
    }

    /// Links faces across frames into people (by horizontal position) and keeps the ones on screen
    /// for a good share of the recording.
    static func people(in track: FaceTrack) -> [Cluster] {
        let n = track.frames.count
        var clusters: [Cluster] = []
        for (i, faces) in track.frames.enumerated() {
            var used = Set<Int>()
            for f in faces.sorted(by: { $0.h > $1.h }) {
                let cx = Double(f.x + f.w / 2)
                let match = clusters.indices.filter { !used.contains($0) && abs(clusters[$0].cx - cx) < 0.1 }
                    .min { abs(clusters[$0].cx - cx) < abs(clusters[$1].cx - cx) }
                let k: Int
                if let match { k = match } else {
                    clusters.append(Cluster(cx: cx, mouth: Array(repeating: nil, count: n))); k = clusters.count - 1
                }
                used.insert(k)
                clusters[k].cx = clusters[k].cx * 0.9 + cx * 0.1
                clusters[k].seen += 1
                clusters[k].mouth[i] = f.mouth
                if clusters[k].boxes.count < 4000 { clusters[k].boxes.append([Double(f.x), Double(f.y), Double(f.w), Double(f.h)]) }
            }
        }
        return clusters.filter { $0.seen >= max(3, n / 7) }.sorted { $0.cx < $1.cx }
    }

    static func medianBox(_ boxes: [[Double]]) -> [Double] {
        (0..<4).map { k in let v = boxes.map { $0[k] }.sorted(); return v.isEmpty ? 0 : v[v.count / 2] }
    }

    /// How much each person's mouth is moving (spread of openness over ~1.6s), scaled so their own
    /// busy moments are about 1 — a far-away face and a close-up compare fairly.
    static func activity(_ mouth: [Float?]) -> [Double] {
        let n = mouth.count
        var raw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let win = mouth[max(0, i - 2)...min(n - 1, i + 2)].compactMap { $0 }
            guard win.count >= 3 else { continue }
            let mean: Float = win.reduce(0, +) / Float(win.count)
            var v: Float = 0
            for x in win { v += (x - mean) * (x - mean) }
            raw[i] = Double((v / Float(win.count)).squareRoot())
        }
        let busy = raw.filter { $0 > 0 }.sorted()
        let scale = busy.isEmpty ? 1 : max(0.004, busy[Int(Double(busy.count - 1) * 0.85)])
        return raw.map { $0 / scale }
    }

    /// Who is talking when, on the first file's clock. `speech` = spans where someone is speaking
    /// (from the transcript), so silence never triggers a switch.
    static func turns(activity: [(person: Int, angleOffset: Double, step: Double, values: [Double])],
                      duration: Double, speech: [ClosedRange<Double>]) -> [PodcastEpisode.Turn] {
        let ids = Array(Set(activity.map(\.person))).sorted()
        guard ids.count > 1 else {
            return ids.first.map { [PodcastEpisode.Turn(start: 0, end: duration, person: $0)] } ?? []
        }
        let step = 0.4
        let n = Int(duration / step) + 1
        func score(_ p: Int, _ t: Double) -> Double {
            activity.filter { $0.person == p }.map { a -> Double in
                let i = Int(((t - a.angleOffset) / a.step).rounded())
                return a.values.indices.contains(i) ? a.values[i] : 0
            }.max() ?? 0
        }
        var speechIdx = 0
        func speaking(_ t: Double) -> Bool {
            while speechIdx < speech.count && speech[speechIdx].upperBound < t { speechIdx += 1 }
            return speechIdx < speech.count && speech[speechIdx].contains(t)
        }
        var current = ids[0], challenger = -1, streak = 0
        var who = [Int](repeating: ids[0], count: n)
        // Start with whoever talks most in the first 10 seconds
        func opening(_ p: Int) -> Double {
            var s = 0.0
            for k in 0..<25 { s += score(p, Double(k) * step) }
            return s
        }
        current = ids.max { opening($0) < opening($1) } ?? ids[0]
        for i in 0..<n {
            let t = Double(i) * step
            if speaking(t) {
                let s = ids.map { ($0, score($0, t)) }
                if let best = s.max(by: { $0.1 < $1.1 }), best.0 != current,
                   best.1 > (s.first { $0.0 == current }?.1 ?? 0) * 1.3 + 0.08 {
                    streak = best.0 == challenger ? streak + 1 : 1
                    challenger = best.0
                    if streak >= 3 {            // leads for ~1.2s
                        for k in max(0, i - streak)..<i { who[k] = best.0 }
                        current = best.0; streak = 0; challenger = -1
                    }
                } else { streak = 0; challenger = -1 }
            }
            who[i] = current
        }
        var out: [PodcastEpisode.Turn] = []
        for i in 0..<n {
            let t = Double(i) * step
            if let last = out.last, last.person == who[i] { out[out.count - 1].end = min(duration, t + step) }
            else { out.append(.init(start: t, end: min(duration, t + step), person: who[i])) }
        }
        // Fold blips under a second into the turn before
        var merged: [PodcastEpisode.Turn] = []
        for t in out {
            if let last = merged.last, (t.end - t.start < 1.0 || last.person == t.person) {
                merged[merged.count - 1].end = t.end
            } else { merged.append(t) }
        }
        return merged
    }

    /// Pearson correlation of two activity series (for matching one person across camera angles).
    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 10 else { return 0 }
        let a = Array(a.prefix(n)), b = Array(b.prefix(n))
        let ma = a.reduce(0, +) / Double(n), mb = b.reduce(0, +) / Double(n)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<n { let x = a[i] - ma, y = b[i] - mb; sab += x * y; saa += x * x; sbb += y * y }
        return saa > 0 && sbb > 0 ? sab / sqrt(saa * sbb) : 0
    }

    // MARK: Lining up camera angles

    /// Loudness envelope (one value per `hop` seconds) of the first `limit` seconds.
    static func envelope(_ path: String, hop: Double, limit: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))
        guard reader.startReading() else { return [] }
        let per = Int(rate * hop)
        var env: [Float] = [], acc: Float = 0, count = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: len / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for x in data {
                acc += x * x; count += 1
                if count == per { env.append(log10(acc / Float(per) + 1e-9)); acc = 0; count = 0 }
            }
        }
        return env
    }

    /// Where `other` starts on `master`'s clock, found by matching their loudness envelopes:
    /// coarse (50 ms) over ±5 minutes, then fine (10 ms) around the best match.
    static func offset(of other: String, against master: String) async throws -> Double {
        func best(_ a: [Float], _ b: [Float], lags: ClosedRange<Int>) -> Int {
            func norm(_ x: [Float]) -> [Float] {
                let c = Float(max(1, x.count))
                let m: Float = x.reduce(0, +) / c
                var v: Float = 0
                for y in x { v += (y - m) * (y - m) }
                let d: Float = max((v / c).squareRoot(), 1e-6)
                return x.map { ($0 - m) / d }
            }
            let a = norm(a), b = norm(b)
            var bestLag = 0, bestScore = -Float.infinity
            for lag in lags {
                var s: Float = 0, k = 0
                // b[i] lines up with a[i + lag]
                var i = max(0, -lag)
                while i < b.count && i + lag < a.count { s += a[i + lag] * b[i]; k += 1; i += 1 }
                if k > 200, s / Float(k) > bestScore { bestScore = s / Float(k); bestLag = lag }
            }
            return bestLag
        }
        let a = try await envelope(master, hop: 0.05, limit: 900)
        let b = try await envelope(other, hop: 0.05, limit: 600)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let coarse = best(a, b, lags: -6000...6000)
        let fa = try await envelope(master, hop: 0.01, limit: 900)
        let fb = try await envelope(other, hop: 0.01, limit: 600)
        let fine = best(fa, fb, lags: (coarse * 5 - 10)...(coarse * 5 + 10))
        return Double(fine) * 0.01
    }

    // MARK: The edit

    static let fillerSounds: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "ah", "ahh", "er", "erm", "hmm", "mm", "mmm"]

    static func isFiller(_ w: Word) -> Bool {
        fillerSounds.contains(w.word.lowercased().filter(\.isLetter))
    }

    /// Long pauses shortened to `maxPause` and "um"/"uh" sounds removed. Earlier choices to keep
    /// a cut are remembered.
    static func cuts(words: [Word], duration: Double, settings: PodcastSettings,
                     previous: [PodcastEpisode.Cut]) -> [PodcastEpisode.Cut] {
        var out: [PodcastEpisode.Cut] = []
        let real = words.filter { !(settings.removeFillers && isFiller($0)) }.sorted { $0.startTime < $1.startTime }
        let fillers = settings.removeFillers ? words.filter(isFiller) : []
        let keep = settings.maxPause
        func pause(_ s: Double, _ e: Double) {
            guard settings.tightenPauses, e - s > keep + 0.15 else { return }
            out.append(.init(start: s + keep / 2, end: e - keep / 2, kind: .pause,
                             label: String(format: "%.1fs pause", e - s)))
        }
        // Silence before the first word and after the last
        if let first = real.first, first.startTime > 1.0 { out.append(.init(start: 0, end: first.startTime - 0.3, kind: .pause, label: "Silence at the start")) }
        var fi = 0
        for (a, b) in zip(real, real.dropFirst()) {
            let gapS = a.endTime, gapE = b.startTime
            var inGap: [Word] = []
            while fi < fillers.count && fillers[fi].startTime < gapE {
                if fillers[fi].startTime >= gapS - 0.05 { inGap.append(fillers[fi]) }
                fi += 1
            }
            if let f0 = inGap.first, let f1 = inGap.last {
                let cs = max(gapS + 0.03, f0.startTime - 0.04), ce = min(gapE - 0.03, f1.endTime + 0.04)
                if ce > cs + 0.08 {
                    let label = inGap.map { $0.word.lowercased().filter(\.isLetter) }.joined(separator: " ")
                    out.append(.init(start: cs, end: ce, kind: .filler, label: "“\(label)”"))
                    pause(gapS, cs); pause(ce, gapE)
                    continue
                }
            }
            pause(gapS, gapE)
        }
        if let last = real.last, duration - last.endTime > 1.5 {
            out.append(.init(start: last.endTime + 0.5, end: duration, kind: .pause, label: "Silence at the end"))
        }
        // Keep what the user switched off before
        let off = Set(previous.filter { !$0.enabled }.map { "\(Int($0.start * 10))-\($0.kind.rawValue)" })
        let manual = previous.filter { $0.kind == .manual }
        for i in out.indices where off.contains("\(Int(out[i].start * 10))-\(out[i].kind.rawValue)") { out[i].enabled = false }
        return (out + manual).sorted { $0.start < $1.start }
    }

    // MARK: The camera plan

    /// Plans the shots: close-ups on whoever is talking, the wide shot for quick back-and-forth,
    /// and (with one camera) extra "angles" made by zooming in. Cuts land just before a new
    /// speaker's first word or at the end of a sentence.
    static func planShots(_ e: PodcastEpisode, words: [Word]) -> [PodcastEpisode.Shot] {
        let d = e.duration
        guard d > 0, !e.isAudioOnly else { return [] }
        let style = e.settings.cameraStyle
        let minShot = style == "calm" ? 4.0 : style == "lively" ? 1.8 : 2.6
        let maxHold = style == "calm" ? 30.0 : style == "lively" ? 9.0 : 16.0
        let zoom = e.settings.zoomShots
        var rng = SplitMix(seed: e.id.utf8.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1) })

        // Sentence ends: good places to change shot without a speaker change
        let sentenceEnds = words.filter { $0.word.hasSuffix(".") || $0.word.hasSuffix("?") || $0.word.hasSuffix("!") }.map(\.endTime)
        func snapToSentence(_ t: Double, within w: Double) -> Double {
            sentenceEnds.min { abs($0 - t) < abs($1 - t) }.flatMap { abs($0 - t) <= w ? $0 + 0.1 : nil } ?? t
        }
        let wordStarts = words.map(\.startTime)
        func snapToWord(_ t: Double) -> Double {
            guard let s = wordStarts.min(by: { abs($0 - t) < abs($1 - t) }), abs(s - t) < 0.8 else { return t }
            return max(0, s - 0.12)
        }

        // Which angle shows everyone (the wide), and each person's best angle for a close-up
        let wideAngle = (0..<e.angles.count).max { a, b in
            e.people.filter { $0.angle == a }.count < e.people.filter { $0.angle == b }.count
        } ?? 0
        func closeAngle(_ p: PodcastEpisode.Person) -> (angle: Int, real: Bool) {
            if let other = p.otherAngles.keys.sorted().first { return (other, true) }
            if p.angle != wideAngle || e.people.filter({ $0.angle == p.angle }).count == 1 && e.angles.count > 1 { return (p.angle, true) }
            return (p.angle, false)
        }
        func closeShot(_ pid: Int, _ s: Double, _ t: Double, punch: Bool = false) -> PodcastEpisode.Shot {
            guard let p = e.person(pid) else { return .init(start: s, end: t, angle: wideAngle, person: nil) }
            let (angle, real) = closeAngle(p)
            if real { return .init(start: s, end: t, angle: angle, person: pid, zoom: punch && zoom ? 1.3 : 1) }
            if zoom { return .init(start: s, end: t, angle: angle, person: pid, zoom: punch ? 1.35 : 1) }
            return .init(start: s, end: t, angle: wideAngle, person: nil)
        }
        func wide(_ s: Double, _ t: Double, punch: Bool = false) -> PodcastEpisode.Shot {
            .init(start: s, end: t, angle: wideAngle, person: nil, zoom: punch && zoom ? 1.25 : 1)
        }

        var shots: [PodcastEpisode.Shot] = []

        if e.people.count <= 1 {
            // One person (or nobody found): alternate a medium and a tighter shot at sentence ends
            let pid = e.people.first?.id
            var t = 0.0, tight = false
            while t < d {
                let len = Double.random(in: maxHold * 0.5...maxHold, using: &rng)
                var end = min(d, snapToSentence(t + len, within: 3))
                if end - t < minShot { end = min(d, t + minShot) }
                if d - end < minShot { end = d }
                if !zoom { shots.append(wide(t, end)) }
                else if let pid { shots.append(tight ? closeShot(pid, t, end) : wide(t, end)) }
                else { shots.append(wide(t, end, punch: tight)) }
                tight.toggle()
                t = end
            }
            return merge(shots)
        }

        // Two or more people
        let opener = min(d, 4.0)
        shots.append(wide(0, opener))
        var t = opener
        var turns = e.turns.filter { $0.end > opener }
        if turns.isEmpty { turns = [.init(start: opener, end: d, person: e.people[0].id)] }
        var i = 0
        while i < turns.count {
            let turn = turns[i]
            let start = t
            // A run of short turns → stay wide for the exchange
            var j = i
            while j < turns.count && turns[j].end - turns[j].start < minShot + 1 { j += 1 }
            if j - i >= 2 {
                let end = j < turns.count ? snapToWord(turns[j].start) : d
                if end > start { shots.append(wide(start, end)) ; t = end }
                i = j
                continue
            }
            let end = i + 1 < turns.count ? max(start + 0.5, snapToWord(turns[i + 1].start)) : d
            // Long turns get variety: punch in, or a reaction from the wide
            var s = start, punch = false
            while end - s > maxHold * 1.3 {
                let split = snapToSentence(s + Double.random(in: maxHold * 0.6...maxHold, using: &rng), within: 3)
                guard split > s + minShot, split < end - minShot else { break }
                if !punch && Double.random(in: 0...1, using: &rng) < 0.3 {
                    let w = min(split + Double.random(in: 3...5, using: &rng), end - minShot)
                    shots.append(closeShot(turn.person, s, split))
                    shots.append(wide(split, w))
                    s = w
                } else {
                    shots.append(closeShot(turn.person, s, split, punch: punch))
                    s = split
                }
                punch.toggle()
            }
            if end > s { shots.append(closeShot(turn.person, s, end, punch: punch && end - s > minShot * 2)) }
            t = end
            i += 1
        }
        if let last = shots.last, last.end < d { shots[shots.count - 1].end = d }
        return merge(shots.filter { $0.end > $0.start })
    }

    /// Joins neighbouring shots that frame the same thing, and folds slivers into the shot before.
    static func merge(_ shots: [PodcastEpisode.Shot]) -> [PodcastEpisode.Shot] {
        var out: [PodcastEpisode.Shot] = []
        for s in shots {
            if let last = out.last, (last.angle == s.angle && last.person == s.person && last.zoom == s.zoom) || s.end - s.start < 0.8 {
                out[out.count - 1].end = s.end
            } else { out.append(s) }
        }
        return out
    }

    /// Small seeded random numbers, so the same episode always gets the same plan.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
