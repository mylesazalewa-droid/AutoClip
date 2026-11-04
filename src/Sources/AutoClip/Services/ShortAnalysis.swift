import Foundation
import AVFoundation
import CoreGraphics
import Vision

/// What happens in the picture over a short.
struct ShortPicture: Codable, Equatable {
    /// Seconds between face checks
    var step: Double
    var faces: [Bool]
    /// When the picture suddenly jumps: a cut or a very big move
    var jumps: [Double]

    func hasFace(at t: Double) -> Bool {
        guard !faces.isEmpty else { return false }
        return faces[min(faces.count - 1, max(0, Int((t / max(step, 0.01)).rounded())))]
    }

    func changes(from: Double, to: Double) -> Bool { jumps.contains { $0 >= from && $0 <= to } }

    /// Stretches with no cut or big move, long enough for the picture to go stale.
    func staleStretches(duration: Double, atLeast: Double = 8) -> [ClosedRange<Double>] {
        let marks = [0.0] + jumps.filter { $0 > 0 && $0 < duration } + [duration]
        var out: [ClosedRange<Double>] = []
        for (a, b) in zip(marks, marks.dropFirst()) where b - a >= atLeast { out.append(a...b) }
        return out
    }

    static func read(path: String, duration: Double) async -> ShortPicture? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let jumps = findJumps(asset: asset, track: track) else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        let close = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = close
        gen.requestedTimeToleranceAfter = close
        let step = max(1, duration / 180)
        var faces: [Bool] = []
        var t = 0.0
        while t < duration {
            if Task.isCancelled { return nil }
            if let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { faces.append(hasFace(image)) }
            else { faces.append(faces.last ?? false) }
            t += step
        }
        return ShortPicture(step: step, faces: faces, jumps: jumps)
    }

    /// Compares every frame with the one right before it. Between neighbouring frames, movement
    /// barely registers even on a handheld phone, so a cut stands out. A steady change is
    /// movement; a cut is a change much bigger than the frame before it had.
    private static func findJumps(asset: AVAsset, track: AVAssetTrack) -> [Double]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }
        let grid = 48
        var previous: [UInt8] = []
        var current = [UInt8](repeating: 0, count: grid * grid)
        var lastDifference: Float = 0
        var jumps: [Double] = []
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            frames += 1
            if frames % 60 == 0, Task.isCancelled { reader.cancelReading(); return nil }
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            if let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self), width > 0, height > 0 {
                for y in 0..<grid {
                    let row = base + (y * height / grid) * rowBytes
                    for x in 0..<grid { current[y * grid + x] = row[x * width / grid] }
                }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if previous.count == current.count {
                var sum = 0
                for i in current.indices { sum += abs(Int(current[i]) - Int(previous[i])) }
                let difference = Float(sum) / Float(current.count) / 255
                if min(difference, abs(difference - lastDifference)) > 0.03, time - (jumps.last ?? -1) > 0.5 { jumps.append(time) }
                lastDifference = difference
            }
            swap(&previous, &current)
            if current.isEmpty { current = [UInt8](repeating: 0, count: grid * grid) }
        }
        return reader.status == .completed ? jumps : nil
    }

    private static func hasFace(_ image: CGImage) -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return !(request.results ?? []).isEmpty
    }
}

// MARK: - Drop-off map

/// A moment viewers are likely to leave. An estimate from the video, not real viewer data.
struct DropOff: Identifiable, Equatable {
    enum Fix: Equatable {
        case removeSilences, removeFillers, useHook
        case cutLine(Int)
        case punchIn(Double)
    }
    var id: String { "\(title)-\(start)" }
    var start: Double
    var end: Double
    /// 1 small, 2 likely, 3 serious
    var severity: Int
    var title: String
    var detail: String
    var fix: Fix?

    var fixLabel: String {
        switch fix {
        case .removeSilences: return "Remove silences"
        case .removeFillers: return "Remove fillers"
        case .useHook: return "Open on a stronger line"
        case .cutLine: return "Cut this line"
        case .punchIn: return "Add punch-in zooms"
        case nil: return ""
        }
    }
}

