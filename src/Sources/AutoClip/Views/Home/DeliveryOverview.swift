import SwiftUI

/// The at-a-glance analysis: four scores as rings, then where each filler word falls in the talk.
/// The scores are a guide worked out from the measurements in the Delivery tab, not a judgement.
struct DeliveryScores: Equatable {
    var energy: Int, variety: Int, pacing: Int, clarity: Int

    /// 0 at `low`, 1 at `high`
    private static func scale(_ v: Double, _ low: Double, _ high: Double) -> Double { min(1, max(0, (v - low) / (high - low))) }
    private static func score(_ v: Double) -> Int { Int((min(1, max(0, v)) * 100).rounded()) }

    init(report r: SpeakerReport, delivery d: SpeakerReport.Delivery) {
        let minutes = max(1, r.speakingMinutes)
        let total = max(1, r.duration)

        // Energy: the voice moves between loud and soft, holds up to the end of sentences, and keeps moving
        let loud = d.loudness.compactMap { $0 }.sorted()
        let spread = loud.isEmpty ? 0 : loud[Int(Double(loud.count - 1) * 0.9)] - loud[Int(Double(loud.count - 1) * 0.1)]
        energy = Self.score(0.5 * Self.scale(spread, 3, 12)
                            + 0.3 * (1 - Self.scale(d.trailingOffPercent, 5, 40))
                            + 0.2 * Self.scale(d.averageWPM, 95, 140))

        // Vocal variety: pitch spread, less time spent flat
        let flat = d.monotoneStretches.reduce(0) { $0 + $1.end - $1.start } / total
        variety = Self.score(Self.scale(d.pitchRangeSemitones, 1.5, 5) - flat)

        // Pacing: time at a comfortable speed, with room to breathe
        let bins = d.pace.compactMap { $0 }
        let comfortable = bins.isEmpty ? 0 : Double(bins.filter { (100...190).contains($0) }.count) / Double(bins.count)
        let breathless = d.breathlessRuns.reduce(0) { $0 + $1.end - $1.start } / total
        pacing = Self.score(comfortable - breathless * 0.5)

        // Clarity: few fillers and crutch phrases in the way of the message
        let clutter = Double(r.fillerCount) / minutes + Double(d.crutches.count) / minutes
        clarity = Self.score(1 - Self.scale(clutter, 1, 9))
    }
}

struct DeliveryOverviewCard: View {
    struct Filler { let kind: String; let time: Double; let context: String }

    let report: SpeakerReport
    let fillers: [Filler]
    let status: String?
    let play: (Double) -> Void

    private static let maxRows = 6
    private var duration: Double { max(1, report.duration) }

    /// Most frequent first
    private var rows: [(kind: String, marks: [Filler])] {
        Dictionary(grouping: fillers, by: \.kind)
            .map { (kind: $0.key, marks: $0.value.sorted { $0.time < $1.time }) }
            .sorted { $0.marks.count != $1.marks.count ? $0.marks.count > $1.marks.count : $0.kind < $1.kind }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mic").font(.system(size: 15)).foregroundColor(Theme.sand).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delivery Analysis").font(Theme.display(22)).foregroundColor(Theme.cream)
                    Text("\(report.title) · Analyzed \(report.analyzedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
                }
            }

            if let d = report.delivery {
                let s = DeliveryScores(report: report, delivery: d)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 16) {
                    ScoreRing(title: "Overall Energy", value: s.energy, why: "How much your volume moves, whether sentences hold up to the last word, and your speed.")
                    ScoreRing(title: "Vocal Variety", value: s.variety, why: "How much your pitch moves, less any flat stretches.")
                    ScoreRing(title: "Pacing", value: s.pacing, why: "Time spent at 100–190 words a minute, less stretches with no pause.")
                    ScoreRing(title: "Clarity", value: s.clarity, why: "How few filler words and crutch phrases there are per minute. It doesn't measure how crisply words are spoken.")
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status ?? "Measuring your delivery…").font(.system(size: 13)).foregroundColor(Theme.muted)
                }
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                Text("FILLER WORDS").font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundColor(Theme.muted)
                if rows.isEmpty {
                    Text("None found.").font(.system(size: 13)).foregroundColor(Theme.good)
                }
                ForEach(rows.prefix(Self.maxRows), id: \.kind) { row in fillerRow(row.kind, row.marks) }
                if rows.count > Self.maxRows {
                    Text("+\(rows.count - Self.maxRows) more").font(.system(size: 11.5)).foregroundColor(Theme.faint)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func fillerRow(_ kind: String, _ marks: [Filler]) -> some View {
        TimelineDotRow(label: "“\(kind)”", marks: marks.map { .init(time: $0.time, seek: $0.time, help: "\(assessTime($0.time)) · \($0.context)") },
                       duration: duration, italic: true, play: play)
    }
}

/// A score out of 100 as a ring. With no value the recording couldn't show it, so none is made up.
struct ScoreRing: View {
    let title: String
    let value: Int?
    let why: String

    var body: some View {
        let strong = (value ?? 0) >= 75
        let color = value == nil ? Theme.muted : strong ? Theme.good : (value ?? 0) >= 55 ? Theme.sand : Theme.warn
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.ink.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(value ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map(String.init) ?? "–").font(Theme.display(20)).foregroundColor(Theme.cream).monospacedDigit()
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.display(15)).foregroundColor(Theme.cream).lineLimit(1)
                Text(value == nil ? "Not readable" : strong ? "Strong" : (value ?? 0) >= 55 ? "Suggestions" : "Focus here")
                    .font(.system(size: 11.5, weight: .medium)).foregroundColor(color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.14)))
            }
        }
        .help(why)
    }
}

/// A count, a label, and a dot on a track for each moment. Click a dot to play it.
struct TimelineDotRow: View {
    struct Mark { let time: Double; let seek: Double; let help: String }
    let label: String
    let marks: [Mark]
    let duration: Double
    var italic = false
    let play: (Double) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(marks.count)").font(.system(size: 11.5, weight: .bold)).foregroundColor(marks.isEmpty ? Theme.muted : Theme.bg).monospacedDigit()
                .frame(minWidth: 32).padding(.vertical, 3)
                .background(Capsule().fill(marks.isEmpty ? Theme.raised2 : Theme.sandDeep))
            Text(label).font(italic ? Theme.display(13).italic() : Theme.display(13)).foregroundColor(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.8).frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.09))
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                        let inset: CGFloat = 8
                        Circle().fill(Theme.sand).frame(width: 7, height: 7)
                            .frame(width: 13, height: 18).contentShape(Rectangle())
                            .position(x: inset + CGFloat(min(1, max(0, m.time / duration))) * (geo.size.width - inset * 2), y: 9)
                            .help(m.help)
                            .onTapGesture { play(m.seek) }
                    }
                }
            }
            .frame(height: 18)
        }
    }
}
