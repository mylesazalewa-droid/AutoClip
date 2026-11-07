import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

// Sections of the Assess tab beyond filler words: delivery, AI coach, stage presence, progress.
// Each takes the saved SpeakerReport plus a `play` closure that jumps the video to a moment.

private let gold = Theme.sand
private let good = Theme.good
private let warn = Theme.warn

func assessTime(_ s: Double) -> String {
    let i = Int(max(0, s))
    return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
}

struct AssessCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "diamond.fill").font(.system(size: 5)).foregroundColor(Theme.sand.opacity(0.8))
                    Text(title.uppercased()).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.sand.opacity(0.85)).tracking(1.6)
                }
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

/// A "time link": click to play that moment.
struct TimeLink: View {
    let time: Double
    let play: (Double) -> Void
    var body: some View {
        Button(assessTime(time)) { play(time) }
            .buttonStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
            .help("Play this moment")
    }
}

struct Pointer: Identifiable { let id = UUID(); let icon: String; let text: String; let good: Bool }

func pointerList(_ pointers: [Pointer]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(pointers) { p in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: p.icon).font(.system(size: 12)).foregroundColor(p.good ? good : warn).frame(width: 14)
                Text(p.text).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Delivery

struct DeliverySection: View {
    let report: SpeakerReport
    let d: SpeakerReport.Delivery
    let play: (Double) -> Void

    private var minutes: Double { report.speakingMinutes }

    var pointers: [Pointer] {
        var p: [Pointer] = []
        let wpm = d.averageWPM
        if wpm > 175 {
            p.append(.init(icon: "hare", text: String(format: "You average %.0f words a minute — fast for preaching. Slow to 140–160 at your key points so they land.", wpm), good: false))
        } else if wpm < 115 {
            p.append(.init(icon: "tortoise", text: String(format: "You average %.0f words a minute. Pick up the pace in stories and transitions to keep energy up.", wpm), good: false))
        } else {
            p.append(.init(icon: "checkmark.circle", text: String(format: "A comfortable %.0f words a minute.", wpm), good: true))
        }
        let pausesPerMin = Double(d.naturalPauses) / minutes
        if pausesPerMin < 3 {
            p.append(.init(icon: "pause.circle", text: String(format: "Only %.1f pauses a minute. Pause for a beat after each big truth — silence tells people \"this matters\".", pausesPerMin), good: false))
        } else {
            p.append(.init(icon: "checkmark.circle", text: String(format: "Good use of pauses (%.1f a minute).", pausesPerMin), good: true))
        }
        if !d.breathlessRuns.isEmpty {
            p.append(.init(icon: "wind", text: "\(d.breathlessRuns.count) stretch\(d.breathlessRuns.count == 1 ? "" : "es") of 30+ seconds with no pause. Break long thoughts into shorter sentences.", good: false))
        }
        if d.pitchRangeSemitones < 3 || !d.monotoneStretches.isEmpty {
            p.append(.init(icon: "waveform.path", text: "Your pitch stays flat\(d.monotoneStretches.isEmpty ? "" : " in \(d.monotoneStretches.count) stretch\(d.monotoneStretches.count == 1 ? "" : "es")"). Let your voice rise for questions and drop low for weighty moments.", good: false))
        } else {
            p.append(.init(icon: "checkmark.circle", text: "Lively vocal variety — your pitch moves naturally.", good: true))
        }
        if d.trailingOffPercent > 20 {
            p.append(.init(icon: "speaker.wave.1", text: String(format: "%.0f%% of sentences trail off at the end. Keep your volume up through the last word — that's often the most important one.", d.trailingOffPercent), good: false))
        }
        let crutchPerMin = Double(d.crutches.count) / minutes
        if let top = Dictionary(grouping: d.crutches, by: \.kind).max(by: { $0.value.count < $1.value.count }), crutchPerMin > 0.5 {
            p.append(.init(icon: "text.bubble", text: "\"\(top.key.replacingOccurrences(of: "?", with: ""))\" came up \(top.value.count) times. Try replacing it with a pause.", good: false))
        }
        let total = max(1, d.youCount + d.weCount + d.iCount)
        if Double(d.iCount) / Double(total) > 0.45 {
            p.append(.init(icon: "person", text: "Lots of \"I/me\" language. Turn more statements toward the listener (\"you\") or the church family (\"we\").", good: false))
        } else {
            p.append(.init(icon: "checkmark.circle", text: "Listener-focused language — plenty of \"you\" and \"we\".", good: true))
        }
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AssessCard(title: "Pointers") { pointerList(pointers) }

            AssessCard(title: "Pace", subtitle: String(format: "Average %.0f words per minute · comfortable preaching is about 130–170", d.averageWPM)) {
                Chart {
                    RectangleMark(yStart: .value("", 130), yEnd: .value("", 170)).foregroundStyle(good.opacity(0.08))
                    ForEach(Array(d.pace.enumerated()), id: \.offset) { i, v in
                        if let v {
                            LineMark(x: .value("Minute", Double(i) * d.paceBin / 60), y: .value("WPM", v))
                                .foregroundStyle(gold).interpolationMethod(.catmullRom)
                        }
                    }
                }
                .chartXAxisLabel("minutes").chartYAxisLabel("words / min")
                .chartYScale(domain: 60...260)
                .frame(height: 150)
                spanList("Too fast (over 180)", d.fastStretches)
                spanList("Slow (under 110)", d.slowStretches)
            }

            AssessCard(title: "Pauses",
                       subtitle: String(format: "%d natural pauses (%.1f a minute) · %d long pauses over 2s", d.naturalPauses, Double(d.naturalPauses) / minutes, d.longPauses)) {
                if d.breathlessRuns.isEmpty {
                    Text("No long stretches without a breath.").font(.system(size: 13)).foregroundColor(good)
                } else {
                    spanList("30+ seconds without pausing", d.breathlessRuns)
                }
            }

            AssessCard(title: "Voice", subtitle: String(format: "Pitch spread %.1f semitones (lively speech is about 3–5) · %.0f%% of sentences trail off", d.pitchRangeSemitones, d.trailingOffPercent)) {
                Chart {
                    ForEach(Array(d.pitch.enumerated()), id: \.offset) { i, v in
                        if let v {
                            LineMark(x: .value("Minute", Double(i) * d.voiceBin / 60), y: .value("Pitch", v))
                                .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                        }
                    }
                    ForEach(d.monotoneStretches, id: \.start) { s in
                        RectangleMark(xStart: .value("", s.start / 60), xEnd: .value("", s.end / 60))
                            .foregroundStyle(warn.opacity(0.15))
                    }
                }
                .chartXAxisLabel("minutes").chartYAxisLabel("pitch (Hz)")
                .frame(height: 120)
                Chart {
                    ForEach(Array(d.loudness.enumerated()), id: \.offset) { i, v in
                        if let v {
                            AreaMark(x: .value("Minute", Double(i) * d.voiceBin / 60), yStart: .value("", -50), yEnd: .value("Loudness", v))
                                .foregroundStyle(gold.opacity(0.35))
                        }
                    }
                }
                .chartYScale(domain: -50...0)
                .chartXAxisLabel("minutes").chartYAxisLabel("loudness (dB)")
                .frame(height: 90)
                spanList("Flat (monotone) stretches", d.monotoneStretches)
            }

            AssessCard(title: "Crutch phrases", subtitle: String(format: "%d in total · %.1f a minute", d.crutches.count, Double(d.crutches.count) / minutes)) {
                let groups = Dictionary(grouping: d.crutches, by: \.kind).sorted { $0.value.count > $1.value.count }
                if groups.isEmpty {
                    Text("None found.").font(.system(size: 13)).foregroundColor(good)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.key) { k, v in
                            Menu {
                                ForEach(v) { m in Button("\(assessTime(m.time))  \(m.context)") { play(m.time) } }
                            } label: {
                                HStack {
                                    Text("\"\(k.replacingOccurrences(of: "?", with: ""))\"").font(.system(size: 13)).foregroundColor(Theme.ink)
                                    Spacer()
                                    Text("\(v.count)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(gold)
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.ink.opacity(0.07)).cornerRadius(7)
                        }
                    }
                    Text("Click a phrase to jump to each time it was said.").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
            }

            AssessCard(title: "Audience focus") {
                let total = Double(max(1, d.youCount + d.weCount + d.iCount))
                HStack(spacing: 14) {
                    stat("\"you\"", d.youCount, Double(d.youCount) / total)
                    stat("\"we\"", d.weCount, Double(d.weCount) / total)
                    stat("\"I\"", d.iCount, Double(d.iCount) / total)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(d.questions)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(Theme.ink)
                        Text("questions asked").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ n: Int, _ share: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(gold)
            Text("\(label) · \(Int(share * 100))%").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
        }
    }

    @ViewBuilder private func spanList(_ title: String, _ spans: [SpeakerReport.Span]) -> some View {
        if !spans.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title + ":").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                HStack(spacing: 8) {
                    ForEach(spans.prefix(10), id: \.start) { s in TimeLink(time: s.start, play: play) }
                    if spans.count > 10 {
                        Text("+\(spans.count - 10) more").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    }
                }
            }
        }
    }
}

