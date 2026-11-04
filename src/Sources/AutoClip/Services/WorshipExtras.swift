import Foundation
import AVFoundation
import AppKit
import QuartzCore

// Setlists, rehearsal clips and goals for the Worship tab.

extension WorshipReport {
    /// One song from the team's setlist, placed in the recording.
    struct SetSong: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var start: Double
        /// How the start was found
        var source: Source
        enum Source: String, Codable { case music, lyrics, estimate, manual }
    }
}

extension WorshipStats {
    struct NamedSong: Identifiable {
        var id: Double { part.start }
        let name: String
        let part: Part
        let source: WorshipReport.SetSong.Source?
        let setIndex: Int?
    }

    /// The songs by name when there's a setlist, otherwise as they were detected.
    var namedSongs: [NamedSong] {
        let set = report.setlist.sorted { $0.start < $1.start }
        guard !set.isEmpty else {
            return songs.enumerated().map { NamedSong(name: "Song \($0 + 1)", part: $1, source: nil, setIndex: nil) }
        }
        let music = WorshipStats.sections(report).filter { $0.kind == .song }
        return set.enumerated().map { i, song in
            let limit = i + 1 < set.count ? set[i + 1].start : report.rangeEnd
            // Ends with its music, not at the talking before the next song
            let end = music.filter { $0.start < limit && $0.end > song.start }.last.map { min($0.end, limit) } ?? limit
            let index = report.setlist.firstIndex { $0.id == song.id }
            return NamedSong(name: song.name, part: Part(kind: .song, start: song.start, end: max(end, song.start + 1)),
                             source: song.source, setIndex: index)
        }
    }

    private func samples(in part: Part) -> [WorshipReport.Visual.Sample] {
        (report.visual?.samples ?? []).filter { $0.t >= part.start && $0.t < part.end }
    }
    func smilePercent(in part: Part) -> Double? {
        let read = samples(in: part).filter { $0.smile != nil }
        return read.count >= 3 ? Double(read.filter { $0.smile == true }.count) / Double(read.count) * 100 : nil
    }
    func handsPercent(in part: Part) -> Double? {
        let seen = samples(in: part).filter { $0.people > 0 }
        return seen.count >= 3 ? Double(seen.filter { $0.handsUp > 0 }.count) / Double(seen.count) * 100 : nil
    }
    func facingPercent(in part: Part) -> Double? {
        let s = samples(in: part)
        let faces = s.reduce(0) { $0 + $1.faces }
        return faces >= 3 ? Double(s.reduce(0) { $0 + $1.facing }) / Double(faces) * 100 : nil
    }
}

enum WorshipSetlist {
    private static let small: Set<String> = ["the", "a", "an", "of", "to", "and", "in", "on", "for", "is", "my", "our", "your", "you", "i", "we", "be", "feat", "live"]

    private static func clean(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    /// The words of a title worth listening for.
    static func keywords(_ title: String) -> [String] {
        // "(Live)" and "(feat. someone)" aren't sung
        let bare = title.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let all = bare.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { clean(String($0)) }.filter { !$0.isEmpty }
        let main = all.filter { !small.contains($0) }
        return main.isEmpty ? all : main
    }

    /// When a title's words are sung close together.
    static func hits(_ title: String, in words: [Word]) -> [Double] {
        let keys = keywords(title)
        guard !keys.isEmpty else { return [] }
        let spoken = words.map { clean($0.word) }
        var out: [Double] = []
        let span = max(6, keys.count * 3)
        for i in spoken.indices where keys.contains(spoken[i]) {
            let window = Set(spoken[i..<min(spoken.count, i + span)])
            guard keys.allSatisfy({ window.contains($0) }) else { continue }
            if words[i].startTime - (out.last ?? -100) > 5 { out.append(words[i].startTime) }
        }
        return out
    }

    /// Places each title in the recording. One piece of music per title lines up directly;
    /// otherwise the sung title words show where a medley changes song.
    static func place(_ titles: [String], in report: WorshipReport, words: [Word]) -> [WorshipReport.SetSong] {
        let music = WorshipStats(report).songs
        guard !titles.isEmpty else { return [] }
        if music.count == titles.count {
            return zip(titles, music).map { .init(name: $0, start: $1.start, source: .music) }
        }
        let inRange = words.filter { $0.startTime >= report.rangeStart && $0.startTime < report.rangeEnd }
        let found = titles.map { hits($0, in: inRange) }
        // Each song's first sung title, in setlist order
        var firsts: [Double?] = []
        var after = report.rangeStart
        for h in found {
            let first = h.first { $0 >= after }
            firsts.append(first)
            if let first { after = first + 20 }
        }
        let open = music.first?.start ?? report.rangeStart
        let close = music.last?.end ?? report.rangeEnd
        var out: [WorshipReport.SetSong] = []
        for (i, title) in titles.enumerated() {
            if i == 0 {
                out.append(.init(name: title, start: open, source: .music))
                continue
            }
            guard let first = firsts[i] else {
                // Nothing heard: share out the time up to the next known point
                let previous = out[i - 1].start
                let next = firsts[(i + 1)...].enumerated().first { $0.element != nil }
                let target = next.flatMap { $0.element } ?? close
                let steps = (next?.offset ?? (titles.count - i - 1)) + 2
                out.append(.init(name: title, start: previous + (target - previous) / Double(max(2, steps)), source: .estimate))
                continue
            }
            let previousStart = out[i - 1].start
            let lastBefore = found[i - 1].last { $0 < first && $0 > previousStart } ?? previousStart
            // A real break in the music wins; otherwise halfway between the two songs' titles
            if let gap = music.first(where: { $0.start > lastBefore && $0.start <= first }) {
                out.append(.init(name: title, start: gap.start, source: .music))
            } else {
                out.append(.init(name: title, start: (lastBefore + first) / 2, source: .lyrics))
            }
        }
        return out
    }
}

// MARK: - Clips

enum WorshipClips {
    struct Moment {
        let time: Double
        let label: String
        let caption: String
    }

