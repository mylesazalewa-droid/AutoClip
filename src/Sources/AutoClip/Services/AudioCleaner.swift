import AVFoundation

/// How a reel's sound is cleaned up on export. Optional on drafts so older reels still decode.
struct AudioSettings: Codable, Equatable {
    /// Apple's voice isolation: removes room echo, hum, crowd and background noise
    var cleanVoice = true
    /// 0 – 1: how much of the isolated voice replaces the original sound
    var strength = 0.85
    /// Even out loud and quiet moments, then bring the whole reel to a steady volume
    var levelVoice = true
    /// Optional background music, ducked under speech
    var musicPath: String?
    /// Music volume while someone is talking (it rises a little in pauses)
    var musicVolume = 0.12

    var isActive: Bool { cleanVoice || levelVoice || musicPath != nil }
    var musicName: String? { musicPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } }

    private static let key = "ar_audioSettings"
    static func load() -> AudioSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AudioSettings.self, from: data)
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Offline audio clean-up for exports: high-pass → voice isolation → compressor,
/// then loudness normalising and a soft limiter. Runs on the stitched reel's audio only.
enum AudioCleaner {
    static let sampleRate = 48_000.0

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Renders the cleaned audio of `asset` (all its audio tracks mixed) into a temporary .caf file.
    static func cleanedAudio(of asset: AVAsset, settings: AudioSettings) async throws -> URL {
        let input = try await readPCM(asset)
        var out = settings.cleanVoice || settings.levelVoice ? try process(input, settings: settings) : input
        if settings.levelVoice { normalize(&out) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoclip-audio-\(UUID().uuidString).caf")
        try write(out, to: url)
        return url
    }

    // MARK: Reading

    private static var format: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    /// Whole audio as two Float channels at 48 kHz.
    static func readPCM(_ asset: AVAsset) async throws -> [[Float]] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure(message: "This video has no sound to clean up.") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw Failure(message: reader.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        var left: [Float] = [], right: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            left.reserveCapacity(left.count + data.count / 2)
            right.reserveCapacity(right.count + data.count / 2)
            for i in stride(from: 0, to: data.count - 1, by: 2) { left.append(data[i]); right.append(data[i + 1]) }
        }
        if reader.status == .failed {
            throw Failure(message: reader.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        return [left, right]
    }

    // MARK: Effects chain

    private static func effect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }

    private static func set(_ unit: AVAudioUnitEffect, _ id: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, value, 0)
    }

