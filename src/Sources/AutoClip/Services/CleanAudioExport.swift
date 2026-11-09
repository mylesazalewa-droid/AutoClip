import AVFoundation

/// A clean, levelled audio file of part of a recording, for podcast hosts (Spotify, Apple Podcasts,
/// Buzzsprout…). Uses the same clean-up as clip exports, but streams in pieces so an hour-long
/// sermon never has to fit in memory at once.
enum CleanAudioExport {
    enum Format: String, CaseIterable, Identifiable {
        case wav, m4a
        var id: String { rawValue }
        var label: String { self == .wav ? "WAV (best quality)" : "M4A (smaller file)" }
        var ext: String { rawValue }
    }

    struct Options: Equatable {
        var cleanVoice = true
        var strength = 0.85
        var levelVoice = true
        var mono = true
        var fades = true
        var format: Format = .wav
    }

    static let rate = AudioCleaner.sampleRate
    private static let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

    /// Renders `start…end` of `path` to `dest`. `progress` gets 0…1.
    static func export(path: String, start: Double, end: Double, options o: Options, to dest: URL,
                       progress: @escaping (Double, String) -> Void) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioCleaner.Failure(message: "This recording has no sound.") }
        guard end - start >= 1 else { throw AudioCleaner.Failure(message: "Choose at least a second of audio.") }

        let pass1 = FileManager.default.temporaryDirectory.appendingPathComponent("autoclip-clean-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: pass1) }

        try await Task.detached(priority: .userInitiated) {
            let stats = try clean(asset: asset, tracks: tracks, start: start, end: end, options: o, to: pass1) { p in
                progress(p * 0.8, o.cleanVoice ? "Cleaning up the voice…" : "Reading the audio…")
            }
            try Task.checkCancellation()
            progress(0.8, "Setting the volume…")
            try finish(pass1, stats: stats, options: o, to: dest) { p in progress(0.8 + p * 0.2, "Saving the file…") }
        }.value
        progress(1, "Done")
    }

    // MARK: Pass 1: read, clean, measure

    struct Stats { var frames: Int; var lag: Int; var blockPowers: [Double] }

    private static func clean(asset: AVAsset, tracks: [AVAssetTrack], start: Double, end: Double, options o: Options,
                              to url: URL, progress: (Double) -> Void) throws -> Stats {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        guard reader.startReading() else {
            throw AudioCleaner.Failure(message: reader.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        let expected = max(1, Int((end - start) * rate))
        let file = try AVAudioFile(forWriting: url, settings: stereo.settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        // Reads the next piece of the recording as a stereo buffer, or nil at the end.
        func nextInput() -> AVAudioPCMBuffer? {
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                let n = length / 8
                guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(n)) else { continue }
                var data = [Float](repeating: 0, count: n * 2)
                _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 8, destination: $0.baseAddress!) }
                buf.frameLength = AVAudioFrameCount(n)
                let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
                for i in 0..<n { l[i] = data[2 * i]; r[i] = data[2 * i + 1] }
                return buf
            }
            return nil
        }

        var powers: [Double] = []
        var pending = 0.0, pendingN = 0
        let block = Int(rate * 0.05)
        func measure(_ b: AVAudioPCMBuffer) {
            let l = b.floatChannelData![0], r = b.floatChannelData![1]
            for i in 0..<Int(b.frameLength) {
                let m = Double(l[i] + r[i]) * 0.5
                pending += m * m; pendingN += 1
                if pendingN == block { powers.append(pending / Double(block)); pending = 0; pendingN = 0 }
            }
        }

        // Nothing to clean: copy straight through.
        guard o.cleanVoice || o.levelVoice else {
            var frames = 0
            while let b = nextInput() {
                try Task.checkCancellation()
                try file.write(from: b); measure(b); frames += Int(b.frameLength)
                progress(min(1, Double(frames) / Double(expected)))
            }
            return Stats(frames: frames, lag: 0, blockPowers: powers)
        }

        // The same chain as clip exports, run offline.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: maxFrames)
        engine.attach(player)
        var chain: [AVAudioNode] = [player]
        if o.cleanVoice {
            let hp = AudioCleaner.effect(kAudioUnitSubType_HighPassFilter)
            AudioCleaner.set(hp, kHipassParam_CutoffFrequency, 80)
            chain.append(hp)
            if AudioCleaner.hasVoiceIsolation {
                let iso = AudioCleaner.effect(0x766f6973)
                AudioCleaner.set(iso, 0, Float(max(0, min(1, o.strength)) * 100))
                AudioCleaner.set(iso, 1, 1)
                chain.append(iso)
            }
        }
        if o.levelVoice {
            let dyn = AudioCleaner.effect(kAudioUnitSubType_DynamicsProcessor)
            AudioCleaner.set(dyn, kDynamicsProcessorParam_Threshold, -26)
            AudioCleaner.set(dyn, kDynamicsProcessorParam_HeadRoom, 8)
            AudioCleaner.set(dyn, kDynamicsProcessorParam_ExpansionRatio, 1.5)
            AudioCleaner.set(dyn, kDynamicsProcessorParam_ExpansionThreshold, -60)
            AudioCleaner.set(dyn, kDynamicsProcessorParam_AttackTime, 0.004)
            AudioCleaner.set(dyn, kDynamicsProcessorParam_ReleaseTime, 0.18)
            chain.append(dyn)
        }
        var latency = 0.0
        for n in chain.dropFirst() { engine.attach(n); if let fx = n as? AVAudioUnitEffect { latency += fx.auAudioUnit.latency } }
        for (a, b) in zip(chain, chain.dropFirst()) { engine.connect(a, to: b, format: stereo) }
        engine.connect(chain.last!, to: engine.mainMixerNode, format: stereo)
        let tail = Int((latency * rate).rounded()) + Int(rate / 2)
        try engine.start()
        player.play()
        defer { engine.stop() }

        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw AudioCleaner.Failure(message: "Not enough memory to process the audio.")
        }
        // Keep the first 30 seconds in and out to measure the clean-up's delay.
        let probe = Int(rate * 30)
        var probeIn: [Float] = [], probeOut: [Float] = []
        var scheduled = 0, inputFrames = 0, rendered = 0
        var inputDone = false, tailScheduled = false
        while true {
            try Task.checkCancellation()
            // Stay a little ahead of the renderer
            while !inputDone && scheduled < rendered + Int(rate) {
                if let b = nextInput() {
                    if probeIn.count < probe {
                        probeIn.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: min(Int(b.frameLength), probe - probeIn.count)))
                    }
                    player.scheduleBuffer(b, completionHandler: nil)
                    scheduled += Int(b.frameLength); inputFrames += Int(b.frameLength)
                } else { inputDone = true }
            }
            if inputDone && !tailScheduled {
                if let silence = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(tail)) {
                    silence.frameLength = AVAudioFrameCount(tail)
                    for c in 0..<2 { silence.floatChannelData![c].update(repeating: 0, count: tail) }
                    player.scheduleBuffer(silence, completionHandler: nil)
                    scheduled += tail
                }
                tailScheduled = true
            }
            guard rendered < scheduled else { break }
            let n = AVAudioFrameCount(min(Int(maxFrames), scheduled - rendered))
            let status = try engine.renderOffline(n, to: chunk)
            if status == .error { throw AudioCleaner.Failure(message: "Audio clean-up failed while rendering.") }
            guard status == .success, chunk.frameLength > 0 else { continue }
            if probeOut.count < probe + tail {
                probeOut.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0], count: min(Int(chunk.frameLength), probe + tail - probeOut.count)))
            }
            try file.write(from: chunk)
            measure(chunk)
            rendered += Int(chunk.frameLength)
            progress(min(1, Double(rendered) / Double(expected + tail)))
        }
        if reader.status == .failed {
            throw AudioCleaner.Failure(message: reader.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        let lag = probeIn.isEmpty ? 0 : AudioCleaner.measureDelay(input: probeIn, output: probeOut, maxLag: tail)
        return Stats(frames: inputFrames, lag: lag, blockPowers: powers)
    }

    // MARK: Pass 2: volume, limiter, fades, save

    private static func finish(_ src: URL, stats: Stats, options o: Options, to dest: URL, progress: (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: src, commonFormat: .pcmFormatFloat32, interleaved: false)
        // Speech to about −16 LUFS (gated, so pauses don't count), the podcast norm
        let gate = pow(10.0, -50.0 / 10)
        let speech = stats.blockPowers.filter { $0 > gate }
        var gain: Float = 1
        if o.levelVoice, !speech.isEmpty {
            let rms = sqrt(speech.reduce(0, +) / Double(speech.count))
            gain = Float(max(0.25, min(8, pow(10.0, -18.0 / 20) / rms)))
        }
        let channels: AVAudioChannelCount = o.mono ? 1 : 2
        let settings: [String: Any] = o.format == .wav
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
               AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
               AVEncoderBitRateKey: o.mono ? 128_000 : 192_000]
        try? FileManager.default.removeItem(at: dest)
        let out = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else { return }

        input.framePosition = AVAudioFramePosition(min(stats.lag, Int(input.length)))
        let total = min(stats.frames, Int(input.length) - Int(input.framePosition))
        let fadeIn = o.fades ? Int(rate * 0.4) : 0, fadeOut = o.fades ? Int(rate * 1.5) : 0
        let t: Float = 0.89    // −1 dBFS ceiling
        let step = 65_536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(step)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(step)) else { return }
        var done = 0
        while done < total {
            try Task.checkCancellation()
            let n = min(step, total - done)
            try input.read(into: inBuf, frameCount: AVAudioFrameCount(n))
            let got = Int(inBuf.frameLength)
            guard got > 0 else { break }
            let l = inBuf.floatChannelData![0], r = inBuf.floatChannelData![1]
            outBuf.frameLength = AVAudioFrameCount(got)
            for i in 0..<got {
                let pos = done + i
                var env: Float = 1
                if pos < fadeIn { env = Float(pos) / Float(fadeIn) }
                if total - pos < fadeOut { env = min(env, Float(total - pos) / Float(fadeOut)) }
                func shape(_ v: Float) -> Float {
                    var x = v * gain
                    let a = abs(x)
                    if a > t { x = (x < 0 ? -1 : 1) * (t + (1 - t) * tanh((a - t) / (1 - t))) }
                    return x * env
                }
                if o.mono {
                    outBuf.floatChannelData![0][i] = shape((l[i] + r[i]) * 0.5)
                } else {
                    outBuf.floatChannelData![0][i] = shape(l[i])
                    outBuf.floatChannelData![1][i] = shape(r[i])
                }
            }
            try out.write(from: outBuf)
            done += got
            progress(Double(done) / Double(max(total, 1)))
        }
    }
}
