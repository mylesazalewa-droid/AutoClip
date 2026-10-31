import Foundation
import AVFoundation
import Accelerate
import Vision

// MARK: - Report (saved per video, also feeds progress tracking)

struct SpeakerReport: Codable, Equatable {
    var videoPath: String
    var title: String
    var videoDate: Date
    var analyzedAt = Date()
    var duration: Double
    var speakingMinutes: Double
    var wordCount: Int
    var fillerCount: Int
    var delivery: Delivery?
    var stage: Stage?
    var coach: Coach?

    var fillersPerMin: Double { Double(fillerCount) / max(1, speakingMinutes) }

    struct Span: Codable, Equatable { var start: Double; var end: Double }
    struct Mark: Codable, Equatable, Identifiable {
        var id: String { "\(kind)@\(time)" }
        var kind: String; var time: Double; var context: String
    }

    struct Delivery: Codable, Equatable {
        // Pace
        var paceBin: Double                 // seconds per pace sample
        var pace: [Double?]                 // words per minute per bin (nil = silence)
        var averageWPM: Double
        var fastStretches: [Span]
        var slowStretches: [Span]
        // Pauses
        var naturalPauses: Int              // 0.5–2s
        var longPauses: Int                 // > 2s
        var breathlessRuns: [Span]          // 30s+ with no pause of 0.5s
        // Voice
        var voiceBin: Double                // seconds per voice sample
        var pitch: [Double?]                // median pitch (Hz) per bin
        var loudness: [Double?]             // dB per bin
        var pitchRangeSemitones: Double     // typical spread (interquartile, in semitones)
        var monotoneStretches: [Span]
        var trailingOffPercent: Double      // sentences whose last word drops off
        // Words
        var crutches: [Mark]
        var youCount: Int, weCount: Int, iCount: Int
        var questions: Int
    }

    struct Stage: Codable, Equatable {
        var positions: [Double]             // 0…1 horizontal position histogram (sums to 1)
        var onScreenPercent: Double
        var facingPercent: Double
        var movementPerMinute: Double       // frame widths travelled per minute
        var track: [Double?]                // x (0…1) every `trackStep` seconds
        var trackStep: Double
    }

    struct Coach: Codable, Equatable {
        struct Note: Codable, Equatable, Identifiable {
            var id: String { title }
            var title: String; var detail: String; var time: Double?; var drill: String?
        }
        struct Section: Codable, Equatable, Identifiable {
            var id: String { "\(kind)\(start)" }
            var kind: String; var title: String; var start: Double; var end: Double
        }
        struct Moment: Codable, Equatable, Identifiable {
            var id: String { "\(time)" }
            var time: Double; var quote: String; var why: String
        }
        var score: Int
        var summary: String
        var strengths: [Note]
        var improvements: [Note]
        var bigIdea: String
        var bigIdeaClarity: Int
        var bigIdeaMentions: [Double]
        var sections: [Section]
        var best: [Moment]
        var weakest: [Moment]
        var jargon: [String]
    }
}

enum SpeakerReportStore {
    static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Assess")
    }
    private static func file(for videoPath: String) -> URL {
        let name = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent(String(name.prefix(120)) + ".json")
    }
    static func load(for videoPath: String) -> SpeakerReport? {
        guard let data = try? Data(contentsOf: file(for: videoPath)) else { return nil }
        return try? JSONDecoder().decode(SpeakerReport.self, from: data)
    }
    static func save(_ r: SpeakerReport) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: file(for: r.videoPath)) }
    }
    static func all() -> [SpeakerReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SpeakerReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.videoDate < $1.videoDate }
    }
}

// MARK: - Analysis

enum SpeakerAnalysis {
    static func newReport(videoPath: String, words: [Word], duration: Double) -> SpeakerReport {
        // YouTube downloads carry the upload date as their modification date; for other files the
        // earlier of the two dates is the best guess. The user can correct it in the report.
        let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
        let dates = [attrs?[.creationDate] as? Date, attrs?[.modificationDate] as? Date].compactMap { $0 }
        let date = dates.min() ?? Date()
        let speaking = max(1, ((words.last?.endTime ?? 0) - (words.first?.startTime ?? 0)) / 60)
        return SpeakerReport(videoPath: videoPath, title: YTDLP.title(fromFile: URL(fileURLWithPath: videoPath)),
                             videoDate: date, duration: duration, speakingMinutes: speaking,
                             wordCount: words.count, fillerCount: FillerReport.find(in: words).count)
    }

