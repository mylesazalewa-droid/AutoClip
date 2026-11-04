import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit
import Vision

// MARK: - Thumbnail helper

func generateThumbnail(from path: String) async -> NSImage? {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 640, height: 640)
    let time = CMTime(seconds: 1.0, preferredTimescale: 600)
    return try? await withCheckedThrowingContinuation { cont in
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, img, _, result, err in
            if result == .succeeded, let img { cont.resume(returning: NSImage(cgImage: img, size: .zero)) }
            else { cont.resume(throwing: err ?? NSError(domain: "", code: 0)) }
        }
    }
}

// MARK: - Persistent record

struct AutoReelRecord: Identifiable, Codable {
    var id: UUID
    var title: String
    var path: String              // primary file (first reel / single reel)
    var paths: [String]           // all files (for multiple reels)
    var format: String
    var duration: Double
    var clipCount: Int
    var dateCreated: Double
    var cutPoints: [Double]       // fractional [0,1] cut positions for scrubber (primary reel)
    var cutPointsPerReel: [[Double]] // per-reel cut points for multi-reel packs
    var transcript: String = ""   // joined words from selected clips
    var reelTitles: [String] = [] // unique per-reel title derived from hook clip
    /// Editable reels (2.61+). nil for older records, which were rendered straight to files.
    var drafts: [ReelDraft]? = nil
    /// Settings + source used to build these reels, for "Generate more" / 🔥 Fire Short
    var genParams: AutoReelJobParams? = nil
    var sourceVideoPath: String? = nil
    /// Sermon, talk, podcast… (nil = records from before 2.87, which were made as sermons)
    var contentKind: String? = nil
    var kind: ContentKind { ContentKind(rawValue: contentKind ?? "") ?? .sermon }

    init(id: UUID, title: String, path: String, paths: [String] = [],
         format: String, duration: Double, clipCount: Int, dateCreated: Double,
         cutPoints: [Double] = [], cutPointsPerReel: [[Double]] = [],
         transcript: String = "", reelTitles: [String] = [], drafts: [ReelDraft]? = nil) {
        self.drafts = drafts
        self.id = id; self.title = title; self.path = path
        self.paths = paths.isEmpty ? [path] : paths
        self.format = format; self.duration = duration
        self.clipCount = clipCount; self.dateCreated = dateCreated
        self.cutPoints = cutPoints
        self.cutPointsPerReel = cutPointsPerReel
        self.transcript = transcript
        self.reelTitles = reelTitles
    }
}

// MARK: - Pipeline params (stored for retry)

struct AutoReelJobParams: Codable {
    var videoURL: URL
    var formatRaw: String
    var captions: Bool
    var captionStyleIndex: Int
    var targetDuration: Double
    var useAI: Bool
    var providerRaw: String
    var desiredReelCount: Int
    var storylineModeRaw: String?
    var topic: String
    var crossDissolve: Bool
    var emojiOverlays: Bool
    var outputDir: URL
    /// One continuous moment per reel (the old Auto Clips) — optional so older records decode
    var singleClip: Bool? = nil
    /// The YouTube video's title, used as the project card's name
    var sourceTitle: String? = nil
}

// MARK: - Active job (lives in store, survives tab switches)

struct AutoReelJob: Identifiable {
    let id: UUID
    var title: String
    var progress: Double
    var statusMsg: String
    var isFinished: Bool
    var error: String?
    var outputURL: URL?          // single reel
    var outputURLs: [URL]?       // multiple reels or individual clips
    var cutPoints: [Double]      // fractional positions [0,1] for scrubber tick marks
    var reelDuration: Double     // total duration of the primary reel (for cut point math)
    var pendingClips: [Clip]?    // non-nil = waiting for user to confirm export
    var sourceVideoPath: String? // for thumbnail generation during processing
    var retryParams: AutoReelJobParams? // stored so failed jobs can be retried

    init(id: UUID, title: String, progress: Double, statusMsg: String,
         isFinished: Bool, error: String? = nil, outputURL: URL? = nil,
         outputURLs: [URL]? = nil, cutPoints: [Double] = [], reelDuration: Double = 0,
         pendingClips: [Clip]? = nil, sourceVideoPath: String? = nil,
         retryParams: AutoReelJobParams? = nil) {
        self.id = id; self.title = title; self.progress = progress
        self.statusMsg = statusMsg; self.isFinished = isFinished
        self.error = error; self.outputURL = outputURL; self.outputURLs = outputURLs
        self.cutPoints = cutPoints; self.reelDuration = reelDuration
        self.pendingClips = pendingClips; self.sourceVideoPath = sourceVideoPath
        self.retryParams = retryParams
    }
}

enum ExportMode: String, CaseIterable {
    case reel            = "Reel"
    case multipleReels   = "Multiple Reels"
    case individualClips = "Individual Clips"
}

enum StorylineMode: String, CaseIterable, Identifiable {
    case linear    = "Linear Journey"
    case contrast  = "Contrast Mode"
    case flashback = "Flashback Loop"
    case random    = "Random Vibes"
    case hero      = "Hero's Journey"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .linear:    return "arrow.right"
        case .contrast:  return "arrow.left.arrow.right"
        case .flashback: return "arrow.counterclockwise"
        case .random:    return "shuffle"
        case .hero:      return "star"
        }
    }

    var description: String {
        switch self {
        case .linear:    return "Follow the story from start to finish."
        case .contrast:  return "Put opposites side by side for impact."
        case .flashback: return "Show the ending first, then reveal how."
        case .random:    return "Connect moments by mood, not time."
        case .hero:      return "Shape the story around one emotional arc."
        }
    }

    func order(_ clips: [Clip]) -> [Clip] {
        guard clips.count > 1 else { return clips }
        switch self {
        case .linear:
            return clips.sorted { $0.startTime < $1.startTime }
        case .contrast:
            let sorted = clips.sorted { $0.score > $1.score }
            var result: [Clip] = []
            var lo = 0, hi = sorted.count - 1
            var toggle = true
            while lo <= hi {
                result.append(toggle ? sorted[lo] : sorted[hi])
                if toggle { lo += 1 } else { hi -= 1 }
                toggle.toggle()
            }
            return result
        case .flashback:
            var s = clips.sorted { $0.score > $1.score }
            let top = s.removeFirst()
            return [top] + s.sorted { $0.startTime < $1.startTime }
        case .random:
            return clips.shuffled()
        case .hero:
            var s = clips.sorted { $0.startTime < $1.startTime }
            if let peakIdx = s.indices.max(by: { s[$0].score < s[$1].score }), s.count >= 3 {
                let peak = s.remove(at: peakIdx)
                let mid = s.count / 2
                s.insert(peak, at: mid)
            }
            return s
        }
    }
}

// MARK: - Store

@MainActor
class AutoReelsStore: ObservableObject {
    static let shared = AutoReelsStore()

    @Published var reels: [AutoReelRecord] = []
    @Published var activeJobs: [AutoReelJob] = []
    @Published var pendingReelName: String = ""
    @Published var rerollVariation: Int = 0
    @Published var navigateToReelID: UUID? = nil   // set by Projects tab to deep-link into a reel

    private let key = "autoReelsHistory"
    private let failedJobsKey = "autoReels_failedJobs"
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundActivity: NSObjectProtocol?