// MARK: - AI coach

struct CoachSection: View {
    let report: SpeakerReport
    let status: String?
    let error: String?
    let run: () -> Void
    let play: (Double) -> Void

    static let kindColors: [String: Color] = [
        "intro": Color(red: 0.6, green: 0.6, blue: 0.65), "point": gold, "story": Color(red: 0.95, green: 0.45, blue: 0.85),
        "scripture": Color(red: 0.45, green: 0.75, blue: 1.0), "application": good, "close": Theme.danger,
        "other": Color(red: 0.4, green: 0.4, blue: 0.45)]

    var body: some View {
        if let c = report.coach {
            VStack(alignment: .leading, spacing: 14) {
                AssessCard(title: "Overall") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 0) {
                            Text("\(c.score)").font(.system(size: 42, weight: .bold, design: .rounded)).foregroundColor(gold)
                            Text("out of 10").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                        }
                        Text(c.summary).font(.system(size: 13)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Run again") { run() }.controlSize(.small).disabled(status != nil)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    AssessCard(title: "Strengths") { notes(c.strengths, icon: "hand.thumbsup.fill", color: good) }
                    AssessCard(title: "Work on") { notes(c.improvements, icon: "arrow.up.right.circle.fill", color: warn) }
                }
                AssessCard(title: "Big idea", subtitle: "Clarity \(c.bigIdeaClarity)/10 · stated \(c.bigIdeaMentions.count) time\(c.bigIdeaMentions.count == 1 ? "" : "s")") {
                    Text("“\(c.bigIdea)”").font(.system(size: 14, weight: .medium)).foregroundColor(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("Where you said it:").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                        ForEach(c.bigIdeaMentions, id: \.self) { t in TimeLink(time: t, play: play) }
                    }
                    if c.bigIdeaMentions.count < 3 {
                        Text("Tip: state your big idea in one memorable sentence and repeat it 3+ times — at the start, middle and end.")
                            .font(.system(size: 12)).foregroundColor(warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
                AssessCard(title: "Sermon map", subtitle: "Click a block to play it") { sermonMap(c) }
                HStack(alignment: .top, spacing: 14) {
                    AssessCard(title: "Strongest moments") { moments(c.best, color: good) }
                    AssessCard(title: "Weakest moments") { moments(c.weakest, color: warn) }
                }
                if !c.jargon.isEmpty {
                    AssessCard(title: "Insider words", subtitle: "A newcomer might not know these — explain them or use plainer words") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(c.jargon, id: \.self) { j in
                                Text(j).font(.system(size: 12)).foregroundColor(Theme.ink).lineLimit(1)
                                    .padding(.horizontal, 9).padding(.vertical, 4).background(Theme.ink.opacity(0.08)).cornerRadius(10)
                            }
                        }
                    }
                }
            }
        } else {
            AssessCard(title: "AI coach") {
                Text("The AI reads the whole message with your delivery measurements and gives a score, 3 strengths, 3 things to work on (with practice drills), your big idea, a map of the sermon, and your strongest and weakest moments.")
                    .font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(status == nil ? "Run AI coach" : "Working…") { run() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(status != nil)
                    if let status { ProgressView().controlSize(.small); Text(status).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.6)) }
                }
                Text("Uses your AI key — about 1–3¢ per sermon.").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                if let error { Text(error).font(.system(size: 12)).foregroundColor(Theme.danger) }
            }
        }
    }

    private func notes(_ list: [SpeakerReport.Coach.Note], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(list) { n in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 12)).foregroundColor(color)
                        Text(n.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                        if let t = n.time { TimeLink(time: t, play: play) }
                    }
                    Text(n.detail).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    if let drill = n.drill, !drill.isEmpty {
                        Text("Practice: " + drill).font(.system(size: 12)).foregroundColor(gold).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func moments(_ list: [SpeakerReport.Coach.Moment], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(list) { m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) { TimeLink(time: m.time, play: play); Text("“\(m.quote)”").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.ink).lineLimit(2) }
                    Text(m.why).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sermonMap(_ c: SpeakerReport.Coach) -> some View {
        let total = max(1, report.duration)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    ForEach(c.sections) { s in
                        let x = CGFloat(s.start / total) * geo.size.width
                        let w = max(3, CGFloat((s.end - s.start) / total) * geo.size.width - 1)
                        Rectangle().fill(Self.kindColors[s.kind] ?? .gray)
                            .frame(width: w, height: 26).offset(x: x)
                            .help("\(s.title) — \(assessTime(s.start))–\(assessTime(s.end))")
                            .onTapGesture { play(s.start) }
                    }
                }
            }
            .frame(height: 26).cornerRadius(4)
            // Time spent per kind
            let byKind = Dictionary(grouping: c.sections, by: \.kind).mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
            HStack(spacing: 12) {
                ForEach(byKind.sorted { $0.value > $1.value }, id: \.key) { k, secs in
                    HStack(spacing: 4) {
                        Circle().fill(Self.kindColors[k] ?? .gray).frame(width: 8, height: 8)
                        Text("\(k.capitalized) \(Int(secs / 60))m").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.75))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(c.sections) { s in
                    HStack(spacing: 8) {
                        TimeLink(time: s.start, play: play)
                        Circle().fill(Self.kindColors[s.kind] ?? .gray).frame(width: 7, height: 7)
                        Text(s.title).font(.system(size: 13)).foregroundColor(Theme.ink)
                        Text("\(max(1, Int((s.end - s.start) / 60))) min").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                    }
                }
            }
        }
    }
}

