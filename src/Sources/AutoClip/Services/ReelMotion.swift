import Foundation
import AVFoundation
import QuartzCore

/// Movement in the picture: a quick punch-in on the lines that land hardest, and a slow push
/// through long stretches where nothing else changes. The preview and the export share this.
enum ReelMotion {
    enum Style: String, CaseIterable, Identifiable {
        case off, punch, drift, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "None"
            case .punch: return "Punch-ins"
            case .drift: return "Slow push"
            case .both: return "Both"
            }
        }
    }

    struct Zoom: Equatable {
        var start: Double
        var end: Double
        var punch: Bool
    }

    static let punchScale: CGFloat = 1.10
    static let driftScale: CGFloat = 1.05

    private static let emphasis = ["never", "always", "everything", "nothing", "but god", "listen", "hear me", "i promise", "the truth", "this is it", "right now", "today"]

    /// Where the zooms go, in reel time.
    static func zooms(_ d: ReelDraft) -> [Zoom] {
        let style = Style(rawValue: d.motion ?? "") ?? .off
        guard style != .off else { return [] }
        let keys = Set((d.keywords ?? []).map { $0.lowercased() })
        let byID = Dictionary(d.numberedSentences.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let timeline = d.sentenceTimeline
        let total = d.duration
        var punches: [Zoom] = []
        if style == .punch || style == .both {
            let scored: [(ReelDraft.TimedSentence, Int)] = timeline.compactMap { ts in
                guard let s = byID[ts.id] else { return nil }
                let text = s.keptWords.map(\.word).joined(separator: " ")
                let lower = text.lowercased()
                var v = HookLab.strength(text)
                if text.contains("!") { v += 3 }
                v += ReelDraft.tokens(text).filter { keys.contains($0) }.count * 2
                v += emphasis.filter { lower.contains($0) }.count * 2
                return (ts, v)
            }
            for (ts, v) in scored.sorted(by: { $0.1 > $1.1 }) where v >= 5 {
                let start = ts.start
                guard start > 1.5, start < total - 1 else { continue }
                guard !punches.contains(where: { abs($0.start - start) < 7 }) else { continue }
                punches.append(Zoom(start: start, end: min(ts.end, start + 3.5, total), punch: true))
                if Double(punches.count) >= max(1, total / 9) { break }
            }
            punches.sort { $0.start < $1.start }
        }
        var out = punches
        if style == .drift || style == .both {
            // Slow pushes fill long stretches between punches, starting and ending on a sentence
            let starts = timeline.map(\.start).filter { $0 > 0.5 }
            var edges = [0.0] + punches.flatMap { [$0.start, $0.end] } + [total]
            edges.sort()
            var i = 0
            while i + 1 < edges.count {
                let a = edges[i], b = edges[i + 1]
                if b - a >= 8 {
                    let from = starts.first { $0 >= a + 0.3 && $0 < b - 6 } ?? a
                    let to = starts.last { $0 > from + 6 && $0 <= b - 0.3 } ?? b
                    if to - from >= 6 { out.append(Zoom(start: from, end: to, punch: false)) }
                }
                i += 2
            }
            out.sort { $0.start < $1.start }
        }
        return out
    }

    /// How far in the picture is at `t`.
    static func scale(at t: Double, _ zooms: [Zoom]) -> CGFloat {
        guard let z = zooms.first(where: { t >= $0.start && t < $0.end }) else { return 1 }
        if z.punch { return punchScale }
        let f = (t - z.start) / max(0.1, z.end - z.start)
        return 1 + (driftScale - 1) * CGFloat(f)
    }

    /// The same movement for the export.
    static func animation(_ zooms: [Zoom], duration: Double) -> CAKeyframeAnimation? {
        guard !zooms.isEmpty, duration > 0 else { return nil }
        var pts: [(Double, CGFloat)] = [(0, 1)]
        for z in zooms {
            let s = max(0, z.start), e = min(duration, z.end)
            guard e > s else { continue }
            pts.append((max(0, s - 0.001), 1))
            pts.append((s, z.punch ? punchScale : 1))
            pts.append((max(s, e - 0.001), z.punch ? punchScale : driftScale))
            pts.append((e, 1))
        }
        pts.append((duration, 1))
        pts.sort { $0.0 < $1.0 }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.keyTimes = pts.map { NSNumber(value: $0.0 / duration) }
        a.values = pts.map { NSNumber(value: Double($0.1)) }
        a.calculationMode = .linear
        a.duration = duration
        a.beginTime = AVCoreAnimationBeginTimeAtZero
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        return a
    }
}

/// How the on-screen hook arrives.
enum HookStyle: String, CaseIterable, Identifiable {
    case pop, slide, drop, stamp, wipe
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pop: return "Pop"
        case .slide: return "Slide in"
        case .drop: return "Drop"
        case .stamp: return "Stamp"
        case .wipe: return "Wipe"
        }
    }
}

/// A sermon series' look, applied to every clip from its messages.
struct SeriesLook: Codable, Equatable {
    var look: CaptionLook?
    var hookStyle: String?
    var motion: String?
    /// Small label on every clip, like "BAGGAGE · PART 3"
    var tag: String?
    var showTag: Bool?
}

extension ReelDraft {
    var hookAnimation: HookStyle { HookStyle(rawValue: hookStyle ?? "") ?? .pop }

    /// Takes on a series' look. Part numbers come from the message's place in the series.
    mutating func applySeries(_ s: SermonSeries) {
        guard let l = s.look else { return }
        if let look = l.look { self.look = look }
        if let h = l.hookStyle { hookStyle = h }
        if let m = l.motion { motion = m }
        if l.showTag == true {
            let src = pieces.first?.sourceVideoPath ?? ""
            let part = s.videos.firstIndex(of: src).map { " · PART \($0 + 1)" } ?? ""
            seriesTag = ((l.tag?.isEmpty == false ? l.tag! : s.name) + part).uppercased()
        } else {
            seriesTag = nil
        }
    }
}
