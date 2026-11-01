import SwiftUI
import AVKit
import UniformTypeIdentifiers

private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)
private let warn = Color(red: 1.0, green: 0.6, blue: 0.25)
private let panel = Color(red: 0.09, green: 0.10, blue: 0.15)

func podcastTime(_ s: Double) -> String { PodcastExports.stamp(s) }

/// Podcasts, video or audio: cut pauses and filler words, clean up the sound, switch between
/// cameras (or zoom into one) to follow whoever is talking, export each size plus the podcast
/// audio with chapters, show notes and a transcript.
struct PodcastTab: View {
    @ObservedObject private var store = PodcastStore.shared
    @AppStorage("podcast_selected") private var selected = ""
    @State private var showNew = false

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 260)
            Divider().background(Color.white.opacity(0.08))
            if let e = store.episode(selected) {
                PodcastEpisodeView(id: e.id).id(e.id)
            } else {
                empty
            }
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
        .sheet(isPresented: $showNew) { NewEpisodeSheet { selected = $0 } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EPISODES").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
                Spacer()
                Button { showNew = true } label: { Label("New", systemImage: "plus") }.controlSize(.small)
            }
            .padding(12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.episodes) { e in
                        Button { selected = e.id } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: e.isAudioOnly ? "mic.fill" : e.angles.count > 1 ? "video.fill.badge.plus" : "video.fill")
                                    .font(.system(size: 11)).foregroundColor(selected == e.id ? .black : gold).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        .foregroundColor(selected == e.id ? .black : .white)
                                    if let st = store.status[e.id] {
                                        Text(st).font(.system(size: 10)).lineLimit(1).foregroundColor(selected == e.id ? .black.opacity(0.6) : Color.white.opacity(0.5))
                                    } else if e.duration > 0 {
                                        Text("\(podcastTime(e.duration)) → \(podcastTime(e.editedDuration))").font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(selected == e.id ? .black.opacity(0.6) : Color.white.opacity(0.45))
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(selected == e.id ? gold : Color.clear).cornerRadius(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(panel)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.and.signal.meter.fill").font(.system(size: 40)).foregroundColor(gold)
            Text("Make a podcast").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
            Text("Add a video or audio recording (and any other camera angles). AutoClip cuts the long pauses and “um”s, cleans up and evens out the voices, switches cameras to whoever is talking (or zooms in to make new shots from one camera), and exports YouTube, vertical, square and feed sizes plus a podcast audio file with chapters, show notes and a transcript.")
                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button { showNew = true } label: { Label("New episode", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(gold).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New episode

struct NewEpisodeSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var files: [String] = []
    @State private var link = ""
    @State private var downloading: String?
    @State private var error: String?
    @State private var perPerson = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New episode").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
            TextField("Episode title", text: $title).textFieldStyle(.roundedBorder)
            Text("RECORDINGS").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.4)).tracking(1)
            Text(perPerson
                 ? "Add each person's own recording (video or audio). AutoClip mixes them, evens out the voices, follows whoever is talking on their own mic, and shows everyone side by side for the back-and-forth."
                 : "Add the video or audio. Filmed with more than one camera? Add each camera's file — AutoClip lines them up by their sound and cuts between them. The sound comes from the first file.")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            Toggle("Each file is one person (Zoom, Riverside, SquadCast, or a mic each)", isOn: $perPerson)
                .font(.system(size: 12)).foregroundColor(.white)
            VStack(spacing: 4) {
                ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                    HStack {
                        Text(perPerson ? "Person \(i + 1)" : i == 0 ? "Main" : "Camera \(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundColor(gold).frame(width: 60, alignment: .leading)
                        Text(URL(fileURLWithPath: f).lastPathComponent).font(.system(size: 12)).foregroundColor(.white).lineLimit(1)
                        Spacer()
                        if i > 0 { Button { files.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless) }
                        Button { files.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    .padding(6).background(Color.white.opacity(0.05)).cornerRadius(6)
                }
            }
            HStack {
                Button { choose() } label: { Label("Add files…", systemImage: "plus") }
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundColor(gold)
                TextField("Or paste a YouTube link", text: $link).textFieldStyle(.roundedBorder).onSubmit(download)
                Button("Import", action: download).disabled(link.isEmpty || downloading != nil)
            }
            if let downloading { HStack { ProgressView().controlSize(.small); Text(downloading).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6)) } }
            if let error { Text(error).font(.system(size: 11)).foregroundColor(warn) }
            if perPerson && files.count == 1 {
                Text("Add a recording for each person.").font(.system(size: 11)).foregroundColor(warn)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create episode") {
                    let t = title.trimmingCharacters(in: .whitespaces)
                    let id = PodcastStore.shared.create(title: t.isEmpty ? YTDLP.title(fromFile: URL(fileURLWithPath: files[0])) : t, paths: files,
                                                        oneFilePerPerson: perPerson)
                    onCreate(id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(gold)
                .disabled(files.isEmpty || downloading != nil || (perPerson && files.count < 2))
            }
        }
        .padding(20).frame(width: 520).background(panel)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls where !files.contains(u.path) { files.append(u.path) }
        if title.isEmpty, let f = files.first { title = YTDLP.title(fromFile: URL(fileURLWithPath: f)) }
    }

    private func download() {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        error = nil; downloading = "Starting download…"
        Task {
            do {
                let f = try await YTDLP.download(l) { _, msg in Task { @MainActor in downloading = msg } }
                files.append(f.path); link = ""
                if title.isEmpty { title = YTDLP.title(fromFile: f) }
            } catch { self.error = error.localizedDescription }
            downloading = nil
        }
    }
}

