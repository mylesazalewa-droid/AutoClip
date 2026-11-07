import SwiftUI
import AppKit

private let gold = Theme.sand
private let good = Theme.good
private let warn = Theme.warn

/// Assess tab → Series: whether a series taught over several weeks holds together.
/// `open` jumps to a message (and optionally a moment in it).
struct SeriesSection: View {
    let path: String
    /// Every video in the Assess list, for suggestions and the edit sheet
    let videos: [String]
    let reports: [SpeakerReport]
    let open: (String, Double?) -> Void
    @ObservedObject private var store = SeriesStore.shared
    @State private var editing: SermonSeries?
    @State private var copied = false

    private func title(_ p: String) -> String { YTDLP.title(fromFile: URL(fileURLWithPath: p)) }

    private var suggestion: SermonSeries? {
        let free = videos.filter { !PracticeRecorder.isPractice($0) && (store.series(containing: $0) == nil || $0 == path) }
        let dates = Dictionary(reports.map { ($0.videoPath, $0.videoDate) }, uniquingKeysWith: { a, _ in a })
        return SeriesStore.suggestions(titles: free.map { ($0, title($0)) }, dates: dates).first { $0.videos.contains(path) }
    }

    var body: some View {
        Group {
            if let s = store.series(containing: path) {
                seriesView(s)
            } else {
                noSeries
            }
        }
        .sheet(item: $editing) { s in
            SeriesEditSheet(series: s, videos: videos.filter { !PracticeRecorder.isPractice($0) }, title: title)
        }
    }

    // MARK: Not in a series yet

