import AVFoundation
import Accelerate

/// Listening to the voices themselves: telling speakers apart by the sound of their voice,
/// hearing the "um"s the transcript leaves out, and how loud each separate track is.
enum PodcastVoice {
    static let sr = 16_000.0
    /// 10 ms frames, 25 ms windows
    static let hop = 160
    static let win = 400
    static let frameS = 0.01
    static let nCoef = 13

    // MARK: Reading

    /// Pulls a recording as 16 kHz (or any rate) mono, in whatever amounts are asked for.
    final class Reader {
        private let reader: AVAssetReader
        private let out: AVAssetReaderOutput
        private var buf: [Float] = []
        private var pos = 0
        private(set) var done = false

        private init(_ reader: AVAssetReader, _ out: AVAssetReaderOutput) { self.reader = reader; self.out = out }

        /// nil when the file has no sound. Starts `from` seconds in.
        static func open(_ path: String, rate: Double = PodcastVoice.sr, from: Double = 0) async throws -> Reader? {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return nil }
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            reader.add(out)
            if from > 0 { reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48_000), duration: .positiveInfinity) }
            guard reader.startReading() else { throw PodcastAudio.Failure(message: reader.error?.localizedDescription ?? "Couldn't read the sound.") }
            return Reader(reader, out)
        }

        /// Up to `n` samples (fewer only at the end of the file).
        func read(_ n: Int) -> [Float] {
            while buf.count - pos < n && !done { pull() }
            let m = min(n, buf.count - pos)
            let r = Array(buf[pos..<pos + m])
            pos += m
            if pos > 1 << 20 { buf.removeFirst(pos); pos = 0 }
            return r
        }

        private func pull() {
            guard let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) else { done = true; return }
            let len = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: len / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            buf.append(contentsOf: data)
        }

        deinit { reader.cancelReading() }
    }

    // MARK: Frame features

    struct Features {
        /// Loudness per 10 ms frame (dB)
        var energy: [Float] = []
        /// `nCoef` voice-colour numbers (MFCCs) per frame, flattened; empty when not asked for
        var mfcc: [Float] = []
        /// How tuneful each frame is (0…1), only measured inside the ranges asked for
        var voicing: [Float] = []
        var count: Int { energy.count }
        func time(_ i: Int) -> Double { Double(i) * PodcastVoice.frameS + 0.0125 }
        func frame(_ t: Double) -> Int { max(0, min(count - 1, Int((t - 0.0125) / PodcastVoice.frameS))) }
    }

    /// Precomputed FFT, mel filters and DCT for the voice-colour numbers.
    private final class MFCC {
        let n = 512
        let log2n = vDSP_Length(9)
        let setup: FFTSetup
        let window: [Float]
        let mel: [Float]          // 26 × 257
        let dct: [Float]          // 13 × 26
        let nMel = 26

        init() {
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            window = vDSP.window(ofType: Float.self, usingSequence: .hamming, count: PodcastVoice.win, isHalfWindow: false)
            func hz2mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
            func mel2hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
            let size = 512, nMel = 26
            let bins = size / 2 + 1
            let lo = hz2mel(80), hi = hz2mel(7600)
            let pts = (0...(nMel + 1)).map { mel2hz(lo + (hi - lo) * Double($0) / Double(nMel + 1)) * Double(size) / PodcastVoice.sr }
            var mel = [Float](repeating: 0, count: nMel * bins)
            for m in 0..<nMel {
                let a = pts[m], b = pts[m + 1], c = pts[m + 2]
                for k in 0..<bins {
                    let f = Double(k)
                    let w = f < a || f > c ? 0 : f <= b ? (f - a) / max(1e-6, b - a) : (c - f) / max(1e-6, c - b)
                    mel[m * bins + k] = Float(w)
                }
            }
            self.mel = mel
            var dct = [Float](repeating: 0, count: PodcastVoice.nCoef * nMel)
            for i in 0..<PodcastVoice.nCoef {
                for j in 0..<nMel { dct[i * nMel + j] = Float(cos(Double.pi * Double(i) * (Double(j) + 0.5) / Double(nMel))) }
            }
            self.dct = dct
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        func coefficients(_ frame: UnsafeBufferPointer<Float>) -> [Float] {
            var x = [Float](repeating: 0, count: n)
            vDSP_vmul(frame.baseAddress!, 1, window, 1, &x, 1, vDSP_Length(PodcastVoice.win))
            var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
            let bins = n / 2 + 1
            var power = [Float](repeating: 0, count: bins)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    x.withUnsafeBufferPointer { xp in
                        xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    power[0] = rp[0] * rp[0]
                    power[n / 2] = ip[0] * ip[0]
                    for k in 1..<(n / 2) { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
                }
            }
            var melE = [Float](repeating: 0, count: nMel)
            vDSP_mmul(mel, 1, power, 1, &melE, 1, vDSP_Length(nMel), 1, vDSP_Length(bins))
            for j in 0..<nMel { melE[j] = log(melE[j] + 1e-6) }
            var out = [Float](repeating: 0, count: PodcastVoice.nCoef)
            vDSP_mmul(dct, 1, melE, 1, &out, 1, vDSP_Length(PodcastVoice.nCoef), 1, vDSP_Length(nMel))
            return out
        }
    }

    /// One pass over the recording: loudness every 10 ms, voice colour when `mfcc`, and how tuneful
    /// it is inside `voicingIn` (sorted source-time ranges).
    static func features(_ path: String, mfcc wantMFCC: Bool, voicingIn: [ClosedRange<Double>] = [],
                         duration: Double = 0, progress: ((Double) -> Void)? = nil) async throws -> Features {
        guard let r = try await Reader.open(path) else { return Features() }
        let mf = wantMFCC ? MFCC() : nil
        var f = Features()
        let need = win + 200               // room for the pitch search
        var pending: [Float] = []
        var off = 0, idx = 0, vi = 0
        let expected = max(1, Int(duration / frameS))
        while true {
            let chunk = r.read(Int(sr) * 4)
            pending.append(contentsOf: chunk)
            let ending = chunk.isEmpty
            while pending.count - off >= (ending ? win : need) {
                pending.withUnsafeBufferPointer { p in
                    let fr = UnsafeBufferPointer(rebasing: p[off..<off + win])
                    var ms: Float = 0
                    vDSP_measqv(fr.baseAddress!, 1, &ms, vDSP_Length(win))
                    f.energy.append(10 * log10(ms + 1e-10))
                    if let mf { f.mfcc.append(contentsOf: mf.coefficients(fr)) }
                    let t = Double(idx) * frameS + 0.0125
                    while vi < voicingIn.count && voicingIn[vi].upperBound < t { vi += 1 }
                    if vi < voicingIn.count, voicingIn[vi].contains(t), p.count - off >= need {
                        f.voicing.append(periodicity(UnsafeBufferPointer(rebasing: p[off..<off + need])))
                    } else { f.voicing.append(0) }
                }
                off += hop; idx += 1
            }
            if off > Int(sr) * 8 { pending.removeFirst(off); off = 0 }
            if idx % 6000 < 400 { progress?(min(1, Double(idx) / Double(expected))) }
            try Task.checkCancellation()
            if ending { break }
        }
        return f
    }

    /// Normalised autocorrelation peak for pitches 80–400 Hz: near 1 for a held vowel or hum,
    /// low for breath, clicks and noise.
    private static func periodicity(_ x: UnsafeBufferPointer<Float>) -> Float {
        let n = 320
        guard x.count >= n + 200 else { return 0 }
        var mean: Float = 0
        vDSP_meanv(x.baseAddress!, 1, &mean, vDSP_Length(n + 200))
        var y = [Float](repeating: 0, count: n + 200)
        var neg = -mean
        vDSP_vsadd(x.baseAddress!, 1, &neg, &y, 1, vDSP_Length(n + 200))
        var best: Float = 0
        y.withUnsafeBufferPointer { p in
            var e0: Float = 0
            vDSP_svesq(p.baseAddress!, 1, &e0, vDSP_Length(n))
            guard e0 > 1e-9 else { return }
            for lag in 40...200 {
                var dot: Float = 0, e1: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(n))
                vDSP_svesq(p.baseAddress! + lag, 1, &e1, vDSP_Length(n))
                if e1 > 1e-9 { best = max(best, dot / (e0 * e1).squareRoot()) }
            }
        }
        return best
    }

    static func percentile(_ v: [Float], _ p: Double) -> Float {
        guard !v.isEmpty else { return -100 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
    }

    // MARK: Hearing "um"s

    /// "um", "uh" and "er" sounds in the pauses between words: a steady, tuneful sound of
    /// 0.15–1.2 s that doesn't touch the words either side. The transcript usually leaves these out.
    static func fillers(words: [Word], features f: Features) -> [ClosedRange<Double>] {
        guard f.count > 100, !f.mfcc.isEmpty else { return [] }
        let sorted = words.sorted { $0.startTime < $1.startTime }
        // Typical speaking loudness and how fast the voice colour changes in speech
        var speechE: [Float] = [], speechFlux: [Float] = []
        for w in sorted.prefix(4000) {
            let a = f.frame(w.startTime), b = f.frame(w.endTime)
            guard b > a + 1 else { continue }
            for i in a..<b { speechE.append(f.energy[i]); speechFlux.append(flux(f, i)) }
        }
        let floor = percentile(f.energy, 0.1)
        let speech = percentile(speechE, 0.5)
        guard speech > floor + 15 else { return [] }
        let loudEnough = max(floor + 12, speech - 16)
        let typicalFlux = percentile(speechFlux, 0.5)
        var out: [ClosedRange<Double>] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let s = a.endTime + 0.1, e = b.startTime - 0.1
            guard e - s >= 0.2 else { continue }
            let i0 = f.frame(s), i1 = f.frame(e)
            var runStart: Int?, gap = 0
            func close(_ end: Int) {
                guard let rs = runStart else { return }
                runStart = nil
                let len = Double(end - rs) * frameS
                guard len >= 0.15 && len <= 1.2 else { return }
                var fl: Float = 0, vo: Float = 0
                for i in rs..<end { fl += flux(f, i); vo += f.voicing[i] }
                fl /= Float(end - rs); vo /= Float(end - rs)
                guard vo > 0.45, fl < typicalFlux * 1.3 else { return }
                // A real "um" sits in a pause: quiet on both sides of it. Music or noise under the
                // gap never goes quiet.
                let ga = f.frame(a.endTime), gb = f.frame(b.startTime)
                let quiet = floor + 6
                let before = rs > ga ? f.energy[ga..<rs].filter { $0 < quiet }.count : 0
                let after = gb > end ? f.energy[end..<gb].filter { $0 < quiet }.count : 0
                guard min(before, after) >= 4 || (max(before, after) >= 20 && min(before, after) >= 1) else { return }
                out.append(max(a.endTime + 0.02, f.time(rs) - 0.04)...min(b.startTime - 0.02, f.time(end) + 0.04))
            }
            for i in i0...max(i0, i1) {
                let on = f.energy[i] > loudEnough && f.voicing[i] > 0.3
                if on { if runStart == nil { runStart = i }; gap = 0 }
                else if runStart != nil { gap += 1; if gap > 3 { close(i - gap + 1); gap = 0 } }
            }
            close(i1 - gap)
        }
        return out
    }

    /// How much the voice colour changes from one frame to the next.
    static func flux(_ f: Features, _ i: Int) -> Float {
        guard i > 0, (i + 1) * nCoef <= f.mfcc.count else { return 0 }
        var d: Float = 0
        for k in 1..<nCoef { let x = f.mfcc[i * nCoef + k] - f.mfcc[(i - 1) * nCoef + k]; d += x * x }
        return d.squareRoot()
    }

    /// The gaps worth listening to for "um"s (so tunefulness is only measured there).
    static func gaps(_ words: [Word]) -> [ClosedRange<Double>] {
        let s = words.sorted { $0.startTime < $1.startTime }
        return zip(s, s.dropFirst()).compactMap { a, b in b.startTime - a.endTime >= 0.4 ? (a.endTime + 0.05)...(b.startTime - 0.05) : nil }
    }

    // MARK: Telling voices apart

    /// A stretch of speech (from the transcript) and its voice fingerprint.
    struct Segment: Codable { var start: Double; var end: Double; var vec: [Float] }

    /// Splits the speech into short stretches at pauses (≤ 2.5 s, where speakers usually change)
    /// and fingerprints each by the average and spread of its voice colour.
    static func segments(words: [Word], features f: Features) -> [Segment] {
        guard !f.mfcc.isEmpty else { return [] }
        let sorted = words.sorted { $0.startTime < $1.startTime }
        var chunks: [(Double, Double)] = []
        var cs: Double?, ce = 0.0
        for w in sorted {
            if let s = cs, w.startTime - ce > 0.3 || w.endTime - s > 2.5 { chunks.append((s, ce)); cs = nil }
            if cs == nil { cs = w.startTime }
            ce = max(ce, w.endTime)
        }
        if let s = cs { chunks.append((s, ce)) }
        let floor = percentile(f.energy, 0.1)
        var speechE: [Float] = []
        for w in sorted.prefix(3000) { let a = f.frame(w.startTime), b = f.frame(w.endTime); if b > a { speechE += f.energy[a..<b] } }
        let gate = max(floor + 10, percentile(speechE, 0.5) - 12)
        let d = nCoef - 1
        return chunks.compactMap { s, e in
            let a = f.frame(s), b = f.frame(e)
            var frames: [Int] = []
            if b > a { for i in a..<b where f.energy[i] > gate { frames.append(i) } }
            guard frames.count >= 25 else { return nil }
            var mean = [Float](repeating: 0, count: d), sq = [Float](repeating: 0, count: d)
            for i in frames { for k in 0..<d { let x = f.mfcc[i * nCoef + k + 1]; mean[k] += x; sq[k] += x * x } }
            let n = Float(frames.count)
            var vec = mean.map { $0 / n }
            for k in 0..<d { vec.append(max(0, sq[k] / n - vec[k] * vec[k]).squareRoot()) }
            return Segment(start: s, end: e, vec: vec)
        }
    }

    /// Groups the stretches by voice. `k` = how many speakers, or nil to work it out (1–4).
    /// Returns one label per segment.
    static func cluster(_ segs: [Segment], k fixed: Int?) -> [Int] {
        guard segs.count >= 6 else { return segs.map { _ in 0 } }
        // Put every number on the same scale
        let dim = segs[0].vec.count
        var mu = [Float](repeating: 0, count: dim), sd = [Float](repeating: 0, count: dim)
        for s in segs { for j in 0..<dim { mu[j] += s.vec[j] } }
        mu = mu.map { $0 / Float(segs.count) }
        for s in segs { for j in 0..<dim { let x = s.vec[j] - mu[j]; sd[j] += x * x } }
        sd = sd.map { max(1e-4, ($0 / Float(segs.count)).squareRoot()) }
        // The averages say more about who is talking than the spreads; the first number (how
        // bright the sound is) shifts with the mic and with loudness, so it counts for less
        let weight = (0..<dim).map { $0 == 0 ? Float(0.3) : $0 < dim / 2 ? Float(1) : Float(0.5) }
        let x = segs.map { s in (0..<dim).map { (s.vec[$0] - mu[$0]) / sd[$0] * weight[$0] } }

        if let fixed { return fixed <= 1 ? x.map { _ in 0 } : kmeans(x, k: fixed).labels }
        var best = (k: 1, score: Float(0.0), labels: x.map { _ in 0 })
        for k in 2...4 where x.count >= k * 6 {
            let r = kmeans(x, k: k)
            // Ignore a "speaker" who only has a few stray stretches
            let sizes = (0..<k).map { c in r.labels.filter { $0 == c }.count }
            guard Double(sizes.min() ?? 0) >= Double(x.count) * 0.06 else { continue }
            let s = silhouette(x, r.labels, k: k)
            if s > best.score + (k > 2 ? 0.02 : 0) { best = (k, s, r.labels) }
        }
        // Weak separation means one voice whose colour shifts (a speaker getting louder, a mic change)
        return best.score >= 0.14 ? best.labels : x.map { _ in 0 }
    }

    static func kmeans(_ x: [[Float]], k: Int) -> (labels: [Int], centers: [[Float]]) {
        var rng = PodcastAnalysis.SplitMix(seed: UInt64(x.count * 7919 + k))
        func dist(_ a: [Float], _ b: [Float]) -> Float { var d: Float = 0; for i in a.indices { let t = a[i] - b[i]; d += t * t }; return d }
        var bestLabels: [Int] = [], bestCenters: [[Float]] = [], bestCost = Float.infinity
        for _ in 0..<8 {
            // k-means++ start
            var centers = [x[Int.random(in: 0..<x.count, using: &rng)]]
            while centers.count < k {
                let d = x.map { p in centers.map { dist(p, $0) }.min()! }
                let total = d.reduce(0, +)
                var r = Float.random(in: 0..<max(total, 1e-6), using: &rng)
                var pick = 0
                for (i, v) in d.enumerated() { r -= v; if r <= 0 { pick = i; break } }
                centers.append(x[pick])
            }
            var labels = [Int](repeating: 0, count: x.count)
            for _ in 0..<40 {
                var changed = false
                for (i, p) in x.enumerated() {
                    var bi = 0, bd = Float.infinity
                    for (c, ctr) in centers.enumerated() { let d = dist(p, ctr); if d < bd { bd = d; bi = c } }
                    if labels[i] != bi { labels[i] = bi; changed = true }
                }
                for c in 0..<k {
                    let members = x.indices.filter { labels[$0] == c }
                    guard !members.isEmpty else { continue }
                    var m = [Float](repeating: 0, count: x[0].count)
                    for i in members { for j in m.indices { m[j] += x[i][j] } }
                    centers[c] = m.map { $0 / Float(members.count) }
                }
                if !changed { break }
            }
            var cost: Float = 0
            for (i, p) in x.enumerated() { cost += dist(p, centers[labels[i]]) }
            if cost < bestCost { bestCost = cost; bestLabels = labels; bestCenters = centers }
        }
        return (bestLabels, bestCenters)
    }

    /// How cleanly the groups separate (−1…1), on up to 1200 stretches.
    static func silhouette(_ x: [[Float]], _ labels: [Int], k: Int) -> Float {
        let step = max(1, x.count / 1200)
        let idx = Array(stride(from: 0, to: x.count, by: step))
        func dist(_ a: [Float], _ b: [Float]) -> Float { var d: Float = 0; for i in a.indices { let t = a[i] - b[i]; d += t * t }; return d.squareRoot() }
        var total: Float = 0
        for i in idx {
            var sum = [Float](repeating: 0, count: k), cnt = [Int](repeating: 0, count: k)
            for j in idx where j != i { sum[labels[j]] += dist(x[i], x[j]); cnt[labels[j]] += 1 }
            let own = labels[i]
            guard cnt[own] > 0 else { continue }
            let a = sum[own] / Float(cnt[own])
            let b = (0..<k).filter { $0 != own && cnt[$0] > 0 }.map { sum[$0] / Float(cnt[$0]) }.min() ?? a
            total += (b - a) / max(a, b, 1e-6)
        }
        return total / Float(idx.count)
    }

    /// Per-person "is talking" series at `step` seconds on the source clock, from labelled stretches.
    static func series(_ segs: [Segment], labels: [Int], people: Int, duration: Double, step: Double = 0.4) -> [[Double]] {
        let n = Int(duration / step) + 1
        var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: people)
        for (s, l) in zip(segs, labels) where l < people {
            let a = max(0, Int(s.start / step)), b = min(n - 1, Int(s.end / step))
            if b >= a { for i in a...b { out[l][i] = 1 } }
        }
        return out
    }

    // MARK: Separate tracks (one per person)

    /// How loud one person's own track is every 10 ms, on the first file's clock.
    static func trackEnergy(_ path: String, offset: Double, duration: Double, progress: ((Double) -> Void)? = nil) async throws -> [Float] {
        let f = try await features(path, mfcc: false, duration: duration, progress: progress)
        let lead = Int((offset / frameS).rounded())
        if lead >= 0 { return [Float](repeating: -100, count: lead) + f.energy }
        return Array(f.energy.dropFirst(-lead))
    }

    /// Talking activity per person (≈1 when they speak normally) at 0.4 s steps, from each
    /// person's own microphone. Someone else's voice leaking into a mic is much quieter, so the
    /// loudest track, relative to how that person usually sounds, is the one talking.
    static func trackActivity(_ energy: [[Float]], step: Double = 0.4) -> [[Double]] {
        let per = Int(step / frameS)
        return energy.map { e in
            let floor = percentile(e.filter { $0 > -99 }, 0.1)
            let loud = percentile(e.filter { $0 > -99 }, 0.9)
            let span = max(6, loud - floor)
            let n = e.count / per + 1
            return (0..<n).map { i in
                let a = i * per, b = min(e.count, a + per)
                guard b > a else { return 0 }
                let m = e[a..<b].max() ?? -100
                return Double(max(0, (m - floor - 6) / (span - 6)))
            }
        }
    }

    /// Mixes the separate tracks into one mono file on the first file's clock: each voice brought
    /// to the same level, and each track turned down 10 dB while that person isn't talking (so
    /// their room noise and the other voices leaking in don't double up).
    static func mix(paths: [String], offsets: [Double], energy: [[Float]], duration: Double, to url: URL,
                    progress: ((Double) -> Void)? = nil) async throws {
        let rate = 48_000.0
        let per = Int(rate * frameS)
        var readers: [Reader?] = []
        var lead: [Int] = []
        for (p, o) in zip(paths, offsets) {
            readers.append(try await Reader.open(p, rate: rate, from: max(0, -o)))
            lead.append(max(0, Int((o * rate).rounded())))
        }
        // Level each voice to −20 dBFS and work out when each track is "open"
        let gains: [Float] = energy.map { e in
            let speech = e.filter { $0 > percentile(e.filter { $0 > -99 }, 0.6) }
            let level = percentile(speech, 0.5)
            return pow(10, max(-12, min(18, -20 - level)) / 20)
        }
        let open: [[Bool]] = energy.map { e in
            let floor = percentile(e.filter { $0 > -99 }, 0.1)
            let loud = percentile(e.filter { $0 > -99 }, 0.9)
            let th = floor + max(6, (loud - floor) * 0.35)
            return e.map { $0 > th }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(duration * rate)
        let chunk = per * 400
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var env = [Float](repeating: 0.32, count: paths.count)
        let attack: Float = 1 - exp(-1 / Float(rate * 0.01)), release: Float = 1 - exp(-1 / Float(rate * 0.35))
        var pos = 0
        while pos < total {
            let n = min(chunk, total - pos)
            buf.frameLength = AVAudioFrameCount(n)
            let out = buf.floatChannelData![0]
            out.update(repeating: 0, count: n)
            for k in readers.indices {
                guard let r = readers[k] else { continue }
                // Silence before this track starts
                let skip = max(0, min(n, lead[k] - pos))
                let samples = skip < n ? r.read(n - skip) : []
                let g = gains[k]
                for (j, x) in samples.enumerated() {
                    let i = pos + skip + j
                    let fi = i / per
                    let target: Float = fi < open[k].count && open[k][fi] ? 1 : 0.32
                    env[k] += (target - env[k]) * (target > env[k] ? attack : release)
                    out[skip + j] += x * g * env[k]
                }
            }
            for j in 0..<n { out[j] = PodcastAudio.softLimit(out[j]) }
            try writer.write(from: buf)
            pos += n
            progress?(Double(pos) / Double(max(1, total)))
            try Task.checkCancellation()
        }
    }
}
