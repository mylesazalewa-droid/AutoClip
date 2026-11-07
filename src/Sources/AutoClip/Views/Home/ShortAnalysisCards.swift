import SwiftUI

/// The video's timeline with the moments viewers are likely to leave, each with its fix.
struct DropOffCard: View {
    @Binding var review: ShortReview
    let issues: [DropOff]
    let playhead: Double
    let real: PostedShort?
    let onJump: (Double) -> Void
    @State private var showAll = false

    private func color(_ issue: DropOff) -> Color {
        if DropOffMap.isFixed(issue, review.choices) { return Theme.good }
        return issue.severity >= 3 ? Theme.danger : issue.severity == 2 ? Theme.warn : Theme.sand.opacity(0.75)
    }

    /// Worst first
    private var ranked: [DropOff] {
        // Fixed items stay where they are, so rows never move under the pointer
        issues.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.start < $1.start }
    }

    var body: some View {
        AssessCard(title: "Drop-off map", subtitle: "Where viewers are likely to leave. This is an estimate from the video, not real viewer data.") {
            if issues.isEmpty {
                Text("Nothing stands out. No long pauses, repeats or slow stretches were found.")
                    .font(.system(size: 12)).foregroundColor(Theme.text)
            } else {
                strip
                let open = issues.filter { !DropOffMap.isFixed($0, review.choices) }.count
                Text(open == 0 ? "All \(issues.count) are handled in your edit." : "\(open) of \(issues.count) still open in your edit.")
                    .font(.system(size: 11)).foregroundColor(Theme.muted)
                let list = showAll ? ranked : Array(ranked.prefix(6))
                ForEach(list) { row($0) }
                if ranked.count > 6 {
                    Button(showAll ? "Show fewer" : "Show all \(ranked.count)") { showAll.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.sand)
                }
            }
            if let real, real.heldAt3s != nil || real.heldAtHalf != nil || real.heldAtEnd != nil {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text("REAL VIEWERS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundColor(Theme.faint)
                Text(realSummary(real)).font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func realSummary(_ s: PostedShort) -> String {
        var parts: [String] = []
        if let v = s.heldAt3s { parts.append("\(Int(v))% still watching at 3 seconds") }
        if let v = s.heldAtHalf { parts.append("\(Int(v))% at the halfway point") }
        if let v = s.heldAtEnd { parts.append("\(Int(v))% at the end") }
        return parts.joined(separator: ", ") + "."
    }

    private func isPicture(_ issue: DropOff) -> Bool {
        if case .punchIn = issue.fix { return true }
        return false
    }

    /// Speech and picture get a lane each, because a long stretch of unchanged picture would cover everything else.
    private var strip: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 6) {
                Text("Speech").frame(height: 12)
                Text("Picture").frame(height: 12)
            }
            .font(.system(size: 9, weight: .medium)).foregroundColor(Theme.faint)
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    lane(issues.filter { !isPicture($0) }, width: width)
                    lane(issues.filter(isPicture), width: width).offset(y: 18)
                    Rectangle().fill(Color.white).frame(width: 2, height: 30)
                        .offset(x: min(width - 2, width * playhead / max(review.duration, 0.1)))
                }
                .contentShape(Rectangle())
                .onTapGesture { location in onJump(max(0, min(1, location.x / max(width, 1))) * review.duration) }
            }
            .frame(height: 30)
        }
    }

    private func lane(_ list: [DropOff], width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07)).frame(width: width, height: 12)
            ForEach(list) { issue in
                let x = width * issue.start / max(review.duration, 0.1)
                let w = max(4, width * (issue.end - issue.start) / max(review.duration, 0.1))
                RoundedRectangle(cornerRadius: 2).fill(color(issue)).frame(width: max(1, min(w, width - x)), height: 12).offset(x: min(x, width - 1))
            }
        }
        .frame(width: width, height: 12, alignment: .leading)
    }

    private func row(_ issue: DropOff) -> some View {
        let fixed = DropOffMap.isFixed(issue, review.choices)
        return HStack(alignment: .top, spacing: 10) {
            Button { onJump(issue.start) } label: {
                Text(assessClock(issue.start)).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.sand).frame(width: 36, alignment: .leading)
            }
            .buttonStyle(.plain).help("Play this moment")
            Circle().fill(color(issue)).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.system(size: 12, weight: .semibold)).foregroundColor(fixed ? Theme.muted : Theme.cream)
                Text(issue.detail).font(.system(size: 11)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if issue.fix != nil {
                if fixed {
                    Button { DropOffMap.toggle(issue, &review.choices) } label: {
                        Label("Fixed", systemImage: "checkmark").font(.system(size: 11, weight: .medium)).foregroundColor(Theme.good)
                    }
                    .buttonStyle(.plain).help("Undo this fix")
                } else {
                    Button(issue.fixLabel) { DropOffMap.toggle(issue, &review.choices) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        }
    }
}

/// The first three seconds scored separately, with other openings to try.
struct HookLabCard<Extra: View>: View {
    @Binding var review: ShortReview
    let onPreviewOriginal: () -> Void
    let onPreview: (HookOption) -> Void
    @ViewBuilder var extra: Extra
    @ObservedObject private var results = ShortResultsStore.shared
    /// Kept so playback doesn't redo this on every tick
    @State private var now: HookReading?
    @State private var options: [HookOption] = []
    // Not the chosen hook: picking one shouldn't reorder the list under the pointer
    private var readKey: String { "\(review.picture?.jumps.count ?? -1)|\(review.hookOptions?.count ?? 0)" }

    private var chosen: Int? { review.choices.useHook ? review.hook?.line : nil }

    var body: some View {
        AssessCard(title: "Hook lab", subtitle: "Your first 3 seconds. These scores are guides from simple checks, not predictions of how it will do.") {
            HStack(spacing: 22) {
                meter("Words", now?.words)
                meter("Picture", now?.picture)
                meter("Sound", now?.sound)
                Spacer()
            }
            ForEach(Array((now?.notes ?? []).enumerated()), id: \.offset) { _, n in
                Label(n.text, systemImage: n.good ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundColor(n.good ? Theme.muted : Theme.warn)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            optionRow(title: "Your opening", text: review.lines.first.map(ShortDoctor.spokenText) ?? "", why: nil, reading: nil, isOn: chosen == nil, badge: nil, action: onPreviewOriginal)
            if options.isEmpty {
                Text("No other line works as an opening by itself.").font(.system(size: 12)).foregroundColor(Theme.muted)
            }
            ForEach(options) { o in
                optionRow(title: nil, text: o.text, why: o.why, reading: o.reading, isOn: chosen == o.line, badge: results.insight(forOpening: o.text)) { onPreview(o) }
            }
            extra
        }
        .task(id: readKey) {
            let r = review
            now = HookLab.current(r)
            options = HookLab.options(r)
        }
    }

    private func meter(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map(String.init) ?? "…").font(Theme.display(24, weight: .medium)).foregroundColor(value.map { $0 >= 70 ? Theme.good : $0 >= 50 ? Theme.cream : Theme.warn } ?? Theme.faint).monospacedDigit()
            Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.muted)
        }
    }

    private func optionRow(title: String?, text: String, why: String?, reading: HookReading?, isOn: Bool, badge: ResultInsight?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundColor(Theme.faint) }
                Text("“\(text)”").font(Theme.display(14).italic()).foregroundColor(isOn ? .white : Theme.text).fixedSize(horizontal: false, vertical: true)
                if let why, !why.isEmpty { Text(why).font(.system(size: 11)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                if let reading {
                    Text("Words \(reading.words) · Picture \(reading.picture.map(String.init) ?? "…") · Sound \(reading.sound)")
                        .font(.system(size: 10, weight: .medium)).foregroundColor(Theme.faint).monospacedDigit()
                }
                if let badge {
                    Text("From your results: \(badge.detail.lowercased().replacingOccurrences(of: ".", with: "")) (\(badge.count) shorts vs \(badge.others))")
                        .font(.system(size: 10, weight: .medium)).foregroundColor(badge.difference > 0 ? Theme.good : Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Button(action: action) {
                Label(isOn ? "In your edit" : "Preview", systemImage: isOn ? "checkmark" : "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .help(isOn ? "Play the first few seconds" : "Put this in your edit and play the first few seconds")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOn ? Theme.sand.opacity(0.1) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isOn ? Theme.sand.opacity(0.5) : Theme.line, lineWidth: 1))
    }
}