// MARK: - Episode

struct PodcastEpisodeView: View {
    let id: String
    @ObservedObject private var store = PodcastStore.shared
    @State private var player = AVPlayer()
    @State private var format = "16:9"
    @State private var section: Section = .edit
    @State private var now = 0.0             // edited time
    @State private var observer: Any?
    @State private var building = false
    @State private var title = ""
    @State private var confirmDelete = false
    enum Section: String, CaseIterable { case edit = "Edit", camera = "Camera", sound = "Sound", notes = "Show notes", export = "Export" }

    private var e: PodcastEpisode? { store.episode(id) }

    /// Changes that need a new preview
    private var previewKey: String {
        guard let e else { return "" }
        let shots = e.shots.map { "\($0.start)\($0.angle)\($0.person ?? -1)\($0.zoom)" }.joined()
        var h: UInt64 = 5381
        for b in shots.utf8 { h = (h &* 33) ^ UInt64(b) }
        return "\(format)|\(e.enabledCuts.count)|\(e.removedSeconds)|\(h)|\(e.analyzed)|\(e.angles.count)"
    }

    var body: some View {
        if let e {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(e)
                    if !e.analyzed {
                        progressCard(e)
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            preview(e)
                            summary(e)
                        }
                        if !e.isAudioOnly { PodcastTimeline(episode: e, now: now) { seek($0) } }
                        if !e.isAudioOnly { currentShot(e) }
                        Picker("", selection: $section) {
                            ForEach(Section.allCases.filter { !(e.isAudioOnly && $0 == .camera) }, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        switch section {
                        case .edit: PodcastEditSection(id: id, seek: seek)
                        case .camera: PodcastCameraSection(id: id)
                        case .sound: PodcastSoundSection(id: id)
                        case .notes: PodcastNotesSection(id: id, seek: seek)
                        case .export: PodcastExportSection(id: id)
                        }
                    }
                }
                .padding(20)
            }
            .task(id: previewKey) { await rebuildPreview() }
            .onAppear {
                title = e.title
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { t in
                    now = CMTimeGetSeconds(t)
                }
            }
            .onDisappear {
                if let observer { player.removeTimeObserver(observer) }
                player.pause()
            }
        }
    }

    private func header(_ e: PodcastEpisode) -> some View {
        HStack(spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                .onSubmit { store.update(id) { $0.title = title } }
                .onChange(of: title) { t in store.update(id) { $0.title = t } }
            Spacer()
            Menu {
                Button("Read the recording again") { store.analyze(id) }
                Button("Show working files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.folder]) }
                Divider()
                Button("Delete episode…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .confirmationDialog("Delete “\(e.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete episode", role: .destructive) { store.cancel(id); store.delete(id) }
        } message: {
            Text("Removes the episode and its working files from AutoClip. Your original recordings and anything you exported stay.")
        }
    }

    @ViewBuilder private func statusLine() -> some View {
        if let st = store.status[id] {
            HStack(spacing: 8) {
                if let p = store.progress[id] { ProgressView(value: p).frame(width: 140) } else { ProgressView().controlSize(.small) }
                Text(st).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.7)).lineLimit(1)
                Spacer()
                Button("Stop") { store.cancel(id) }.controlSize(.small)
            }
        }
        if let err = store.errors[id] {
            Text(err).font(.system(size: 11)).foregroundColor(warn).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressCard(_ e: PodcastEpisode) -> some View {
        AssessCard(title: "Getting the episode ready") {
            Text("Transcribing, finding the pauses and filler words\(e.isAudioOnly ? "" : ", finding faces and working out who is talking"). An hour-long episode takes a few minutes.")
                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            statusLine()
            if store.status[id] == nil {
                Button("Start") { store.analyze(id) }.buttonStyle(.borderedProminent).tint(gold)
            }
        }
    }

    private func preview(_ e: PodcastEpisode) -> some View {
        let size = PodcastVideo.renderSize(format)
        let box = CGSize(width: 480, height: 300)
        let s = min(box.width / size.width, box.height / size.height)
        return VStack(spacing: 6) {
            ZStack {
                Color.black
                VideoPlayer(player: player)
                    .frame(width: e.isAudioOnly ? box.width : size.width * s, height: e.isAudioOnly ? 80 : size.height * s)
                if building { ProgressView().controlSize(.small) }
            }
            .frame(width: box.width, height: e.isAudioOnly ? 80 : box.height).cornerRadius(8)
            if !e.isAudioOnly {
                Picker("", selection: $format) {
                    ForEach(PodcastVideo.formats, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            Text("Preview with the original sound. Names, title card and cleaned-up sound are added on export.")
                .font(.system(size: 9)).foregroundColor(Color.white.opacity(0.35))
        }
    }

    private func summary(_ e: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine()
            VStack(alignment: .leading, spacing: 2) {
                Text(podcastTime(e.editedDuration)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundColor(gold)
                Text("after the edit · was \(podcastTime(e.duration))").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55))
            }
            let pauses = e.enabledCuts.filter { $0.kind == .pause }, fillers = e.enabledCuts.filter { $0.kind == .filler }
            Text("\(pauses.count) pause\(pauses.count == 1 ? "" : "s") shortened · \(fillers.count) filler word\(fillers.count == 1 ? "" : "s") cut").font(.system(size: 12)).foregroundColor(.white)
            if !e.isAudioOnly {
                Text("\(e.people.count) \(e.people.count == 1 ? "person" : "people") · \(e.angles.count) \(e.separateTracks ? "recordings" : e.angles.count == 1 ? "camera" : "cameras") · \(e.shots.count) shots")
                    .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.7))
            }
            HStack(spacing: 8) {
                Button { section = .export } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).tint(gold)
                if !e.isAudioOnly {
                    Button { makeClips(e) } label: { Label("Make clips", systemImage: "scissors") }
                        .help("Open Auto Reels with this episode (the exported 16:9 video if there is one) to cut short clips")
                }
            }
            .padding(.top, 4)
        }
    }

    private func currentShot(_ e: PodcastEpisode) -> some View {
        let src = e.sourceTime(now)
        let shot = e.shots.first { src >= $0.start && src < $0.end }
        return HStack(spacing: 10) {
            Text(podcastTime(now)).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
            if let shot {
                Circle().fill(shot.person.map { PodcastStore.palette[$0 % PodcastStore.palette.count] } ?? Color.gray).frame(width: 9, height: 9)
                Text(describe(shot, e)).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                if shot.manual { Text("chosen by you").font(.system(size: 10)).foregroundColor(gold) }
                Menu("Change this shot") {
                    ForEach(options(e), id: \.label) { o in
                        Button(o.label) { store.setShot(id, shotID: shot.id, angle: o.angle, person: o.person, zoom: o.zoom) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
        }
        .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
    }

    private func describe(_ s: PodcastEpisode.Shot, _ e: PodcastEpisode) -> String {
        if s.angle == PodcastEpisode.grid { return "Everyone side by side" }
        if e.separateTracks, let p = e.person(s.person) { return s.zoom > 1 ? "Tight shot of \(p.name)" : p.name }
        let cam = e.angles.count > 1 ? "Camera \(s.angle + 1): " : ""
        guard let p = e.person(s.person) else { return cam + (s.zoom > 1 ? "Wide, pushed in" : "Wide shot") }
        return cam + (s.zoom > 1 ? "Tight close-up on \(p.name)" : "Close-up on \(p.name)")
    }

    private func options(_ e: PodcastEpisode) -> [(label: String, angle: Int, person: Int?, zoom: Double)] {
        var out: [(String, Int, Int?, Double)] = []
        if e.separateTracks {
            if e.angles.filter({ $0.hasVideo == true }).count > 1 { out.append(("Everyone side by side", PodcastEpisode.grid, nil, 1)) }
            for p in e.people where e.angles[safe: p.angle]?.hasVideo == true {
                out.append((p.name, p.angle, p.id, 1))
                out.append(("Tight shot of \(p.name)", p.angle, p.id, 1.3))
            }
            return out
        }
        for k in e.angles.indices {
            let cam = e.angles.count > 1 ? "Camera \(k + 1) – " : ""
            out.append((cam + "Wide", k, nil, 1))
            out.append((cam + "Wide, pushed in", k, nil, 1.25))
            for p in e.people where p.angle == k || p.otherAngles[k] != nil {
                out.append((cam + "Close-up on \(p.name)", k, p.id, 1))
                out.append((cam + "Tight close-up on \(p.name)", k, p.id, 1.35))
            }
        }
        return out
    }

    private func seek(_ edited: Double) {
        player.seek(to: CMTime(seconds: max(0, edited), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func rebuildPreview() async {
        guard let e, e.analyzed else { return }
        building = true
        let at = player.currentTime()
        if let built = try? await PodcastVideo.build(e, format: format, program: nil, previewHeight: 540) {
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            player.replaceCurrentItem(with: item)
            await player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        building = false
    }

    private func makeClips(_ e: PodcastEpisode) {
        let path = e.exports["16:9"].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? e.angles[0].path
        player.pause()
        AutoReelsHandoff.shared.pending = URL(fileURLWithPath: path)
        AutoReelsHandoff.shared.showTab = true
    }
}

// MARK: - Timeline

/// The camera plan across the edited episode: one colour per person (grey = wide), cut points
/// as red ticks, and the playhead. Click to jump.
struct PodcastTimeline: View {
    let episode: PodcastEpisode
    let now: Double
    let seek: (Double) -> Void

    var body: some View {
        let e = episode
        let total = max(1, e.editedDuration)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                Canvas { ctx, size in
                    for s in e.shots {
                        let x0 = e.editedTime(s.start) / total * w, x1 = e.editedTime(s.end) / total * w
                        guard x1 > x0 else { continue }
                        let color = s.person.map { PodcastStore.palette[$0 % PodcastStore.palette.count] } ?? Color.white.opacity(0.3)
                        let h = s.zoom > 1 ? size.height - 4 : size.height - 10
                        ctx.fill(Path(roundedRect: CGRect(x: x0, y: size.height - h, width: max(1, x1 - x0 - 1), height: h), cornerRadius: 2),
                                 with: .color(color.opacity(s.manual ? 1 : 0.8)))
                    }
                    for c in e.enabledCuts {
                        let x = e.editedTime(c.start) / total * w
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: 5)), with: .color(Color.red.opacity(0.8)))
                    }
                    let px = now / total * w
                    ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in seek(max(0, min(1, v.location.x / w)) * total) })
            }
            .frame(height: 30)
            HStack(spacing: 12) {
                ForEach(e.people) { p in
                    HStack(spacing: 4) {
                        Circle().fill(PodcastStore.palette[p.id % PodcastStore.palette.count]).frame(width: 7, height: 7)
                        Text(p.name).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.6))
                    }
                }
                HStack(spacing: 4) { Circle().fill(Color.white.opacity(0.3)).frame(width: 7, height: 7); Text("Wide").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.6)) }
                HStack(spacing: 4) { Rectangle().fill(Color.red).frame(width: 2, height: 8); Text("Cut").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.6)) }
                Spacer()
                Text(podcastTime(total)).font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Edit

struct PodcastEditSection: View {
    let id: String
    let seek: (Double) -> Void
    @ObservedObject private var store = PodcastStore.shared
    @State private var showAll = false

    var body: some View {
        if let e = store.episode(id) {
            VStack(alignment: .leading, spacing: 14) {
                if e.isAudioOnly { PodcastSpeakersCard(id: id) }
                AssessCard(title: "Tighten the edit") {
                    HStack(spacing: 16) {
                        Toggle("Shorten long pauses", isOn: setting(\.tightenPauses))
                        Picker("to", selection: setting(\.maxPause)) {
                            Text("Tight (0.5s)").tag(0.5); Text("Natural (0.8s)").tag(0.8)
                            Text("Relaxed (1.2s)").tag(1.2); Text("Only very long (2s)").tag(2.0)
                        }
                        .fixedSize().disabled(!e.settings.tightenPauses)
                    }
                    Toggle("Remove “um”, “uh” and “ah”", isOn: setting(\.removeFillers))
                    let heard = e.heardFillers?.count ?? 0
                    Text(heard > 0
                         ? "Includes \(heard) “um”\(heard == 1 ? "" : "s") heard in the pauses that the transcript left out. Ones run straight into the next word can still slip through."
                         : "AutoClip also listens in the pauses for “um”s the transcript leaves out; ones run straight into the next word can still slip through.")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
                    let pauses = e.cuts.filter { $0.kind == .pause && $0.enabled }, fillers = e.cuts.filter { $0.kind == .filler && $0.enabled }
                    let texts = e.cuts.filter { $0.kind == .manual && $0.enabled }
                    if !texts.isEmpty {
                        Text("Plus \(texts.count) cut\(texts.count == 1 ? "" : "s") made in the transcript (\(podcastTime(texts.reduce(0) { $0 + $1.length }))).")
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7))
                    }
                    Text("Cuts \(pauses.count) pause\(pauses.count == 1 ? "" : "s") (\(podcastTime(pauses.reduce(0) { $0 + $1.length }))) and \(fillers.count) filler word\(fillers.count == 1 ? "" : "s") — the episode goes from \(podcastTime(e.duration)) to \(podcastTime(e.editedDuration)).")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                }
                PodcastTranscriptEditor(id: id, seek: seek)
                AssessCard(title: "Every cut", subtitle: "Untick any you want to keep. ▶ plays across the cut.") {
                    HStack {
                        Button("Cut all") { store.update(id) { e in for i in e.cuts.indices { e.cuts[i].enabled = true } } }
                        Button("Keep all") { store.update(id) { e in for i in e.cuts.indices { e.cuts[i].enabled = false } } }
                    }
                    .controlSize(.small)
                    let list = showAll ? e.cuts : Array(e.cuts.prefix(150))
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(list) { c in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { c.enabled }, set: { on in
                                    store.update(id) { e in if let i = e.cuts.firstIndex(where: { $0.id == c.id }) { e.cuts[i].enabled = on } }
                                })).labelsHidden().toggleStyle(.checkbox)
                                Text(podcastTime(c.start)).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.5)).frame(width: 56, alignment: .leading)
                                Image(systemName: c.kind == .filler ? "text.bubble" : c.kind == .manual ? "scissors" : "pause.circle").font(.system(size: 11))
                                    .foregroundColor(c.kind == .pause ? Color.white.opacity(0.6) : gold)
                                Text(c.label).font(.system(size: 12)).foregroundColor(c.enabled ? .white : Color.white.opacity(0.4))
                                Spacer()
                                Text(String(format: "−%.1fs", c.length)).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.45))
                                Button { seek(max(0, e.editedTime(c.start) - 3)) } label: { Image(systemName: "play.fill") }
                                    .buttonStyle(.borderless).foregroundColor(gold)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if e.cuts.count > 150 && !showAll {
                        Button("Show all \(e.cuts.count)") { showAll = true }.controlSize(.small)
                    }
                    if e.cuts.isEmpty { Text("Nothing to cut with these settings.").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.5)) }
                }
            }
        }
    }

    private func setting<T: Equatable>(_ kp: WritableKeyPath<PodcastSettings, T>) -> Binding<T> {
        Binding(get: { store.episode(id)?.settings[keyPath: kp] ?? PodcastSettings()[keyPath: kp] },
                set: { v in store.update(id) { $0.settings[keyPath: kp] = v }; store.refreshCuts(id) })
    }
}