    /// True when this Mac has Apple's voice isolation audio unit (macOS 14+).
    static var hasVoiceIsolation: Bool {
        var d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766f6973,
                                          componentManufacturer: kAudioUnitManufacturer_Apple,
                                          componentFlags: 0, componentFlagsMask: 0)
        return AudioComponentFindNext(nil, &d) != nil
    }

    static func process(_ input: [[Float]], settings: AudioSettings) throws -> [[Float]] {
        let frames = input[0].count
        guard frames > 0 else { return input }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        engine.attach(player)

        var chain: [AVAudioNode] = [player]
        var latency = 0.0

        if settings.cleanVoice {
            // Rumble, stage thumps and mains hum fundamentals
            let hp = effect(kAudioUnitSubType_HighPassFilter)
            set(hp, kHipassParam_CutoffFrequency, 80)
            chain.append(hp)
            if hasVoiceIsolation {
                let iso = effect(0x766f6973)          // AUSoundIsolation
                set(iso, 0, Float(max(0, min(1, settings.strength)) * 100))   // wet/dry %
                set(iso, 1, 1)                        // isolate voice
                chain.append(iso)
            }
        }
        if settings.levelVoice {
            let dyn = effect(kAudioUnitSubType_DynamicsProcessor)
            set(dyn, kDynamicsProcessorParam_Threshold, -26)
            set(dyn, kDynamicsProcessorParam_HeadRoom, 8)
            set(dyn, kDynamicsProcessorParam_ExpansionRatio, 1.5)
            set(dyn, kDynamicsProcessorParam_ExpansionThreshold, -60)
            set(dyn, kDynamicsProcessorParam_AttackTime, 0.004)
            set(dyn, kDynamicsProcessorParam_ReleaseTime, 0.18)
            chain.append(dyn)
        }
        for n in chain.dropFirst() { engine.attach(n) }
        for (a, b) in zip(chain, chain.dropFirst()) { engine.connect(a, to: b, format: format) }
        engine.connect(chain.last!, to: engine.mainMixerNode, format: format)
        for n in chain.dropFirst() {
            if let fx = n as? AVAudioUnitEffect { latency += fx.auAudioUnit.latency }
        }

        // Input buffer + a tail of silence so effect latency doesn't cut the ending.
        // Voice isolation under-reports its delay, so we also allow for up to 0.5s and measure it.
        let latencyFrames = Int((latency * sampleRate).rounded()) + Int(sampleRate / 2)
        let total = frames + latencyFrames
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else {
            throw Failure(message: "Not enough memory to process the audio.")
        }
        buf.frameLength = AVAudioFrameCount(total)
        for ch in 0..<2 {
            let dst = buf.floatChannelData![ch]
            input[ch].withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frames) }
            (dst + frames).update(repeating: 0, count: latencyFrames)
        }
        player.scheduleBuffer(buf, completionHandler: nil)
        try engine.start()
        player.play()

        var out: [[Float]] = [[], []]
        out[0].reserveCapacity(total); out[1].reserveCapacity(total)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw Failure(message: "Not enough memory to process the audio.")
        }
        var rendered = 0
        while rendered < total {
            let n = AVAudioFrameCount(min(Int(maxFrames), total - rendered))
            let status = try engine.renderOffline(n, to: chunk)
            guard status == .success else {
                if status == .error { throw Failure(message: "Audio clean-up failed while rendering.") }
                continue
            }
            for ch in 0..<2 {
                out[ch].append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![ch], count: Int(chunk.frameLength)))
            }
            rendered += Int(chunk.frameLength)
        }
        engine.stop()
        // Drop the measured delay so sound stays in sync with the picture
        let lag = measureDelay(input: input[0], output: out[0], maxLag: latencyFrames)
        return out.map { ch in
            var a = Array(ch[min(lag, ch.count)..<min(ch.count, lag + frames)])
            if a.count < frames { a += [Float](repeating: 0, count: frames - a.count) }
            return a
        }
    }

    /// How many samples later `output` is than `input`: cross-correlates loudness envelopes,
    /// first coarsely (10 ms), then finely (1 ms) around the best match.
    static func measureDelay(input: [Float], output: [Float], maxLag: Int) -> Int {
        func envelope(_ x: [Float], _ block: Int) -> [Double] {
            stride(from: 0, to: x.count - block, by: block).map { i in
                x[i..<i + block].reduce(0.0) { $0 + Double(abs($1)) }
            }
        }
        func best(_ block: Int, _ range: ClosedRange<Int>) -> Int {
            let ei = envelope(input, block), eo = envelope(output, block)
            var bestLag = range.lowerBound, bestScore = -Double.infinity
            for lag in range {
                var s = 0.0
                var i = 0
                while i < ei.count && i + lag < eo.count {
                    if i + lag >= 0 { s += ei[i] * eo[i + lag] }
                    i += 1
                }
                if s > bestScore { bestScore = s; bestLag = lag }
            }
            return bestLag
        }
        let coarse = best(480, 0...(maxLag / 480))
        let fine = best(48, max(0, coarse * 10 - 10)...(coarse * 10 + 10))
        return max(0, min(maxLag, fine * 48))
    }

    // MARK: Loudness

    /// Bring speech to about -16 LUFS-ish (−18 dBFS gated RMS) and soft-limit peaks at −1 dBFS.
    static func normalize(_ ch: inout [[Float]]) {
        let frames = ch[0].count
        guard frames > 0 else { return }
        let block = Int(sampleRate * 0.05)
        var powers: [Double] = []
        var i = 0
        while i < frames {
            let e = min(frames, i + block)
            var sum = 0.0
            for k in i..<e { let m = Double(ch[0][k] + ch[1][k]) * 0.5; sum += m * m }
            powers.append(sum / Double(e - i))
            i = e
        }
        // Gate out silence (below −50 dBFS) so pauses don't drag the average down
        let gate = pow(10.0, -50.0 / 10)
        let speech = powers.filter { $0 > gate }
        guard !speech.isEmpty else { return }
        let rms = sqrt(speech.reduce(0, +) / Double(speech.count))
        let target = pow(10.0, -18.0 / 20)
        let gain = Float(max(0.25, min(8, target / rms)))
        let t: Float = 0.89        // −1 dBFS
        for c in 0..<2 {
            for k in 0..<frames {
                var x = ch[c][k] * gain
                let a = abs(x)
                if a > t { x = (x < 0 ? -1 : 1) * (t + (1 - t) * tanh((a - t) / (1 - t))) }
                ch[c][k] = x
            }
        }
    }

    // MARK: Writing

    static func write(_ ch: [[Float]], to url: URL) throws {
        let frames = ch[0].count
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let step = 65_536
        var i = 0
        while i < frames {
            let n = min(step, frames - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<2 { ch[c].withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress! + i, count: n) } }
            try file.write(from: buf)
            i += n
        }
    }

    // MARK: Background music

    /// Adds `musicURL` (looped) under the reel and ducks it while words are spoken.
    /// Returns the audio mix to hand to the export session.
    static func addMusic(_ musicURL: URL, to composition: AVMutableComposition, duration: Double,
                         words: [Word], volume: Double) async throws -> AVAudioMix? {
        let music = AVURLAsset(url: musicURL)
        guard let src = try await music.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let musicDur = CMTimeGetSeconds(try await music.load(.duration))
        guard musicDur > 1 else { return nil }
        var at = 0.0
        while at < duration - 0.05 {
            let len = min(musicDur, duration - at)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: len, preferredTimescale: 600)),
                                      of: src, at: CMTime(seconds: at, preferredTimescale: 600))
            at += len
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        let under = Float(max(0, min(1, volume)))
        let gap = min(1, under * 2.5)                // louder in pauses longer than ~0.8s
        let ramp = 0.35
        func t(_ s: Double) -> CMTime { CMTime(seconds: max(0, min(duration, s)), preferredTimescale: 600) }

        // Speech spans: words merged across short breaths
        var spans: [(Double, Double)] = []
        for w in words.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = spans.last, w.startTime - last.1 < 0.8 { spans[spans.count - 1].1 = max(last.1, w.endTime) }
            else { spans.append((w.startTime, w.endTime)) }
        }
        // Fade in, then alternate between "under speech" and "in the gap" levels
        var level: Float = 0
        var cursor = 0.0
        func rampTo(_ v: Float, at s: Double, over d: Double) {
            let s0 = max(cursor, s), s1 = min(duration, s0 + d)
            guard s1 > s0 else { return }
            params.setVolumeRamp(fromStartVolume: level, toEndVolume: v, timeRange: CMTimeRange(start: t(s0), end: t(s1)))
            level = v; cursor = s1
        }
        rampTo(spans.first.map { $0.0 < 1.0 } ?? false ? under : gap, at: 0, over: 1.0)
        for (s, e) in spans {
            if level != under { rampTo(under, at: s - ramp, over: ramp) }
            if e + ramp * 2 < duration { rampTo(gap, at: e + 0.1, over: ramp) }
        }
        rampTo(0, at: duration - 1.5, over: 1.5)        // fade out at the end
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
