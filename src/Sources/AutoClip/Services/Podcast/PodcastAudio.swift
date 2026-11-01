import AVFoundation
import AudioToolbox

/// The episode's sound, streamed through files so hour-long recordings don't fill memory:
/// cut the pauses and filler words (with tiny fades at each join) → voice isolation and
/// compression → even out the voices → bring it to podcast loudness → add intro, outro and
/// music bed → soft-limit. Then encode for podcast hosts, with chapters and cover art.
enum PodcastAudio {
    static let rate = 48_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// What the program file depends on, so it is only rebuilt when something changed.
    static func signature(_ e: PodcastEpisode) -> String {
        let s = e.settings
        let parts: [String] = [e.angles.first?.path ?? "", e.keptRanges.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ","),
                               "\(s.cleanVoice)\(s.strength)\(s.levelVoices)\(s.loudness)", s.introPath ?? "", s.outroPath ?? "",
                               s.musicBedPath ?? "", "\(s.musicVolume)\(s.introLead)\(s.outroTail)"]
        var h: UInt64 = 1469598103934665603
        for b in parts.joined(separator: "|").utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    /// Seconds of intro before the episode starts, and of outro after it ends.
    static func lead(_ s: PodcastSettings) -> Double { s.introPath != nil ? s.introLead : 0 }