// MARK: - Camera

struct PodcastCameraSection: View {
    let id: String
    @ObservedObject private var store = PodcastStore.shared

    var body: some View {
        if let e = store.episode(id) {
            VStack(alignment: .leading, spacing: 14) {
                AssessCard(title: "People", subtitle: "Name them to show their name on screen the first time they talk") {
                    if e.people.isEmpty {
                        Text("No faces were found, so the camera stays wide (with zoomed-in shots for variety).")
                            .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    }
                    ForEach(e.people) { p in
                        HStack(spacing: 12) {
                            if let img = store.thumbnail(e, p) {
                                Image(nsImage: img).resizable().frame(width: 56, height: 56).cornerRadius(28)
                                    .overlay(Circle().stroke(PodcastStore.palette[p.id % PodcastStore.palette.count], lineWidth: 2))
                            } else {
                                Circle().fill(PodcastStore.palette[p.id % PodcastStore.palette.count]).frame(width: 20, height: 20)
                            }
                            TextField("Name", text: Binding(get: { p.name }, set: { n in
                                store.update(id) { e in if let i = e.people.firstIndex(where: { $0.id == p.id }) { e.people[i].name = n } }
                            })).textFieldStyle(.roundedBorder).frame(width: 200)
                            let talk = e.turns.filter { $0.person == p.id }.reduce(0) { $0 + $1.end - $1.start }
                            Text("talks \(Int(talk / max(1, e.duration) * 100))% of the time").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                            if !p.otherAngles.isEmpty {
                                Text("on camera \(([p.angle] + p.otherAngles.keys.sorted()).map { "\($0 + 1)" }.joined(separator: " & "))")
                                    .font(.system(size: 10)).foregroundColor(gold)
                            }
                        }
                    }
                }
                AssessCard(title: e.separateTracks ? "Recordings" : "Cameras") {
                    ForEach(Array(e.angles.enumerated()), id: \.offset) { i, a in
                        HStack {
                            Image(systemName: a.hasVideo == false ? "mic.fill" : "video.fill").foregroundColor(gold)
                            Text(e.separateTracks ? (e.people.first { $0.angle == i }?.name ?? "Person \(i + 1)") : "Camera \(i + 1)")
                                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                            Text(URL(fileURLWithPath: a.path).lastPathComponent).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6)).lineLimit(1)
                            Spacer()
                            Text(e.separateTracks ? (i == 0 || a.offset == 0 ? "starts with the others" : String(format: "lined up (%@%.1fs)", a.offset >= 0 ? "+" : "", a.offset))
                                 : i == 0 ? "sound comes from here" : String(format: "lined up (%@%.1fs)", a.offset >= 0 ? "+" : "", a.offset))
                                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.45))
                            if i > 0 {
                                Button { store.update(id) { $0.angles.remove(at: i) }; store.analyze(id) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button { addAngle() } label: { Label(e.separateTracks ? "Add another person's recording…" : "Add another camera angle…", systemImage: "plus") }.controlSize(.small)
                    Text(e.separateTracks ? "Each person's own mic decides who is talking. Quick back-and-forth shows everyone side by side."
                         : "With one camera, AutoClip makes extra shots by zooming in on whoever is talking.")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
                }
                AssessCard(title: "Camera style") {
                    Picker("Cutting", selection: plan(\.cameraStyle)) {
                        Text("Calm — long shots").tag("calm"); Text("Balanced").tag("balanced"); Text("Lively — more cuts").tag("lively")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Make extra shots by zooming in", isOn: plan(\.zoomShots))
                    Toggle("Show names on screen", isOn: setting(\.showNames))
                    Toggle("Title card at the start, end card at the end", isOn: setting(\.titleCard))
                    HStack {
                        Text("Cover art").font(.system(size: 12)).foregroundColor(.white)
                        Text(e.settings.coverPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none")
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5)).lineLimit(1)
                        Button("Choose…") { pickCover() }.controlSize(.small)
                        if e.settings.coverPath != nil { Button("Remove") { store.update(id) { $0.settings.coverPath = nil } }.controlSize(.small) }
                    }
                    Text("Cover art shows on the title card and is embedded in the podcast audio file.")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
                    Button("Re-plan every shot") { store.replanShots(id, resetManual: true) }
                        .controlSize(.small).help("Also replaces shots you changed by hand")
                }
            }
        }
    }

