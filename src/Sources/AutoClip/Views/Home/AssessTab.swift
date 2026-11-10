import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Assess a talk as a speaker: filler words (a dot on the timeline for each), delivery (pace,
/// pauses, voice, crutch phrases), an AI coach report, stage presence, and progress across
/// messages. Click any dot, time or block to hear that moment.
struct AssessTab: View {
    @ObservedObject private var reelsStore = AutoReelsStore.shared
    @ObservedObject private var profiles = SpeakerProfiles.shared
    /// The speaker the list and progress charts show ("" = everyone)
    @AppStorage("assess_speaker") private var speakerFilter = ""
    @State private var showSpeakers = false
    @State private var selected: String?
    @State private var words: [Word] = []
    @State private var hits: [FillerReport.Hit] = []
    @State private var duration: Double = 1
    @State private var status: String?
    @State private var error: String?
    @State private var hidden: Set<String> = []
    @State private var hovered: FillerReport.Hit?
    @State private var player = AVPlayer()
    /// Files picked with "Choose…" and videos removed from the list (both remembered)
    @AppStorage("assess_extra") private var extraRaw = ""
    @AppStorage("assess_hidden") private var hiddenRaw = ""
    @State private var ytURL = ""
    @State private var ytStatus: String?
    @State private var ytError: String?
    @State private var pendingDelete: String?
    @State private var hoveredVideo: String?
    /// A moment to play once the next selected video loads (from the Series view)
    @State private var pendingSeek: Double?
    enum Mode: String, CaseIterable { case fillers = "Filler words", delivery = "Delivery", coach = "AI Coach", notes = "Notes", series = "Series", stage = "Stage", progress = "Progress" }
    @State private var mode: Mode = .fillers
    @State private var report: SpeakerReport?
    @State private var deliveryStatus: String?
    @State private var stageStatus: String?
    @State private var coachStatus: String?
    @State private var coachError: String?
    @State private var allReports: [SpeakerReport] = []
    @State private var notesStatus: String?
    @State private var notesError: String?
    @State private var showPractice = false
    /// Real sermons only: practice runs stay out of the progress charts
    private var allSermons: [SpeakerReport] { allReports.filter { !$0.isPractice } }
    /// The chosen speaker, or the only one when there is just one
    private var activeSpeaker: SpeakerProfiles.Speaker? {
        profiles.speakers.count == 1 ? profiles.primary : profiles.speaker(id: speakerFilter)
    }
    /// Sermons by the chosen speaker (all of them when "Everyone" is picked)
    private var sermonReports: [SpeakerReport] { sermons(of: activeSpeaker) }
    private func sermons(of s: SpeakerProfiles.Speaker?) -> [SpeakerReport] {
        guard let s else { return allSermons }
        return allSermons.filter { profiles.speaker(for: $0.videoPath).id == s.id }
    }
    private var extraVideos: [String] { extraRaw.split(separator: "\n").map(String.init) }
    private var hiddenVideos: Set<String> { Set(hiddenRaw.split(separator: "\n").map(String.init)) }

    private let gold = Theme.sand

    static let colors: [String: Color] = [
        "like": Theme.danger, "um": Theme.sand,
        "uh": Theme.warn, "ah": Color(red: 0.95, green: 0.45, blue: 0.85),
        "well": Color(red: 0.4, green: 0.8, blue: 1.0), "so": Theme.good,
        "you see": Color(red: 0.7, green: 0.6, blue: 1.0), "i mean": Color(red: 0.95, green: 0.95, blue: 0.95)
    ]
    private func color(_ k: String) -> Color { Self.colors[k] ?? .white }

    /// Videos already in AutoClip (practice runs, Auto Reels sources, YouTube downloads) plus any picked here.
    private var allVideos: [String] { Self.knownVideos(reels: reelsStore.reels, extra: extraVideos, hidden: hiddenVideos) }
    private var videos: [String] {
        let all = allVideos
        guard let s = activeSpeaker, profiles.speakers.count > 1 else { return all }
        return all.filter { profiles.speaker(for: $0).id == s.id }
    }

    /// A video added while one speaker is showing belongs to that speaker.
    private func claim(_ path: String) {
        if profiles.speakers.count > 1, let s = activeSpeaker { profiles.assign(path, to: s.id) }
    }

    /// The same list for other tabs (Search), read from saved settings.
    static func knownVideos(reels: [AutoReelRecord]) -> [String] {
        let d = UserDefaults.standard
        return knownVideos(reels: reels,
                           extra: (d.string(forKey: "assess_extra") ?? "").split(separator: "\n").map(String.init),
                           hidden: Set((d.string(forKey: "assess_hidden") ?? "").split(separator: "\n").map(String.init)))
    }

    private static func knownVideos(reels: [AutoReelRecord], extra: [String], hidden: Set<String>) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for r in reels {
            if let p = ReelGenerator.sourceVideoPath(for: r), fm.fileExists(atPath: p), !out.contains(p) { out.append(p) }
        }
        let dir = YTDLP.videosDir
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["mp4", "mov", "m4v", "webm", "mkv"].contains(f.pathExtension.lowercased()) && !YTDLP.isPartialStream(f) {
            if !out.contains(f.path) { out.append(f.path) }
        }
        let practice = ((try? fm.contentsOfDirectory(at: PracticeRecorder.dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { ["mov", "m4a", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .map(\.path)
        out = practice + out.filter { !practice.contains($0) }
        return (extra.filter { !out.contains($0) && fm.fileExists(atPath: $0) } + out).filter { !hidden.contains($0) }
    }

    /// Auto Reels projects made from this video (its file must stay)
    private func reelsUsing(_ path: String) -> Int {
        reelsStore.reels.filter { ReelGenerator.sourceVideoPath(for: $0) == path }.count
    }

    private var shown: [FillerReport.Hit] { hits.filter { !hidden.contains($0.kind) } }

    var body: some View {
        Group {
          if selected == nil && mode != .progress {
            library
          } else {
          VStack(spacing: 0) {
            backBar
            Group {
                if selected == nil && mode == .progress {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            progressHeader
                            progressBody
                        }.padding(28)
                    }
                } else if selected == nil {
                    VStack(spacing: 14) {
                        placeholder("Pick a video or audio file to assess", "AutoClip transcribes it (or reuses the saved transcript), then measures filler words, pace, pauses, voice and stage presence. The AI coach adds strengths, things to work on and a sermon map.")
                            .frame(maxHeight: 360)
                        HStack(spacing: 10) {
                            Button { showPractice = true } label: { Label("Record a practice run", systemImage: "mic.fill") }
                                .buttonStyle(SecondaryButtonStyle())
                            if !sermonReports.isEmpty {
                                Button("See \(progressOwner) progress across \(sermonReports.count) message\(sermonReports.count == 1 ? "" : "s")") { mode = .progress }
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let status {
                    VStack(spacing: 10) { ProgressView().controlSize(.small); Text(status).font(.ui(size: 13)).foregroundColor(Theme.ink.opacity(0.6)) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    placeholder("Couldn't assess this video", error)
                } else {
                    report_
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            if let path = pendingDelete {
                if reelsUsing(path) == 0 {
                    Button("Move Video to Trash", role: .destructive) { trash(path) }
                }
                Button("Remove from This List") { hide(path) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        } message: {
            if let path = pendingDelete {
                let n = reelsUsing(path)
                Text(n > 0 ? "\(n) Clips project\(n == 1 ? " uses" : "s use") this video, so the file stays on your Mac."
                           : "Moving it to the Trash removes the video file. You can put it back from the Trash.")
            }
        }
        .pausesWhenHidden { player.pause() }
        .onPageShown { allReports = SpeakerReportStore.all() }
        .reportsWork(.assess, "video", status != nil || ytStatus != nil)
        .reportsWork(.assess, "reading", deliveryStatus != nil || stageStatus != nil)
        .reportsWork(.assess, "writing", coachStatus != nil || notesStatus != nil)
        .onAppear {
            allReports = SpeakerReportStore.all()
            if let p = HomeNav.shared.assessPath { HomeNav.shared.assessPath = nil; mode = .fillers; select(p) }
        }
        // A sermon picked on Home
        .onReceive(HomeNav.shared.$assessPath) { p in
            if let p { HomeNav.shared.assessPath = nil; mode = .fillers; select(p) }
        }
        .sheet(isPresented: $showSpeakers) { SpeakersSheet(reports: allReports) }
        .sheet(isPresented: $showPractice) {
            PracticeSheet { url in
                hiddenRaw = hiddenVideos.subtracting([url.path]).joined(separator: "\n")
                claim(url.path)
                mode = .delivery
                select(url.path)
            }
        }
    }

    private func placeholder(_ title: String, _ sub: String) -> some View {
        EmptyState(icon: "waveform.badge.magnifyingglass", title: title, message: sub) { EmptyView() }
    }

    // MARK: Speakers

    private func speakerName(_ r: SpeakerReport) -> String? {
        profiles.speakers.count > 1 || profiles.primary.name != "Me" ? profiles.speaker(for: r.videoPath).name : nil
    }

    private var progressOwner: String {
        guard let s = activeSpeaker, profiles.speakers.count > 1 || s.name != "Me" else { return profiles.speakers.count > 1 ? "everyone's" : "your" }
        return s.name + "'s"
    }

    private var progressHeader: some View {
        Text(progressOwner == "your" ? "Your progress" : progressOwner.prefix(1).uppercased() + progressOwner.dropFirst() + " progress")
            .font(Theme.display(28)).foregroundColor(Theme.cream)
    }

    /// One speaker's trends, or (with "Everyone" picked) the speakers side by side.
    @ViewBuilder private var progressBody: some View {
        if activeSpeaker == nil {
            SpeakerCompareCard(rows: profiles.speakers.map { s in (s, profiles.color(s), sermons(of: s)) },
                               pick: { speakerFilter = $0.id })
        } else {
            SpeakerProgressSection(reports: sermonReports, open: { select($0) })
        }
    }

    private var speakerMenu: some View {
        Menu {
            if profiles.speakers.count > 1 {
                Button { speakerFilter = "" } label: { if speakerFilter.isEmpty { Label("Everyone", systemImage: "checkmark") } else { Text("Everyone") } }
                Divider()
            }
            ForEach(profiles.speakers) { s in
                Button { speakerFilter = s.id } label: {
                    if activeSpeaker?.id == s.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Divider()
            Button("Add or edit speakers…") { showSpeakers = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeSpeaker == nil ? "person.2.fill" : "person.fill")
                    .foregroundColor(activeSpeaker.map(profiles.color) ?? gold)
                Text(activeSpeaker?.name ?? "Everyone").foregroundColor(Theme.ink)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.ui(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
            }
            .font(.ui(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.ink.opacity(0.05))).overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("Whose messages to show. Each speaker gets their own progress charts.")
    }

    @ViewBuilder private func speakerAssignMenu(_ path: String) -> some View {
        Menu("Speaker") {
            ForEach(profiles.speakers) { s in
                Button { profiles.assign(path, to: s.id) } label: {
                    if profiles.speaker(for: path).id == s.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Divider()
            Button("Add a speaker…") { showSpeakers = true }
        }
    }

    // MARK: Video list

    /// The page you land on: every sermon as a card. Click one to open its assessment.
    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Assess", title: "Sermons",
                       subtitle: "\(videos.count) message\(videos.count == 1 ? "" : "s") · filler words, pace, delivery and coaching for each one") {
                speakerMenu.fixedSize()
                if !sermonReports.isEmpty {
                    Button { mode = .progress } label: { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                IconPillButton(icon: "mic.fill", help: "Record a practice run") { showPractice = true }
                LibraryMenu(exclude: Set(allVideos), onPick: { use($0.path) }) {
                    Label("Already in AutoClip", systemImage: "tray.full")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button { chooseVideo() } label: { Label("Add video", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            youTubeField.frame(maxWidth: 520).padding(.horizontal, 32).padding(.bottom, 18)
            ScrollView {
                if videos.isEmpty {
                    EmptyState(icon: "waveform.badge.magnifyingglass", title: "No sermons yet",
                               message: "Add a video or paste a YouTube link. AutoClip measures filler words, pace, pauses, voice and stage presence, and the AI coach adds strengths, things to work on and a sermon map.") {
                        Button { chooseVideo() } label: { Label("Add video", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        let done = videos.filter { p in allReports.contains { $0.videoPath == p } }
                        let waiting = videos.filter { p in !allReports.contains { $0.videoPath == p } }
                        if let path = done.first, let r = allReports.first(where: { $0.videoPath == path }) {
                            CinematicHero(path: path, eyebrow: "Latest assessment", title: r.title,
                                          detail: r.speakingMinutes > 0 ? String(format: "%.1f filler words a minute over %.0f minutes", r.fillersPerMin, r.speakingMinutes) : nil, height: 400) {
                                Button { select(path) } label: { Label("Open", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                                Button { chooseVideo() } label: { Label("Add video", systemImage: "plus") }.buttonStyle(SecondaryButtonStyle())
                            }
                            .padding(.horizontal, 32)
                        }
                        if !done.isEmpty { sermonGrid("Assessed", done) }
                        if !waiting.isEmpty { sermonGrid("Not assessed yet", waiting) }
                    }
                    .padding(.top, 4).padding(.bottom, 36)
                }
            }
        }
    }

    private func sermonGrid(_ title: String, _ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: title, count: paths.count).padding(.horizontal, 32)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 330), spacing: 22, alignment: .top)],
                      alignment: .leading, spacing: 26) {
                ForEach(paths, id: \.self) { path in
                    SermonCard(path: path, report: allReports.first { $0.videoPath == path },
                               speaker: profiles.speakers.count > 1 ? profiles.speaker(for: path).name : nil,
                               open: { select(path) }, delete: { pendingDelete = path })
                        .contextMenu {
                            speakerAssignMenu(path)
                            Divider()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            Button("Delete…") { pendingDelete = path }
                        }
                }
            }
            .padding(.horizontal, 32)
        }
    }

    /// Paste a YouTube link to add a sermon.
    private var youTubeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.ui(size: 12)).foregroundColor(gold)
                TextField("Paste a YouTube link to add a sermon", text: $ytURL)
                    .textFieldStyle(.plain).font(.ui(size: 13)).foregroundColor(Theme.text)
                    .onSubmit { importYouTube() }
                Button("Import") { importYouTube() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(ytURL.trimmingCharacters(in: .whitespaces).isEmpty || ytStatus != nil)
            }
            .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 4)
            .background(Capsule().fill(Theme.ink.opacity(0.05))).overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            if let ytStatus {
                HStack(spacing: 5) { ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                    Text(ytStatus).font(.ui(size: 11.5)).foregroundColor(Theme.muted) }
            } else if let ytError {
                Text(ytError).font(.ui(size: 11.5)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Back to the sermon cards from an assessment or the progress page.
    private var backBar: some View {
        HStack {
            Button {
                player.pause()
                selected = nil
                mode = .fillers
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.ui(size: 12, weight: .semibold))
                    Text("All sermons").font(.ui(size: 13, weight: .medium))
                }
                .foregroundColor(Theme.sand)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 28).padding(.top, 16)
    }

    private var deleteTitle: String {
        "Delete “\(YTDLP.title(fromFile: URL(fileURLWithPath: pendingDelete ?? "")))”?"
    }

    private func hide(_ path: String) {
        var h = hiddenVideos; h.insert(path)
        hiddenRaw = h.joined(separator: "\n")
        extraRaw = extraVideos.filter { $0 != path }.joined(separator: "\n")
        if selected == path { selected = nil; player.replaceCurrentItem(with: nil) }
        pendingDelete = nil
    }

    private func trash(_ path: String) {
        if selected == path { selected = nil; player.replaceCurrentItem(with: nil) }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        extraRaw = extraVideos.filter { $0 != path }.joined(separator: "\n")
        pendingDelete = nil
    }

    private func importYouTube() {
        let link = ytURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        ytError = nil; ytStatus = "Starting download…"
        Task {
            do {
                let file = try await YTDLP.download(link) { _, msg in Task { @MainActor in ytStatus = msg } }
                ytStatus = nil; ytURL = ""
                // A video removed earlier but downloaded again comes back
                hiddenRaw = hiddenVideos.subtracting([file.path]).joined(separator: "\n")
                claim(file.path)
                select(file.path)
            } catch {
                ytStatus = nil
                ytError = error.localizedDescription
            }
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url.path)
    }

    /// Adds a recording to this page (if it isn't already) and opens it.
    private func use(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if !extraVideos.contains(url.path) { extraRaw = ([url.path] + extraVideos).joined(separator: "\n") }
        hiddenRaw = hiddenVideos.subtracting([url.path]).joined(separator: "\n")
        claim(url.path)
        select(url.path)
    }

    private func select(_ path: String) {
        selected = path
        Backdrop.shared.path = path
        error = nil; hits = []; words = []; hidden = []; hovered = nil
        report = nil; deliveryStatus = nil; stageStatus = nil; coachStatus = nil; coachError = nil
        notesStatus = nil; notesError = nil
        if mode == .progress { mode = .fillers }
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        if let t = pendingSeek { pendingSeek = nil; play(at: t) }
        status = "Reading the transcript…"
        Task {
            do {
                let ws = try await TranscriptCache.transcript(for: path) { msg in Task { @MainActor in status = msg } }
                guard selected == path else { return }
                let dur = CMTimeGetSeconds((try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration)) ?? .zero)
                words = ws
                hits = FillerReport.find(in: ws)
                duration = max(1, dur.isFinite && dur > 0 ? dur : (ws.last?.endTime ?? 1))
                status = nil
                startAnalysis(path: path, words: ws, duration: duration)
            } catch {
                guard selected == path else { return }
                self.error = error.localizedDescription
                status = nil
            }
        }
    }

    // MARK: Analysis

    /// Loads the saved report (or starts one) and fills in whatever is missing: delivery
    /// first (seconds), then stage presence (about a minute). The AI coach runs on request.
    private func startAnalysis(path: String, words ws: [Word], duration: Double) {
        var r = SpeakerReportStore.load(for: path) ?? SpeakerAnalysis.newReport(videoPath: path, words: ws, duration: duration)
        r.fillerCount = hits.count; r.wordCount = ws.count
        report = r
        SpeakerReportStore.save(r)
        allReports = SpeakerReportStore.all()
        Task {
            if report?.delivery == nil {
                deliveryStatus = "Listening to your voice…"
                do {
                    let d = try await Task.detached(priority: .userInitiated) {
                        try await SpeakerAnalysis.delivery(videoPath: path, words: ws) { p in
                            Task { @MainActor in if selected == path { deliveryStatus = "Listening to your voice… \(Int(p * 100))%" } }
                        }
                    }.value
                    guard selected == path else { return }
                    report?.delivery = d
                    if let r = report { SpeakerReportStore.save(r) }
                } catch {
                    guard selected == path else { return }
                    deliveryStatus = "Couldn't analyse the audio: \(error.localizedDescription)"
                    return
                }
                deliveryStatus = nil
            }
            if report?.stage == nil {
                stageStatus = "Watching the video…"
                let st = await Task.detached(priority: .utility) {
                    await SpeakerAnalysis.stage(videoPath: path) { p in
                        Task { @MainActor in if selected == path { stageStatus = "Watching the video… \(Int(p * 100))%" } }
                    }
                }.value
                guard selected == path else { return }
                report?.stage = st
                stageStatus = nil
                if let r = report { SpeakerReportStore.save(r) }
            }
            allReports = SpeakerReportStore.all()
        }
    }

    private func runCoach() {
        guard let path = selected, let r = report else { return }
        coachError = nil; coachStatus = "The AI coach is reading your message…"
        let sentences = ReelDraft.sentences(from: words)
        let fillersPerMin = Double(hits.count) / max(1, r.speakingMinutes)
        var stats = String(format: "Length %.0f min. Filler words %.1f/min (%d total).", r.speakingMinutes, fillersPerMin, hits.count)
        if let d = r.delivery {
            stats += String(format: " Average pace %.0f wpm (%d fast stretches over 180 wpm). %d natural pauses, %d stretches of 30s+ without pausing. Pitch spread %.1f semitones, %d monotone stretches. %.0f%% of sentences trail off. Crutch phrases: %d. Pronouns: you %d, we %d, I %d. Questions asked: %d.",
                             d.averageWPM, d.fastStretches.count, d.naturalPauses, d.breathlessRuns.count, d.pitchRangeSemitones,
                             d.monotoneStretches.count, d.trailingOffPercent, d.crutches.count, d.youCount, d.weCount, d.iCount, d.questions)
        }
        if let st = r.stage {
            stats += String(format: " Face visible %.0f%% of video, facing camera %.0f%%.", st.onScreenPercent, st.facingPercent)
        }
        Task {
            do {
                let provider = LLMClipService.AIProvider(rawValue: UserDefaults.standard.string(forKey: "ar_provider") ?? "") ?? .google
                guard let key = await LLMClipService.shared.loadAPIKey(for: provider), !key.isEmpty else {
                    coachStatus = nil
                    coachError = "Add an API key in AutoClip → Settings → AI to use the AI coach."
                    return
                }
                let c = try await CostTag.$video.withValue(report?.title) {
                    try await LLMClipService.shared.coachReport(
                        sentences: sentences.map { ($0.start, $0.end, $0.text) }, stats: stats, provider: provider, apiKey: key)
                }
                guard selected == path else { return }
                report?.coach = c
                if let r = report { SpeakerReportStore.save(r) }
                allReports = SpeakerReportStore.all()
                coachStatus = nil
            } catch {
                guard selected == path else { return }
                coachStatus = nil
                coachError = error.localizedDescription
            }
        }
    }

    private func runNotes() {
        guard let path = selected, let r = report else { return }
        notesError = nil; notesStatus = "Writing sermon notes…"
        let sentences = ReelDraft.sentences(from: words)
        var verses: [String] = []
        for v in VerseDetector.find(in: words) where !verses.contains(v.text) { verses.append(v.text) }
        Task {
            do {
                let provider = LLMClipService.AIProvider(rawValue: UserDefaults.standard.string(forKey: "ar_provider") ?? "") ?? .google
                guard let key = await LLMClipService.shared.loadAPIKey(for: provider), !key.isEmpty else {
                    notesStatus = nil
                    notesError = "Add an API key in AutoClip → Settings → AI to write sermon notes."
                    return
                }
                let n = try await CostTag.$video.withValue(r.title) {
                    try await LLMClipService.shared.sermonNotes(
                        sentences: sentences.map { ($0.start, $0.end, $0.text) }, title: r.title, verses: verses,
                        kind: ContentKind.current, provider: provider, apiKey: key)
                }
                guard selected == path else { return }
                report?.notes = n
                if let r = report { SpeakerReportStore.save(r) }
                notesStatus = nil
            } catch {
                guard selected == path else { return }
                notesStatus = nil
                notesError = error.localizedDescription
            }
        }
    }

    private func play(at t: Double) {
        player.seek(to: CMTime(seconds: max(0, t - 1), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: Report

    private var report_: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Image(systemName: "diamond.fill").font(.ui(size: 5)).foregroundColor(Theme.sand)
                            Text(report?.isPractice == true ? "PRACTICE RUN" : ContentKind.current == .sermon ? "SERMON ASSESSMENT" : "TALK ASSESSMENT").font(.ui(size: 11.5, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
                        }
                        Text(YTDLP.title(fromFile: URL(fileURLWithPath: selected ?? "")))
                            .font(Theme.display(28)).foregroundColor(Theme.cream).lineLimit(2)
                    }
                    if let path = selected, profiles.speakers.count > 1 {
                        let who = profiles.speaker(for: path)
                        Menu { speakerAssignMenu(path) } label: {
                            Label(who.name, systemImage: "person.fill")
                        }
                        .menuStyle(.borderlessButton).fixedSize().tint(profiles.color(who))
                        .help("Whose message is this?")
                    }
                    Spacer()
                    if let r = report {
                        Button { SpeakerReportDocument.savePDF(r, speaker: speakerName(r), history: sermons(of: profiles.speaker(for: r.videoPath)), fillers: hits.map { ($0.kind, $0.time) }) } label: {
                            Label("Save PDF", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        .help("A PDF of this assessment to keep or send to a mentor or coach")
                        Button { SpeakerReportDocument.email(r, speaker: speakerName(r), history: sermons(of: profiles.speaker(for: r.videoPath)), fillers: hits.map { ($0.kind, $0.time) }) } label: {
                            Label("Email", systemImage: "envelope")
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .help("A PDF of this assessment to send to a mentor or coach")
                    }
                    IconPillButton(icon: "trash", help: "Delete or remove from the list") { pendingDelete = selected }
                }

                HStack(alignment: .top, spacing: 16) {
                    VideoPlayer(player: player)
                        .frame(width: 400, height: 225)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    summary
                }

                if let r = report, r.isPractice {
                    PracticeCompareCard(report: r, sermons: sermons(of: profiles.speaker(for: r.videoPath)))
                }

                if let r = report {
                    DeliveryOverviewCard(report: r, fillers: overviewFillers, status: deliveryStatus, play: play(at:))
                }

                PillTabs(selection: $mode, items: Mode.allCases.map { ($0, $0.rawValue) })

                switch mode {
                case .fillers:
                    chips
                    occurrences
                case .delivery:
                    if let r = report, let d = r.delivery {
                        DeliverySection(report: r, d: d, play: play(at:))
                    } else {
                        AssessCard(title: "Delivery") {
                            HStack(spacing: 8) { ProgressView().controlSize(.small)
                                Text(deliveryStatus ?? "Starting…").font(.ui(size: 13)).foregroundColor(Theme.ink.opacity(0.7)) }
                        }
                    }
                case .coach:
                    if let r = report { CoachSection(report: r, status: coachStatus, error: coachError, run: runCoach, play: play(at:)) }
                case .notes:
                    if let r = report { NotesSection(report: r, status: notesStatus, error: notesError, run: runNotes, play: play(at:)) }
                case .series:
                    if let path = selected {
                        SeriesSection(path: path, videos: allVideos, reports: allReports) { p, t in
                            if p == selected { if let t { play(at: t) } } else { pendingSeek = t; select(p) }
                        }
                    }
                case .stage:
                    if let r = report { StageSection(report: r, status: stageStatus, play: play(at:)) }
                case .progress:
                    progressBody
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
        }
    }

    /// Filler words plus crutch phrases, each moment once
    private var overviewFillers: [DeliveryOverviewCard.Filler] {
        var out = shown.map { DeliveryOverviewCard.Filler(kind: $0.kind, time: $0.time, context: $0.context) }
        for c in report?.delivery?.crutches ?? [] {
            let kind = c.kind.replacingOccurrences(of: "?", with: "")
            guard !hidden.contains(kind), !out.contains(where: { $0.kind == kind && abs($0.time - c.time) < 0.5 }) else { continue }
            out.append(.init(kind: kind, time: c.time, context: c.context))
        }
        return out
    }

    private var speakingMinutes: Double {
        guard let first = words.first, let last = words.last else { return 1 }
        return max(1, (last.endTime - first.startTime) / 60)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(shown.count)").font(.ui(size: 44, weight: .bold, design: .rounded)).foregroundColor(gold)
            Text(hidden.isEmpty ? "filler words" : "filler words (filtered)")
                .font(.ui(size: 13)).foregroundColor(Theme.ink.opacity(0.7))
            let perMin = Double(shown.count) / speakingMinutes
            Text(String(format: "%.1f per minute of speaking", perMin))
                .font(.ui(size: 13, weight: .medium)).foregroundColor(Theme.ink)
            Text(perMin < 2 ? "Very clean delivery" : perMin < 4 ? "Typical for live preaching" : "Noticeable — worth working on")
                .font(.ui(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
            if report != nil {
                DatePicker("Preached on", selection: Binding(get: { report?.videoDate ?? Date() },
                                                             set: { report?.videoDate = $0
                                                                    if let r = report { SpeakerReportStore.save(r); allReports = SpeakerReportStore.all() } }),
                           displayedComponents: .date)
                    .font(.ui(size: 12)).foregroundColor(Theme.ink.opacity(0.6)).fixedSize()
                    .help("Used to chart your progress over time")
            }
            HStack(spacing: 14) {
                if let d = report?.delivery {
                    Text(String(format: "%.0f wpm", d.averageWPM)).font(.ui(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                }
                if let c = report?.coach {
                    Text("Coach \(c.score)/10").font(.ui(size: 13, weight: .semibold)).foregroundColor(gold)
                }
                if deliveryStatus != nil || stageStatus != nil {
                    HStack(spacing: 4) { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                        Text(deliveryStatus ?? stageStatus ?? "").font(.ui(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55)) }
                }
            }
            Text("Transcription drops some \"um\"s and \"uh\"s, so those counts may be low.")
                .font(.ui(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line for the whole video with a dot for each filler word.
    private var chips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BY WORD — click to show or hide").font(.ui(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(FillerReport.kinds, id: \.self) { k in
                    let n = hits.filter { $0.kind == k }.count
                    Button {
                        if hidden.contains(k) { hidden.remove(k) } else { hidden.insert(k) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color(k)).frame(width: 9, height: 9)
                            Text("\"\(k)\"").font(.ui(size: 13)).foregroundColor(Theme.ink)
                            Spacer(minLength: 4)
                            Text("\(n)").font(.ui(size: 13, weight: .bold, design: .rounded)).foregroundColor(color(k))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.ink.opacity(hidden.contains(k) ? 0.02 : 0.07)).cornerRadius(7)
                        .opacity(hidden.contains(k) ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var occurrences: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EVERY ONE — click to play").font(.ui(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { h in
                    Button { play(h) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(fmt(h.time)).font(.ui(size: 12, design: .monospaced)).foregroundColor(Theme.ink.opacity(0.55))
                                .frame(width: 52, alignment: .leading)
                            Circle().fill(color(h.kind)).frame(width: 7, height: 7)
                            Text(h.context).font(.ui(size: 13)).foregroundColor(Theme.ink.opacity(0.85)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(hovered == h ? Theme.ink.opacity(0.06) : Color.clear).cornerRadius(5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in if inside { hovered = h } }
                }
            }
        }
    }

    private func play(_ h: FillerReport.Hit) {
        player.seek(to: CMTime(seconds: max(0, h.time - 2), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(max(0, s)); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60)
                                                 : String(format: "%d:%02d", i / 60, i % 60)
    }
}

/// One sermon in the Assess library: a poster framed on the preacher, with its filler-word
/// count once it has been assessed.
private struct SermonCard: View {
    let path: String
    let report: SpeakerReport?
    let speaker: String?
    let open: () -> Void
    let delete: () -> Void
    @State private var hover = false

    private var title: String { YTDLP.title(fromFile: URL(fileURLWithPath: path)) }
    private var audioOnly: Bool { AudioSource.isAudioFile(URL(fileURLWithPath: path)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Group {
                    if audioOnly {
                        LinearGradient(colors: [Theme.olive, Theme.charcoal], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "mic.fill").font(.ui(size: 34)).foregroundColor(Theme.sand.opacity(0.5)))
                    } else {
                        Color.clear.overlay(ReelThumbnailView(path: path, faceAspect: 9 / 16))
                    }
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                HStack(spacing: 6) {
                    if let r = report {
                        Text("\(r.fillerCount) FILLERS").font(.ui(size: 11, weight: .bold)).tracking(1).foregroundColor(Theme.onSand)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Theme.sand))
                    } else {
                        Text(PracticeRecorder.isPractice(path) ? "PRACTICE" : "NOT ASSESSED").font(.ui(size: 11, weight: .bold)).tracking(1)
                            .foregroundColor(Theme.cream).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                    Spacer()
                    if hover {
                        Button(action: delete) {
                            Image(systemName: "trash").font(.ui(size: 11.5)).foregroundColor(Theme.danger)
                                .frame(width: 24, height: 24).background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain).help("Delete or remove from the list")
                    }
                }
                .padding(9)
                if let r = report, r.speakingMinutes > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Text("\(Int(Double(r.wordCount) / r.speakingMinutes)) wpm · \(String(format: "%.1f", Double(r.fillerCount) / r.speakingMinutes))/min")
                                .font(.ui(size: 11.5, weight: .semibold)).foregroundColor(Theme.cream)
                            Spacer()
                        }
                        .padding(10)
                    }
                }
                if hover {
                    Image(systemName: "chart.bar.doc.horizontal").font(.ui(size: 17)).foregroundColor(Theme.onColor)
                        .frame(width: 46, height: 46).background(Circle().fill(Theme.terracotta.opacity(0.95)))
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hover ? Theme.sand.opacity(0.6) : Theme.line, lineWidth: hover ? 1.5 : 1))
            .shadow(color: .black.opacity(hover ? 0.45 : 0.25), radius: hover ? 16 : 8, y: hover ? 8 : 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(size: 13, weight: .semibold)).foregroundColor(Theme.text)
                    .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text([speaker, report.map { $0.videoDate.formatted(date: .abbreviated, time: .omitted) }].compactMap { $0 }.joined(separator: " · ").ifEmpty("Click to assess"))
                    .font(.ui(size: 11.5)).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hover ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