    /// While any reel is in progress, tell macOS not to throttle us (App Nap) or let the Mac
    /// idle-sleep — so reels keep rendering at full speed when AutoClip is in the background.
    private func refreshBackgroundActivity() {
        let busy = activeJobs.contains { !$0.isFinished }
        if busy, backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Creating Auto Reels")
        } else if !busy, let a = backgroundActivity {
            ProcessInfo.processInfo.endActivity(a)
            backgroundActivity = nil
        }
    }

    init() { load(); loadFailedJobs() }

    func add(_ reel: AutoReelRecord) {
        reels.insert(reel, at: 0)
        save()
    }

    func updateJob(_ job: AutoReelJob) {
        if let idx = activeJobs.firstIndex(where: { $0.id == job.id }) {
            activeJobs[idx] = job
        } else {
            activeJobs.append(job)
        }
        if job.isFinished && job.error == nil {
            activeTasks.removeValue(forKey: job.id)
            let jobID = job.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.activeJobs.removeAll { $0.id == jobID }
            }
        }
        if job.isFinished && job.error != nil {
            saveFailedJobs()
        }
        refreshBackgroundActivity()
    }

    func registerTask(_ task: Task<Void, Never>, for jobID: UUID) {
        activeTasks[jobID] = task
    }

    func cancelJob(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        if let idx = activeJobs.firstIndex(where: { $0.id == id }) {
            activeJobs[idx].error = "Cancelled"
            activeJobs[idx].isFinished = true
            activeJobs[idx].statusMsg = "Cancelled"
            activeJobs[idx].progress = 0
        }
        refreshBackgroundActivity()
    }

    func clearJob(id: UUID) {
        activeJobs.removeAll { $0.id == id }
        saveFailedJobs()
    }

    func clearAllFinished() {
        activeJobs.removeAll { $0.isFinished }
        saveFailedJobs()
    }

    func update(_ reel: AutoReelRecord) {
        guard let i = reels.firstIndex(where: { $0.id == reel.id }) else { return }
        reels[i] = reel
        save()
    }

    func remove(id: UUID) {
        reels.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reels) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([AutoReelRecord].self, from: data) else { return }
        reels = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        // Projects named after their first spoken words ("He's speaking to us… – 10 Reels")
        // take their video's title instead, once
        if !UserDefaults.standard.bool(forKey: "autoReels_titlesFromVideo") {
            UserDefaults.standard.set(true, forKey: "autoReels_titlesFromVideo")
            var changed = false
            for i in reels.indices where reels[i].title.range(of: #" – (\d+ Reels|Reel)$"#, options: .regularExpression) != nil {
                if let src = ReelGenerator.sourceVideoPath(for: reels[i]) {
                    reels[i].title = YTDLP.title(fromFile: URL(fileURLWithPath: src)); changed = true
                }
            }
            if changed { save() }
        }
    }

    /// Renames a reel project.
    func rename(id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = reels.firstIndex(where: { $0.id == id }) else { return }
        reels[i].title = t
        save()
    }

    private func saveFailedJobs() {
        struct PersistedJob: Codable {
            var id: UUID; var title: String; var error: String; var retryParams: AutoReelJobParams?
        }
        let failed = activeJobs.filter { $0.isFinished && $0.error != nil }.map {
            PersistedJob(id: $0.id, title: $0.title, error: $0.error ?? "", retryParams: $0.retryParams)
        }
        if let data = try? JSONEncoder().encode(failed) {
            UserDefaults.standard.set(data, forKey: failedJobsKey)
        }
    }

    private func loadFailedJobs() {
        struct PersistedJob: Codable {
            var id: UUID; var title: String; var error: String; var retryParams: AutoReelJobParams?
        }
        guard let data = UserDefaults.standard.data(forKey: failedJobsKey),
              let jobs = try? JSONDecoder().decode([PersistedJob].self, from: data) else { return }
        for j in jobs {
            // Only restore if not already in active jobs (avoid duplication on normal session)
            guard !activeJobs.contains(where: { $0.id == j.id }) else { continue }
            let srcPath = j.retryParams?.videoURL.path
            let job = AutoReelJob(id: j.id, title: j.title, progress: 0, statusMsg: j.error,
                                  isFinished: true, error: j.error,
                                  sourceVideoPath: srcPath, retryParams: j.retryParams)
            activeJobs.append(job)
        }
    }
}

// MARK: - Main View

struct AutoReelsTab: View {
    @ObservedObject private var store = AutoReelsStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var showingCreateSheet = false
    @State private var pickedVideoURL: URL?
    @State private var inputMode: InputMode = .file
    @State private var youtubeURL = ""
    @State private var downloadError: String?

    @State private var previewURL: URL?
    @State private var previewPlayer: AVPlayer?
    @State private var previewPlaying = false
    @State private var showingPreviewFor: UUID?
    @State private var previewProgress: Double = 0
    @State private var previewDuration: Double = 1
    @State private var previewTimeObserver: Any?
    @State private var isScrubbing = false
    @State private var previewCutPoints: [Double] = []
    @State private var selectedReel: AutoReelRecord?

    @AppStorage("ar_format")      private var formatRaw: String = VideoExportService.ExportFormat.vertical9x16.rawValue
    @AppStorage("ar_captions")    private var burnCaptions: Bool = true
    @AppStorage("ar_captionIdx")  private var captionStyleIndex: Int = 0
    @AppStorage("ar_targetDur")   private var targetDuration: Double = 90
    @AppStorage("ar_reelCount")   private var desiredReelCount: Int = 0
    @AppStorage("ar_useAI")       private var useAI: Bool = false
    @AppStorage("ar_singleClip")  private var singleClip: Bool = false
    @AppStorage("ar_provider")    private var providerRaw: String = LLMClipService.AIProvider.anthropic.rawValue
    @AppStorage("ar_dissolve")    private var crossDissolve: Bool = false
    @AppStorage("ar_emoji")       private var emojiOverlays: Bool = false
    @AppStorage("ar_storyline")   private var useStoryline: Bool = false
    @AppStorage("ar_storyMode")   private var storylineModeRaw: String = StorylineMode.linear.rawValue

    private var selectedFormat: VideoExportService.ExportFormat {
        get { VideoExportService.ExportFormat(rawValue: formatRaw) ?? .vertical9x16 }
        nonmutating set { formatRaw = newValue.rawValue }
    }
    private var aiProvider: LLMClipService.AIProvider {
        get { LLMClipService.AIProvider(rawValue: providerRaw) ?? .anthropic }
        nonmutating set { providerRaw = newValue.rawValue }
    }
    private var storylineMode: StorylineMode {
        get { StorylineMode(rawValue: storylineModeRaw) ?? .linear }
        nonmutating set { storylineModeRaw = newValue.rawValue }
    }