    // MARK: Words: pace, pauses, crutch phrases, audience focus

    static let crutchPhrases: [String] = ["right?", "amen?", "you know what i mean", "you know", "literally",
                                          "really", "kind of", "sort of", "basically", "actually", "okay",
                                          "come on", "you guys", "obviously", "honestly"]

    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    static func crutches(in words: [Word]) -> [SpeakerReport.Mark] {
        let toks = words.map { clean($0.word) }
        var out: [SpeakerReport.Mark] = []
        var i = 0
        while i < words.count {
            var matched = 0
            for p in crutchPhrases {
                let needsQ = p.hasSuffix("?")
                let parts = p.replacingOccurrences(of: "?", with: "").split(separator: " ").map(String.init)
                guard i + parts.count <= toks.count, Array(toks[i..<i + parts.count]) == parts else { continue }
                if needsQ && !words[i + parts.count - 1].word.contains("?") { continue }
                // "you know" inside "you know what i mean" is already counted
                let ctx = words[max(0, i - 4)..<min(words.count, i + parts.count + 4)].map(\.word).joined(separator: " ")
                out.append(.init(kind: p, time: words[i].startTime, context: ctx))
                matched = parts.count
                break
            }
            i += max(1, matched)
        }
        return out
    }

    static func wordDelivery(_ words: [Word]) -> (pace: [Double?], avg: Double, fast: [SpeakerReport.Span], slow: [SpeakerReport.Span],
                                                   natural: Int, long: Int, breathless: [SpeakerReport.Span],
                                                   you: Int, we: Int, i: Int, questions: Int) {
        let bin = 30.0
        let end = words.last?.endTime ?? 0
        let n = max(1, Int(ceil(end / bin)))
        var counts = Array(repeating: 0, count: n)
        var speech = Array(repeating: 0.0, count: n)
        for w in words {
            let b = min(n - 1, Int(w.startTime / bin))
            counts[b] += 1
            speech[b] += max(0, w.endTime - w.startTime)
        }
        // Bins that are mostly silence (worship, video, prayer) aren't counted for pace
        // (the last bin is usually partial, so it's measured over the time it actually covers)
        let pace: [Double?] = (0..<n).map { k in
            let span = k == n - 1 ? max(1, end - Double(k) * bin) : bin
            return counts[k] >= 15 && span >= 15 ? Double(counts[k]) * 60 / span : nil
        }
        let valid = pace.compactMap { $0 }
        let avg = valid.isEmpty ? 0 : valid.reduce(0, +) / Double(valid.count)
        func stretches(_ test: (Double) -> Bool) -> [SpeakerReport.Span] {
            var out: [SpeakerReport.Span] = []
            for (k, p) in pace.enumerated() {
                guard let p, test(p) else { continue }
                let s = Double(k) * bin, e = s + bin
                if let last = out.last, last.end >= s { out[out.count - 1].end = e } else { out.append(.init(start: s, end: e)) }
            }
            return out
        }
        var natural = 0, long = 0
        var breathless: [SpeakerReport.Span] = []
        var runStart = words.first?.startTime ?? 0
        for k in 1..<max(1, words.count) {
            let gap = words[k].startTime - words[k - 1].endTime
            if gap >= 0.5 {
                if gap <= 2 { natural += 1 } else { long += 1 }
                if words[k - 1].endTime - runStart >= 30 { breathless.append(.init(start: runStart, end: words[k - 1].endTime)) }
                runStart = words[k].startTime
            }
        }
        let toks = words.map { clean($0.word) }
        let you = toks.filter { ["you", "your", "yours", "yourself", "you're", "you've", "you'll"].contains($0) }.count
        let we = toks.filter { ["we", "us", "our", "ours", "we're", "we've", "we'll", "ourselves"].contains($0) }.count
        let me = toks.filter { ["i", "me", "my", "mine", "i'm", "i've", "i'll", "myself"].contains($0) }.count
        let questions = words.filter { $0.word.hasSuffix("?") }.count
        return (pace, avg, stretches { $0 > 180 }, stretches { $0 < 110 }, natural, long, breathless, you, we, me, questions)
    }

    // MARK: Voice: pitch + loudness from the audio