    private func setting<T: Equatable>(_ kp: WritableKeyPath<PodcastSettings, T>) -> Binding<T> {
        Binding(get: { store.episode(id)?.settings[keyPath: kp] ?? PodcastSettings()[keyPath: kp] },
                set: { v in store.update(id) { $0.settings[keyPath: kp] = v } })
    }
    /// A setting that changes the camera plan
    private func plan<T: Equatable>(_ kp: WritableKeyPath<PodcastSettings, T>) -> Binding<T> {
        Binding(get: { store.episode(id)?.settings[keyPath: kp] ?? PodcastSettings()[keyPath: kp] },
                set: { v in store.update(id) { $0.settings[keyPath: kp] = v }; store.replanShots(id) })
    }

    private func addAngle() {
        let p = NSOpenPanel()
        p.allowedContentTypes = store.episode(id)?.separateTracks == true
            ? [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
            : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        store.update(id) { e in for u in p.urls where !e.angles.contains(where: { $0.path == u.path }) { e.angles.append(.init(path: u.path)) } }
        store.analyze(id)
    }

    private func pickCover() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .heic]
        guard p.runModal() == .OK, let u = p.url else { return }
        store.update(id) { $0.settings.coverPath = u.path }
    }
}

// MARK: - Sound

struct PodcastSoundSection: View {
    let id: String
    @ObservedObject private var store = PodcastStore.shared