enum DropOffMap {
    private static let quietWords: Set<String> = ["the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "at", "is", "it", "that", "this", "you", "i", "we", "they", "he", "she", "was", "were", "are", "be", "for", "with", "as", "my", "your", "our", "not", "do", "did", "have", "has", "just"]

    private static func contentWords(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !quietWords.contains($0) })
    }

    private static func level(_ r: ShortReview, from: Double, to: Double) -> Float? {
        guard !r.levels.isEmpty else { return nil }
        let a = max(0, Int(from * 10)), b = min(r.levels.count, max(a + 1, Int(to * 10)))
        guard a < b else { return nil }
        let slice = r.levels[a..<b].sorted()
        return slice[slice.count / 2]
    }

    private static func median(_ list: [Double]) -> Double {
        guard !list.isEmpty else { return 0 }
        return list.sorted()[list.count / 2]
    }

    static func find(_ r: ShortReview) -> [DropOff] {
        var out: [DropOff] = []
        let sorted = r.words.sorted { $0.startTime < $1.startTime }
        let lines = r.lines
        guard let first = sorted.first else { return [] }

        // A slow start costs the most, because that's where most viewers decide
        if first.startTime > 0.8 {
            if r.isQuiet(0, first.startTime) {
                out.append(.init(start: 0, end: first.startTime, severity: first.startTime > 1.5 ? 3 : 2, title: "Slow start",
                                 detail: String(format: "%.1f seconds of silence before the first word.", first.startTime), fix: .removeSilences))
            } else if first.startTime > 2 {
                out.append(.init(start: 0, end: first.startTime, severity: 3, title: "Slow start",
                                 detail: String(format: "%.1f seconds pass before anyone speaks.", first.startTime), fix: r.hook == nil ? nil : .useHook))
            }
        }

        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.startTime - a.endTime
            if gap > 0.7, r.isQuiet(a.endTime, b.startTime) {
                out.append(.init(start: a.endTime, end: b.startTime, severity: gap > 1.5 ? 2 : 1, title: "Long pause",
                                 detail: String(format: "%.1f seconds with nothing said.", gap), fix: .removeSilences))
            }
        }

        // One filler is natural; a run of them is what people notice
        let cut = LongformCleanup.removals(sorted, .init(fillers: true, falseStarts: true, pauses: false)).ids
        let marked = sorted.filter { cut.contains($0.id) }
        var i = 0
        while i < marked.count {
            var j = i
            while j + 1 < marked.count, marked[j + 1].startTime - marked[j].startTime < 4 { j += 1 }
            if j - i >= 1 {
                out.append(.init(start: marked[i].startTime, end: marked[j].endTime, severity: 1, title: "Filler words",
                                 detail: "\(j - i + 1) ums, uhs or false starts close together.", fix: .removeFillers))
            }
            i = j + 1
        }

        // What the AI flagged, then what can be measured. One note per line.
        var noted = Set<Int>()
        func add(_ line: Int, severity: Int, title: String, detail: String) {
            guard lines.indices.contains(line), !noted.contains(line), lines.count > 1 else { return }
            noted.insert(line)
            out.append(.init(start: lines[line].start, end: lines[line].end, severity: severity, title: title, detail: detail, fix: .cutLine(line)))
        }
        for d in r.drops { add(d.line, severity: 2, title: "Drags", detail: d.why) }

        let content = lines.map { contentWords(ShortDoctor.spokenText($0)) }
        for j in lines.indices where content[j].count >= 4 {
            for k in 0..<j where content[k].count >= 4 {
                let shared = content[j].intersection(content[k]).count
                if Double(shared) / Double(content[j].union(content[k]).count) >= 0.6 {
                    add(j, severity: 2, title: "Says the same thing again", detail: "This repeats the line at \(assessClock(lines[k].start)).")
                    break
                }
            }
        }

        let rates = lines.filter { $0.words.count >= 4 && $0.end > $0.start }.map { Double($0.words.count) / ($0.end - $0.start) }
        let usualRate = median(rates)
        let speech = level(r, words: sorted)
        for (j, line) in lines.enumerated() {
            let length = line.end - line.start
            if line.words.count > 32 || length > 12 {
                add(j, severity: 1, title: "Very long sentence", detail: "\(line.words.count) words in one go. Shorter lines are easier to follow.")
            } else if line.words.count >= 4, usualRate > 0, length > 2, Double(line.words.count) / length < usualRate * 0.6 {
                add(j, severity: 1, title: "Pace slows down", detail: "Noticeably slower than the rest of the video.")
            } else if let speech, length > 2, let here = level(r, from: line.start, to: line.end), here < speech - 8 {
                add(j, severity: 1, title: "Voice drops away", detail: "Quieter than the rest of the video, so the energy dips here.")
            }
        }

        // A picture that never changes gives the eye nothing new
        if let picture = r.picture {
            for stretch in picture.staleStretches(duration: r.duration) {
                let seconds = stretch.upperBound - stretch.lowerBound
                out.append(.init(start: stretch.lowerBound, end: stretch.upperBound, severity: seconds > 20 ? 2 : 1, title: "Picture stays the same",
                                 detail: "\(Int(seconds)) seconds with no cut or big change on screen.", fix: .punchIn(stretch.lowerBound)))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func level(_ r: ShortReview, words: [Word]) -> Float? {
        let spoken = words.compactMap { level(r, from: $0.startTime, to: $0.endTime) }.sorted()
        return spoken.isEmpty ? nil : spoken[spoken.count / 2]
    }

    static func isFixed(_ issue: DropOff, _ c: ShortReview.Choices) -> Bool {
        switch issue.fix {
        case .removeSilences: return c.removeSilences
        case .removeFillers: return c.removeFillers && c.removeStutters
        case .useHook: return c.useHook
        case .cutLine(let line): return c.dropped.contains(line)
        case .punchIn(let t): return c.punchIns?.contains { abs($0 - t) < 0.01 } ?? false
        case nil: return false
        }
    }

    static func toggle(_ issue: DropOff, _ c: inout ShortReview.Choices) {
        let on = !isFixed(issue, c)
        switch issue.fix {
        case .removeSilences: c.removeSilences = on
        case .removeFillers: c.removeFillers = on; c.removeStutters = on
        case .useHook: c.useHook = on
        case .cutLine(let line): if on { c.dropped.insert(line) } else { c.dropped.remove(line) }
        case .punchIn(let t):
            var list = c.punchIns ?? []
            list.removeAll { abs($0 - t) < 0.01 }
            if on { list.append(t) }
            c.punchIns = list.isEmpty ? nil : list
        case nil: break
        }
    }
}

func assessClock(_ t: Double) -> String {
    let s = Int(max(0, t).rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Punch-in zooms

extension ShortDoctor {
    static let punchZoom: CGFloat = 1.12

    /// The parts of the source shown zoomed in: a few seconds in, then every other stretch of a few seconds.
    static func zoomSpans(_ r: ShortReview) -> [ClosedRange<Double>] {
        guard let starts = r.choices.punchIns, !starts.isEmpty, let picture = r.picture else { return [] }
        var out: [ClosedRange<Double>] = []
        for stretch in picture.staleStretches(duration: r.duration) where starts.contains(where: { abs($0 - stretch.lowerBound) < 0.01 }) {
            var t = stretch.lowerBound + 3
            while t + 3 < stretch.upperBound {
                out.append(t...(t + 3.5))
                t += 7
            }
        }
        return out
    }

    /// Where the zoomed parts land in the finished edit. Cuts and moved lines carry them along.
    static func zoomTimes(_ r: ShortReview) -> [ClosedRange<Double>] {
        let spans = zoomSpans(r)
        guard !spans.isEmpty else { return [] }
        var out: [ClosedRange<Double>] = []
        var at = 0.0
        for range in ranges(r) {
            for z in spans {
                let a = max(z.lowerBound, range.lowerBound), b = min(z.upperBound, range.upperBound)
                if b - a > 0.5 { out.append((at + a - range.lowerBound)...(at + b - range.lowerBound)) }
            }
            at += range.upperBound - range.lowerBound
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The zooms as a video composition, or nil when there are none.
    static func zoomComposition(_ r: ShortReview, comp: AVComposition, transform: CGAffineTransform, natural: CGSize) async throws -> AVMutableVideoComposition? {
        let times = zoomTimes(r)
        guard !times.isEmpty, let track = try await comp.loadTracks(withMediaType: .video).first else { return nil }
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(box.width), height: abs(box.height))
        let base = transform.concatenating(.init(translationX: -box.minX, y: -box.minY))
        let zoomed = base
            .concatenating(.init(translationX: -size.width / 2, y: -size.height / 2))
            .concatenating(.init(scaleX: punchZoom, y: punchZoom))
            .concatenating(.init(translationX: size.width / 2, y: size.height / 2))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(base, at: .zero)
        for t in times {
            layer.setTransform(zoomed, at: CMTime(seconds: t.lowerBound, preferredTimescale: 600))
            layer.setTransform(base, at: CMTime(seconds: t.upperBound, preferredTimescale: 600))
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instruction.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [instruction]
        return vc
    }

    /// Where a moment in the original lands in the edit, or nil when it was cut.
    static func editTime(ofSource t: Double, _ r: ShortReview) -> Double? {
        var at = 0.0
        for range in ranges(r) {
            if range.contains(t) { return at + t - range.lowerBound }
            at += range.upperBound - range.lowerBound
        }
        return nil
    }

    /// The moment in the original that's playing at this point in the edit.
    static func sourceTime(ofEdit t: Double, _ r: ShortReview) -> Double {
        var at = 0.0
        for range in ranges(r) {
            let length = range.upperBound - range.lowerBound
            if t <= at + length { return range.lowerBound + t - at }
            at += length
        }
        return r.duration
    }
}

// MARK: - Hook lab

/// The first three seconds, judged on words, picture and sound separately.
struct HookReading: Equatable {
    struct Note: Equatable {
        var good: Bool
        var text: String
    }
    var words: Int
    /// Nil until the picture has been read
    var picture: Int?
    var sound: Int
    var notes: [Note]
}

struct HookOption: Identifiable, Equatable {
    var id: Int { line }
    var line: Int
    var text: String
    var why: String
    var onScreen: String
    var reading: HookReading
}

enum HookLab {
    private static let leads = ["and ", "so ", "but ", "because ", "that ", "this ", "it ", "he ", "she ", "they ", "then ", "or ", "these ", "those ", "which "]
    private static let strong = ["never", "stop", "secret", "why", "how", "truth", "mistake", "nobody", "everyone", "always", "wrong", "most people", "what if", "the reason"]

    /// How well a line grabs attention by itself, from its wording alone.
    static func strength(_ raw: String) -> Int {
        let text = raw.lowercased()
        let n = text.split(separator: " ").count
        var v = 0
        if (4...16).contains(n) { v += 2 }
        if n > 24 { v -= 2 }
        if text.contains("?") { v += 3 }
        if text.rangeOfCharacter(from: .decimalDigits) != nil { v += 1 }
        if [" you ", "you ", " your "].contains(where: { (" " + text).contains($0) }) { v += 1 }
        for word in strong where text.contains(word) { v += 2 }
        if dependsOnEarlier(text) { v -= 4 }
        return v
    }

    static func dependsOnEarlier(_ raw: String) -> Bool {
        let text = raw.lowercased()
        return leads.contains { text.hasPrefix($0) }
    }

    /// Lines that close a video rather than open one.
    static func signsOff(_ raw: String) -> Bool {
        let text = " " + raw.lowercased().components(separatedBy: CharacterSet.letters.inverted.subtracting(.whitespaces)).joined() + " "
        return [" amen ", " subscribe ", " thanks for watching ", " thank you for watching ", " follow me ", " see you ", " link in "].contains { text.contains($0) }
    }

    static func wordScore(_ text: String) -> Int { min(98, max(10, 55 + strength(text) * 7)) }

    /// Reads a line as an opening. `delay` is how long the viewer waits for it.
    static func read(_ r: ShortReview, line: Int, delay: Double) -> HookReading {
        let lines = r.lines
        guard lines.indices.contains(line) else { return HookReading(words: 0, picture: nil, sound: 0, notes: []) }
        let sentence = lines[line]
        let text = ShortDoctor.spokenText(sentence)
        let count = text.split(separator: " ").count
        var notes: [HookReading.Note] = []

        if dependsOnEarlier(text) { notes.append(.init(good: false, text: "Starts with a word that points back to something earlier")) }
        if text.contains("?") { notes.append(.init(good: true, text: "Opens with a question")) }
        if count > 24 { notes.append(.init(good: false, text: "Long for an opening, at \(count) words")) }
        if count < 4 { notes.append(.init(good: false, text: "Very short, so it may not say enough")) }

        var picture: Int?
        if let p = r.picture {
            let face = p.hasFace(at: sentence.start)
            let moves = p.changes(from: sentence.start, to: sentence.start + 3)
            picture = 40 + (face ? 35 : 0) + (moves ? 15 : 0)
            notes.append(.init(good: face, text: face ? "A face is on screen" : "No face on screen"))
            if moves { notes.append(.init(good: true, text: "Something changes on screen in the first 3 seconds")) }
        }

        var sound = 90 - Int(delay * 25)
        if delay > 0.5 { notes.append(.init(good: false, text: String(format: "%.1f seconds pass before the first word", delay))) }
        else { notes.append(.init(good: true, text: "Speech starts right away")) }
        if !r.levels.isEmpty {
            func level(_ a: Double, _ b: Double) -> Float? {
                let from = max(0, Int(a * 10)), to = min(r.levels.count, Int(b * 10))
                guard from < to else { return nil }
                let slice = r.levels[from..<to].sorted()
                return slice[slice.count / 2]
            }
            let all = r.words.compactMap { level($0.startTime, $0.endTime) }.sorted()
            if !all.isEmpty, let here = level(sentence.start, min(sentence.start + 3, sentence.end)) {
                let drop = Double(all[all.count / 2] - here)
                if drop > 3 {
                    sound -= Int(drop * 3)
                    notes.append(.init(good: false, text: "Quieter than the rest of the video"))
                } else if drop < -2 {
                    sound += 8
                    notes.append(.init(good: true, text: "More energy than the rest of the video"))
                }
            }
        }
        return HookReading(words: wordScore(text), picture: picture, sound: min(98, max(10, sound)), notes: notes)
    }

    /// The opening as it is now.
    static func current(_ r: ShortReview) -> HookReading {
        read(r, line: 0, delay: r.lines.first?.start ?? 0)
    }

    /// Other openings from the video itself: the AI's picks first, then the strongest lines by wording.
    static func options(_ r: ShortReview, limit: Int = 5) -> [HookOption] {
        let lines = r.lines
        var picks: [ShortReview.Hook] = []
        if let h = r.hook { picks.append(h) }
        picks += r.hookOptions ?? []
        let standAlone = lines.indices.dropFirst().filter { i in
            let text = ShortDoctor.spokenText(lines[i])
            let n = text.split(separator: " ").count
            return (3...24).contains(n) && !dependsOnEarlier(text) && !signsOff(text) && i != lines.count - 1
        }
        let currentStrength = lines.first.map { strength(ShortDoctor.spokenText($0)) } ?? 0
        for i in standAlone.sorted(by: { strength(ShortDoctor.spokenText(lines[$0])) > strength(ShortDoctor.spokenText(lines[$1])) }) {
            let text = ShortDoctor.spokenText(lines[i])
            picks.append(.init(line: i, why: strength(text) > currentStrength ? "Makes sense by itself and its wording grabs attention more than your opening." : "Makes sense by itself, so it can work as an opening.",
                               text: text.split(separator: " ").prefix(8).joined(separator: " "), scoreAfter: wordScore(text)))
        }
        var seen = Set<Int>()
        var out: [HookOption] = []
        for p in picks where lines.indices.contains(p.line) && p.line != 0 && !seen.contains(p.line) {
            seen.insert(p.line)
            out.append(.init(line: p.line, text: ShortDoctor.spokenText(lines[p.line]), why: p.why, onScreen: p.text, reading: read(r, line: p.line, delay: 0)))
            if out.count == limit { break }
        }
        return out
    }
}