    /// Per 40 ms frame: loudness (dB) and pitch (Hz, 0 when unvoiced). Reads the audio at 8 kHz mono.
    static func voiceFrames(of url: URL, progress: @escaping (Double) -> Void) async throws -> (db: [Float], hz: [Float], frame: Double) {
        let sr = 8000.0, frameLen = 320
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw NSError(domain: "AutoClip", code: 21, userInfo: [NSLocalizedDescriptionKey: "This video has no sound."]) }
        let total = CMTimeGetSeconds(try await asset.load(.duration))
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "AutoClip", code: 22) }

        var db: [Float] = [], hz: [Float] = []
        var pending: [Float] = []
        var acf = [Float](repeating: 0, count: 161)
        func analyze(_ f: ArraySlice<Float>) {
            let x = Array(f)
            var ms: Float = 0
            vDSP_measqv(x, 1, &ms, vDSP_Length(frameLen))
            let level = 10 * log10(max(ms, 1e-10))
            db.append(level)
            guard level > -45 else { hz.append(0); return }
            // Normalised autocorrelation over 50–400 Hz
            var e0: Float = 0
            vDSP_dotpr(x, 1, x, 1, &e0, vDSP_Length(frameLen))
            var bestLag = 0; var best: Float = 0
            x.withUnsafeBufferPointer { p in
                for lag in 20...160 {
                    var c: Float = 0
                    vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &c, vDSP_Length(frameLen - lag))
                    acf[lag] = c / max(e0, 1e-9)
                    if acf[lag] > best { best = acf[lag]; bestLag = lag }
                }
            }
            // Octave fix: a strong peak at half the lag means we locked onto a sub-harmonic
            while bestLag / 2 >= 20, acf[bestLag / 2] > best * 0.8 { bestLag /= 2; best = acf[bestLag] }
            hz.append(best > 0.45 && bestLag > 0 ? Float(sr) / Float(bestLag) : 0)
        }
        var lastReport = Date()
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            pending += chunk
            var k = 0
            while k + frameLen <= pending.count { analyze(pending[k..<k + frameLen]); k += frameLen }
            pending.removeFirst(k)
            if Date().timeIntervalSince(lastReport) > 0.3 {
                lastReport = Date()
                progress(min(1, Double(db.count) * 0.04 / max(1, total)))
            }
        }
        return (db, hz, Double(frameLen) / sr)
    }

    static func voiceDelivery(db: [Float], hz rawHz: [Float], frame: Double, words: [Word])
        -> (pitch: [Double?], loud: [Double?], range: Double, monotone: [SpeakerReport.Span], trailing: Double) {
        // Fold octave errors back toward the speaker's usual pitch: real speech rarely sits
        // a whole octave away from its median, but pitch trackers often jump by exactly one.
        let rawVoiced = rawHz.filter { $0 > 0 }.sorted()
        let center = rawVoiced.isEmpty ? 0 : rawVoiced[rawVoiced.count / 2]
        let hz: [Float] = rawHz.map { f in
            guard f > 0, center > 0 else { return f }
            var g = f
            while g > center * 1.6 { g /= 2 }
            while g < center * 0.62 { g *= 2 }
            return g
        }
        let bin = 5.0
        let per = Int(bin / frame)
        let n = max(1, db.count / max(1, per))
        var pitch: [Double?] = [], loud: [Double?] = []
        for b in 0..<n {
            let r = (b * per)..<min(db.count, (b + 1) * per)
            let voiced = r.filter { hz[$0] > 0 }
            pitch.append(voiced.count > per / 6 ? Double(voiced.map { hz[$0] }.sorted()[voiced.count / 2]) : nil)
            loud.append(voiced.isEmpty ? nil : Double(voiced.map { db[$0] }.reduce(0, +)) / Double(voiced.count))
        }
        // Semitones relative to the speaker's median pitch
        let allVoiced = hz.filter { $0 > 0 }.sorted()
        guard !allVoiced.isEmpty else { return (pitch, loud, 0, [], 0) }
        let median = Double(allVoiced[allVoiced.count / 2])
        func semis(_ f: Float) -> Double { 12 * log2(Double(f) / median) }
        let q1 = semis(allVoiced[allVoiced.count / 4]), q3 = semis(allVoiced[allVoiced.count * 3 / 4])

        // Monotone: 2-minute windows (step 30s) whose pitch barely moves
        let win = Int(120 / frame), step = Int(30 / frame)
        var mono: [SpeakerReport.Span] = []
        var s = 0
        while s + win <= hz.count {
            let st = (s..<(s + win)).compactMap { hz[$0] > 0 ? semis(hz[$0]) : nil }
            if st.count > win / 5 {
                // Interquartile spread: lively speech is ~3–5 semitones, a flat drone under 2
                let sorted = st.sorted()
                let spread = sorted[sorted.count * 3 / 4] - sorted[sorted.count / 4]
                if spread < 2.0 {
                    let a = Double(s) * frame, e = Double(s + win) * frame
                    if let last = mono.last, last.end >= a { mono[mono.count - 1].end = e } else { mono.append(.init(start: a, end: e)) }
                }
            }
            s += step
        }

        // Trailing off: a sentence's last word clearly quieter than the rest of it
        var checked = 0, trailing = 0
        func level(_ a: Double, _ b: Double) -> Double? {
            let i0 = max(0, Int(a / frame)), i1 = min(db.count, Int(b / frame))
            guard i1 > i0 else { return nil }
            let v = db[i0..<i1].filter { $0 > -50 }
            return v.isEmpty ? nil : Double(v.reduce(0, +)) / Double(v.count)
        }
        for sentence in ReelDraft.sentences(from: words) where sentence.words.count >= 5 {
            guard let last = sentence.words.last,
                  let body = level(sentence.start, last.startTime), let end = level(last.startTime, last.endTime) else { continue }
            checked += 1
            if end < body - 6 { trailing += 1 }
        }
        return (pitch, loud, q3 - q1, mono, checked == 0 ? 0 : Double(trailing) / Double(checked) * 100)
    }

    static func delivery(videoPath: String, words: [Word], progress: @escaping (Double) -> Void) async throws -> SpeakerReport.Delivery {
        let w = wordDelivery(words)
        let v = try await voiceFrames(of: URL(fileURLWithPath: videoPath), progress: progress)
        let voice = voiceDelivery(db: v.db, hz: v.hz, frame: v.frame, words: words)
        return .init(paceBin: 30, pace: w.pace, averageWPM: w.avg, fastStretches: w.fast, slowStretches: w.slow,
                     naturalPauses: w.natural, longPauses: w.long, breathlessRuns: w.breathless,
                     voiceBin: 5, pitch: voice.pitch, loudness: voice.loud, pitchRangeSemitones: voice.range,
                     monotoneStretches: voice.monotone, trailingOffPercent: voice.trailing,
                     crutches: crutches(in: words), youCount: w.you, weCount: w.we, iCount: w.i, questions: w.questions)
    }

    // MARK: Stage presence from the video

    static func stage(videoPath: String, progress: @escaping (Double) -> Void) async -> SpeakerReport.Stage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        guard let dur = try? await asset.load(.duration), CMTimeGetSeconds(dur) > 5,
              (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }
        let total = CMTimeGetSeconds(dur)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let step = total > 1800 ? 3.0 : 2.0
        var track: [Double?] = []
        var seen = 0, facing = 0, frames = 0
        var t = 0.0
        while t < total {
            frames += 1
            var x: Double? = nil
            if let img = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) {
                let req = VNDetectFaceRectanglesRequest()
                req.revision = VNDetectFaceRectanglesRequestRevision3
                try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
                if let f = (req.results ?? []).filter({ $0.boundingBox.height > 0.06 })
                    .max(by: { $0.boundingBox.height < $1.boundingBox.height }) {
                    seen += 1
                    x = Double(f.boundingBox.midX)
                    if let yaw = f.yaw?.doubleValue, abs(yaw) < 0.45 { facing += 1 }
                }
            }
            track.append(x)
            t += step
            if frames % 10 == 0 { progress(min(1, t / total)) }
        }
        let xs = track.compactMap { $0 }
        guard !xs.isEmpty else { return nil }
        var hist = Array(repeating: 0.0, count: 15)
        for x in xs { hist[min(14, max(0, Int(x * 15)))] += 1 }
        hist = hist.map { $0 / Double(xs.count) }
        // Movement: median-smoothed track so camera jitter doesn't count as walking
        var moved = 0.0
        var prev: Double? = nil
        for k in track.indices {
            let win = track[max(0, k - 1)...min(track.count - 1, k + 1)].compactMap { $0 }.sorted()
            guard !win.isEmpty else { prev = nil; continue }
            let m = win[win.count / 2]
            if let p = prev { moved += abs(m - p) }
            prev = m
        }
        return .init(positions: hist, onScreenPercent: Double(seen) / Double(frames) * 100,
                     facingPercent: seen == 0 ? 0 : Double(facing) / Double(seen) * 100,
                     movementPerMinute: moved / max(1, total / 60), track: track, trackStep: step)
    }
}