    private static func fail(_ m: String) -> NSError { NSError(domain: "AutoClip", code: 81, userInfo: [NSLocalizedDescriptionKey: m]) }

    private static func safeName(_ s: String) -> String {
        String(s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-").prefix(60))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Writes a clip per moment plus one rehearsal reel of them all, each with its note on screen.
    /// Returns the folder they went into.
    static func export(path: String, title: String, moments: [Moment], into parent: URL,
                       progress: @escaping (Double) -> Void) async throws -> URL {
        guard !moments.isEmpty else { throw fail("Add a note first.") }
        let folder = parent.appendingPathComponent(safeName(title) + " clips")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sorted = moments.sorted { $0.time < $1.time }
        let steps = Double(sorted.count + 1)
        var list = "Rehearsal clips from \(title)\n\n"
        for (i, m) in sorted.enumerated() {
            try Task.checkCancellation()
            let name = String(format: "%02d %@.mp4", i + 1, safeName(m.label))
            try await write(path: path, moments: [m], to: folder.appendingPathComponent(name)) { progress((Double(i) + $0) / steps) }
            list += "\(String(format: "%02d", i + 1)). \(assessTime(m.time))  \(m.caption)\n"
        }
        try await write(path: path, moments: sorted, to: folder.appendingPathComponent("Rehearsal reel.mp4")) {
            progress((Double(sorted.count) + $0) / steps)
        }
        try? list.write(to: folder.appendingPathComponent("Watch list.txt"), atomically: true, encoding: .utf8)
        progress(1)
        return folder
    }

    /// The note as white text on a dark pill, at twice its size for sharpness.
    private static func captionImage(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGImage? {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize * 2, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: style])
        let pad = fontSize * 1.4
        let bounds = string.boundingRect(with: CGSize(width: width * 2 - pad * 2, height: fontSize * 12),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = Int((bounds.width + pad * 2).rounded(.up)), h = Int((bounds.height + pad).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: fontSize, yRadius: fontSize).fill()
        string.draw(with: NSRect(x: pad, y: pad / 2, width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func write(path: String, moments: [Moment], to url: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw fail("This recording has no picture, so clips can't be made.")
        }
        let total = try await asset.load(.duration).seconds
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw fail("Couldn't start the clip.")
        }
        let audioSource = try await asset.loadTracks(withMediaType: .audio).first
        let audio = audioSource == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var at = CMTime.zero
        var spans: [(start: Double, length: Double, caption: String)] = []
        for m in moments {
            let a = max(0, m.time - 8), b = min(total, m.time + 12)
            let range = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
            try video.insertTimeRange(range, of: source, at: at)
            if let audio, let audioSource { try audio.insertTimeRange(range, of: audioSource, at: at) }
            spans.append((at.seconds, range.duration.seconds, m.caption))
            at = at + range.duration
        }

        // Scale to 1280 wide at most, upright
        let natural = try await source.load(.naturalSize)
        let transform = try await source.load(.preferredTransform)
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        let scale = min(1, 1280 / abs(box.width))
        let size = CGSize(width: (abs(box.width) * scale / 2).rounded() * 2, height: (abs(box.height) * scale / 2).rounded() * 2)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layerInstruction.setTransform(transform.concatenating(.init(translationX: -box.minX, y: -box.minY)).concatenating(.init(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: at)
        instruction.layerInstructions = [layerInstruction]
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]

        // The note sits along the bottom while its moment plays
        let parent = CALayer(), videoLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        let overall = max(at.seconds, 0.1)
        for span in spans {
            guard let image = captionImage(span.caption, width: size.width * 0.88, fontSize: size.height * 0.034) else { continue }
            let note = CALayer()
            note.contents = image
            note.contentsGravity = .resize
            let w = CGFloat(image.width) / 2, h = CGFloat(image.height) / 2
            note.frame = CGRect(x: (size.width - w) / 2, y: size.height * 0.95 - h, width: w, height: h)
            note.opacity = 0
            // Shown only during its own moment
            let show = CAKeyframeAnimation(keyPath: "opacity")
            let from = span.start / overall, to = min(1, (span.start + span.length) / overall)
            show.keyTimes = [0, NSNumber(value: from), NSNumber(value: min(1, from + 0.0001)), NSNumber(value: max(from, to - 0.0001)), NSNumber(value: to), 1]
            show.values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
            show.calculationMode = .linear
            show.duration = overall
            show.beginTime = AVCoreAnimationBeginTimeAtZero
            show.isRemovedOnCompletion = false
            show.fillMode = .both
            note.add(show, forKey: "opacity")
            parent.addSublayer(note)
        }
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw fail("Couldn't start the clip.")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = composition
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in progress(Double(session.progress)) }
        RunLoop.main.add(timer, forMode: .common)
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        timer.invalidate()
        if let e = session.error { throw e }
        guard session.status == .completed else { throw CancellationError() }
    }
}

// MARK: - Goals

struct WorshipGoal: Codable, Equatable, Identifiable {
    enum Measure: String, Codable, CaseIterable, Identifiable {
        case sound = "Sound score", engagement = "Engagement score", smiles = "Smiles in close shots"
        case facing = "Faces toward the camera", stage = "Stage presence score", communication = "Communication score"
        case quietGaps = "Quiet gaps", fillers = "Filler words a minute"
        var id: String { rawValue }
        /// Goals for these are a limit to stay under
        var lowerIsBetter: Bool { self == .quietGaps || self == .fillers }
        var unit: String { self == .smiles || self == .facing ? "%" : "" }
        var defaultTarget: Double {
            switch self {
            case .smiles: return 30
            case .facing: return 65
            case .quietGaps: return 1
            case .fillers: return 3
            default: return 75
            }
        }
        var range: ClosedRange<Double> { self == .quietGaps ? 0...10 : self == .fillers ? 0...10 : 0...100 }
        var step: Double { self == .quietGaps || self == .fillers ? 1 : 5 }
    }
    var id = UUID()
    var measure: Measure
    var target: Double

    var title: String {
        let value = "\(Int(target))\(measure.unit)"
        return measure.lowerIsBetter ? "\(measure.rawValue): \(value) or fewer" : "\(measure.rawValue): \(value) or more"
    }

    /// This service's value; nil when the recording can't show it.
    func value(in s: WorshipStats) -> Double? {
        switch measure {
        case .sound: return s.soundScore.map(Double.init)
        case .engagement: return s.engagementScore.map(Double.init)
        case .smiles: return s.smilePercent
        case .facing: return s.facingPercent
        case .stage: return s.stageScore.map(Double.init)
        case .communication: return s.communicationScore.map(Double.init)
        case .quietGaps: return s.songs.isEmpty ? nil : Double(s.quietGaps.count)
        case .fillers: return s.fillersPerMinute
        }
    }
    func met(_ v: Double) -> Bool { measure.lowerIsBetter ? v <= target : v >= target }
    func text(_ v: Double) -> String {
        measure == .fillers ? String(format: "%.1f", v) : "\(Int(v.rounded()))\(measure.unit)"
    }
}

enum WorshipGoals {
    private static var file: URL { WorshipStore.dir.appendingPathComponent("goals.data") }
    static func load() -> [WorshipGoal] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([WorshipGoal].self, from: $0) } ?? []
    }
    static func save(_ goals: [WorshipGoal]) {
        try? FileManager.default.createDirectory(at: WorshipStore.dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(goals) { try? d.write(to: file) }
    }
}