    private var noSeries: some View {
        AssessCard(title: "Series", subtitle: "Is a series taught over several weeks coherent, tied together and easy to follow?") {
            Text("Put the messages of a series together and the AI reads them all at once: the one idea that ties them together, how each week builds on the last, callbacks, gaps, repeats and anything that pulls in different directions.")
                .font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            if let sug = suggestion {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Looks like part of “\(sug.name)”").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                    ForEach(Array(sug.videos.enumerated()), id: \.offset) { i, v in
                        Text("\(i + 1).  \(title(v))").font(.system(size: 13))
                            .foregroundColor(v == path ? gold : Theme.ink.opacity(0.75))
                    }
                    HStack {
                        Button { editing = sug } label: { Label("Make this a series", systemImage: "square.stack.3d.up.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Choose the messages myself…") { editing = SermonSeries(name: SeriesStore.seriesName(title(path)), videos: [path]) }
                    }
                    .padding(.top, 4)
                }
                .padding(12).background(Theme.ink.opacity(0.04)).cornerRadius(8)
            } else {
                Button { editing = SermonSeries(name: SeriesStore.seriesName(title(path)), videos: [path]) } label: {
                    Label("Make a series with this message…", systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: A series

    @ViewBuilder private func seriesView(_ s: SermonSeries) -> some View {
        let status = store.status[s.id]
        VStack(alignment: .leading, spacing: 14) {
            AssessCard(title: "Series · \(s.name)", subtitle: "\(s.videos.count) messages in teaching order") {
                ForEach(Array(s.videos.enumerated()), id: \.offset) { i, v in
                    Button { open(v, nil) } label: {
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(Theme.onSand)
                                .frame(width: 20, height: 20).background(v == path ? gold : Theme.ink.opacity(0.6)).clipShape(Circle())
                            Text(title(v)).font(.system(size: 13, weight: v == path ? .semibold : .regular))
                                .foregroundColor(v == path ? gold : .white).lineLimit(1)
                            Spacer()
                            if let a = s.analysis, a.videos == s.videos, a.parts.indices.contains(i) {
                                fitBar(a.parts[i].fit)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    Button("Edit series…") { editing = s }
                    Spacer()
                    if let status {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.6)).lineLimit(1)
                    } else if s.videos.count < 2 {
                        Text("Add at least one more message").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    } else {
                        Button { store.analyze(s.id) } label: {
                            Label(s.analysis == nil ? "Assess the series" : "Assess again", systemImage: "sparkles")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .controlSize(.small).padding(.top, 4)
                if let e = store.errors[s.id] { Text(e).font(.system(size: 12)).foregroundColor(warn).fixedSize(horizontal: false, vertical: true) }
                if s.analysis == nil && status == nil {
                    Text("Messages without a transcript are transcribed first, so this can take a while. The AI part costs a few cents.")
                        .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
            }
            if let a = s.analysis { results(a, s) }
        }
    }

    private func fitBar(_ fit: Int) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.1)).frame(width: 60, height: 5)
                Capsule().fill(fit >= 7 ? good : fit >= 5 ? gold : warn).frame(width: CGFloat(fit) * 6, height: 5)
            }
            Text("\(fit)/10").font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.ink.opacity(0.6))
        }
        .help("How well this message ties into the series")
    }

    @ViewBuilder private func results(_ a: SeriesAnalysis, _ s: SermonSeries) -> some View {
        if a.videos != s.videos {
            Text("The messages in this series changed since it was assessed. Assess again to update.")
                .font(.system(size: 12)).foregroundColor(warn)
        }
        AssessCard(title: "Coherence") {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    Text("\(a.score)").font(.system(size: 42, weight: .bold, design: .rounded)).foregroundColor(gold)
                    Text("out of 10").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(a.verdict).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    Text(a.summary).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        HStack(alignment: .top, spacing: 14) {
            AssessCard(title: "Throughline") {
                Text(a.throughline).font(.system(size: 13, weight: .semibold)).foregroundColor(gold).fixedSize(horizontal: false, vertical: true)
            }
            AssessCard(title: "How it builds") {
                Text(a.arc).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
        AssessCard(title: "Week by week", subtitle: "Click a moment to hear where the message connects to another week") {
            ForEach(Array(zip(s.videos, a.parts).enumerated()), id: \.offset) { i, pair in
                let (v, p) = pair
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Part \(i + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(gold)
                        Button(title(v)) { open(v, nil) }.buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                        Spacer()
                        fitBar(p.fit)
                    }
                    if !p.bigIdea.isEmpty { Text(p.bigIdea).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.ink.opacity(0.9)).fixedSize(horizontal: false, vertical: true) }
                    if !p.role.isEmpty { Text(p.role).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.65)).fixedSize(horizontal: false, vertical: true) }
                    if !p.note.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb").font(.system(size: 11.5)).foregroundColor(gold)
                            Text(p.note).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(Array(p.links.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let t = l.time {
                                Button(assessTime(t)) { open(v, t) }.buttonStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced)).foregroundColor(gold).help("Play this moment")
                            }
                            Text("“\(l.quote)”").font(.system(size: 12)).italic().foregroundColor(Theme.ink.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                            if let to = l.to {
                                Text(to < i + 1 ? "↩︎ part \(to)" : "↪︎ part \(to)").font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(good)
                            }
                        }
                        .padding(.leading, 4)
                    }
                    if p.links.isEmpty {
                        Text("No clear links to the other weeks").font(.system(size: 11.5)).foregroundColor(warn.opacity(0.8))
                    }
                }
                .padding(.vertical, 6)
                if i < s.videos.count - 1 { Divider().background(Theme.ink.opacity(0.08)) }
            }
        }
        HStack(alignment: .top, spacing: 14) {
            findings("What ties it together", a.strengths, icon: "link", color: good)
            findings("Gaps", a.gaps, icon: "exclamationmark.triangle", color: warn, empty: "No gaps found")
        }
        if !a.overlaps.isEmpty || !a.tensions.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                findings("Repeated without adding", a.overlaps, icon: "arrow.triangle.2.circlepath", color: gold, empty: "None")
                findings("Pulling in different directions", a.tensions, icon: "arrow.left.and.right", color: warn, empty: "None")
            }
        }
        if !a.suggestions.isEmpty {
            AssessCard(title: "To tie it together better") {
                ForEach(Array(a.suggestions.enumerated()), id: \.offset) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").font(.system(size: 13, weight: .semibold)).foregroundColor(gold).frame(width: 18, alignment: .leading)
                        Text(t).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if !a.recap.isEmpty {
            AssessCard(title: "Series recap", subtitle: "For the church website or a newsletter") {
                Text(a.recap).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                Button { copy(a.recap) } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .controlSize(.small)
            }
        }
        Text("Assessed \(a.analyzedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
    }

    private func findings(_ title: String, _ list: [SeriesAnalysis.Finding], icon: String, color: Color, empty: String = "–") -> some View {
        AssessCard(title: title) {
            if list.isEmpty {
                Text(empty).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.55))
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon).font(.system(size: 12)).foregroundColor(color).frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(f.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                            if !f.parts.isEmpty {
                                Text(f.parts.map { "Pt \($0)" }.joined(separator: ", ")).font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                            }
                        }
                        Text(f.detail).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

/// Name a series and choose its messages in teaching order.
struct SeriesEditSheet: View {
    @State var series: SermonSeries
    let videos: [String]
    let title: (String) -> String
    @ObservedObject private var store = SeriesStore.shared
    @Environment(\.dismiss) private var dismiss

    private var isSaved: Bool { store.series.contains { $0.id == series.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isSaved ? "Edit series" : "New series").font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.ink)
            TextField("Series name", text: $series.name).textFieldStyle(.roundedBorder)

            Text("MESSAGES, IN THE ORDER THEY WERE PREACHED").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
            VStack(spacing: 4) {
                ForEach(Array(series.videos.enumerated()), id: \.element) { i, v in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(gold).frame(width: 18)
                        Text(title(v)).font(.system(size: 13)).foregroundColor(Theme.ink).lineLimit(1)
                        Spacer()
                        Button { series.videos.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                        Button { series.videos.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }.disabled(i == series.videos.count - 1)
                        Button { series.videos.remove(at: i) } label: { Image(systemName: "minus.circle") }
                    }
                    .buttonStyle(.borderless).padding(6).background(Theme.ink.opacity(0.05)).cornerRadius(6)
                }
                if series.videos.isEmpty {
                    Text("Add messages from the list below").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                }
            }

            Text("ADD MESSAGES").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(videos.filter { !series.videos.contains($0) }, id: \.self) { v in
                        Button { series.videos.append(v) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle").foregroundColor(gold)
                                Text(title(v)).font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.85)).lineLimit(1)
                                Spacer()
                                if let other = store.series(containing: v), other.id != series.id {
                                    Text("in “\(other.name)”").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                                }
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 180)

            HStack {
                if isSaved {
                    Button("Delete series", role: .destructive) { store.remove(series.id); dismiss() }
                        .help("Only the grouping is removed; the videos stay")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    series.name = series.name.trimmingCharacters(in: .whitespaces)
                    store.upsert(series)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(series.videos.isEmpty || series.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.surface)
    }
}
