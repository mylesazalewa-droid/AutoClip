import AVKit
import SwiftUI
import Charts

/// Assess → Compare: this message next to another one (one of yours, or any YouTube link),
/// to compare preaching styles.
struct CompareSection: View {
    let path: String
    let videos: [String]
    /// Plays a moment in this message (the other one opens in its own window)
    var openOther: (String, Double?) -> Void

    @AppStorage("compare_with") private var otherPath = ""
    @State private var link = ""
    @State private var linkStatus: String?
    @State private var linkError: String?
    @State private var a: MessageCompare.Side?
    @State private var b: MessageCompare.Side?
    @State private var aStatus: String?
    @State private var bStatus: String?
    @State private var problem: String?
    @State private var style: MessageCompare.Style?
    @State private var styleStatus: String?
    @State private var styleError: String?
    @State private var confirmAI = false
    @State private var watching: Watch?

    private let gold = Theme.sand
    private var other: String? { otherPath.isEmpty || otherPath == path || !FileManager.default.fileExists(atPath: otherPath) ? nil : otherPath }
    private var otherTitle: String { b?.title ?? other.map { YTDLP.title(fromFile: URL(fileURLWithPath: $0)) } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            recentCard
            picker
            if let problem { Text(problem).font(.ui(size: 12.5)).foregroundColor(Theme.warn) }
            if other != nil {
                if let a, let b {
                    differencesCard(a, b)
                    sideBySide(a, b)
                    paceChart(a, b)
                    styleCard(a, b)
                } else {
                    AssessCard(title: "Getting both ready") {
                        VStack(alignment: .leading, spacing: 6) {
                            statusLine("This message", aStatus ?? (a == nil ? "Starting…" : "Ready"))
                            statusLine(otherTitle, bStatus ?? (b == nil ? "Starting…" : "Ready"))
                            Text("Measured on this Mac for free. A message that hasn't been transcribed yet takes a few minutes.")
                                .font(.ui(size: 11.5)).foregroundColor(Theme.muted)
                        }
                    }
                }
            }
        }
        .task(id: "\(path)|\(otherPath)") { await load() }
        .sheet(item: $watching) { w in WatchBothSheet(watch: w).appLook() }
        .reportsWork(.assess, "compare", aStatus != nil || bStatus != nil || linkStatus != nil || styleStatus != nil)
    }

    // MARK: Against the last few messages

    @ViewBuilder private var recentCard: some View {
        if let recent = MessageCompare.againstRecent(path), !recent.rows.isEmpty {
            AssessCard(title: "Against the \(recent.count) messages before this one",
                       subtitle: "How this message compares with the average of the ones before it. Free, measured on this Mac.") {
                VStack(spacing: 0) {
                    HStack {
                        Text("").frame(maxWidth: .infinity, alignment: .leading)
                        Text("This one").frame(width: 110, alignment: .trailing)
                        Text("Before (avg)").frame(width: 110, alignment: .trailing)
                    }
                    .font(.ui(size: 11, weight: .semibold)).foregroundColor(Theme.muted).padding(.bottom, 4)
                    ForEach(recent.rows.filter { $0.label != "Coach score" }) { r in
                        HStack {
                            Text(r.label).font(.ui(size: 12.5)).foregroundColor(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                                .help(r.help)
                            value(r.a, r.format).frame(width: 110, alignment: .trailing)
                            value(r.b, r.format).frame(width: 110, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        .overlay(Rectangle().fill(Theme.ink.opacity(0.06)).frame(height: 1), alignment: .bottom)
                    }
                }
            }
        }
    }

    // MARK: Choosing the other message

    private var picker: some View {
        AssessCard(title: "Compare with", subtitle: "Another of your messages, or any preacher's message from YouTube, to compare preaching styles.") {
            HStack(spacing: 10) {
                Menu {
                    ForEach(videos.filter { $0 != path }, id: \.self) { v in
                        Button(YTDLP.title(fromFile: URL(fileURLWithPath: v))) { choose(v) }
                    }
                } label: {
                    Label(other == nil ? "Pick a message" : otherTitle, systemImage: "rectangle.on.rectangle")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton).frame(maxWidth: 320, alignment: .leading)
                .disabled(videos.filter { $0 != path }.isEmpty)
                Text("or").font(.ui(size: 12)).foregroundColor(Theme.muted)
                TextField("Paste a YouTube link", text: $link)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    .onSubmit(download)
                Button("Download", action: download)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || linkStatus != nil)
            }
            if let linkStatus {
                HStack(spacing: 6) { LoadingBar(status: linkStatus, width: 120); Text(linkStatus).font(.ui(size: 12)).foregroundColor(Theme.muted) }
            }
            if let linkError { Text(linkError).font(.ui(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func choose(_ p: String) {
        style = nil; styleError = nil; b = nil
        otherPath = p
    }

    private func download() {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        linkError = nil; linkStatus = "Starting download…"
        Task {
            do {
                let file = try await YTDLP.download(l) { _, msg in Task { @MainActor in linkStatus = msg } }
                linkStatus = nil; link = ""
                choose(file.path)
            } catch {
                linkStatus = nil
                linkError = error.localizedDescription
            }
        }
    }

    // MARK: Loading

    private func load() async {
        problem = nil
        let mine = path
        if a?.path != mine {
            a = nil
            do {
                a = try await MessageCompare.prepare(mine) { msg in Task { @MainActor in aStatus = msg } }
                aStatus = nil
            } catch { problem = "Couldn't read this message: \(error.localizedDescription)"; return }
        }
        guard let o = other else { return }
        if b?.path != o {
            b = nil
            do {
                let side = try await MessageCompare.prepare(o) { msg in Task { @MainActor in bStatus = msg } }
                guard otherPath == o else { return }
                b = side; bStatus = nil
            } catch { problem = "Couldn't read \(YTDLP.title(fromFile: URL(fileURLWithPath: o))): \(error.localizedDescription)"; return }
        }
        style = MessageCompare.savedStyle(mine, o)
    }

    private func statusLine(_ title: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if s == "Ready" { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.good) }
                Text(title).font(.ui(size: 12.5, weight: .medium)).foregroundColor(Theme.ink).lineLimit(1)
                Text(s).font(.ui(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
            if s != "Ready" { LoadingBar(status: s, width: 320) }
        }
    }

    // MARK: Results

    private func differencesCard(_ a: MessageCompare.Side, _ b: MessageCompare.Side) -> some View {
        let d = MessageCompare.differences(a.report, b.report, other: "The other message")
        return AssessCard(title: "What stands out", subtitle: "\u{201C}\(b.title)\u{201D} compared with this message") {
            if d.isEmpty {
                Text("The two are close on everything AutoClip measures. The AI comparison below looks at the content.")
                    .font(.ui(size: 13)).foregroundColor(Theme.ink.opacity(0.8))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(d, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(gold).frame(width: 5, height: 5).padding(.top, 6)
                            Text(line).font(.ui(size: 13)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func sideBySide(_ a: MessageCompare.Side, _ b: MessageCompare.Side) -> some View {
        AssessCard(title: "Side by side") {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("").frame(width: 150, alignment: .leading)
                Text("This message").frame(maxWidth: .infinity, alignment: .trailing)
                Text(b.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.ui(size: 11.5, weight: .semibold)).foregroundColor(Theme.muted)
            ForEach(MessageCompare.rows(a.report, b.report).filter { $0.a != nil || $0.b != nil }) { r in
                HStack {
                    Text(r.label).font(.ui(size: 13)).foregroundColor(Theme.ink).frame(width: 150, alignment: .leading)
                        .help(r.help)
                    value(r.a, r.format).frame(maxWidth: .infinity, alignment: .trailing)
                    value(r.b, r.format).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .help(r.help)
                Divider().opacity(0.4)
            }
          }
          .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func value(_ v: Double?, _ f: String) -> some View {
        Text(v.map { String(format: f, $0) } ?? "–").font(.ui(size: 13, weight: .semibold, design: .rounded)).foregroundColor(gold)
    }

    /// Pace through each message, laid over the same stretch (start to end) so different lengths line up.
    private func paceChart(_ a: MessageCompare.Side, _ b: MessageCompare.Side) -> some View {
        /// About 40 points per message: each the average pace over its stretch, so the lines read as a shape
        func points(_ s: MessageCompare.Side, _ name: String) -> [(Double, Double, String)] {
            guard let d = s.report.delivery, !d.pace.isEmpty else { return [] }
            let n = d.pace.count, buckets = min(40, n)
            return (0..<buckets).compactMap { k in
                let lo = k * n / buckets, hi = max(lo + 1, (k + 1) * n / buckets)
                let vals = d.pace[lo..<hi].compactMap { $0 }
                guard !vals.isEmpty else { return nil }
                return (Double(k) / Double(max(1, buckets - 1)) * 100, vals.reduce(0, +) / Double(vals.count), name)
            }
        }
        let pts = points(a, "This message") + points(b, b.title)
        return AssessCard(title: "Pace through the message", subtitle: "Words a minute from start to finish, so a longer and a shorter message line up") {
            if pts.isEmpty {
                Text("Pace isn't measured yet.").font(.ui(size: 12.5)).foregroundColor(Theme.muted)
            } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Through the message", p.0), y: .value("Words / min", p.1))
                            .foregroundStyle(by: .value("Message", p.2))
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartForegroundStyleScale(domain: ["This message", b.title], range: [gold, Theme.action])
                .chartXAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
                .frame(height: 170)
            }
        }
    }

    private func styleCard(_ a: MessageCompare.Side, _ b: MessageCompare.Side) -> some View {
        AssessCard(title: "Preaching style", subtitle: "AI reads both transcripts: opening, structure, stories, Scripture, application and close, and what you could borrow.") {
            if let style {
                VStack(alignment: .leading, spacing: 12) {
                    Text(style.summary).font(.ui(size: 13.5)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    ForEach(style.areas) { ar in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(ar.area).font(.ui(size: 12, weight: .semibold)).foregroundColor(gold)
                                if let ta = MessageCompare.moment(ar, side: a, a: true), let tb = MessageCompare.moment(ar, side: b, a: false) {
                                    Button { watching = Watch(area: ar.area, a: a.path, aTime: ta, aTitle: "This message", b: b.path, bTime: tb, bTitle: b.title) } label: {
                                        Label("Watch both", systemImage: "play.rectangle.on.rectangle")
                                    }
                                    .buttonStyle(.plain).font(.ui(size: 11.5)).foregroundColor(gold)
                                    .help("Play this part of each message side by side")
                                }
                            }
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("This message").font(.ui(size: 11)).foregroundColor(Theme.muted)
                                    Text(ar.a).font(.ui(size: 12.5)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .topLeading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.title).font(.ui(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
                                    Text(ar.b).font(.ui(size: 12.5)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        Divider().opacity(0.4)
                    }
                    if !style.borrow.isEmpty {
                        Text("Worth borrowing").font(.ui(size: 12, weight: .semibold)).foregroundColor(gold)
                        ForEach(style.borrow) { x in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(x.idea).font(.ui(size: 13, weight: .medium)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    Text("\u{201C}\(x.example)\u{201D}").font(.ui(size: 12)).italic().foregroundColor(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let t = x.time {
                                        Button { openOther(b.path, t) } label: { Label(stamp(t), systemImage: "play.fill") }
                                            .buttonStyle(.plain).font(.ui(size: 11.5)).foregroundColor(gold)
                                            .help("Open the other message at this moment")
                                    }
                                }
                            }
                        }
                    }
                    if !style.keep.isEmpty {
                        Text("Keep doing").font(.ui(size: 12, weight: .semibold)).foregroundColor(gold)
                        ForEach(style.keep, id: \.self) { k in
                            Text("• \(k)").font(.ui(size: 12.5)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Compare again") { confirmAI = true }.buttonStyle(.plain).font(.ui(size: 12)).foregroundColor(gold)
                }
            } else if let styleStatus {
                HStack(spacing: 8) { LoadingBar(status: styleStatus); Text(styleStatus).font(.ui(size: 13)).foregroundColor(Theme.muted) }
            } else {
                Button { confirmAI = true } label: { Label("Compare preaching styles with AI", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }
            if let styleError { Text(styleError).font(.ui(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
        }
        .alert("Compare preaching styles?", isPresented: $confirmAI) {
            Button("Compare") { runStyle(a, b) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI reads both transcripts. Uses \(AICost.phrase()). The result is saved, so opening it again is free.")
        }
    }

    private func runStyle(_ a: MessageCompare.Side, _ b: MessageCompare.Side) {
        styleError = nil; styleStatus = "Reading both messages…"
        Task {
            do {
                let s = try await MessageCompare.styleCompare(a, b)
                styleStatus = nil
                style = s
            } catch {
                styleStatus = nil
                styleError = error.localizedDescription
            }
        }
    }

    private func stamp(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}


/// One part of two messages, to watch side by side
struct Watch: Identifiable {
    var id: String { area + a + b }
    let area: String
    let a: String, aTime: Double, aTitle: String
    let b: String, bTime: Double, bTitle: String
}

/// The same part of two messages, side by side: play one, then the other.
struct WatchBothSheet: View {
    let watch: Watch
    @Environment(\.dismiss) private var dismiss
    @State private var left: AVPlayer?
    @State private var right: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(watch.area).font(.ui(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 14) {
                side(watch.aTitle, left, watch.aTime)
                side(watch.bTitle, right, watch.bTime)
            }
            Text("Starting a video pauses the other, so you can hear one, then the other.")
                .font(.ui(size: 12)).foregroundColor(Theme.muted)
        }
        .padding(20)
        .frame(width: 980, height: 440)
        .onAppear {
            let l = AVPlayer(url: URL(fileURLWithPath: watch.a)), r = AVPlayer(url: URL(fileURLWithPath: watch.b))
            l.seek(to: CMTime(seconds: watch.aTime, preferredTimescale: 600))
            r.seek(to: CMTime(seconds: watch.bTime, preferredTimescale: 600))
            left = l; right = r
        }
        .onDisappear { left?.pause(); right?.pause() }
        // Only one plays at a time
        .onReceive(NotificationCenter.default.publisher(for: AVPlayer.rateDidChangeNotification)) { n in
            guard let p = n.object as? AVPlayer, p.rate > 0 else { return }
            if p === left { right?.pause() } else if p === right { left?.pause() }
        }
    }

    private func side(_ title: String, _ player: AVPlayer?, _ t: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(size: 12.5, weight: .medium)).lineLimit(1)
            if let player { VideoPlayer(player: player).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 8)) }
            else { Rectangle().fill(Color.black).frame(height: 300) }
            Text("From \(String(format: "%d:%02d", Int(t) / 60, Int(t) % 60))").font(.ui(size: 11.5)).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