    var body: some View {
        if let e = store.episode(id) {
            VStack(alignment: .leading, spacing: 14) {
                AssessCard(title: "Voices") {
                    Toggle("Clean up the voices (remove echo, hum and background noise)", isOn: setting(\.cleanVoice))
                    if e.settings.cleanVoice {
                        if AudioCleaner.hasVoiceIsolation {
                            HStack {
                                Text("Strength").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6))
                                Slider(value: setting(\.strength), in: 0.3...1).frame(width: 220)
                                Text("\(Int(e.settings.strength * 100))%").font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.6))
                            }
                        } else {
                            Text("Voice isolation needs macOS 14 or later; AutoClip will still remove rumble and hum.")
                                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.45))
                        }
                    }
                    Toggle("Even out the voices (a loud host and a quiet guest end up at the same level)", isOn: setting(\.levelVoices))
                    Picker("Loudness", selection: setting(\.loudness)) {
                        Text("−16 LUFS · Apple Podcasts and most hosts").tag(-16.0)
                        Text("−14 LUFS · Spotify and YouTube").tag(-14.0)
                        Text("−19 LUFS · quieter").tag(-19.0)
                    }
                    .fixedSize()
                }
                AssessCard(title: "Music", subtitle: "Applied when you export") {
                    musicRow("Intro", path: e.settings.introPath, set: { p in store.update(id) { $0.settings.introPath = p } })
                    if e.settings.introPath != nil {
                        Stepper("Plays alone for \(Int(e.settings.introLead)) seconds, then fades under the first words",
                                value: setting(\.introLead), in: 2...20, step: 1).font(.system(size: 11))
                    }
                    musicRow("Outro", path: e.settings.outroPath, set: { p in store.update(id) { $0.settings.outroPath = p } })
                    if e.settings.outroPath != nil {
                        Stepper("Comes in under the last words and plays \(Int(e.settings.outroTail)) seconds after",
                                value: setting(\.outroTail), in: 2...30, step: 1).font(.system(size: 11))
                    }
                    musicRow("Music bed", path: e.settings.musicBedPath, set: { p in store.update(id) { $0.settings.musicBedPath = p } })
                    if e.settings.musicBedPath != nil {
                        HStack {
                            Text("Volume under the talking").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6))
                            Slider(value: setting(\.musicVolume), in: 0.02...0.3).frame(width: 200)
                        }
                    }
                }
            }
        }
    }

    private func musicRow(_ label: String, path: String?, set: @escaping (String?) -> Void) -> some View {
        HStack {
            Image(systemName: "music.note").foregroundColor(gold)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).frame(width: 80, alignment: .leading)
            Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none").font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.55)).lineLimit(1)
            Spacer()
            Button("Choose…") {
                let p = NSOpenPanel()
                p.allowedContentTypes = [.audio, .mp3, .wav, .mpeg4Audio]
                if p.runModal() == .OK, let u = p.url { set(u.path) }
            }
            .controlSize(.small)
            if path != nil { Button("Remove") { set(nil) }.controlSize(.small) }
        }
    }

    private func setting<T: Equatable>(_ kp: WritableKeyPath<PodcastSettings, T>) -> Binding<T> {
        Binding(get: { store.episode(id)?.settings[keyPath: kp] ?? PodcastSettings()[keyPath: kp] },
                set: { v in store.update(id) { $0.settings[keyPath: kp] = v } })
    }
}