// MARK: - Stage presence

struct StageSection: View {
    let report: SpeakerReport
    let status: String?
    let play: (Double) -> Void

    var body: some View {
        if let s = report.stage {
            VStack(alignment: .leading, spacing: 14) {
                AssessCard(title: "Where you stand", subtitle: "How often you're in each part of the frame (left → right)") {
                    HStack(spacing: 2) {
                        let peak = max(0.0001, s.positions.max() ?? 1)
                        ForEach(Array(s.positions.enumerated()), id: \.offset) { _, v in
                            Rectangle().fill(gold.opacity(0.08 + 0.92 * v / peak)).frame(height: 40)
                        }
                    }
                    .cornerRadius(4)
                    Text("If the camera operator follows you, this shows the framing more than where you walk.")
                        .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
                HStack(spacing: 14) {
                    metric(String(format: "%.0f%%", s.onScreenPercent), "of the video your face is visible")
                    metric(String(format: "%.0f%%", s.facingPercent), "of that time facing the camera")
                    metric(String(format: "%.2f", s.movementPerMinute), "frame widths moved per minute")
                }
                AssessCard(title: "Pointers") {
                    pointerList(stagePointers(s))
                }
                AssessCard(title: "Movement over time") {
                    Chart {
                        ForEach(Array(s.track.enumerated()), id: \.offset) { i, x in
                            if let x {
                                PointMark(x: .value("Minute", Double(i) * s.trackStep / 60), y: .value("Position", x))
                                    .symbolSize(8).foregroundStyle(gold.opacity(0.7))
                            }
                        }
                    }
                    .chartYScale(domain: 0...1).chartYAxis(.hidden)
                    .chartXAxisLabel("minutes")
                    .frame(height: 90)
                }
            }
        } else {
            AssessCard(title: "Stage presence") {
                HStack(spacing: 8) {
                    if status != nil { ProgressView().controlSize(.small) }
                    Text(status ?? "Not available — no face found in this video (or it was recorded as sound only).")
                        .font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.7))
                }
            }
        }
    }

    private func stagePointers(_ s: SpeakerReport.Stage) -> [Pointer] {
        var p: [Pointer] = []
        if s.facingPercent < 70 {
            p.append(.init(icon: "eye", text: String(format: "You face the camera %.0f%% of the time. Online viewers feel connected when you look into the lens at key moments.", s.facingPercent), good: false))
        } else {
            p.append(.init(icon: "checkmark.circle", text: "Great connection — you face the camera most of the time.", good: true))
        }
        if s.movementPerMinute > 1.2 {
            p.append(.init(icon: "figure.walk", text: "Lots of movement. Plant your feet when you deliver an important line, then move on transitions.", good: false))
        } else if s.movementPerMinute < 0.05 && s.onScreenPercent > 50 {
            p.append(.init(icon: "figure.stand", text: "You stay in one spot. Moving purposefully between points can add energy and mark transitions.", good: false))
        } else {
            p.append(.init(icon: "checkmark.circle", text: "Balanced movement on stage.", good: true))
        }
        return p
    }

    private func metric(_ big: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(big).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(gold)
            Text(label).font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.ink.opacity(0.04)).cornerRadius(10)
    }
}

