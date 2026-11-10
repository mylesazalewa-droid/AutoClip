import SwiftUI
import AppKit

/// What's been made from one message, and what could be made next.
struct MessageStatus {
    enum Step: String, CaseIterable, Identifiable {
        case clips, graphics, posts, captions, approval, audio, podcast, assess
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clips: return "Clips"
            case .graphics: return "Carousel"
            case .posts: return "Posts"
            case .captions: return "Captions"
            case .approval: return "Approval"
            case .audio: return "Podcast audio"
            case .podcast: return "Episode"
            case .assess: return "Assess"
            }
        }
        var icon: String {
            switch self {
            case .clips: return "play.rectangle.on.rectangle"
            case .graphics: return "rectangle.split.3x1"
            case .posts: return "square.grid.2x2"
            case .captions: return "text.quote"
            case .approval: return "checkmark.seal"
            case .audio: return "waveform"
            case .podcast: return "mic"
            case .assess: return "waveform.badge.magnifyingglass"
            }
        }
        /// What the button says when this hasn't been done
        var todo: String {
            switch self {
            case .clips: return "Export your clips"
            case .graphics: return "Make the carousel"
            case .posts: return "Write a week of posts"
            case .captions: return "Write the clip captions"
            case .approval: return "Send it for approval"
            case .audio: return "Export podcast audio"
            case .podcast: return "Make a podcast episode"
            case .assess: return "See how the delivery went"
            }
        }
    }

    enum State { case done, partly, todo, working }
    var states: [Step: State] = [:]
    var details: [Step: String] = [:]

    var doneCount: Int { states.values.filter { $0 == .done }.count }
    /// The first thing not finished, in a sensible order
    var next: Step? { Step.allCases.first { states[$0] != .done && states[$0] != .working } }

    @MainActor
    static func of(_ rec: AutoReelRecord) -> MessageStatus {
        var s = MessageStatus()
        let drafts = rec.drafts ?? []
        let src = ReelGenerator.sourceVideoPath(for: rec)
        let fm = FileManager.default

        let exported = drafts.filter { d in d.exportedPath.map { fm.fileExists(atPath: $0) } == true && !d.editedSinceExport }.count
        s.states[.clips] = drafts.isEmpty ? .todo : exported == drafts.count ? .done : exported > 0 ? .partly : .todo
        s.details[.clips] = drafts.isEmpty ? "None yet" : "\(exported) of \(drafts.count) exported"

        let c = CarouselStore.load(rec.id)
        let making = CarouselJobs.shared.running(rec.id)
        s.states[.graphics] = making ? .working : (c?.slides.isEmpty == false ? .done : .todo)
        s.details[.graphics] = making ? "Being made" : c.map { "\($0.slides.count) slides" } ?? "Not made"
        let posts = c?.postList.count ?? 0
        s.states[.posts] = making ? .working : posts > 0 ? .done : .todo
        s.details[.posts] = posts > 0 ? "\(posts) posts" : "Not made"

        let captioned = drafts.filter { $0.seo != nil }.count
        s.states[.captions] = drafts.isEmpty ? .todo : captioned == drafts.count ? .done : captioned > 0 ? .partly : .todo
        s.details[.captions] = drafts.isEmpty ? "No clips yet" : "\(captioned) of \(drafts.count) clips"

        let items = ReviewStore.shared.requests.filter { $0.recordID == rec.id }.flatMap(\.items)
        if items.isEmpty {
            s.states[.approval] = .todo; s.details[.approval] = "Not sent"
        } else if items.contains(where: { $0.decision == .changes }) {
            s.states[.approval] = .partly; s.details[.approval] = "Changes asked"
        } else if items.allSatisfy({ $0.decision == .approved }) {
            s.states[.approval] = .done; s.details[.approval] = "Approved"
        } else {
            s.states[.approval] = .partly; s.details[.approval] = "Waiting"
        }

        if let src {
            let audio = UserDefaults.standard.string(forKey: CleanAudioJobs.doneKey(src))
            let hasAudio = audio.map { fm.fileExists(atPath: $0) } == true
            s.states[.audio] = CleanAudioJobs.shared.running(src) ? .working : hasAudio ? .done : .todo
            s.details[.audio] = hasAudio ? "Saved" : "Not exported"
            let episode = PodcastStore.shared.episodes.contains { $0.angles.first?.path == src }
            s.states[.podcast] = episode ? .done : .todo
            s.details[.podcast] = episode ? "Started" : "Not made"
            let report = SpeakerReportStore.load(for: src) != nil
            s.states[.assess] = report ? .done : .todo
            s.details[.assess] = report ? "Report ready" : "Not run"
        }
        return s
    }
}