// MARK: - Show notes

struct PodcastNotesSection: View {
    let id: String
    let seek: (Double) -> Void
    @ObservedObject private var store = PodcastStore.shared
    @State private var copied: String?

    var body: some View {
        if let e = store.episode(id) {
            if let n = e.notes {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button { copy(PodcastExports.showNotes(e, n, lead: PodcastAudio.lead(e.settings)), "all") } label: {
                            Label(copied == "all" ? "Copied" : "Copy all", systemImage: "doc.on.doc")
                        }
                        Spacer()
                        Button("Write again") { store.writeNotes(id) }.disabled(store.status[id] != nil)
                    }
                    .controlSize(.small)
                    AssessCard(title: "Title ideas") {
                        ForEach(n.titles, id: \.self) { t in
                            HStack {
                                Text(t).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                                Spacer()
                                Button("Use") { store.update(id) { $0.title = t } }.controlSize(.small).disabled(e.title == t)
                            }
                        }
                    }
                    AssessCard(title: "Description") {
                        Text(n.description).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.85)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(copied == "desc" ? "Copied" : "Copy") { copy(n.description, "desc") }.controlSize(.small)
                    }
                    AssessCard(title: "Chapters", subtitle: "Times in the finished episode. Added to the audio file, and ready to paste into YouTube.") {
                        let lead = PodcastAudio.lead(e.settings)
                        ForEach(Array(n.chapters.enumerated()), id: \.offset) { _, c in
                            HStack {
                                Button(podcastTime(c.time <= 1 ? 0 : lead + e.editedTime(c.time))) { seek(e.editedTime(c.time)) }
                                    .buttonStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundColor(gold)
                                Text(c.title).font(.system(size: 12)).foregroundColor(.white)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        AssessCard(title: "Keywords") {
                            Text(n.keywords.joined(separator: ", ")).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.8)).textSelection(.enabled)
                        }
                        if !n.guests.isEmpty {
                            AssessCard(title: "Guests") { Text(n.guests.joined(separator: ", ")).font(.system(size: 12)).foregroundColor(.white) }
                        }
                    }
                    if !n.quotes.isEmpty {
                        AssessCard(title: "Quotes") {
                            ForEach(n.quotes, id: \.self) { q in
                                Text("“\(q)”").font(.system(size: 12)).italic().foregroundColor(Color.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !n.socialPost.isEmpty {
                        AssessCard(title: "Social post") {
                            Text(n.socialPost).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.85)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(copied == "social" ? "Copied" : "Copy") { copy(n.socialPost, "social") }.controlSize(.small)
                        }
                    }
                }
            } else {
                AssessCard(title: "Show notes and chapters") {
                    Text("The AI reads the episode and writes three title ideas, a description, chapters with timestamps, keywords, quotes and a social post. Chapters are added to the podcast audio file. Costs a few cents.")
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    Button { store.writeNotes(id) } label: { Label("Write show notes", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).tint(gold).disabled(store.status[id] != nil)
                    if let err = store.errors[id] { Text(err).font(.system(size: 11)).foregroundColor(warn) }
                }
            }
        }
    }

    private func copy(_ s: String, _ tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == tag { copied = nil } }
    }
}