// MARK: - Progress across sermons

struct SpeakerProgressSection: View {
    let reports: [SpeakerReport]
    let open: (String) -> Void

    var body: some View {
        if reports.count < 2 {
            AssessCard(title: "Progress") {
                Text("Assess at least two messages to see your trends over time. Each assessed video is saved automatically.")
                    .font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.7))
                ForEach(reports, id: \.videoPath) { r in row(r) }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    trend("Filler words per minute", lowerIsBetter: true) { $0.fillersPerMin }
                    trend("Words per minute", lowerIsBetter: nil) { $0.delivery?.averageWPM }
                }
                HStack(alignment: .top, spacing: 14) {
                    trend("Crutch phrases per minute", lowerIsBetter: true) { r in r.delivery.map { Double($0.crutches.count) / max(1, r.speakingMinutes) } }
                    trend("AI coach score", lowerIsBetter: false) { $0.coach.map { Double($0.score) } }
                }
                HStack(alignment: .top, spacing: 14) {
                    trend("Pitch variety (semitones)", lowerIsBetter: false) { $0.delivery?.pitchRangeSemitones }
                    trend("Length (minutes)", lowerIsBetter: nil) { $0.speakingMinutes }
                }
                AssessCard(title: "All assessed messages") {
                    ForEach(reports.reversed(), id: \.videoPath) { r in row(r) }
                }
            }
        }
    }

    private func row(_ r: SpeakerReport) -> some View {
        Button { open(r.videoPath) } label: {
            HStack {
                Text(r.videoDate.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.ink.opacity(0.55)).frame(width: 96, alignment: .leading)
                Text(r.title).font(.system(size: 13)).foregroundColor(Theme.ink).lineLimit(1)
                Spacer()
                Text(String(format: "%.1f fillers/min", r.fillersPerMin)).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.6))
                if let d = r.delivery { Text(String(format: "%.0f wpm", d.averageWPM)).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.6)) }
                if let c = r.coach { Text("\(c.score)/10").font(.system(size: 12, weight: .semibold)).foregroundColor(gold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func trend(_ title: String, lowerIsBetter: Bool?, _ value: @escaping (SpeakerReport) -> Double?) -> some View {
        let pts = reports.compactMap { r in value(r).map { (r.videoDate, $0, r.title) } }
        var verdict: String? = nil
        if pts.count >= 2, let lower = lowerIsBetter {
            let first = pts.prefix(max(1, pts.count / 2)).map(\.1).reduce(0, +) / Double(max(1, pts.count / 2))
            let last = pts.suffix(max(1, pts.count / 2)).map(\.1).reduce(0, +) / Double(max(1, pts.count / 2))
            let better = lower ? last < first * 0.95 : last > first * 1.05
            let worse = lower ? last > first * 1.05 : last < first * 0.95
            verdict = better ? "Improving ↗︎" : worse ? "Slipping — keep an eye on it" : "Steady"
        }
        return AssessCard(title: title, subtitle: verdict) {
            if pts.count < 2 {
                Text("Not enough data yet").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55)).frame(height: 110)
            } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Date", p.0), y: .value(title, p.1)).foregroundStyle(gold)
                        PointMark(x: .value("Date", p.0), y: .value(title, p.1)).foregroundStyle(gold)
                    }
                }
                .frame(height: 110)
            }
        }
    }
}