    @State private var apiKeys: [LLMClipService.AIProvider: String] = [:]
    @State private var captionLook: CaptionLook = CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0])
    @State private var showKey = false
    @AppStorage("ar_topic") private var topicText: String = ""
    @State private var errorDetailText: String? = nil
    @State private var reelSearch: String = ""

    private let gold = Theme.sand
    private let captionStyles = CaptionStyle.all

    enum InputMode { case file, youtube }

    var body: some View {
        Group {
            if store.reels.isEmpty && store.activeJobs.isEmpty {
                landingPage
            } else {
                gridView
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            createReelSheet
        }
        .onReceive(AutoReelsHandoff.shared.$pending) { url in
            guard let url else { return }
            AutoReelsHandoff.shared.pending = nil
            pickedVideoURL = url
            inputMode = .file
            showingCreateSheet = true
        }
        .alert("Error Detail", isPresented: Binding(
            get: { errorDetailText != nil },
            set: { if !$0 { errorDetailText = nil } }
        )) {
            Button("OK") { errorDetailText = nil }
        } message: {
            Text(errorDetailText ?? "")
        }
        .task {
            var loaded: [LLMClipService.AIProvider: String] = [:]
            for p in LLMClipService.AIProvider.allCases {
                if let k = await LLMClipService.shared.loadAPIKey(for: p), !k.isEmpty {
                    loaded[p] = k
                }
            }
            apiKeys = loaded
            if !loaded.isEmpty { useAI = true }
        }
        .onChange(of: store.navigateToReelID) { reelID in
            guard let reelID else { return }
            selectedReel = store.reels.first { $0.id == reelID }
            store.navigateToReelID = nil
        }
    }

    // MARK: - Landing Page

    var landingPage: some View {
        ScrollView {
            VStack(spacing: 40) {
                Spacer(minLength: 40)

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isDropTargeted ? gold : Color.white.opacity(0.15),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isDropTargeted ? gold.opacity(0.06) : Color.white.opacity(0.03))
                        )

                    VStack(spacing: 16) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 44))
                            .foregroundColor(Color.white.opacity(isDropTargeted ? 0.7 : 0.3))

                        VStack(spacing: 6) {
                            Text("Drop your video or audio here")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                            Text("MP4, MOV, MKV — any format works")
                                .font(.system(size: 14))
                                .foregroundColor(Color.white.opacity(0.4))
                        }

                        HStack(spacing: 12) {
                            Button(action: {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.audiovisualContent]
                                panel.allowsOtherFileTypes = true
                                panel.canChooseDirectories = false
                                panel.begin { response in
                                    if response == .OK, let url = panel.url {
                                        pickedVideoURL = url
                                        inputMode = .file
                                        showingCreateSheet = true
                                    }
                                }
                            }) {
                                HStack(spacing: 7) {
                                    Image(systemName: "square.and.arrow.down").font(.system(size: 13))
                                    Text("Browse Files").font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(9)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                inputMode = .youtube
                                showingCreateSheet = true
                            }) {
                                HStack(spacing: 7) {
                                    Image(systemName: "link").font(.system(size: 13))
                                    Text("YouTube URL").font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                .background(Theme.terracotta)
                                .cornerRadius(9)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 50)
                    .padding(.horizontal, 40)
                }
                .frame(maxWidth: 580)
                .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
                .onDrop(of: [.movie, .fileURL], isTargeted: $isDropTargeted) { providers in
                    for p in providers {
                        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                            guard let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                            DispatchQueue.main.async {
                                pickedVideoURL = url
                                inputMode = .file
                                showingCreateSheet = true
                            }
                        }
                    }
                    return true
                }

                HStack(spacing: 14) {
                    reelFeatureCard(icon: "rectangle.stack.fill", emoji: nil,
                                   title: "Multi-Reel Mode", subtitle: "Up to 10 unique reels")
                    reelFeatureCard(icon: nil, emoji: "😊",
                                   title: "Face Tracking", subtitle: "Smart vertical crop")
                    reelFeatureCard(icon: "text.bubble", emoji: nil,
                                   title: "Auto Captions", subtitle: "Viral-style text")
                    reelFeatureCard(icon: "brain.head.profile", emoji: nil,
                                   title: "On-Device AI", subtitle: "No API key needed")
                }
                .frame(maxWidth: 580)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
    }

    func reelFeatureCard(icon: String?, emoji: String?, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            if let emoji = emoji {
                Text(emoji).font(.system(size: 28))
            } else if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(Color.white.opacity(0.5))
            }
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Grid View

    var gridView: some View {
        VStack(spacing: 0) {
            let displayCount = reelSearch.isEmpty ? store.reels.count
                : store.reels.filter { $0.title.localizedCaseInsensitiveContains(reelSearch) }.count
            PageHeader(eyebrow: "Auto Reels", title: "My Reels",
                       subtitle: "\(displayCount) project\(displayCount == 1 ? "" : "s") · short vertical clips cut from your messages") {
                SearchPill(text: $reelSearch, placeholder: "Search reels", width: 200)
                Button(action: {
                    pickedVideoURL = nil
                    inputMode = .file
                    showingCreateSheet = true
                }) { Label("New Reel", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if reelSearch.isEmpty, let latest = store.reels.first {
                        CinematicHero(path: latest.sourceVideoPath ?? latest.path, eyebrow: "Latest project", title: latest.title,
                                      detail: "\(latest.drafts?.count ?? latest.paths.count) reels ready to review", height: 400) {
                            Button { selectedReel = latest } label: { Label("Open", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                            Button {
                                pickedVideoURL = nil; inputMode = .file; showingCreateSheet = true
                            } label: { Label("New reel", systemImage: "plus") }.buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.horizontal, 32)
                        SectionTitle(title: "All projects", count: store.reels.count).padding(.horizontal, 32)
                    }
                    // Active jobs + finished reels, as posters
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250, maximum: 330), spacing: 22, alignment: .top)],
                        alignment: .leading,
                        spacing: 22
                    ) {
                        ForEach(store.activeJobs) { job in activeJobCard(job) }
                        let visibleReels = reelSearch.isEmpty ? store.reels
                            : store.reels.filter { $0.title.localizedCaseInsensitiveContains(reelSearch) }
                        ForEach(visibleReels) { reel in reelCard(reel) }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Reel detail opens as a sheet (same pattern as clicking into a project)
        // 2.61+ reels open in their own resizable window (review, preview, edit, export)
        .onChange(of: selectedReel?.id) { _ in
            if let reel = selectedReel, reel.drafts != nil {
                openWindow(id: "reel-window", value: reel.id)
                selectedReel = nil
            }
        }
        .sheet(item: Binding(get: { selectedReel?.drafts == nil ? selectedReel : nil },
                             set: { selectedReel = $0 })) { reel in
            Group {
                ReelDetailSidebar(
                    reel: reel,
                    gold: gold,
                    onPlay: { url, pts, dur in showPreview(url: url, id: reel.id, cutPoints: pts, reelDuration: dur) },
                    onFinder: { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) },
                    onDelete: { store.remove(id: reel.id); selectedReel = nil }
                )
                .frame(minWidth: 420, minHeight: 600)
            }
        }
    }

    // MARK: - Create Reel Sheet

    var createReelSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Source
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SOURCE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.35))

                        if let url = pickedVideoURL, inputMode == .file {
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(gold)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 13)).foregroundColor(.white).lineLimit(1)
                                Spacer()
                                Button("Change") {
                                    let panel = NSOpenPanel()
                                    panel.allowedContentTypes = [.audiovisualContent]
                                    panel.allowsOtherFileTypes = true
                                    panel.canChooseDirectories = false
                                    panel.begin { response in
                                        if response == .OK, let u = panel.url { pickedVideoURL = u }
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.4))
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)
                        } else {
                            // Mode toggle
                            HStack(spacing: 0) {
                                Button(action: { inputMode = .file; youtubeURL = "" }) {
                                    Text("Video File")
                                        .font(.system(size: 12, weight: inputMode == .file ? .semibold : .regular))
                                        .foregroundColor(inputMode == .file ? .black : Color.white.opacity(0.5))
                                        .padding(.horizontal, 14).padding(.vertical, 6)
                                        .background(inputMode == .file ? gold : Color.clear)
                                        .cornerRadius(7)
                                }
                                .buttonStyle(.plain)
                                Button(action: { inputMode = .youtube; pickedVideoURL = nil }) {
                                    Text("YouTube")
                                        .font(.system(size: 12, weight: inputMode == .youtube ? .semibold : .regular))
                                        .foregroundColor(inputMode == .youtube ? .black : Color.white.opacity(0.5))
                                        .padding(.horizontal, 14).padding(.vertical, 6)
                                        .background(inputMode == .youtube ? gold : Color.clear)
                                        .cornerRadius(7)
                                }
                                .buttonStyle(.plain)
                            }
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)

                            if inputMode == .file {
                                Button(action: {
                                    let panel = NSOpenPanel()
                                    panel.allowedContentTypes = [.audiovisualContent]
                                    panel.allowsOtherFileTypes = true
                                    panel.canChooseDirectories = false
                                    panel.begin { response in
                                        if response == .OK, let url = panel.url { pickedVideoURL = url }
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "square.and.arrow.down").font(.system(size: 12))
                                        Text("Browse Files").font(.system(size: 13, weight: .medium))
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "link")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.white.opacity(0.4))
                                    TextField("https://youtube.com/watch?v=...", text: $youtubeURL)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .foregroundColor(.white)
                                        .onChange(of: youtubeURL) { _ in downloadError = nil }
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.07))
                                .cornerRadius(8)

                                if let err = downloadError {
                                    Text(err)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.danger)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    Divider().background(Color.white.opacity(0.08))

                    sheetSettingsSection
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Create Auto Reel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingCreateSheet = false
                        pickedVideoURL = nil
                        downloadError = nil
                    }
                    .foregroundColor(Color.white.opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
                let canCreate = (inputMode == .file && pickedVideoURL != nil) ||
                                (inputMode == .youtube && !youtubeURL.isEmpty)
                Button(action: {
                    showingCreateSheet = false
                    if inputMode == .youtube && !youtubeURL.isEmpty {
                        startYouTubeDownload()
                    } else if let url = pickedVideoURL {
                        startPipeline(videoURL: url)
                        pickedVideoURL = nil
                    }
                }) {
                    Text("Create Auto Reel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canCreate ? .black : Color.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canCreate ? gold : Color.white.opacity(0.08))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
                .disabled(!canCreate)
                // Opaque bar so scrolled settings don't show through the (translucent) disabled button
                .background(Theme.bg)
            }
        }
        .frame(minWidth: 420, minHeight: 500)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sheet Settings

    var sheetSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35))

            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Format").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    HStack(spacing: 6) {
                        ForEach([VideoExportService.ExportFormat.vertical9x16, .square1x1, .original], id: \.self) { fmt in
                            Button(action: { selectedFormat = fmt }) {
                                Text(fmtLabel(fmt))
                                    .font(.system(size: 11, weight: selectedFormat == fmt ? .semibold : .regular))
                                    .foregroundColor(selectedFormat == fmt ? .black : Color.white.opacity(0.6))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(selectedFormat == fmt ? gold : Color.white.opacity(0.07))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Style").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    Picker("", selection: $singleClip) {
                        Text("Story (stitched)").tag(false)
                        Text("Single clip").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(singleClip
                         ? "Each reel is one continuous moment from the video — no cuts."
                         : "Each reel stitches the best lines into one story.")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
                }
                HStack {
                    Text("Target length").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    Spacer()
                    Text(formatDur(targetDuration)).font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
                }
                Slider(value: $targetDuration, in: 30...300, step: 10).tint(Theme.action)
                HStack {
                    Text("Captions").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    Spacer()
                    Toggle("", isOn: $burnCaptions).toggleStyle(.switch).tint(Theme.action)
                }
                if burnCaptions && !captionStyles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(captionStyles.indices, id: \.self) { i in
                                Button(action: {
                                    captionStyleIndex = i
                                    captionLook = CaptionLook(preset: captionStyles[i])
                                }) {
                                    Text(captionStyles[i].name)
                                        .font(.system(size: 11, weight: captionStyleIndex == i ? .semibold : .regular))
                                        .foregroundColor(captionStyleIndex == i ? .black : Color.white.opacity(0.6))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(captionStyleIndex == i ? gold : Color.white.opacity(0.07))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    CaptionEditorView(look: $captionLook, gold: gold)
                        .padding(.top, 4)
                        .onChange(of: captionLook) { $0.save() }
                }
            }
            .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)

            chatSection
            reelCountSection
            storylineSection
            aiSettingsSection
        }
    }

    // MARK: - Settings sub-sections (reused in sheet)

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundColor(gold).font(.system(size: 11))
                Text("What's this reel about?")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            }
            TextField("faith, business, motivation...", text: $topicText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(10)
                .background(Color.white.opacity(0.09))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(topicText.isEmpty ? Color.clear : gold.opacity(0.45), lineWidth: 1))
            if !topicText.isEmpty {
                Text("AI will prioritize segments and highlight keywords matching this theme.")
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Toggle("", isOn: $crossDissolve).toggleStyle(.switch).tint(Theme.action).labelsHidden()
                    Text("Dissolve cuts").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7))
                }
                HStack(spacing: 6) {
                    Toggle("", isOn: $emojiOverlays).toggleStyle(.switch).tint(Theme.action).labelsHidden()
                    Text("Emoji overlays").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7))
                }
            }
        }
        .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)
    }

    private var reelCountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.stack.fill").foregroundColor(gold).font(.system(size: 11))
                Text("Number of Reels").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                HStack(spacing: 0) {
                    Button(action: { if desiredReelCount > 0 { desiredReelCount -= 1 } }) {
                        Image(systemName: "minus")
                            .font(.system(size: 12))
                            .foregroundColor(desiredReelCount == 0 ? Color.white.opacity(0.2) : Color.white.opacity(0.7))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.07))
                    }
                    .buttonStyle(.plain).disabled(desiredReelCount == 0)

                    Text(desiredReelCount == 0 ? "Auto" : "\(desiredReelCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(desiredReelCount == 0 ? gold : .white)
                        .frame(width: 40)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.05))

                    Button(action: { if desiredReelCount < 10 { desiredReelCount += 1 } }) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                            .foregroundColor(desiredReelCount == 10 ? Color.white.opacity(0.2) : Color.white.opacity(0.7))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.07))
                    }
                    .buttonStyle(.plain).disabled(desiredReelCount == 10)
                }
                .cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            Text(desiredReelCount == 0
                 ? "Auto-calculated from video length — longer videos produce more reels (up to 10)."
                 : "Creates exactly \(desiredReelCount) distinct reel\(desiredReelCount == 1 ? "" : "s"), each with a unique mix of the best moments.")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)
    }

    private var storylineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack").foregroundColor(gold).font(.system(size: 12))
                Text("Storyline").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $useStoryline).toggleStyle(.switch).tint(Theme.action)
            }
            if useStoryline {
                VStack(spacing: 4) {
                    ForEach(StorylineMode.allCases) { mode in
                        Button(action: { storylineMode = mode }) {
                            HStack(spacing: 8) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 11))
                                    .foregroundColor(storylineMode == mode ? .black : gold.opacity(0.7))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mode.rawValue)
                                        .font(.system(size: 11, weight: storylineMode == mode ? .semibold : .regular))
                                        .foregroundColor(storylineMode == mode ? .black : .white)
                                    Text(mode.description)
                                        .font(.system(size: 10))
                                        .foregroundColor(storylineMode == mode ? .black.opacity(0.6) : Color.white.opacity(0.4))
                                        .lineLimit(1)
                                }
                                Spacer()
                                if storylineMode == mode {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.black)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(storylineMode == mode ? gold : Color.white.opacity(0.04))
                            .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)
    }

    private var aiSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(gold).font(.system(size: 12))
                Text("Smart AI Selection")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $useAI).toggleStyle(.switch).tint(Theme.action)
            }

            if useAI {
                Text("AI understands context, complete thoughts, and emotional tone — not just sentence length.")
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                    HStack(spacing: 6) {
                        ForEach(LLMClipService.AIProvider.allCases) { p in
                            Button(action: { aiProvider = p }) {
                                Text(providerShortLabel(p))
                                    .font(.system(size: 11, weight: aiProvider == p ? .semibold : .regular))
                                    .foregroundColor(aiProvider == p ? .black : Color.white.opacity(0.6))
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(aiProvider == p ? gold : Color.white.opacity(0.07))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Model: \(aiProvider.modelLabel)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.3))

                    let estTokens = max(400, Int(targetDuration * 2.5))
                    let estCost: String = {
                        switch aiProvider {
                        case .anthropic: return String(format: "~$%.4f", Double(estTokens) / 1_000_000 * 0.80)
                        case .openai:    return String(format: "~$%.4f", Double(estTokens) / 1_000_000 * 0.30)
                        case .google:    return "~$0.00 (free tier)"
                        }
                    }()
                    HStack(spacing: 5) {
                        Image(systemName: "dollarsign.circle").font(.system(size: 10))
                        Text("Estimated cost per reel: \(estCost)").font(.system(size: 10))
                    }
                    .foregroundColor(Color.white.opacity(0.4))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.05)).cornerRadius(6)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                    HStack(spacing: 6) {
                        let binding = Binding<String>(
                            get: { apiKeys[aiProvider] ?? "" },
                            set: { newVal in
                                apiKeys[aiProvider] = newVal
                                Task { await LLMClipService.shared.saveAPIKey(newVal, for: aiProvider) }
                            }
                        )
                        Group {
                            if showKey {
                                TextField(aiProvider.keyPlaceholder, text: binding)
                            } else {
                                SecureField(aiProvider.keyPlaceholder, text: binding)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.white.opacity(0.06)).cornerRadius(6)

                        Button(action: { showKey.toggle() }) {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Stored in macOS Keychain. Only sent to the selected provider's API.")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                }
            } else {
                Text("Fast on-device mode — no API key needed. Uses rule-based sentence detection.")
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(useAI ? gold.opacity(0.35) : Color.clear, lineWidth: 1))
        )
    }

    private func providerShortLabel(_ p: LLMClipService.AIProvider) -> String {
        switch p {
        case .anthropic: return "Claude"
        case .openai:    return "GPT-4o"
        case .google:    return "Gemini"
        }
    }

    // MARK: - Active job card

    func activeJobCard(_ job: AutoReelJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail area — matches ReelCard height
            ZStack(alignment: .bottom) {
                // Thumbnail from source video (or placeholder while unavailable)
                if let srcPath = job.sourceVideoPath {
                    Color.clear
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .overlay(ReelThumbnailView(path: srcPath, faceAspect: 9 / 16))
                        .clipped()
                        .overlay(Color.black.opacity(0.35))  // dim so overlay text is readable
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .overlay(
                            Image(systemName: job.error != nil ? "exclamationmark.triangle" : "film.stack")
                                .font(.system(size: 36))
                                .foregroundColor(Color.white.opacity(0.10))
                        )
                }

                if job.isFinished && job.error == nil {
                    // Done state: green check + file count
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(gold).font(.system(size: 11))
                        Text(job.outputURLs != nil
                             ? "\(job.outputURLs!.count) reels saved to \(job.outputURLs!.first?.deletingLastPathComponent().lastPathComponent ?? "folder")"
                             : "Reel saved to \(job.outputURL?.deletingLastPathComponent().lastPathComponent ?? "folder")")
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.8))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.black.opacity(0.75))
                } else if let err = job.error {
                    // Error state — tap for full error detail
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 10))
                        Text(err).font(.system(size: 10)).foregroundColor(Color(red: 1, green: 0.55, blue: 0.4)).lineLimit(2)
                        Spacer()
                        Image(systemName: "info.circle").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.black.opacity(0.80))
                    .contentShape(Rectangle())
                    .onTapGesture { errorDetailText = err }
                } else {
                    // Processing overlay — matches ProjectCard style
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform").font(.system(size: 10)).foregroundColor(gold)
                            Text(job.statusMsg).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.7)).lineLimit(1)
                            Spacer()
                            Text("\(Int(job.progress * 100))%")
                                .font(.system(size: 10, design: .monospaced)).foregroundColor(gold)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.15)).frame(height: 3)
                                RoundedRectangle(cornerRadius: 2).fill(gold)
                                    .frame(width: geo.size.width * job.progress, height: 3)
                                    .animation(.easeOut(duration: 0.3), value: job.progress)
                            }
                        }
                        .frame(height: 3)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.black.opacity(0.75))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            // Title row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(job.isFinished && job.error == nil ? "Complete" : job.error != nil ? "Failed" : "Processing…")
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                }
                Spacer()
                if job.isFinished {
                    if job.error != nil, let params = job.retryParams {
                        Button(action: { retryJob(params: params, oldJobID: job.id) }) {
                            Text("Retry")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(gold)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: { store.clearJob(id: job.id) }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                            .foregroundColor(Color.white.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { store.cancelJob(id: job.id) }) {
                        Text("Cancel")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.5))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2).padding(.top, 8).padding(.bottom, 4)

            if job.isFinished, job.error == nil {
                if let urls = job.outputURLs, urls.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: {
                            if let first = urls.first {
                                NSWorkspace.shared.activateFileViewerSelecting([first])
                            }
                        }) {
                            Label("Show in Finder", systemImage: "folder")
                                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.08)).cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                                    HStack(spacing: 8) {
                                        Text("\(i + 1)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Color.white.opacity(0.4))
                                            .frame(width: 18, alignment: .trailing)
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .font(.system(size: 11)).foregroundColor(.white).lineLimit(1)
                                        Spacer()
                                        Button(action: { showPreview(url: url, id: job.id) }) {
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 16)).foregroundColor(gold)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Color.white.opacity(0.04)).cornerRadius(6)
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                } else if let url = job.outputURL {
                    HStack(spacing: 8) {
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                            Label("Finder", systemImage: "folder")
                                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.08)).cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        Button(action: { showPreview(url: url, id: job.id) }) {
                            Label("Preview", systemImage: "play.circle.fill")
                                .font(.system(size: 12, weight: .semibold)).foregroundColor(.black)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(gold).cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    func reelCard(_ reel: AutoReelRecord) -> some View {
        ReelCard(reel: reel, gold: gold,
                 isSelected: selectedReel?.id == reel.id,
                 onSelect: { selectedReel = reel },
                 onPlay: { url, pts, dur in
                     // Draft reels aren't rendered files yet — open the review/editor instead
                     if reel.drafts != nil { selectedReel = reel }
                     else { showPreview(url: url, id: reel.id, cutPoints: pts, reelDuration: dur) }
                 },
                 onFinder: { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) },
                 onDelete: { store.remove(id: reel.id); if selectedReel?.id == reel.id { selectedReel = nil } })
    }
}