/// Every message in one place: what's been made from it, what's next, and a way into each part.
struct MessagesTab: View {
    @ObservedObject private var reels = AutoReelsStore.shared
    @ObservedObject private var jobs = CarouselJobs.shared
    @ObservedObject private var reviews = ReviewStore.shared
    @ObservedObject private var audioJobs = CleanAudioJobs.shared
    @Environment(\.openWindow) private var openWindow
    @State private var statuses: [UUID: MessageStatus] = [:]
    @State private var search = ""
    @State private var reviewFor: AutoReelRecord?
    @ObservedObject private var seriesStore = SeriesStore.shared
    @AppStorage("messages_by_series") private var bySeries = true
    @AppStorage("messages_closed_series") private var closedRaw = ""

    private var messages: [AutoReelRecord] {
        let all = reels.reels.filter { ReelGenerator.sourceVideoPath(for: $0) != nil || !($0.drafts ?? []).isEmpty }
            .sorted { $0.dateCreated > $1.dateCreated }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Your work", title: "Messages",
                       subtitle: "Each sermon and everything made from it. Ticks show what's done; the highlighted step is a good next thing to do.") {
                Button(action: addSermon) { Label("Add a sermon", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }
            if !reels.reels.isEmpty {
                HStack(spacing: 14) {
                    TextField("Find a message", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Toggle("Group by series", isOn: $bySeries).toggleStyle(.checkbox).font(.ui(size: 13))
                }
                .padding(.horizontal, 32).padding(.bottom, 14)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(reels.activeJobs.filter { !$0.isFinished }) { job in
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("\(job.title): \(job.statusMsg)").font(.ui(size: 13)).foregroundColor(Theme.muted).lineLimit(1)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                    }
                    if bySeries {
                        ForEach(groups, id: \.key) { g in seriesGroup(g) }
                    } else {
                        ForEach(messages) { rec in card(rec) }
                    }
                    if messages.isEmpty && reels.activeJobs.isEmpty {
                        EmptyState(icon: "rectangle.stack", title: search.isEmpty ? "No messages yet" : "Nothing matches",
                                   message: search.isEmpty ? "Add a sermon video or audio file. AutoClip makes the clips, then everything else for that message lives here." : "Try another word from the title.") {
                            if search.isEmpty { Button(action: addSermon) { Label("Add a sermon", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle()) }
                        }
                        .frame(height: 320)
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 40)
            }
        }
        .onAppear(perform: refresh)
        .onPageShown { refresh() }
        .onChange(of: reels.reels.count) { _, _ in refresh() }
        .onChange(of: jobs.finished) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: CarouselStore.changed)) { _ in refresh() }
        .onReceive(reviews.$requests) { _ in refresh() }
        .onReceive(audioJobs.$states) { _ in refresh() }
        .sheet(item: $reviewFor) { ReviewSendSheet(record: $0) }
    }

    private func refresh() {
        var out: [UUID: MessageStatus] = [:]
        for r in reels.reels { out[r.id] = MessageStatus.of(r) }
        statuses = out
    }

    // MARK: Card