// MARK: - Export

struct PodcastExportSection: View {
    let id: String
    @ObservedObject private var store = PodcastStore.shared

    var body: some View {
        if let e = store.episode(id) {
            VStack(alignment: .leading, spacing: 14) {
                if !e.isAudioOnly {
                    AssessCard(title: "Video sizes") {
                        HStack(spacing: 16) {
                            ForEach(PodcastVideo.formats, id: \.self) { f in
                                Toggle(PodcastVideo.formatNames[f] ?? f, isOn: Binding(get: { e.settings.formats.contains(f) }, set: { on in
                                    store.update(id) { e in
                                        if on { e.settings.formats.append(f) } else { e.settings.formats.removeAll { $0 == f } }
                                    }
                                }))
                                .toggleStyle(.checkbox)
                            }
                        }
                        Text("Each size follows whoever is talking. Vertical and square sizes frame one person at a time.")
                            .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
                    }
                }
                AssessCard(title: "Podcast audio") {
                    Toggle("Podcast audio file for Spotify, Apple Podcasts and other hosts", isOn: Binding(
                        get: { e.settings.exportAudio || e.isAudioOnly }, set: { v in store.update(id) { $0.settings.exportAudio = v } }))
                        .disabled(e.isAudioOnly)
                    Picker("Format", selection: Binding(get: { e.settings.audioFormat }, set: { v in store.update(id) { $0.settings.audioFormat = v } })) {
                        Text("MP3 (192 kbps)").tag("mp3"); Text("M4A (AAC)").tag("m4a"); Text("WAV (uncompressed)").tag("wav")
                    }
                    .fixedSize()
                    if PodcastAudio.ffmpeg() == nil {
                        Text("MP3 needs ffmpeg (brew install ffmpeg). Without it, AutoClip saves M4A, which every podcast host accepts.")
                            .font(.system(size: 10)).foregroundColor(warn)
                    }
                    Text("Includes the title\(e.notes == nil ? "" : ", chapters")\(e.settings.coverPath == nil ? "" : " and cover art"). \(e.notes == nil ? "Write show notes first to add chapters." : "")")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.45))
                }
                AssessCard(title: "Also saved") {
                    Text("• Transcript (.txt) with who said what\n• Captions (.srt) for YouTube\(e.notes == nil ? "" : "\n• Show notes (.txt)")")
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.75))
                    HStack {
                        Text(store.exportFolder(e).path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.5)).lineLimit(1)
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: store.exportFolder(e), withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([store.exportFolder(e)])
                        }
                        .controlSize(.small)
                    }
                }
                HStack(spacing: 10) {
                    Button { store.export(id) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent).tint(gold).controlSize(.large)
                        .disabled(store.status[id] != nil || (e.settings.formats.isEmpty && !e.settings.exportAudio && !e.isAudioOnly))
                    if let st = store.status[id] {
                        if let p = store.progress[id] { ProgressView(value: p).frame(width: 160) } else { ProgressView().controlSize(.small) }
                        Text(st).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.7))
                        Button("Stop") { store.cancel(id) }.controlSize(.small)
                    }
                }
                if let err = store.errors[id] { Text(err).font(.system(size: 11)).foregroundColor(warn) }
                if !e.exports.isEmpty {
                    AssessCard(title: "Exported") {
                        ForEach(e.exports.sorted { $0.key < $1.key }, id: \.key) { k, path in
                            HStack {
                                Image(systemName: k == "audio" ? "waveform" : ["transcript", "srt", "notes"].contains(k) ? "doc.text" : "film")
                                    .foregroundColor(gold)
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12)).foregroundColor(.white).lineLimit(1)
                                Spacer()
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }
}