// MARK: - Reel card (matches ProjectCard design)

private struct ReelCard: View {
    let reel: AutoReelRecord
    let gold: Color
    let isSelected: Bool
    var onSelect: () -> Void
    var onPlay: (URL, [Double], Double) -> Void
    var onFinder: ([URL]) -> Void
    var onDelete: () -> Void

    @State private var isHovered = false
    @State private var renaming = false
    @State private var newTitle = ""
    @FocusState private var titleFocused: Bool

    private var isMulti: Bool { reel.paths.count > 1 }
    private var primaryURL: URL { URL(fileURLWithPath: reel.path) }

    private var waveformBars: [CGFloat] {
        var seed = reel.id.hashValue
        return (0..<24).map { _ in
            seed = seed &* 1664525 &+ 1013904223
            let h = CGFloat((seed >> 16) & 0xFF) / 255.0
            return 0.15 + h * 0.85
        }
    }

    private var captionSnippet: String {
        let words = reel.title.split(separator: " ").prefix(6)
        return words.joined(separator: " ")
    }

    private var scoreBadge: Int {
        let clamped = min(max(reel.duration, 30), 180)
        return Int(60 + (clamped - 30) / 150 * 35)
    }

    private func shortDate(_ ts: Double) -> String {
        let df = DateFormatter()
        df.dateStyle = .short; df.timeStyle = .none
        return df.string(from: Date(timeIntervalSince1970: ts))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .overlay(ReelThumbnailView(path: reel.path, faceAspect: 9 / 16))
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipped()
                // Shade for the labels
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                HStack(spacing: 6) {
                    if isMulti {
                        Text("\(reel.paths.count) REELS").font(.system(size: 9, weight: .bold)).tracking(1)
                            .foregroundColor(Theme.bg)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Theme.sand))
                    }
                    Spacer()
                    Text(formatReelDur(reel.duration)).font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.cream)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.55)))
                }
                .padding(9)
                // Hover: play, show in Finder, delete
                if isHovered {
                    Color.black.opacity(0.35)
                    VStack(spacing: 12) {
                        Button {
                            let pts = reel.cutPointsPerReel.first ?? reel.cutPoints
                            onPlay(primaryURL, pts, reel.duration)
                        } label: {
                            Image(systemName: "play.fill").font(.system(size: 18)).foregroundColor(Theme.cream)
                                .frame(width: 48, height: 48).background(Circle().fill(Theme.terracotta.opacity(0.95)))
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain).help("Preview")
                        HStack(spacing: 8) {
                            Button {
                                let urls = reel.paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                                onFinder(urls.isEmpty ? [primaryURL] : urls)
                            } label: {
                                Image(systemName: "folder").font(.system(size: 11)).foregroundColor(Theme.cream)
                                    .frame(width: 28, height: 28).background(Circle().fill(Color.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain).help("Show in Finder")
                            Button(action: onDelete) {
                                Image(systemName: "trash").font(.system(size: 11)).foregroundColor(Theme.danger)
                                    .frame(width: 28, height: 28).background(Circle().fill(Color.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain).help("Delete")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Theme.sand : isHovered ? Theme.sand.opacity(0.6) : Theme.line, lineWidth: isSelected || isHovered ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.45 : 0.25), radius: isHovered ? 16 : 8, y: isHovered ? 8 : 4)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }

            VStack(alignment: .leading, spacing: 3) {
                if renaming {
                    TextField("Title", text: $newTitle)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.cream)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                        .focused($titleFocused)
                        .onSubmit { AutoReelsStore.shared.rename(id: reel.id, to: newTitle); renaming = false }
                        .onExitCommand { renaming = false }
                        .onAppear { titleFocused = true }
                } else {
                    HStack(alignment: .top, spacing: 4) {
                        Text(reel.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
                            .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            .onTapGesture(count: 2) { newTitle = reel.title; renaming = true }
                        if isHovered {
                            Button { newTitle = reel.title; renaming = true } label: {
                                Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(Theme.muted)
                            }
                            .buttonStyle(.plain).help("Rename")
                        }
                    }
                }
                Text("\(reel.format) · \(relativeDate(reel.dateCreated))").font(.system(size: 10)).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename…") { newTitle = reel.title; renaming = true }
            Button("Show in Finder") { onFinder(reel.paths.map { URL(fileURLWithPath: $0) }) }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func formatReelDur(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }

    private func relativeDate(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let df = RelativeDateTimeFormatter(); df.unitsStyle = .short
        return df.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Reel detail sidebar

private enum ReelDetailTab: String, CaseIterable {
    case actions    = "Actions"
    case transcript = "Transcript"
}

private struct ReelDetailSidebar: View {
    let reel: AutoReelRecord
    let gold: Color
    var onPlay: (URL, [Double], Double) -> Void
    var onFinder: ([URL]) -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ReelDetailTab = .actions
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserverToken: Any?
    @State private var activeURL: URL? = nil
    @State private var activeCutPoints: [Double] = []
    @State private var showFullPreview = false

    private var primaryURL: URL { URL(fileURLWithPath: reel.path) }
    private var isMulti: Bool { reel.paths.count > 1 }

    private func formatSecs(_ s: Double) -> String {
        let i = Int(max(0, s))
        return String(format: "%d:%02d", i / 60, i % 60)
    }

    private func loadPlayer(url: URL, cutPoints: [Double] = []) {
        if let token = timeObserverToken { player?.removeTimeObserver(token); timeObserverToken = nil }
        player?.pause()
        let p = AVPlayer(url: url)
        player = p; isPlaying = false; currentTime = 0; activeURL = url; activeCutPoints = cutPoints
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero); isPlaying = false; currentTime = 0
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            currentTime = CMTimeGetSeconds(t)
            if let dur = p.currentItem?.duration, dur.isValid && !dur.isIndefinite {
                duration = max(1, CMTimeGetSeconds(dur))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video preview — uses fit (not fill) so portrait video shows without cropping
            ZStack {
                Color.black
                if let player = player {
                    FitVideoPlayerView(player: player)
                }
                // Play/pause overlay
                Color.clear.contentShape(Rectangle()).onTapGesture {
                    guard let p = player else { return }
                    if isPlaying { p.pause(); isPlaying = false }
                    else { p.play(); isPlaying = true }
                }
                if !isPlaying {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .allowsHitTesting(false)
                }
                // Top controls: close (left) + full-screen (right)
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                                .padding(6)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        Spacer()
                        Button(action: { showFullPreview = true }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                                .padding(6)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
                    Spacer()
                }
            }
            .frame(height: 220)
            .onAppear {
                loadPlayer(url: primaryURL, cutPoints: reel.cutPoints)
            }
            .onDisappear {
                if let token = timeObserverToken { player?.removeTimeObserver(token); timeObserverToken = nil }
                player?.pause(); player = nil; isPlaying = false
            }
            .sheet(isPresented: $showFullPreview) {
                ReelFullPreviewSheet(
                    url: activeURL ?? primaryURL,
                    cutPoints: activeCutPoints,
                    gold: gold
                )
            }

            // Scrubber + cut markers
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                    let progress = duration > 0 ? min(1, currentTime / duration) : 0
                    Capsule().fill(gold).frame(width: max(3, geo.size.width * progress), height: 3)
                    ForEach(Array(reel.cutPoints.enumerated()), id: \.offset) { _, frac in
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: 10)
                            .offset(x: geo.size.width * frac - 1)
                    }
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .offset(x: max(0, min(geo.size.width - 10, geo.size.width * (duration > 0 ? min(1, currentTime / duration) : 0) - 5)))
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let frac = max(0, min(1, drag.location.x / geo.size.width))
                    let t = CMTime(seconds: frac * duration, preferredTimescale: 600)
                    player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                    currentTime = frac * duration
                })
            }
            .frame(height: 14)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            HStack {
                Text(formatSecs(currentTime)).font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.4))
                Spacer()
                Text(formatSecs(duration)).font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 12).padding(.bottom, 6)

            Divider().background(Color.white.opacity(0.08))

            if isMulti {
                VStack(spacing: 0) {
                    ForEach(Array(reel.paths.enumerated()), id: \.offset) { i, path in
                        let url = URL(fileURLWithPath: path)
                        let exists = FileManager.default.fileExists(atPath: path)
                        let pts = i < reel.cutPointsPerReel.count ? reel.cutPointsPerReel[i] : reel.cutPoints
                        let isActive = activeURL?.path == path
                        Button(action: {
                            if exists { loadPlayer(url: url, cutPoints: pts) }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "film")
                                    .font(.system(size: 10))
                                    .foregroundColor(isActive ? gold : gold.opacity(0.4))
                                Text(i < reel.reelTitles.count ? reel.reelTitles[i] : "Reel \(i + 1)")
                                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                                    .foregroundColor(exists ? (isActive ? gold : .white) : Color.white.opacity(0.3))
                                    .lineLimit(1)
                                Spacer()
                                Button(action: { if exists { NSWorkspace.shared.activateFileViewerSelecting([url]) } }) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.white.opacity(0.3))
                                }
                                .buttonStyle(.plain)
                                Image(systemName: isActive && isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(exists ? gold.opacity(0.8) : Color.white.opacity(0.2))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(isActive ? gold.opacity(0.08) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < reel.paths.count - 1 {
                            Divider().background(Color.white.opacity(0.06))
                        }
                    }
                }
                .background(Color.white.opacity(0.04))
                Divider().background(Color.white.opacity(0.08))
            }

            HStack(spacing: 0) {
                ForEach(ReelDetailTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? gold : Color.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.05))
            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                if selectedTab == .actions {
                    VStack(spacing: 10) {
                        Button(action: {
                            let urls = reel.paths.map { URL(fileURLWithPath: $0) }
                                .filter { FileManager.default.fileExists(atPath: $0.path) }
                            onFinder(urls.isEmpty ? [primaryURL] : urls)
                        }) {
                            Label("Export / Show in Finder", systemImage: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(gold)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([primaryURL])
                        }) {
                            Label("Show in Finder", systemImage: "folder")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button(action: { onDelete() }) {
                            Text("Delete Reel")
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 1, green: 0.38, blue: 0.38))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if !reel.transcript.isEmpty {
                            Text(reel.transcript)
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.8))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        } else {
                            Text("Transcript not available.\nReprocess the video to generate a transcript.")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.4))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }
        }
        .id(reel.id)
        .background(Theme.surface)
    }
}

