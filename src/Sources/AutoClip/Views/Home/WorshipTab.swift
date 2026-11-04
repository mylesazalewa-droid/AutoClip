import SwiftUI
import AVKit
import Charts
import UniformTypeIdentifiers

/// Assess the worship part of a service: sound, clapping, smiles, stage presence and how the
/// team talks to the room, plus the team's own notes, so each week can build on the last.
struct WorshipTab: View {
    private enum Section: String, CaseIterable { case flow = "Service flow", sound = "Sound", stage = "Stage", talk = "Communication", team = "Team notes", coach = "AI Coach" }

    @State private var reports: [WorshipReport] = []
    @State private var current: WorshipReport?
    @State private var section: Section = .flow
    @State private var player = AVPlayer()
    @State private var status: String?
    @State private var progress = 0.0
    @State private var error: String?
    @State private var job: Task<Void, Never>?
    @State private var link = ""
    @State private var noteText = ""
    @State private var noteCategory = "Sound"
    @State private var coachStatus: String?
    @State private var coachError: String?
    @State private var copied = false
    @State private var setlistText = ""
    @State private var setlistNote: String?
    @State private var goals: [WorshipGoal] = []
    @State private var clipStatus: Double?
    @State private var clipTask: Task<Void, Never>?
    @State private var clipFolder: URL?
    @State private var clipError: String?
    @State private var includeFlagged = false
    @State private var confirmDelete: WorshipReport?

    private static let categories = ["Sound", "Band", "Vocals", "Stage", "Communication", "Flow"]
    private let gold = Theme.sand

    var body: some View {
        Group {
            if let status { working(status) }
            else if let r = current { detail(r) }
            else { landing }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reports = WorshipStore.all(); goals = WorshipGoals.load() }
        .confirmationDialog("Delete this assessment?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { r in
            Button("Delete", role: .destructive) { delete(r) }
            Button("Cancel", role: .cancel) { }
        } message: { r in
            Text("This removes the scores, notes and ratings for \(r.title). Your original recording isn't deleted.")
        }
    }

    private func working(_ text: String) -> some View {
        VStack(spacing: 12) {
            Text("Assessing the worship").font(Theme.display(22)).foregroundColor(Theme.cream)
            ProgressView(value: progress).tint(Theme.action).frame(width: 320)
            Text(text).font(.system(size: 12)).foregroundColor(Theme.muted)
            Button("Cancel") { job?.cancel(); job = nil; status = nil }.buttonStyle(SecondaryButtonStyle(compact: true))
        }
    }