    private func card(_ rec: AutoReelRecord) -> some View {
        let s = statuses[rec.id] ?? MessageStatus()
        let total = MessageStatus.Step.allCases.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ScrubThumb(draft: rec.drafts?.first, path: ReelGenerator.sourceVideoPath(for: rec) ?? rec.path, faceAspect: 16 / 9)
                    .frame(width: 176, height: 99).clipShape(RoundedRectangle(cornerRadius: 8))
                    .environment(\.colorScheme, .dark)
                    .onTapGesture { open(rec, .clips) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(rec.title).font(Theme.display(20, weight: .medium)).foregroundColor(Theme.cream).lineLimit(1)
                    Text(meta(rec)).font(.ui(size: 12)).foregroundColor(Theme.muted)
                    HStack(spacing: 8) {
                        ProgressView(value: Double(s.doneCount), total: Double(total)).tint(Theme.sand).frame(width: 140)
                        Text("\(s.doneCount) of \(total) done").font(.ui(size: 11.5, weight: .semibold)).foregroundColor(Theme.muted)
                    }
                    if let n = s.next {
                        Button { act(rec, n) } label: {
                            Label("Next: \(n.todo)", systemImage: "arrow.right.circle.fill").lineLimit(1).fixedSize()
                        }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        .padding(.top, 2)
                    } else {
                        Label("Everything's made for this message", systemImage: "checkmark.circle.fill")
                            .font(.ui(size: 12.5, weight: .semibold)).foregroundColor(Theme.good)
                    }
                }
                Spacer(minLength: 8)
                Button { open(rec, .clips) } label: { Label("Open", systemImage: "rectangle.stack").lineLimit(1).fixedSize() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("This message's clips, graphics, captions and audio")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(MessageStatus.Step.allCases) { step in chip(rec, step, s) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
    }

    private func chip(_ rec: AutoReelRecord, _ step: MessageStatus.Step, _ s: MessageStatus) -> some View {
        let state = s.states[step] ?? .todo
        let isNext = s.next == step
        let (mark, colour): (String, Color) = {
            switch state {
            case .done: return ("checkmark.circle.fill", Theme.good)
            case .partly: return ("circle.lefthalf.filled", Theme.warn)
            case .working: return ("hourglass", Theme.sand)
            case .todo: return ("circle", Theme.faint)
            }
        }()
        return Button { act(rec, step) } label: {
            HStack(spacing: 8) {
                Image(systemName: mark).font(.ui(size: 13)).foregroundColor(colour)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title).font(.ui(size: 12.5, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                    Text(s.details[step] ?? "").font(.ui(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(isNext ? Theme.sand.opacity(0.13) : Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isNext ? Theme.sand.opacity(0.6) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state == .done ? "Open \(step.title.lowercased())" : step.todo)
    }

    private func meta(_ rec: AutoReelRecord) -> String {
        var parts = [Date(timeIntervalSince1970: rec.dateCreated).formatted(date: .abbreviated, time: .omitted)]
        if rec.duration >= 60 { parts.append("\(Int(rec.duration / 60)) min") }
        parts.append("\(rec.drafts?.count ?? 0) clips")
        return parts.joined(separator: " · ")
    }

    // MARK: Series

    struct SeriesGroup { var key: String; var name: String; var saved: SermonSeries?; var items: [AutoReelRecord] }

    /// Messages grouped by saved series first, then by a series spotted in their titles ("Supply | Pt. 2").
    private var groups: [SeriesGroup] {
        var out: [SeriesGroup] = []
        func src(_ r: AutoReelRecord) -> String { ReelGenerator.sourceVideoPath(for: r) ?? r.path }
        for r in messages {
            if let s = seriesStore.series(containing: src(r)) {
                if let i = out.firstIndex(where: { $0.key == s.id }) { out[i].items.append(r) }
                else { out.append(SeriesGroup(key: s.id, name: s.name, saved: s, items: [r])) }
                continue
            }
            let name = SeriesStore.seriesName(r.title)
            let k = SeriesStore.key(name)
            if name != r.title, let i = out.firstIndex(where: { $0.saved == nil && SeriesStore.sameSeries($0.key, k) }) {
                out[i].items.append(r)
            } else {
                out.append(SeriesGroup(key: name != r.title ? k : "single-" + r.id.uuidString, name: name != r.title ? name : "", saved: nil, items: [r]))
            }
        }
        // Parts in order inside a series
        for i in out.indices where out[i].items.count > 1 {
            out[i].items.sort { (SeriesStore.partNumber($0.title) ?? 0, $0.dateCreated) > (SeriesStore.partNumber($1.title) ?? 0, $1.dateCreated) }
        }
        return out
    }

    private func isClosed(_ key: String) -> Bool { closedRaw.split(separator: ",").contains(Substring(key)) }
    private func toggle(_ key: String) {
        var set = Set(closedRaw.split(separator: ",").map(String.init))
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        closedRaw = set.sorted().joined(separator: ",")
    }

    @ViewBuilder private func seriesGroup(_ g: SeriesGroup) -> some View {
        if g.items.count == 1 && g.saved == nil {
            card(g.items[0])
        } else {
            let closed = isClosed(g.key)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { toggle(g.key) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.right").font(.ui(size: 12, weight: .bold)).foregroundColor(Theme.sand)
                                .rotationEffect(.degrees(closed ? 0 : 90))
                            Image(systemName: "books.vertical").foregroundColor(Theme.sand)
                            Text(g.name.isEmpty ? "Series" : g.name).font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
                            Text("\(g.items.count) message\(g.items.count == 1 ? "" : "s")").font(.ui(size: 12, weight: .semibold)).foregroundColor(Theme.muted)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.ink.opacity(0.07)))
                            let done = g.items.reduce(0) { $0 + (statuses[$1.id]?.doneCount ?? 0) }
                            Text("\(done) of \(g.items.count * MessageStatus.Step.allCases.count) done").font(.ui(size: 12)).foregroundColor(Theme.faint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if g.saved == nil {
                        Button { saveSeries(g) } label: { Label("Save as a series", systemImage: "plus.square.on.square").lineLimit(1).fixedSize() }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .help("Keeps these together for good, and lets the series share one clip look and graphic. Assess can then check the series holds together")
                    } else {
                        Label("Series", systemImage: "checkmark.seal").font(.ui(size: 12, weight: .semibold)).foregroundColor(Theme.good)
                            .help("Saved as a series. Edit it in Assess → Series")
                    }
                }
                if !closed {
                    VStack(spacing: 10) { ForEach(g.items) { card($0) } }
                        .padding(.leading, 18)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.sand.opacity(0.35)).frame(width: 2).padding(.leading, 4) }
                }
            }
        }
    }

    private func saveSeries(_ g: SeriesGroup) {
        let paths = g.items.sorted { (SeriesStore.partNumber($0.title) ?? 0, $0.dateCreated) < (SeriesStore.partNumber($1.title) ?? 0, $1.dateCreated) }
            .compactMap { ReelGenerator.sourceVideoPath(for: $0) }
        guard !paths.isEmpty else { return }
        seriesStore.upsert(SermonSeries(name: g.name.isEmpty ? (g.items.first?.title ?? "Series") : g.name, videos: paths))
    }

    // MARK: Going to each part

    private func open(_ rec: AutoReelRecord, _ pane: MessagePane) {
        UserDefaults.standard.set(pane.rawValue, forKey: "message_pane")
        openWindow(id: "reel-window", value: rec.id)
    }

    private func act(_ rec: AutoReelRecord, _ step: MessageStatus.Step) {
        let src = ReelGenerator.sourceVideoPath(for: rec)
        switch step {
        case .clips: open(rec, .clips)
        case .graphics, .posts: open(rec, .graphics)
        case .captions: open(rec, .captions)
        case .audio: open(rec, .audio)
        case .approval: reviewFor = rec
        case .podcast:
            guard let src else { return }
            let id = PodcastStore.shared.episodes.first { $0.angles.first?.path == src }?.id
                ?? PodcastStore.shared.create(title: rec.title, paths: [src])
            HomeNav.shared.openPodcast(id)
        case .assess:
            if let src { HomeNav.shared.openAssess(src) }
        }
    }

    private func addSermon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent, .audio]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Choose the sermon video, or the audio if there's no video"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await AutoImport.shared.makeReelsNow(from: url) }
    }
}