// MARK: - Sermon notes

struct NotesSection: View {
    let report: SpeakerReport
    let status: String?
    let error: String?
    let run: () -> Void
    let play: (Double) -> Void
    @State private var copied = false

    var body: some View {
        if let n = report.notes {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Button { copy(n) } label: { Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    Button { saveWord(n) } label: { Label("Save as Word…", systemImage: "doc.richtext") }
                    Spacer()
                    if let status {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.6))
                    } else {
                        Button("Write again") { run() }.help("Ask the AI for a fresh set of notes")
                    }
                }
                .controlSize(.small)
                if let error { Text(error).font(.system(size: 12)).foregroundColor(warn) }

                AssessCard(title: n.title) {
                    Text(n.bigIdea).font(.system(size: 14, weight: .semibold)).foregroundColor(gold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(n.summary).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    if !n.verses.isEmpty {
                        Text("Scripture: " + n.verses.joined(separator: "; ")).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    }
                }
                AssessCard(title: "Outline") {
                    ForEach(Array(n.points.enumerated()), id: \.offset) { i, p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(i + 1).").font(.system(size: 13, weight: .bold)).foregroundColor(gold)
                                Text(p.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                                Spacer()
                                if let t = p.time { TimeLink(time: t, play: play) }
                            }
                            Text(p.summary).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
                            if !p.verses.isEmpty {
                                Text(p.verses.joined(separator: "; ")).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55)).padding(.leading, 22)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                if !n.quotes.isEmpty { list("Key quotes", n.quotes.map { "“\($0)”" }, numbered: false) }
                if !n.questions.isEmpty { list("Discussion questions", n.questions, numbered: true) }
                if !n.application.isEmpty { list("This week", n.application, numbered: false) }
                if !n.prayer.isEmpty {
                    AssessCard(title: "Prayer") {
                        Text(n.prayer).font(.system(size: 13)).italic().foregroundColor(Theme.ink.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            AssessCard(title: "Sermon notes", subtitle: "For small groups, the church website or anyone who missed it") {
                Text("The AI reads the message and writes a title, the big idea, a summary, the outline with Scripture, key quotes, five discussion questions, things to try this week and a closing prayer. Copy it or save it as a Word document. Costs about a cent with Claude.")
                    .font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let status {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.7))
                    } else {
                        Button { run() } label: { Label("Write sermon notes", systemImage: "sparkles") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundColor(warn).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func list(_ title: String, _ items: [String], numbered: Bool) -> some View {
        AssessCard(title: title) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(numbered ? "\(i + 1)." : "•").font(.system(size: 13, weight: .semibold)).foregroundColor(gold).frame(width: 16, alignment: .leading)
                    Text(s).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func copy(_ n: SpeakerReport.Notes) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.plainText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func saveWord(_ n: SpeakerReport.Notes) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "docx")!]
        panel.nameFieldStringValue = n.title.replacingOccurrences(of: "/", with: "-") + " – Notes.docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = SermonNotesDocument.attributed(n)
        if let data = try? doc.data(from: NSRange(location: 0, length: doc.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
            try? data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Sermon notes as a formatted document (Word export).
enum SermonNotesDocument {
    static func attributed(_ n: SpeakerReport.Notes) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let accent = NSColor(srgbRed: 0.72, green: 0.42, blue: 0.0, alpha: 1)
        func add(_ s: String, size: CGFloat, bold: Bool = false, italic: Bool = false, color: NSColor = .black,
                 before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0) {
            var font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = before; para.paragraphSpacing = after
            para.headIndent = indent; para.firstLineHeadIndent = indent > 0 ? indent - 14 : 0
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        func heading(_ s: String) { add(s.uppercased(), size: 11, bold: true, color: accent, before: 14, after: 6) }

        add(n.title, size: 22, bold: true, after: 8)
        add(n.bigIdea, size: 13, bold: true, color: accent, after: 8)
        add(n.summary, size: 11, after: 6)
        if !n.verses.isEmpty { add("Scripture: " + n.verses.joined(separator: "; "), size: 10, italic: true, color: .darkGray) }
        heading("Outline")
        for (i, p) in n.points.enumerated() {
            add("\(i + 1).  \(p.title)", size: 12, bold: true, before: 4, after: 2)
            add(p.summary, size: 11, after: 2, indent: 20)
            if !p.verses.isEmpty { add(p.verses.joined(separator: "; "), size: 10, italic: true, color: .darkGray, indent: 20) }
        }
        if !n.quotes.isEmpty { heading("Key quotes"); n.quotes.forEach { add("“\($0)”", size: 11, italic: true, indent: 14) } }
        if !n.questions.isEmpty {
            heading("Discussion questions")
            for (i, q) in n.questions.enumerated() { add("\(i + 1).  \(q)", size: 11, indent: 20) }
        }
        if !n.application.isEmpty { heading("This week"); n.application.forEach { add("•  \($0)", size: 11, indent: 14) } }
        if !n.prayer.isEmpty { heading("Prayer"); add(n.prayer, size: 11, italic: true) }
        return out
    }
}

// MARK: - Practice vs sermons

/// For a practice recording: how it compares with the speaker's real sermons.
struct PracticeCompareCard: View {
    let report: SpeakerReport
    let sermons: [SpeakerReport]

    var body: some View {
        AssessCard(title: "Practice run", subtitle: sermons.isEmpty ? "Assess a sermon too and this compares the two"
                                                                     : "Compared with your average across \(sermons.count) sermon\(sermons.count == 1 ? "" : "s")") {
            if sermons.isEmpty {
                Text("This is a practice recording, so it isn't included in your progress charts.")
                    .font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.7))
            } else {
                HStack(spacing: 10) {
                    cell("Filler words / min", report.fillersPerMin, avg { $0.fillersPerMin }, "%.1f", lowerIsBetter: true)
                    cell("Words / min", report.delivery?.averageWPM, avg { $0.delivery?.averageWPM }, "%.0f", lowerIsBetter: nil)
                    cell("Pauses / min", report.delivery.map { Double($0.naturalPauses) / max(1, report.speakingMinutes) },
                         avg { r in r.delivery.map { Double($0.naturalPauses) / max(1, r.speakingMinutes) } }, "%.1f", lowerIsBetter: false)
                    cell("Pitch variety", report.delivery?.pitchRangeSemitones, avg { $0.delivery?.pitchRangeSemitones }, "%.1f", lowerIsBetter: false)
                }
            }
        }
    }

    private func avg(_ f: (SpeakerReport) -> Double?) -> Double? {
        let v = sermons.compactMap(f)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    private func cell(_ title: String, _ value: Double?, _ average: Double?, _ fmt: String, lowerIsBetter: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value.map { String(format: fmt, $0) } ?? "–").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(gold)
            Text(title).font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
            if let value, let average {
                let better = lowerIsBetter.map { $0 ? value < average * 0.95 : value > average * 1.05 }
                let worse = lowerIsBetter.map { $0 ? value > average * 1.05 : value < average * 0.95 }
                Text("Sermons: " + String(format: fmt, average))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(better == true ? good : worse == true ? warn : Theme.ink.opacity(0.5))
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.ink.opacity(0.04)).cornerRadius(8)
    }
}