    /// Builds (or reuses) the finished episode sound as a .caf in the episode folder.
    static func program(_ e: PodcastEpisode, progress: @escaping (String, Double) -> Void) async throws -> (url: URL, lead: Double, total: Double) {
        let sig = signature(e)
        let url = e.folder.appendingPathComponent("program-\(sig).caf")
        let infoURL = url.appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: infoURL),
           let info = try? JSONDecoder().decode([Double].self, from: data), info.count == 2 {
            return (url, info[0], info[1])
        }
        // Old programs are replaced
        for f in (try? FileManager.default.contentsOfDirectory(at: e.folder, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("program-") { try? FileManager.default.removeItem(at: f) }

        guard let source = e.angles.first?.path else { throw Failure(message: "This episode has no recording.") }
        let tmp = FileManager.default.temporaryDirectory
        let edited = tmp.appendingPathComponent("podcast-edit-\(UUID().uuidString).caf")
        let cleaned = tmp.appendingPathComponent("podcast-clean-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: edited); try? FileManager.default.removeItem(at: cleaned) }

        progress("Cutting pauses and filler words…", 0)
        let frames = try await cut(source, kept: e.keptRanges, to: edited) { progress("Cutting pauses and filler words…", $0 * 0.25) }
        var voice = edited, lag = 0
        if e.settings.cleanVoice || e.settings.levelVoices {
            progress("Cleaning up the sound…", 0.25)
            lag = try clean(edited, frames: frames, to: cleaned, settings: e.settings) { progress("Cleaning up the sound…", 0.25 + $0 * 0.45) }
            voice = cleaned
        }
        progress("Evening out the voices…", 0.7)
        let leveler = e.settings.levelVoices ? try levelerGains(voice, skip: lag, frames: frames) : nil
        progress("Setting the loudness…", 0.78)
        let loud = try loudness(voice, skip: lag, frames: frames, leveler: leveler)
        let gain = Float(pow(10, max(-20, min(20, e.settings.loudness - loud)) / 20))

        // Intro, outro and music bed
        let leadS = lead(e.settings)
        let intro = try e.settings.introPath.map { try decodeMusic(URL(fileURLWithPath: $0)) }
        let outro = try e.settings.outroPath.map { try decodeMusic(URL(fileURLWithPath: $0)) }
        let bed = try e.settings.musicBedPath.map { try decodeMusic(URL(fileURLWithPath: $0)) }
        let leadF = Int(leadS * rate)
        let tailF = outro.map { min($0[0].count, Int(e.settings.outroTail * rate)) } ?? 0
        let total = leadF + frames + tailF
        let speechEnd = Double(leadF + frames) / rate

        progress("Mixing…", 0.85)
        let reader = try AVAudioFile(forReading: voice)
        if lag > 0 { reader.framePosition = AVAudioFramePosition(lag) }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw Failure(message: "Not enough memory to mix the audio.")
        }
        var pos = 0, voiceRead = 0
        while pos < total {
            let n = min(chunk, total - pos)
            outBuf.frameLength = AVAudioFrameCount(n)
            let L = outBuf.floatChannelData![0], R = outBuf.floatChannelData![1]
            L.update(repeating: 0, count: n); R.update(repeating: 0, count: n)
            // Voice
            let vStart = max(pos, leadF), vEnd = min(pos + n, leadF + frames)
            if vEnd > vStart {
                let want = vEnd - vStart
                inBuf.frameLength = 0
                try reader.read(into: inBuf, frameCount: AVAudioFrameCount(want))
                let got = Int(inBuf.frameLength)
                let iL = inBuf.floatChannelData![0], iR = inBuf.floatChannelData![min(1, Int(inBuf.format.channelCount) - 1)]
                for k in 0..<got {
                    let g = gain * (leveler.map { levelAt($0, voiceRead + k) } ?? 1)
                    L[vStart - pos + k] = iL[k] * g
                    R[vStart - pos + k] = iR[k] * g
                }
                voiceRead += got
            }
            // Music
            for k in 0..<n {
                let f = pos + k, t = Double(f) / rate
                var l: Float = 0, r: Float = 0
                if let m = intro, f < m[0].count {
                    let g = introGain(t, lead: leadS, length: Double(m[0].count) / rate)
                    l += m[0][f] * g; r += m[1][f] * g
                }
                if let m = outro {
                    let start = max(0, speechEnd - 3)
                    let i = Int((t - start) * rate)
                    if i >= 0 && i < m[0].count {
                        let g = outroGain(t, start: start, speechEnd: speechEnd, end: Double(total) / rate)
                        l += m[0][i] * g; r += m[1][i] * g
                    }
                }
                if let m = bed, f >= leadF, f < leadF + frames {
                    let i = (f - leadF) % m[0].count
                    let fromStart = Double(f - leadF) / rate, toEnd = Double(leadF + frames - f) / rate
                    let g = Float(e.settings.musicVolume) * Float(min(1, fromStart / 2, toEnd / 2))
                    l += m[0][i] * g; r += m[1][i] * g
                }
                L[k] = softLimit(L[k] + l); R[k] = softLimit(R[k] + r)
            }
            try writer.write(from: outBuf)
            pos += n
            if (pos / chunk) % 8 == 0 { progress("Mixing…", 0.85 + 0.15 * Double(pos) / Double(total)) }
        }
        let info = [leadS, Double(total) / rate]
        try? JSONEncoder().encode(info).write(to: infoURL)
        return (url, leadS, Double(total) / rate)
    }

    @inline(__always) static func softLimit(_ x: Float) -> Float {
        let t: Float = 0.89, a = abs(x)                 // −1 dBFS
        return a > t ? (x < 0 ? -1 : 1) * (t + (1 - t) * tanh((a - t) / (1 - t))) : x
    }

    /// Intro: full until just before the first words, then under the voice, then fades away.
    static func introGain(_ t: Double, lead: Double, length: Double) -> Float {
        let duck = 0.16
        var g: Double
        if t < lead - 0.4 { g = 1 }
        else if t < lead + 1.0 { g = 1 - (1 - duck) * (t - (lead - 0.4)) / 1.4 }
        else { g = duck }
        let end = min(length, lead + 9)
        if t > end - 3 { g *= max(0, (end - t) / 3) }
        if t > length - 0.5 { g *= max(0, (length - t) / 0.5) }
        if t < 0.05 { g *= t / 0.05 }
        return Float(g)
    }

    /// Outro: comes in quietly under the last few seconds, rises after the last word, fades at the end.
    static func outroGain(_ t: Double, start: Double, speechEnd: Double, end: Double) -> Float {
        let duck = 0.16
        var g: Double
        if t < start + 1 { g = duck * max(0, (t - start)) }
        else if t < speechEnd { g = duck }
        else { g = min(1, duck + (1 - duck) * (t - speechEnd) / 1.5) }
        if t > end - 2.5 { g *= max(0, (end - t) / 2.5) }
        return Float(g)
    }

    // MARK: Cutting

    /// Streams the kept ranges of `path` into `url` (48 kHz stereo), fading 5 ms in and out at each
    /// join so cuts don't click. Returns the number of frames written.
    static func cut(_ path: String, kept: [ClosedRange<Double>], to url: URL, progress: @escaping (Double) -> Void) async throws -> Int {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure(message: "This recording has no sound.") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { throw Failure(message: reader.error?.localizedDescription ?? "Couldn't read the sound.") }
        let ranges = kept.map { (Int($0.lowerBound * rate), Int($0.upperBound * rate)) }
        let lastEnd = ranges.last?.1 ?? 1
        let writer = try FrameWriter(url)
        let fade = 240
        var g = 0, ri = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: len / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            let n = data.count / 2
            var k = 0
            while k < n && ri < ranges.count {
                let f = g + k
                let (s, e) = ranges[ri]
                if f >= e { ri += 1; continue }
                if f < s { k += min(n - k, s - f); continue }
                let fromS = f - s, toE = e - f
                let a: Float = fromS < fade && s > 0 ? Float(fromS) / Float(fade) : toE < fade ? Float(toE) / Float(fade) : 1
                writer.append(data[2 * k] * a, data[2 * k + 1] * a)
                k += 1
            }
            g += n
            if ri >= ranges.count { break }
            if g % (Int(rate) * 30) < n { progress(min(1, Double(g) / Double(lastEnd))) }
            try Task.checkCancellation()
        }
        reader.cancelReading()
        try writer.finish()
        return writer.written
    }