    // MARK: Landing

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let latest = reports.first {
                    let stats = WorshipStats(latest)
                    CinematicHero(path: latest.visual == nil ? nil : latest.videoPath, eyebrow: "Latest service · \(latest.date.formatted(date: .abbreviated, time: .omitted))",
                                  title: latest.title, detail: "\(stats.namedSongs.count) song\(stats.namedSongs.count == 1 ? "" : "s") · sound \(stats.soundScore.map(String.init) ?? "–") · communication \(stats.communicationScore.map(String.init) ?? "–")",
                                  height: 400, icon: "music.note") {
                        Button { open(latest) } label: { Label("Open", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    PageHeader(eyebrow: "Review", title: "Worship", subtitle: "Add a service recording to see how the sound, clapping, smiles, stage presence and communication came across. Your files stay on this Mac.")
                        .padding(.horizontal, -32)
                }
                HStack(spacing: 10) {
                    Button { chooseFile() } label: { Label("Add a recording", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle(compact: true))
                    TextField("Or paste a YouTube link", text: $link).textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(maxWidth: 340)
                        .onSubmit { addLink() }
                    Button("Get it") { addLink() }.buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                if reports.count >= 2 { trend }
                if !reports.isEmpty { goalsCard(current: nil) }
                if reports.isEmpty {
                    EmptyState(icon: "music.mic", title: "No services yet", message: "Add a recording of a service. AutoClip finds the songs and leaves out the sermon.") { EmptyView() }
                        .frame(height: 300)
                } else {
                    ForEach(Array(reports.enumerated()), id: \.element.videoPath) { _, r in serviceRow(r) }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
        }
    }

    private func serviceRow(_ r: WorshipReport) -> some View {
        let s = WorshipStats(r)
        return HStack(spacing: 8) {
        Button { open(r) } label: {
            HStack(spacing: 16) {
                if r.visual != nil {
                    VideoFrameView(path: r.videoPath, width: 480).frame(width: 150, height: 84).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream).lineLimit(1)
                    Text("\(r.date.formatted(date: .abbreviated, time: .omitted)) · \(s.namedSongs.count) song\(s.namedSongs.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundColor(Theme.muted)
                }
                Spacer()
                ForEach(Self.scoreList(s), id: \.0) { name, v in
                    VStack(spacing: 2) {
                        Text(v.map(String.init) ?? "–").font(.system(size: 14, weight: .semibold, design: .serif)).foregroundColor(Theme.cream).monospacedDigit()
                        Text(name).font(.system(size: 9)).foregroundColor(Theme.faint)
                    }
                    .frame(width: 88)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Button { confirmDelete = r } label: { Image(systemName: "trash").font(.system(size: 12)) }
            .buttonStyle(.plain).foregroundColor(Theme.muted).padding(8).help("Delete this assessment")
        }
    }

    private func delete(_ r: WorshipReport) {
        WorshipStore.delete(r)
        // A rewrapped copy made just for this tab goes too; the original recording stays
        let copies = WorshipStore.dir.appendingPathComponent("Recordings").path
        if r.videoPath.hasPrefix(copies) { try? FileManager.default.removeItem(atPath: r.videoPath) }
        if current?.videoPath == r.videoPath { player.pause(); player.replaceCurrentItem(with: nil); current = nil }
        reports = WorshipStore.all()
    }

    private static func scoreList(_ s: WorshipStats) -> [(String, Int?)] {
        [("Sound", s.soundScore), ("Engagement", s.engagementScore), ("Smiles", s.smilesScore),
         ("Stage", s.stageScore), ("Communication", s.communicationScore)]
    }

    private var trend: some View {
        AssessCard(title: "Week by week", subtitle: "Compare like with like: a different camera or sound feed changes these scores too.") {
            Chart {
                ForEach(reports.reversed(), id: \.videoPath) { r in
                    ForEach(Self.scoreList(WorshipStats(r)), id: \.0) { name, v in
                        if let v {
                            LineMark(x: .value("Service", r.date), y: .value("Score", v))
                                .foregroundStyle(by: .value("Measure", name))
                            PointMark(x: .value("Service", r.date), y: .value("Score", v))
                                .foregroundStyle(by: .value("Measure", name))
                        }
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 170)
        }
    }

    // MARK: Adding

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent, .movie, .audio]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Choose a recording of the service"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start { _ in url }
    }

    private func addLink() {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        link = ""
        start { update in
            try await YTDLP.download(url) { p, msg in update(p * 0.2, msg) }
        }
    }

    private func start(_ fetch: @escaping (@escaping (Double, String) -> Void) async throws -> URL) {
        error = nil; progress = 0; status = "Getting the recording…"
        let report: (Double, String) -> Void = { p, msg in
            Task { @MainActor in progress = p; status = msg }
        }
        job = Task {
            do {
                let raw = try await fetch(report)
                let url = try await WorshipAnalysis.playable(raw)
                try Task.checkCancellation()
                if let saved = WorshipStore.load(for: url.path) {
                    status = nil; open(saved); return
                }
                let r = try await WorshipAnalysis.run(path: url.path, progress: report)
                try Task.checkCancellation()
                WorshipStore.save(r)
                reports = WorshipStore.all()
                status = nil
                open(r)
            } catch {
                status = nil
                if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    private func open(_ r: WorshipReport) {
        current = r
        section = .flow
        if r.visual != nil { Backdrop.shared.path = r.videoPath }
        coachStatus = nil; coachError = nil
        setlistText = r.setlist.sorted { $0.start < $1.start }.map(\.name).joined(separator: "\n")
        setlistNote = nil; clipStatus = nil; clipFolder = nil; clipError = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: r.videoPath)))
    }

    private func save(_ change: (inout WorshipReport) -> Void) {
        guard var r = current else { return }
        change(&r)
        current = r
        WorshipStore.save(r)
    }

    private func play(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private var playhead: Double { max(0, player.currentTime().seconds.isNaN ? 0 : player.currentTime().seconds) }

    // MARK: Detail

    private func detail(_ r: WorshipReport) -> some View {
        let s = WorshipStats(r)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { player.pause(); current = nil; reports = WorshipStore.all() } label: {
                        Label("All services", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)).foregroundColor(gold)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button { confirmDelete = r } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(SecondaryButtonStyle(compact: true)).help("Delete this assessment")
                }

                HStack(alignment: .top, spacing: 18) {
                    VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(r.title).font(Theme.display(24)).foregroundColor(Theme.cream).lineLimit(2)
                        DatePicker("Service date", selection: Binding(get: { r.date }, set: { d in save { $0.date = d } }), displayedComponents: .date)
                            .font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize()
                        rangeControls(r)
                        Button { copySummary(s) } label: {
                            Label(copied ? "Copied" : "Copy summary for the team", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(SecondaryButtonStyle(compact: true))
                        if let previous = previousFocus(r) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("LAST TIME'S FOCUS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundColor(Theme.faint)
                                Text(previous).font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                overview(r, s)
                PillTabs(selection: $section, items: Section.allCases.map { ($0, $0.rawValue) })
                switch section {
                case .flow: flow(s)
                case .sound: sound(r, s)
                case .stage: stage(r, s)
                case .talk: talk(s)
                case .team: team(r, s)
                case .coach: coach(r, s)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
        }
    }

    private func previousFocus(_ r: WorshipReport) -> String? {
        WorshipStore.all().filter { $0.date < r.date && !$0.focus.isEmpty }.max { $0.date < $1.date }?.focus
    }

    private func copySummary(_ s: WorshipStats) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.summaryText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func rangeControls(_ r: WorshipReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WORSHIP PART").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundColor(Theme.faint)
            Text("\(assessTime(r.rangeStart)) to \(assessTime(r.rangeEnd))").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text).monospacedDigit()
            HStack(spacing: 6) {
                Button("Start here") { let t = playhead; if t < r.rangeEnd { save { $0.rangeStart = t } } }.controlSize(.small)
                Button("End here") { let t = playhead; if t > r.rangeStart { save { $0.rangeEnd = t } } }.controlSize(.small)
                Button("Whole recording") { save { $0.rangeStart = 0; $0.rangeEnd = $0.duration } }.controlSize(.small)
            }
            let stale = WorshipStats(r).needsRewatch
            if stale {
                Text("This was measured before AutoClip could tell clapping from raised hands, or find exhortations.")
                    .font(.system(size: 11)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true)
            }
            if stale || r.visual.map({ r.rangeStart < $0.start - 5 || r.rangeEnd > $0.end + 5 }) == true {
                Button { rewatch(r) } label: { Label("Measure again", systemImage: "eye") }.buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }
    }

    private func rewatch(_ r: WorshipReport) {
        progress = 0; status = "Watching the stage…"
        job = Task {
            do {
                let v = try await WorshipAnalysis.watch(AVURLAsset(url: URL(fileURLWithPath: r.videoPath)), from: r.rangeStart, to: r.rangeEnd) { p in
                    Task { @MainActor in progress = p }
                }
                let words = (try? await TranscriptCache.transcript(for: r.videoPath) { _ in }) ?? []
                save { $0.visual = v; $0.talks = WorshipAnalysis.talks(in: $0, words: words); $0.analyzedAt = Date() }
            } catch {}
            status = nil
        }
    }

    // MARK: Overview

    private func overview(_ r: WorshipReport, _ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "music.note").font(.system(size: 15)).foregroundColor(gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Worship Analysis").font(Theme.display(22)).foregroundColor(Theme.cream)
                    Text("\(s.namedSongs.count) song\(s.namedSongs.count == 1 ? "" : "s") · Analyzed \(r.analyzedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11)).foregroundColor(Theme.muted)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 16) {
                ScoreRing(title: "Sound", value: s.soundScore, why: "Distortion, possible feedback, sudden volume changes, and how even the songs are.")
                ScoreRing(title: "Engagement", value: s.engagementScore, why: "Clapping heard or seen, and raised hands. When the congregation is in shot, what it's doing counts most.")
                ScoreRing(title: "Smiles", value: s.smilesScore, why: "Smiles in frames where a face is close enough to read. A rough read.")
                ScoreRing(title: "Stage Presence", value: s.stageScore, why: "How often faces point toward the camera, and how much bodies move with the music.")
                ScoreRing(title: "Communication", value: s.communicationScore, why: "Inviting the room in, quiet gaps between songs, filler words and how long the talking runs.")
            }
            Text("A guide from what the recording shows. Compare weeks recorded the same way.")
                .font(.system(size: 10)).foregroundColor(Theme.faint)
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("THROUGH THE WORSHIP").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundColor(Theme.muted)
                flowStrip(r, s)
                row("Clapping heard or team", s.clapMarks, r)
                row("Applause and cheers", s.applauseMarks, r)
                row("Smiles", s.smileMarks, r)
                row("Room: hands or claps", s.roomHandsMarks, r)
                row("Hands up, team", s.handsMarks, r)
                row("Talking", s.talks.map(\.start), r)
                row("Possible feedback", s.feedback, r)
                row("Volume jumps", s.jumps, r)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func row(_ name: String, _ times: [Double], _ r: WorshipReport) -> some View {
        TimelineDotRow(label: name, marks: times.map { .init(time: $0 - r.rangeStart, seek: $0, help: assessTime($0)) },
                       duration: max(1, r.rangeEnd - r.rangeStart), italic: false, play: play)
    }

    /// Songs, talking and quiet laid end to end.
    private func flowStrip(_ r: WorshipReport, _ s: WorshipStats) -> some View {
        HStack(spacing: 12) {
            Text("").frame(minWidth: 32)
            Text("Songs and talking").font(Theme.display(13)).foregroundColor(Theme.text).frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                let span = max(1, r.rangeEnd - r.rangeStart)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    ForEach(s.parts) { p in
                        Rectangle().fill(color(p.kind))
                            .frame(width: max(1, CGFloat(p.length / span) * geo.size.width), height: 18)
                            .offset(x: CGFloat((p.start - r.rangeStart) / span) * geo.size.width)
                            .help("\(label(p.kind)) · \(assessTime(p.start)) · \(assessTime(p.length))")
                            .onTapGesture { play(p.start) }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 18)
        }
    }

    private func color(_ k: WorshipStats.Part.Kind) -> Color {
        switch k {
        case .song: return Theme.sand.opacity(0.75)
        case .talk: return Theme.oliveLight.opacity(0.8)
        case .quiet: return Color.white.opacity(0.08)
        }
    }

    private func label(_ k: WorshipStats.Part.Kind) -> String {
        switch k { case .song: return "Music"; case .talk: return "Talking"; case .quiet: return "Quiet" }
    }

    // MARK: Sections

    private func flow(_ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
        AssessCard(title: "Clapping and response") { pointerList(s.engagementPointers) }
        setlistCard(s)
        AssessCard(title: "Songs", subtitle: s.report.setlist.isEmpty ? "Add your setlist to see these by name. Songs with no break between them show as one until you do." : "Click a time to play. Pause where a song really starts and press Starts here to correct it.") {
            if s.namedSongs.isEmpty {
                Text("No songs found in this part. Use Start here and End here to set the worship part.").font(.system(size: 12)).foregroundColor(Theme.muted)
            }
            ForEach(Array(s.namedSongs.enumerated()), id: \.element.id) { i, song in songRow(i, song, s) }
            if !s.quietGaps.isEmpty {
                Text("Quiet gaps").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.muted).padding(.top, 4)
                HStack(spacing: 8) { ForEach(s.quietGaps) { g in TimeLink(time: g.start, play: play) } }
            }
        }
        }
    }

    private func songRow(_ i: Int, _ song: WorshipStats.NamedSong, _ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("\(i + 1)").font(Theme.display(15)).foregroundColor(gold).frame(width: 22)
                Text(song.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream).lineLimit(1)
                if song.source == .estimate {
                    Text("Start is a guess").font(.system(size: 9, weight: .medium)).foregroundColor(Theme.warn)
                        .help("The title wasn't heard, so this start is estimated. Pause where it really starts and press Starts here.")
                } else if song.source == .lyrics {
                    Text("Found from the lyrics").font(.system(size: 9)).foregroundColor(Theme.faint)
                        .help("No break in the music here, so the change is placed between where each title is sung. It may be off by a little.")
                }
                Spacer()
                TimeLink(time: song.part.start, play: play)
                Text(assessTime(song.part.length)).font(.system(size: 12)).foregroundColor(Theme.text).monospacedDigit().frame(width: 44, alignment: .trailing)
                if let index = song.setIndex {
                    Button("Starts here") { let t = playhead; save { $0.setlist[index].start = t; $0.setlist[index].source = .manual } }
                        .controlSize(.small).help("Set this song's start to where the video is paused")
                }
            }
            HStack(spacing: 14) {
                let clap = s.clapSeconds(in: song.part)
                stat(String(format: "%.0f dB", s.loudness(of: song.part)), "Average level in the recording, to compare songs. It isn't the volume in the room.")
                stat(clap >= 5 ? "\(Int(clap))s of clapping" : "No clapping heard", "Clapping under a loud band can be missed.")
                if let v = s.smilePercent(in: song.part) { stat(String(format: "%.0f%% smiles", v), "Smiles in close shots during this song.") }
                if let v = s.facingPercent(in: song.part) { stat(String(format: "%.0f%% facing", v), "Faces toward the camera during this song.") }
                if let v = s.handsPercent(in: song.part), v > 0 { stat(String(format: "%.0f%% hands up", v), "Shots with hands raised on stage during this song.") }
            }
            .padding(.leading, 32)
        }
        .padding(.vertical, 3)
    }

    private func stat(_ text: String, _ help: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Theme.muted).help(help)
    }

    private func setlistCard(_ s: WorshipStats) -> some View {
        AssessCard(title: "Setlist", subtitle: "Paste your songs in order, one per line. AutoClip names each song and uses the lyrics to split medleys.") {
            TextEditor(text: $setlistText).font(.system(size: 12)).scrollContentBackground(.hidden)
                .padding(6).frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            HStack(spacing: 10) {
                Button("Match the setlist") { matchSetlist() }.buttonStyle(SecondaryButtonStyle(compact: true))
                if !s.report.setlist.isEmpty {
                    Button("Clear") { setlistText = ""; setlistNote = nil; save { $0.setlist = [] } }.controlSize(.small)
                }
                if let setlistNote { Text(setlistNote).font(.system(size: 11)).foregroundColor(Theme.muted) }
            }
        }
    }

    private func matchSetlist() {
        guard let r = current else { return }
        let titles = setlistText.split(whereSeparator: \.isNewline).map {
            // Drop list numbers such as "1." or "2)"
            $0.replacingOccurrences(of: #"^\s*\d+[.)]\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard !titles.isEmpty else { setlistNote = "Paste at least one song."; return }
        setlistNote = "Matching…"
        Task {
            let words = (try? await TranscriptCache.transcript(for: r.videoPath) { _ in }) ?? []
            let placed = WorshipSetlist.place(titles, in: r, words: words)
            save { $0.setlist = placed }
            let guesses = placed.filter { $0.source == .estimate }.count
            setlistNote = guesses == 0 ? "Matched \(placed.count) song\(placed.count == 1 ? "" : "s")." : "Matched, but \(guesses) start\(guesses == 1 ? " is a guess" : "s are guesses"). Check the marked songs."
        }
    }

    private func goalsCard(current r: WorshipReport?) -> some View {
        let recent = Array(reports.sorted { $0.date > $1.date }.prefix(6).reversed())
        return AssessCard(title: "Goals", subtitle: "Targets the team is working toward, checked on every service. Oldest to newest, up to the last 6.") {
            if goals.isEmpty {
                Text("No goals yet. Add one to track it week by week.").font(.system(size: 12)).foregroundColor(Theme.muted)
            }
            ForEach(goals) { goal in
                HStack(spacing: 10) {
                    Text(goal.title).font(.system(size: 12)).foregroundColor(Theme.text).lineLimit(1)
                    Spacer()
                    ForEach(recent, id: \.videoPath) { report in
                        let v = goal.value(in: WorshipStats(report))
                        let isCurrent = report.videoPath == r?.videoPath
                        Text(v.map { goal.text($0) } ?? "–")
                            .font(.system(size: 10, weight: isCurrent ? .bold : .medium)).monospacedDigit()
                            .foregroundColor(v == nil ? Theme.faint : goal.met(v!) ? Theme.good : Theme.warn)
                            .frame(minWidth: 36).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Color.white.opacity(0.1) : Color.white.opacity(0.03)))
                            .help("\(report.title), \(report.date.formatted(date: .abbreviated, time: .omitted))")
                    }
                    Stepper("", value: Binding(get: { goal.target }, set: { v in setGoal(goal.id) { $0.target = v } }),
                            in: goal.measure.range, step: goal.measure.step).labelsHidden().controlSize(.small)
                    Button { goals.removeAll { $0.id == goal.id }; WorshipGoals.save(goals) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundColor(Theme.faint).help("Remove this goal")
                }
            }
            Menu("Add a goal") {
                ForEach(WorshipGoal.Measure.allCases.filter { m in !goals.contains { $0.measure == m } }) { m in
                    Button(m.rawValue) { goals.append(.init(measure: m, target: m.defaultTarget)); WorshipGoals.save(goals) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
        }
    }

    private func setGoal(_ id: UUID, _ change: (inout WorshipGoal) -> Void) {
        guard let i = goals.firstIndex(where: { $0.id == id }) else { return }
        change(&goals[i])
        WorshipGoals.save(goals)
    }

    private func clipsCard(_ r: WorshipReport, _ s: WorshipStats) -> some View {
        let count = clipMoments(r, s).count
        return AssessCard(title: "Rehearsal clips", subtitle: "Makes about 20 seconds around each note with the note on screen, plus one reel of them all to watch together.") {
            if r.visual == nil {
                Text("This recording has no picture, so clips can't be made.").font(.system(size: 12)).foregroundColor(Theme.muted)
            } else {
                Toggle("Also include possible feedback and volume jumps", isOn: $includeFlagged).toggleStyle(.checkbox)
                    .font(.system(size: 12)).foregroundColor(Theme.text)
                if let p = clipStatus {
                    HStack(spacing: 10) {
                        ProgressView(value: p).tint(Theme.action)
                        Text("\(Int(p * 100))%").font(.system(size: 11)).foregroundColor(Theme.muted).monospacedDigit()
                        Button("Cancel") { clipTask?.cancel() }.controlSize(.small)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button { makeClips(r, s) } label: { Label("Make \(count) clip\(count == 1 ? "" : "s")", systemImage: "film.stack") }
                            .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(count == 0)
                        if let clipFolder {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clipFolder]) }.controlSize(.small)
                        }
                    }
                }
                if let clipError { Text(clipError).font(.system(size: 11)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private func clipMoments(_ r: WorshipReport, _ s: WorshipStats) -> [WorshipClips.Moment] {
        var out = r.notes.map { n in
            WorshipClips.Moment(time: n.time, label: "\(assessTime(n.time)) \(n.category) - \(n.text)", caption: "\(n.category): \(n.text)")
        }
        if includeFlagged {
            out += s.feedback.map { .init(time: $0, label: "\(assessTime($0)) Possible feedback", caption: "Possible feedback. Listen here.") }
            out += s.jumps.map { .init(time: $0, label: "\(assessTime($0)) Volume jump", caption: "Sudden volume change. Was it planned?") }
        }
        return out
    }

    private func makeClips(_ r: WorshipReport, _ s: WorshipStats) {
        let panel = NSOpenPanel()
        panel.title = "Where should the clips go?"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let moments = clipMoments(r, s)
        clipError = nil; clipFolder = nil; clipStatus = 0
        clipTask = Task {
            do {
                clipFolder = try await WorshipClips.export(path: r.videoPath, title: r.title, moments: moments, into: parent) { p in
                    Task { @MainActor in if clipStatus != nil { clipStatus = p } }
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { clipError = error.localizedDescription }
            }
            clipStatus = nil
        }
    }

    private func sound(_ r: WorshipReport, _ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AssessCard(title: "Pointers") { pointerList(s.soundPointers) }
            AssessCard(title: "Level over time", subtitle: "From the recording, which may be a board feed or a camera mic. It isn't the volume in the room.") {
                Chart {
                    ForEach(Array(r.loudness.enumerated()), id: \.offset) { i, v in
                        let t = Double(i) * r.bin
                        if t >= r.rangeStart && t < r.rangeEnd {
                            AreaMark(x: .value("Minute", t / 60), yStart: .value("", -60), yEnd: .value("Level", max(-60, Double(v))))
                                .foregroundStyle(gold.opacity(0.35))
                        }
                    }
                }
                .chartYScale(domain: -60...0)
                .chartXAxisLabel("minutes").chartYAxisLabel("dB")
                .frame(height: 130)
            }
        }
    }

    private func stage(_ r: WorshipReport, _ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if r.visual == nil {
                AssessCard(title: "Stage") { Text("This recording has no picture, so stage presence and smiles can't be read.").font(.system(size: 12)).foregroundColor(Theme.muted) }
            } else {
                AssessCard(title: "Pointers") { pointerList(s.stagePointers) }
                HStack(spacing: 12) {
                    metric(s.smilePercent.map { String(format: "%.0f%%", $0) } ?? "–", "smiling, in \(s.smileReadable) close shots")
                    metric(s.facingPercent.map { String(format: "%.0f%%", $0) } ?? "–", "of faces toward the camera")
                    metric(s.handsPercent.map { String(format: "%.0f%%", $0) } ?? "–", "of shots with team hands raised")
                    metric(s.averagePeople.map { String(format: "%.1f", $0) } ?? "–", "people in shot on average")
                }
                Text("Camera choices shape these numbers. A wide shot can't show smiles, and someone singing toward a screen reads as facing away.")
                    .font(.system(size: 10)).foregroundColor(Theme.faint)
            }
        }
    }

    private func metric(_ big: String, _ small: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(big).font(Theme.display(22)).foregroundColor(gold).monospacedDigit()
            Text(small).font(.system(size: 10)).foregroundColor(Theme.muted)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    }

    private func talk(_ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AssessCard(title: "Pointers") { pointerList(s.communicationPointers) }
            AssessCard(title: "What was said", subtitle: "\(assessTime(s.talkSeconds)) of talking\(s.averageWPM.map { String(format: " · %.0f words a minute", $0) } ?? "")") {
                if s.talks.isEmpty { Text("Nothing found.").font(.system(size: 12)).foregroundColor(Theme.muted) }
                ForEach(s.talks) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TimeLink(time: t.start, play: play)
                        Text(t.overMusic == true ? "Exhortation" : "Talking").font(.system(size: 10, weight: .semibold)).foregroundColor(gold).frame(width: 70, alignment: .leading)
                        Text(t.text).font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func team(_ r: WorshipReport, _ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AssessCard(title: "Add a note", subtitle: "Pause the video where you want the note. It's saved at that moment.") {
                HStack(spacing: 8) {
                    Picker("", selection: $noteCategory) { ForEach(Self.categories, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().fixedSize()
                    TextField("What did you notice?", text: $noteText).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { addNote() }
                    Button("Add") { addNote() }.buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(r.notes.sorted { $0.time < $1.time }) { n in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TimeLink(time: n.time, play: play)
                        Text(n.category).font(.system(size: 10, weight: .semibold)).foregroundColor(gold).frame(width: 90, alignment: .leading)
                        Text(n.text).font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { save { $0.notes.removeAll { $0.id == n.id } } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).font(.system(size: 9)).foregroundColor(Theme.faint).help("Delete this note")
                    }
                }
            }
            clipsCard(r, s)
            goalsCard(current: r)
            AssessCard(title: "How did it feel?", subtitle: "Your team's own rating, which the numbers can't give you.") {
                ForEach(Self.categories, id: \.self) { c in
                    HStack(spacing: 10) {
                        Text(c).font(.system(size: 12)).foregroundColor(Theme.text).frame(width: 110, alignment: .leading)
                        ForEach(1...5, id: \.self) { n in
                            Button { save { $0.ratings[c] = $0.ratings[c] == n ? nil : n } } label: {
                                Image(systemName: (r.ratings[c] ?? 0) >= n ? "circle.fill" : "circle").font(.system(size: 12)).foregroundColor(gold)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            AssessCard(title: "Focus for next time", subtitle: "Shown on your next service so you can see if it improved.") {
                TextField("One thing to work on", text: Binding(get: { r.focus }, set: { v in save { $0.focus = v } }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12)).lineLimit(2...4)
            }
        }
    }

    private func addNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let t = playhead, c = noteCategory
        save { $0.notes.append(.init(time: t, category: c, text: text)) }
        noteText = ""
    }

    private func coach(_ r: WorshipReport, _ s: WorshipStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AssessCard(title: "AI Coach", subtitle: "Turns the measurements, what was said and your team notes into wins and a rehearsal plan. Uses your AI key.") {
                HStack(spacing: 10) {
                    Button { runCoach(s) } label: { Label(r.coach == nil ? "Write the coaching" : "Write it again", systemImage: "sparkles") }
                        .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(coachStatus != nil)
                    if let coachStatus { ProgressView().controlSize(.small); Text(coachStatus).font(.system(size: 11)).foregroundColor(Theme.muted) }
                }
                if let coachError { Text(coachError).font(.system(size: 11)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            }
            if let c = r.coach {
                AssessCard(title: "Summary") { Text(c.summary).font(.system(size: 13)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true) }
                coachList("What went well", c.wins, icon: "checkmark.circle", color: Theme.good)
                coachList("What to work on", c.improvements, icon: "arrow.up.circle", color: Theme.warn)
                AssessCard(title: "Rehearsal plan") {
                    ForEach(Array(c.rehearsal.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step)").font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func coachList(_ title: String, _ items: [WorshipCoach.Item], icon: String, color: Color) -> some View {
        AssessCard(title: title) {
            ForEach(items) { n in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon).font(.system(size: 12)).foregroundColor(color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.cream)
                        Text(n.detail).font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func runCoach(_ s: WorshipStats) {
        coachError = nil; coachStatus = "Writing…"
        let facts = s.coachFacts, title = s.report.title, path = s.report.videoPath
        Task {
            do {
                let provider = LLMClipService.AIProvider(rawValue: UserDefaults.standard.string(forKey: "ar_provider") ?? "") ?? .google
                guard let key = await LLMClipService.shared.loadAPIKey(for: provider), !key.isEmpty else {
                    coachStatus = nil
                    coachError = "Add an API key in Auto Reels → AI settings to use the AI coach."
                    return
                }
                let c = try await CostTag.$video.withValue(title) {
                    try await LLMClipService.shared.worshipCoach(facts: facts, provider: provider, apiKey: key)
                }
                if current?.videoPath == path { save { $0.coach = c } }
                coachStatus = nil
            } catch {
                coachStatus = nil
                coachError = error.localizedDescription
            }
        }
    }
}