// MARK: - Fit video player (resizeAspect — shows full portrait video without cropping)

private struct FitVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.frame = view.bounds
        view.layer?.addSublayer(layer)
        context.coordinator.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.layer?.player = player
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var layer: AVPlayerLayer?
    }
}

// MARK: - Full-screen preview sheet

private struct ReelFullPreviewSheet: View {
    let url: URL
    let cutPoints: [Double]
    let gold: Color

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserverToken: Any?
    @Environment(\.dismiss) private var dismiss

    private func formatSecs(_ s: Double) -> String {
        let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)

                // Video — fit inside the window
                FitVideoPlayerView(player: player ?? AVPlayer())
                    .background(Color.black)
                    .onTapGesture {
                        guard let p = player else { return }
                        if isPlaying { p.pause(); isPlaying = false }
                        else { p.play(); isPlaying = true }
                    }
                    .overlay(
                        Group {
                            if !isPlaying {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 56))
                                    .foregroundColor(.white.opacity(0.85))
                                    .shadow(color: .black.opacity(0.5), radius: 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    )

                // Controls
                VStack(spacing: 10) {
                    // Scrubber with cut markers
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15)).frame(height: 4)
                            let progress = duration > 0 ? min(1, currentTime / duration) : 0
                            Capsule().fill(gold).frame(width: max(4, geo.size.width * progress), height: 4)
                            ForEach(Array(cutPoints.enumerated()), id: \.offset) { _, frac in
                                Rectangle().fill(Color.white).frame(width: 2, height: 14)
                                    .offset(x: geo.size.width * frac - 1)
                            }
                            Circle().fill(Color.white).frame(width: 12, height: 12)
                                .offset(x: max(0, min(geo.size.width - 12, geo.size.width * (duration > 0 ? min(1, currentTime / duration) : 0) - 6)))
                        }
                        .frame(height: 14)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            let frac = max(0, min(1, drag.location.x / geo.size.width))
                            player?.seek(to: CMTime(seconds: frac * duration, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
                            currentTime = frac * duration
                        })
                    }
                    .frame(height: 14)

                    HStack {
                        Text(formatSecs(currentTime)).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
                        Spacer()
                        HStack(spacing: 20) {
                            Button(action: { player?.seek(to: CMTime(seconds: max(0, currentTime - 5), preferredTimescale: 600)) }) {
                                Image(systemName: "gobackward.5").font(.system(size: 18)).foregroundColor(.white.opacity(0.7))
                            }.buttonStyle(.plain)
                            Button(action: {
                                guard let p = player else { return }
                                if isPlaying { p.pause(); isPlaying = false } else { p.play(); isPlaying = true }
                            }) {
                                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 36)).foregroundColor(gold)
                            }.buttonStyle(.plain)
                            Button(action: { player?.seek(to: CMTime(seconds: min(duration, currentTime + 5), preferredTimescale: 600)) }) {
                                Image(systemName: "goforward.5").font(.system(size: 18)).foregroundColor(.white.opacity(0.7))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Text(formatSecs(duration)).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 16)

                if !cutPoints.isEmpty {
                    Text("\(cutPoints.count) cut\(cutPoints.count == 1 ? "" : "s") — white marks on scrubber")
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.35))
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                object: p.currentItem, queue: .main) { _ in p.seek(to: .zero); isPlaying = false; currentTime = 0 }
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserverToken = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
                currentTime = CMTimeGetSeconds(t)
                if let dur = p.currentItem?.duration, dur.isValid && !dur.isIndefinite {
                    duration = max(1, CMTimeGetSeconds(dur))
                }
            }
            p.play(); isPlaying = true
        }
        .onDisappear {
            if let token = timeObserverToken { player?.removeTimeObserver(token) }
            player?.pause(); player = nil
        }
    }
}