    /// Buffers frames and writes them in blocks.
    final class FrameWriter {
        let file: AVAudioFile
        let buf: AVAudioPCMBuffer
        var n = 0
        var written = 0
        init(_ url: URL) throws {
            file = try AVAudioFile(forWriting: url, settings: PodcastAudio.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            buf = AVAudioPCMBuffer(pcmFormat: PodcastAudio.format, frameCapacity: 65_536)!
        }
        @inline(__always) func append(_ l: Float, _ r: Float) {
            buf.floatChannelData![0][n] = l; buf.floatChannelData![1][n] = r
            n += 1
            if n == 65_536 { try? flush() }
        }
        func flush() throws {
            guard n > 0 else { return }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            written += n; n = 0
        }
        func finish() throws { try flush() }
    }

    // MARK: Clean-up (voice isolation + compression), streamed from disk

    private static func effect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }
    private static func set(_ u: AVAudioUnitEffect, _ id: AudioUnitParameterID, _ v: Float) {
        AudioUnitSetParameter(u.audioUnit, id, kAudioUnitScope_Global, 0, v, 0)
    }

    /// Runs `input` through the clean-up chain into `output`. Returns how many frames the
    /// output runs late (skip them when reading it back).
    static func clean(_ input: URL, frames: Int, to output: URL, settings s: PodcastSettings,
                      progress: @escaping (Double) -> Void) throws -> Int {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        engine.attach(player)
        var chain: [AVAudioNode] = [player]
        if s.cleanVoice {
            let hp = effect(kAudioUnitSubType_HighPassFilter)
            set(hp, kHipassParam_CutoffFrequency, 75)
            chain.append(hp)
            if AudioCleaner.hasVoiceIsolation {
                let iso = effect(0x766f6973)
                set(iso, 0, Float(max(0, min(1, s.strength)) * 100))
                set(iso, 1, 1)
                chain.append(iso)
            }
        }
        if s.levelVoices {
            let dyn = effect(kAudioUnitSubType_DynamicsProcessor)
            set(dyn, kDynamicsProcessorParam_Threshold, -24)
            set(dyn, kDynamicsProcessorParam_HeadRoom, 7)
            set(dyn, kDynamicsProcessorParam_ExpansionRatio, 1.5)
            set(dyn, kDynamicsProcessorParam_ExpansionThreshold, -58)
            set(dyn, kDynamicsProcessorParam_AttackTime, 0.004)
            set(dyn, kDynamicsProcessorParam_ReleaseTime, 0.2)
            chain.append(dyn)
        }
        for n in chain.dropFirst() { engine.attach(n) }
        for (a, b) in zip(chain, chain.dropFirst()) { engine.connect(a, to: b, format: format) }
        engine.connect(chain.last!, to: engine.mainMixerNode, format: format)
        var latency = 0.0
        for n in chain.dropFirst() { if let fx = n as? AVAudioUnitEffect { latency += fx.auAudioUnit.latency } }
        let tail = Int((latency * rate).rounded()) + Int(rate / 2)

        let file = try AVAudioFile(forReading: input)
        player.scheduleFile(file, at: nil, completionHandler: nil)
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tail)) {
            silence.frameLength = AVAudioFrameCount(tail)
            for c in 0..<2 { silence.floatChannelData![c].update(repeating: 0, count: tail) }
            player.scheduleBuffer(silence, completionHandler: nil)
        }
        try engine.start()
        player.play()
        let writer = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
        let total = frames + tail
        var rendered = 0
        while rendered < total {
            let n = AVAudioFrameCount(min(Int(maxFrames), total - rendered))
            let st = try engine.renderOffline(n, to: buf)
            if st == .error { throw Failure(message: "Sound clean-up failed while rendering.") }
            guard st == .success else { continue }
            try writer.write(from: buf)
            rendered += Int(buf.frameLength)
            if rendered % (Int(rate) * 60) < Int(maxFrames) { progress(Double(rendered) / Double(total)) }
        }
        engine.stop()
        // Measure the delay on the first minute
        let probe = min(frames, Int(rate * 60))
        let a = try readMono(input, count: probe), b = try readMono(output, count: probe + tail)
        return AudioCleaner.measureDelay(input: a, output: b, maxLag: tail)
    }

    static func readMono(_ url: URL, count: Int, from start: Int = 0) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        f.framePosition = AVAudioFramePosition(start)
        guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { return [] }
        try f.read(into: buf, frameCount: AVAudioFrameCount(count))
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        let L = buf.floatChannelData![0], R = buf.floatChannelData![min(1, ch - 1)]
        return (0..<n).map { (L[$0] + R[$0]) * 0.5 }
    }

    // MARK: Evening out voices

    /// Gain per half second (dB) that brings quiet stretches (a soft-spoken guest, someone
    /// leaning back) up to the typical speaking level and loud ones down, within limits.
    struct Leveler { var block: Int; var gains: [Float] }

    static func levelerGains(_ url: URL, skip: Int, frames: Int) throws -> Leveler {
        let block = Int(rate / 2)
        var levels: [Double] = []
        try stream(url, skip: skip, frames: frames, chunk: block * 64) { L, R, n in
            var i = 0
            while i < n {
                let e = min(n, i + block)
                var s = 0.0
                for k in i..<e { let m = Double(L[k] + R[k]) * 0.5; s += m * m }
                levels.append(10 * log10(s / Double(max(1, e - i)) + 1e-12))
                i = e
            }
        }
        let sorted = levels.sorted()
        guard !sorted.isEmpty else { return Leveler(block: block, gains: []) }
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let gate = max(-50, floor + 10)
        let speech = levels.filter { $0 > gate }.sorted()
        guard !speech.isEmpty else { return Leveler(block: block, gains: levels.map { _ in 0 }) }
        let target = speech[speech.count / 2]
        var gains: [Float] = []
        var last: Float = 0
        for i in levels.indices {
            let win = levels[max(0, i - 3)...min(levels.count - 1, i + 3)].filter { $0 > gate }
            if win.count >= 2 {
                let avg = win.reduce(0, +) / Double(win.count)
                last = Float(max(-6, min(8, target - avg)))
            }
            gains.append(last)
        }
        return Leveler(block: block, gains: gains)
    }

    @inline(__always) static func levelAt(_ l: Leveler, _ frame: Int) -> Float {
        guard !l.gains.isEmpty else { return 1 }
        let pos = Double(frame) / Double(l.block) - 0.5
        let i = max(0, min(l.gains.count - 1, Int(pos)))
        let j = min(l.gains.count - 1, i + 1)
        let f = Float(max(0, min(1, pos - Double(i))))
        let db = l.gains[i] * (1 - f) + l.gains[j] * f
        return pow(10, db / 20)
    }

    // MARK: Loudness (ITU-R BS.1770, gated)

    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    static func loudness(_ url: URL, skip: Int, frames: Int, leveler: Leveler?) throws -> Double {
        func kFilters() -> (Biquad, Biquad) {
            (Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585),
             Biquad(b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621))
        }
        var (l1, l2) = kFilters(), (r1, r2) = kFilters()
        let sub = Int(rate / 10)          // 100 ms
        var subs: [Double] = []
        var acc = 0.0, cnt = 0, frame = 0
        try stream(url, skip: skip, frames: frames, chunk: 65_536) { L, R, n in
            for k in 0..<n {
                let g = Double(leveler.map { levelAt($0, frame) } ?? 1)
                let a = l2.run(l1.run(Double(L[k]) * g)), b = r2.run(r1.run(Double(R[k]) * g))
                acc += a * a + b * b; cnt += 1; frame += 1
                if cnt == sub { subs.append(acc / Double(sub)); acc = 0; cnt = 0 }
            }
        }
        guard subs.count >= 4 else { return -23 }
        var blocks: [Double] = []
        for i in 0...(subs.count - 4) {
            let sum: Double = subs[i] + subs[i + 1] + subs[i + 2] + subs[i + 3]
            blocks.append(sum / 4)
        }
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(p + 1e-15) }
        let abs = blocks.filter { lufs($0) > -70 }
        guard !abs.isEmpty else { return -70 }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        return lufs(gated.reduce(0, +) / Double(max(1, gated.count)))
    }

    /// Reads `frames` frames of a file (after skipping `skip`) in chunks.
    static func stream(_ url: URL, skip: Int, frames: Int, chunk: Int,
                       _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) throws -> Void) throws {
        let f = try AVAudioFile(forReading: url)
        f.framePosition = AVAudioFramePosition(skip)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var left = frames
        while left > 0 {
            buf.frameLength = 0
            try f.read(into: buf, frameCount: AVAudioFrameCount(min(chunk, left)))
            let n = Int(buf.frameLength)
            if n == 0 { break }
            let ch = Int(buf.format.channelCount)
            try body(buf.floatChannelData![0], buf.floatChannelData![min(1, ch - 1)], n)
            left -= n
        }
    }

    // MARK: Music

    /// A music file at 48 kHz stereo, brought to a steady level (about −20 dBFS).
    static func decodeMusic(_ url: URL) throws -> [[Float]] {
        let f = try AVAudioFile(forReading: url)
        let inFmt = f.processingFormat
        let n = AVAudioFrameCount(f.length)
        guard n > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: n) else { throw Failure(message: "Couldn't read \(url.lastPathComponent).") }
        try f.read(into: inBuf)
        var buf = inBuf
        if inFmt.sampleRate != rate || inFmt.channelCount != 2 {
            guard let conv = AVAudioConverter(from: inFmt, to: format),
                  let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(n) * rate / inFmt.sampleRate) + 4096) else {
                throw Failure(message: "Couldn't convert \(url.lastPathComponent).")
            }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            buf = out
        }
        let len = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        var L = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: len))
        var R = Array(UnsafeBufferPointer(start: buf.floatChannelData![min(1, ch - 1)], count: len))
        let rms = sqrt(zip(L, R).reduce(0.0) { $0 + Double($1.0 * $1.0 + $1.1 * $1.1) / 2 } / Double(max(1, len)))
        let g = Float(rms > 0 ? pow(10, -20.0 / 20) / rms : 1)
        for i in 0..<len { L[i] *= g; R[i] *= g }
        return [L, R]
    }

    // MARK: Encoding for podcast hosts

    static func ffmpeg() -> String? {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    /// MP3 (192 kbps), M4A (AAC) or WAV, with title, chapters and cover art where the format allows.
    static func encode(_ program: URL, to out: URL, format fmt: String, title: String, artist: String?,
                       chapters: [(start: Double, title: String)], total: Double, cover: URL?) async throws {
        try? FileManager.default.removeItem(at: out)
        guard let ff = ffmpeg() else {
            try await encodeWithoutFFmpeg(program, to: out, format: fmt)
            return
        }
        func esc(_ s: String) -> String {
            var o = ""
            for c in s { if "=;#\\\n".contains(c) { o.append("\\") }; o.append(c) }
            return o
        }
        var meta = ";FFMETADATA1\ntitle=\(esc(title))\n"
        if let artist { meta += "artist=\(esc(artist))\nalbum_artist=\(esc(artist))\n" }
        meta += "genre=Podcast\n"
        let ch = chapters.sorted { $0.start < $1.start }
        for (i, c) in ch.enumerated() {
            let end = i + 1 < ch.count ? ch[i + 1].start : total
            guard end > c.start else { continue }
            meta += "\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(c.start * 1000))\nEND=\(Int(end * 1000))\ntitle=\(esc(c.title))\n"
        }
        let metaURL = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-meta-\(UUID().uuidString).txt")
        try meta.write(to: metaURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: metaURL) }

        var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", program.path, "-i", metaURL.path]
        let useCover = cover != nil && fmt != "wav"
        if let cover, useCover { args += ["-i", cover.path] }
        args += ["-map", "0:a", "-map_metadata", "1", "-map_chapters", "1"]
        if useCover { args += ["-map", "2:v", "-c:v", "mjpeg", "-vf", "scale='min(1400,iw)':-2", "-disposition:v", "attached_pic"] }
        switch fmt {
        case "wav": args += ["-c:a", "pcm_s16le"]
        case "m4a": args += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        default: args += ["-c:a", "libmp3lame", "-b:a", "192k", "-id3v2_version", "3"]
        }
        args.append(out.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        if p.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(message: "Couldn't save the audio: \(msg.suffix(200))")
        }
    }

    private static func encodeWithoutFFmpeg(_ program: URL, to out: URL, format fmt: String) async throws {
        if fmt == "wav" {
            let inF = try AVAudioFile(forReading: program)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            let outF = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: inF.processingFormat, frameCapacity: 65_536)!
            while inF.framePosition < inF.length {
                try inF.read(into: buf)
                try outF.write(from: buf)
            }
            return
        }
        // MP3 needs ffmpeg; without it, save AAC (.m4a), which every podcast host accepts
        let target = fmt == "mp3" ? out.deletingPathExtension().appendingPathExtension("m4a") : out
        guard let s = AVAssetExportSession(asset: AVURLAsset(url: program), presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure(message: "Couldn't save the audio.")
        }
        s.outputURL = target
        s.outputFileType = .m4a
        await s.export()
        if let err = s.error { throw err }
    }
}