// MARK: - Video thumbnail from file

struct ReelThumbnailView: View {
    let path: String
    /// Width ÷ height of the frame it fills. When set, the picture is cropped to that shape
    /// around the speaker's face, so a wide video in a tall card still shows the person.
    var faceAspect: CGFloat? = nil
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Theme.surface)
                    .overlay(
                        Image(systemName: "film")
                            .font(.system(size: 32))
                            .foregroundColor(Color.white.opacity(0.12))
                    )
            }
        }
        .task(id: path + "\(faceAspect ?? 0)") { await loadThumbnail() }
    }

    /// Pictures already made, shared by every card, sidebar row and banner
    private static let cache = NSCache<NSString, NSImage>()

    private func loadThumbnail() async {
        let key = (path + "|\(faceAspect ?? 0)") as NSString
        if let hit = Self.cache.object(forKey: key) { image = hit; return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 960)
        // Long videos (sermons, episodes) open on black or a title; pick a moment further in
        let dur = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let first = dur > 60 ? dur * 0.12 : min(1.5, dur / 2)
        // When framing a person, look a little further if the first moment has no face
        let moments = faceAspect == nil || dur <= 60 ? [first] : [first, dur * 0.3, dur * 0.5]
        var chosen: CGImage?
        for m in moments {
            guard let cg = try? await gen.image(at: CMTime(seconds: m, preferredTimescale: 600)).image else { continue }
            if chosen == nil { chosen = cg }
            if let aspect = faceAspect, let framed = Self.frame(cg, aspect: aspect) { chosen = framed; break }
            if faceAspect == nil { break }
        }
        guard var cg = chosen else { return }
        // No face anywhere: still crop to the shape, from the middle
        if let aspect = faceAspect, abs(CGFloat(cg.width) / CGFloat(cg.height) - aspect) > 0.02 {
            cg = Self.crop(cg, aspect: aspect, centerX: 0.5, centerY: 0.5) ?? cg
        }
        let ns = NSImage(cgImage: cg, size: .zero)
        Self.cache.setObject(ns, forKey: key)
        await MainActor.run { image = ns }
    }

    /// Crops to `aspect` around the biggest face, with the face a little above the middle.
    private static func frame(_ img: CGImage, aspect: CGFloat) -> CGImage? {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        guard let face = (req.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let b = face.boundingBox                     // 0…1, origin bottom-left
        return crop(img, aspect: aspect, centerX: b.midX, centerY: 1 - b.midY + 0.12)
    }

    private static func crop(_ img: CGImage, aspect: CGFloat, centerX: CGFloat, centerY: CGFloat) -> CGImage? {
        let W = CGFloat(img.width), H = CGFloat(img.height)
        var w = W, h = W / aspect
        if h > H { h = H; w = H * aspect }
        let x = max(0, min(W - w, centerX * W - w / 2))
        let y = max(0, min(H - h, centerY * H - h / 2))
        return img.cropping(to: CGRect(x: x, y: y, width: w, height: h).integral)
    }
}

// Dummy extension container so the next section compiles
private extension AutoReelsTab {

    // MARK: - Preview panel

    func previewPanel(url: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(gold).font(.system(size: 13))
                    Text("Reel preview").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                        Label("Finder", systemImage: "folder")
                            .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.white.opacity(0.08)).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    Button(action: { closePreview() }) {
                        Image(systemName: "xmark").font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.5))
                            .padding(6).background(Color.white.opacity(0.08)).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.surface)

            Divider().background(Color.white.opacity(0.08))

            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Spacer()
                    ZStack {
                        Color.black
                        if let player = previewPlayer {
                            VideoPlayerView(player: player, captionStyle: CaptionStyle.all[0],
                                            currentWord: nil, showCaptionBg: false,
                                            captionBgOpacity: 0, captionBgColor: .black)
                        }
                        if !previewPlaying {
                            Image(systemName: "play.circle.fill").font(.system(size: 44))
                                .foregroundColor(.white.opacity(0.85)).shadow(color: .black.opacity(0.5), radius: 8)
                        }
                        Color.clear.contentShape(Rectangle()).onTapGesture {
                            guard let player = previewPlayer else { return }
                            if previewPlaying { player.pause() } else { player.play() }
                            previewPlaying.toggle()
                        }
                    }
                    .frame(width: 280, height: 498)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.5), radius: 16)
                    Spacer()
                }
                Spacer()

                VStack(spacing: 6) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.12))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(gold)
                                .frame(width: max(0, CGFloat(previewProgress) * w), height: 4)
                                .animation(isScrubbing ? nil : .linear(duration: 0.1), value: previewProgress)
                            ForEach(previewCutPoints, id: \.self) { cut in
                                Rectangle()
                                    .fill(gold.opacity(0.85))
                                    .frame(width: 2, height: 10)
                                    .offset(x: CGFloat(cut) * w - 1, y: -3)
                            }
                            Circle()
                                .fill(gold)
                                .frame(width: 14, height: 14)
                                .offset(x: max(0, CGFloat(previewProgress) * w - 7), y: -5)
                                .animation(isScrubbing ? nil : .linear(duration: 0.1), value: previewProgress)
                        }
                        .frame(height: 4)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle().size(CGSize(width: w, height: 24)))
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                isScrubbing = true
                                let f = max(0, min(1, v.location.x / w))
                                previewProgress = f
                                previewPlayer?.seek(to: CMTime(seconds: f * previewDuration, preferredTimescale: 600),
                                                    toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                            .onEnded { _ in isScrubbing = false })
                    }
                    .frame(height: 24)

                    HStack {
                        Text(formatDur(previewProgress * previewDuration))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
                        Spacer()
                        Button(action: {
                            guard let player = previewPlayer else { return }
                            if previewPlaying { player.pause() } else { player.play() }
                            previewPlaying.toggle()
                        }) {
                            Image(systemName: previewPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14)).foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(formatDur(previewDuration))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
            .background(Color(red: 0.08, green: 0.09, blue: 0.12))
            .onAppear {
                let player = AVPlayer(url: url)
                previewPlayer = player; player.play(); previewPlaying = true
                Task {
                    if let item = player.currentItem,
                       let dur = try? await item.asset.load(.duration) {
                        previewDuration = max(1, CMTimeGetSeconds(dur))
                    }
                }
                let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
                previewTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
                    guard !isScrubbing else { return }
                    let s = CMTimeGetSeconds(t)
                    previewProgress = previewDuration > 0 ? s / previewDuration : 0
                }
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
                ) { _ in player.seek(to: .zero); player.play() }
            }
            .onDisappear {
                if let obs = previewTimeObserver { previewPlayer?.removeTimeObserver(obs) }
                previewTimeObserver = nil
                previewPlayer?.pause(); previewPlayer = nil
                previewProgress = 0; previewDuration = 1
            }
        }
    }

    // MARK: - YouTube download

    /// Downloads run as a regular job in AutoReelsStore (not view state), so progress stays
    /// visible and the work keeps going when you switch to Projects / Auto Clips and back.
    private func startYouTubeDownload() {
        let rawURL = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return }
        guard let ytdlp = ytDlpPath() else {
            downloadError = "yt-dlp not found.\n\nInstall with: brew install yt-dlp"
            return
        }
        downloadError = nil
        let outDir = Self.defaultOutputDir  // folder is chosen when a reel is exported

        let fmt = selectedFormat; let captions = burnCaptions
        let styleIdx = captionStyleIndex; let dur = targetDuration
        let ai = useAI; let prov = aiProvider
        let key = apiKeys[aiProvider] ?? ""; let reelCnt = desiredReelCount
        let sMode = useStoryline && !singleClip ? storylineMode : nil
        let topic = topicText; let dissolve = crossDissolve; let emojis = emojiOverlays
        let single = singleClip
        let store = self.store

        let jobID = UUID()
        func report(_ progress: Double, _ msg: String, error: String? = nil) {
            Task { @MainActor in
                store.updateJob(AutoReelJob(id: jobID, title: "YouTube video", progress: progress,
                                            statusMsg: msg, isFinished: error != nil, error: error))
            }
        }
        report(0, "Starting download…")

        let task = Task.detached(priority: .userInitiated) {
            let videosDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/AutoClip/Videos")
            try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
            let outTemplate = videosDir.appendingPathComponent("%(title)s.%(ext)s").path

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ytdlp)
            process.arguments = YTDLP.arguments(url: rawURL, outTemplate: outTemplate)
            process.environment = YTDLP.environment
            process.currentDirectoryURL = videosDir

            let outPipe = Pipe(); let errPipe = Pipe()
            process.standardOutput = outPipe; process.standardError = errPipe
            var stderrBuf = ""

            errPipe.fileHandleForReading.readabilityHandler = { h in
                guard let line = String(data: h.availableData, encoding: .utf8), !line.isEmpty else { return }
                stderrBuf += line
                if line.contains("%"),
                   let n = line.split(separator: "%").first?.split(separator: " ").compactMap({ Double($0) }).last {
                    // Download is the first 10% of the job; the pipeline takes it from there
                    report(min(0.1, n / 1000.0), "Downloading video: \(Int(n))%")
                } else if line.contains("Merger") {
                    report(0.1, "Combining video and audio…")
                }
            }

            do {
                try await withTaskCancellationHandler {
                    try process.run(); process.waitUntilExit()
                } onCancel: { process.terminate() }
                errPipe.fileHandleForReading.readabilityHandler = nil
                if Task.isCancelled { return }

                guard process.terminationStatus == 0 else {
                    let detail = stderrBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                    report(0, "Download failed", error: detail.isEmpty ? "Download failed (exit \(process.terminationStatus))" : String(detail.suffix(250)))
                    return
                }

                let printed = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !printed.isEmpty, FileManager.default.fileExists(atPath: printed),
                      !YTDLP.isPartialStream(URL(fileURLWithPath: printed)) else {
                    report(0, "Download failed", error: "Download finished but the video and audio couldn't be combined. Make sure ffmpeg is installed (brew install ffmpeg).")
                    return
                }
                let videoURL = URL(fileURLWithPath: printed)

                var ytParams = AutoReelJobParams(videoURL: videoURL, formatRaw: fmt.rawValue,
                    captions: captions, captionStyleIndex: styleIdx, targetDuration: dur,
                    useAI: ai, providerRaw: prov.rawValue, desiredReelCount: reelCnt,
                    storylineModeRaw: sMode?.rawValue, topic: topic, crossDissolve: dissolve,
                    emojiOverlays: emojis, outputDir: outDir, singleClip: single)
                // The file is saved as "%(title)s.ext", so its name is the YouTube title
                ytParams.sourceTitle = YTDLP.title(fromFile: videoURL)
                await self.startPipelineAsync(jobID: jobID, videoURL: videoURL, format: fmt, captions: captions,
                                              styleIdx: styleIdx, targetDur: dur,
                                              useAI: ai, provider: prov, apiKey: key,
                                              desiredReelCount: reelCnt,
                                              storylineMode: sMode, topic: topic,
                                              crossDissolve: dissolve, emojiOverlays: emojis,
                                              outputDir: outDir, retryParams: ytParams)
            } catch {
                report(0, "Download failed", error: error.localizedDescription)
            }
        }
        store.registerTask(task, for: jobID)
        youtubeURL = ""
    }

    // MARK: - Save location picker

    static var defaultOutputDir: URL {
        if let last = UserDefaults.standard.string(forKey: "ar_lastOutputDir"),
           FileManager.default.fileExists(atPath: last) { return URL(fileURLWithPath: last) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }


    // MARK: - Reel pipeline

    private func startPipeline(videoURL: URL) {
        let outDir = Self.defaultOutputDir  // folder is chosen when a reel is exported
        let fmt = selectedFormat; let captions = burnCaptions
        let styleIdx = captionStyleIndex; let dur = targetDuration
        let ai = useAI; let prov = aiProvider
        let key = apiKeys[aiProvider] ?? ""; let reelCnt = desiredReelCount
        let sMode = useStoryline && !singleClip ? storylineMode : nil
        let topic = topicText; let dissolve = crossDissolve; let emojis = emojiOverlays
        let single = singleClip
        let params = AutoReelJobParams(videoURL: videoURL, formatRaw: fmt.rawValue,
                                       captions: captions, captionStyleIndex: styleIdx,
                                       targetDuration: dur, useAI: ai, providerRaw: prov.rawValue,
                                       desiredReelCount: reelCnt, storylineModeRaw: sMode?.rawValue,
                                       topic: topic, crossDissolve: dissolve,
                                       emojiOverlays: emojis, outputDir: outDir, singleClip: single)
        let jobID = UUID()
        let task = Task.detached(priority: .userInitiated) {
            await self.startPipelineAsync(jobID: jobID, videoURL: videoURL, format: fmt,
                                          captions: captions, styleIdx: styleIdx, targetDur: dur,
                                          useAI: ai, provider: prov, apiKey: key,
                                          desiredReelCount: reelCnt,
                                          storylineMode: sMode, topic: topic,
                                          crossDissolve: dissolve, emojiOverlays: emojis,
                                          outputDir: outDir, retryParams: params)
        }
        store.registerTask(task, for: jobID)
    }

    private func retryJob(params: AutoReelJobParams, oldJobID: UUID) {
        let outDir = Self.defaultOutputDir  // folder is chosen when a reel is exported
        store.clearJob(id: oldJobID)
        let fmt = VideoExportService.ExportFormat(rawValue: params.formatRaw) ?? .vertical9x16
        let prov = LLMClipService.AIProvider(rawValue: params.providerRaw) ?? .anthropic
        let apiKey = apiKeys[prov] ?? ""
        let sMode = params.storylineModeRaw.flatMap { StorylineMode(rawValue: $0) }
        var newParams = params; newParams.outputDir = outDir
        // Jobs from before 2.60 may point at an unmerged video-only part ("Title.f299.mp4");
        // use the combined file instead when it exists.
        if YTDLP.isPartialStream(params.videoURL) {
            let base = params.videoURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: #"\.f\d+(-\d+)?$"#, with: "", options: .regularExpression)
            let merged = params.videoURL.deletingLastPathComponent().appendingPathComponent(base + ".mp4")
            if FileManager.default.fileExists(atPath: merged.path) { newParams.videoURL = merged }
        }
        let jobID = UUID()
        let task = Task.detached(priority: .userInitiated) {
            await self.startPipelineAsync(jobID: jobID, videoURL: newParams.videoURL, format: fmt,
                                          captions: params.captions, styleIdx: params.captionStyleIndex,
                                          targetDur: params.targetDuration,
                                          useAI: params.useAI, provider: prov, apiKey: apiKey,
                                          desiredReelCount: params.desiredReelCount,
                                          storylineMode: sMode, topic: params.topic,
                                          crossDissolve: params.crossDissolve,
                                          emojiOverlays: params.emojiOverlays,
                                          outputDir: outDir, retryParams: newParams)
        }
        store.registerTask(task, for: jobID)
    }

    private func startPipelineAsync(jobID: UUID = UUID(),
                                    videoURL: URL, format: VideoExportService.ExportFormat,
                                    captions: Bool, styleIdx: Int, targetDur: Double,
                                    useAI: Bool = false,
                                    provider: LLMClipService.AIProvider = .anthropic,
                                    apiKey: String = "",
                                    desiredReelCount: Int = 0,
                                    storylineMode: StorylineMode? = nil,
                                    topic: String = "",
                                    crossDissolve: Bool = true,
                                    emojiOverlays: Bool = false,
                                    outputDir: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!,
                                    retryParams: AutoReelJobParams? = nil) async {
        await ReelPipeline.run(jobID: jobID, videoURL: videoURL, format: format, captions: captions,
                               styleIdx: styleIdx, targetDur: targetDur, useAI: useAI, provider: provider,
                               apiKey: apiKey, desiredReelCount: desiredReelCount, storylineMode: storylineMode,
                               topic: topic, crossDissolve: crossDissolve, emojiOverlays: emojiOverlays,
                               outputDir: outputDir, retryParams: retryParams)
    }

    // MARK: - Helpers

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.begin { if $0 == .OK, let url = panel.url { pickedVideoURL = url } }
    }

    private func showPreview(url: URL, id: UUID, cutPoints: [Double] = [], reelDuration: Double = 0) {
        previewURL = url; showingPreviewFor = id
        previewCutPoints = cutPoints
    }

    private func closePreview() {
        previewPlayer?.pause(); previewPlayer = nil
        previewURL = nil; showingPreviewFor = nil
        previewCutPoints = []
    }

    private func ytDlpPath() -> String? {
        if let b = Bundle.main.path(forResource: "yt-dlp", ofType: nil),
           FileManager.default.fileExists(atPath: b) { return b }
        let execDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent().path
        let sibling = execDir + "/../Resources/yt-dlp"
        if FileManager.default.fileExists(atPath: sibling) { return sibling }
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/opt/homebrew/opt/yt-dlp/bin/yt-dlp"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        let w = Process(); w.executableURL = URL(fileURLWithPath: "/usr/bin/which"); w.arguments = ["yt-dlp"]
        let p = Pipe(); w.standardOutput = p; w.standardError = Pipe()
        try? w.run(); w.waitUntilExit()
        let out = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private func fmtLabel(_ f: VideoExportService.ExportFormat) -> String {
        switch f {
        case .vertical9x16: return "9:16"
        case .square1x1:    return "1:1"
        case .portrait4x5:  return "4:5"
        case .original:     return "Original"
        case .horizontal16x9: return "16:9"
        }
    }

    private func formatDur(_ s: Double) -> String {
        let t = Int(s)
        return t >= 60 ? "\(t / 60)m \(t % 60)s" : "\(t)s"
    }
}
