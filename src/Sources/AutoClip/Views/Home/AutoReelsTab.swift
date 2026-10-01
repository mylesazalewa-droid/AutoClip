import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Persistent record

struct AutoReelRecord: Identifiable, Codable {
    var id: UUID
    var title: String
    var path: String          // primary file (first reel / single reel)
    var paths: [String]       // all files (for multiple reels)
    var format: String
    var duration: Double
    var clipCount: Int
    var dateCreated: Double
    var cutPoints: [Double]   // fractional [0,1] cut positions for scrubber

    init(id: UUID, title: String, path: String, paths: [String] = [],
         format: String, duration: Double, clipCount: Int, dateCreated: Double,
         cutPoints: [Double] = []) {
        self.id = id; self.title = title; self.path = path
        self.paths = paths.isEmpty ? [path] : paths
        self.format = format; self.duration = duration
        self.clipCount = clipCount; self.dateCreated = dateCreated
        self.cutPoints = cutPoints
    }
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

    init(id: UUID, title: String, progress: Double, statusMsg: String,
         isFinished: Bool, error: String? = nil, outputURL: URL? = nil,
         outputURLs: [URL]? = nil, cutPoints: [Double] = [], reelDuration: Double = 0,
         pendingClips: [Clip]? = nil) {
        self.id = id; self.title = title; self.progress = progress
        self.statusMsg = statusMsg; self.isFinished = isFinished
        self.error = error; self.outputURL = outputURL; self.outputURLs = outputURLs
        self.cutPoints = cutPoints; self.reelDuration = reelDuration
        self.pendingClips = pendingClips
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
            // Interleave high-score and low-score clips
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
            // Best clip first, rest in chronological order
            var s = clips.sorted { $0.score > $1.score }
            let top = s.removeFirst()
            return [top] + s.sorted { $0.startTime < $1.startTime }
        case .random:
            return clips.shuffled()
        case .hero:
            // Chronological but with the highest-score clip placed in the middle
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
    @Published var activeJob: AutoReelJob?

    private let key = "autoReelsHistory"
    private var exportContinuation: CheckedContinuation<Bool, Never>?

    init() { load() }

    func add(_ reel: AutoReelRecord) {
        reels.insert(reel, at: 0)
        save()
    }

    func updateJob(_ job: AutoReelJob) { activeJob = job }
    func clearJob() { activeJob = nil }

    func setPendingExport(clips: [Clip], jobID: UUID, jobTitle: String) async -> Bool {
        if var job = activeJob, job.id == jobID {
            job.pendingClips = clips
            job.statusMsg = "\(clips.count) clips selected — ready to export"
            job.progress = 0.48
            activeJob = job
        }
        return await withCheckedContinuation { cont in
            exportContinuation = cont
        }
    }

    func confirmExport() {
        exportContinuation?.resume(returning: true)
        exportContinuation = nil
    }

    func cancelExport() {
        exportContinuation?.resume(returning: false)
        exportContinuation = nil
        activeJob = nil
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
    }
}

// MARK: - Main View

struct AutoReelsTab: View {
    @ObservedObject private var store = AutoReelsStore.shared
    @State private var isDropTargeted = false
    @State private var pickedVideoURL: URL?
    @State private var inputMode: InputMode = .file   // file | youtube
    @State private var youtubeURL = ""
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus = ""
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

    // Settings
    @State private var selectedFormat: VideoExportService.ExportFormat = .vertical9x16
    @State private var burnCaptions = true
    @State private var captionStyleIndex = 0
    @State private var targetDuration: Double = 90

    // AI-powered selection
    @State private var useAI = false
    @State private var aiProvider: LLMClipService.AIProvider = .anthropic
    @State private var apiKeys: [LLMClipService.AIProvider: String] = [:]
    @State private var showKey = false

    // Export mode
    @State private var exportMode: ExportMode = .reel
    @State private var numberOfReels: Double = 2
    @State private var storylineMode: StorylineMode = .linear

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)
    private let captionStyles = CaptionStyle.all

    enum InputMode { case file, youtube }

    var body: some View {
        HStack(spacing: 0) {
            leftPanel.frame(width: 320)
            Divider().background(Color.white.opacity(0.08))
            rightPanel
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
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
    }

    // MARK: - Left panel

    var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inputSection
                if pickedVideoURL != nil || (inputMode == .youtube && !youtubeURL.isEmpty) {
                    settingsSection
                    createButton
                }
            }
            .padding(20)
        }
    }

    // MARK: - Input section (file drop OR youtube)

    var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Mode toggle
            HStack(spacing: 0) {
                modeToggleButton("Video File", mode: .file)
                modeToggleButton("YouTube", mode: .youtube)
            }
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)

            if inputMode == .file {
                fileDropZone
            } else {
                youtubeInputField
            }
        }
    }

    func modeToggleButton(_ label: String, mode: InputMode) -> some View {
        Button(action: { inputMode = mode; downloadError = nil }) {
            Text(label)
                .font(.system(size: 12, weight: inputMode == mode ? .semibold : .regular))
                .foregroundColor(inputMode == mode ? .black : Color.white.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(inputMode == mode ? gold : Color.clear)
                .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    var fileDropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted
                    ? gold.opacity(0.08)
                    : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isDropTargeted ? gold : Color.white.opacity(0.12),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )

            VStack(spacing: 10) {
                if let url = pickedVideoURL {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24)).foregroundColor(gold)
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                        .lineLimit(2).multilineTextAlignment(.center)
                    Button("Change") { pickedVideoURL = nil }
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                        .buttonStyle(.plain)
                } else {
                    Image(systemName: "film").font(.system(size: 28)).foregroundColor(gold.opacity(0.6))
                    Text("Drop a video").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Button(action: pickVideo) {
                        Text("Browse files")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(gold)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(gold.opacity(0.12)).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .frame(height: 140)
        .onDrop(of: [.movie, .fileURL], isTargeted: $isDropTargeted) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { pickedVideoURL = url }
                }
            }
            return true
        }
    }

    var youtubeInputField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
                TextField("https://youtube.com/watch?v=...", text: $youtubeURL)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                    .disabled(isDownloading)
            }
            .padding(10)
            .background(Color.white.opacity(0.07))
            .cornerRadius(8)

            if isDownloading {
                VStack(spacing: 6) {
                    HStack {
                        Text(downloadStatus)
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(gold)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1)).frame(height: 3)
                            RoundedRectangle(cornerRadius: 2).fill(gold)
                                .frame(width: geo.size.width * max(0.03, downloadProgress), height: 3)
                                .animation(.easeOut(duration: 0.3), value: downloadProgress)
                        }
                    }
                    .frame(height: 3)
                }
            }

            if let err = downloadError {
                Text(err)
                    .font(.system(size: 11)).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = pickedVideoURL, inputMode == .youtube {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(gold).font(.system(size: 11))
                    Text(url.lastPathComponent).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Settings

    var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SETTINGS")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35))

            VStack(spacing: 10) {
                // Format
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
                HStack {
                    Text("Target length").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    Spacer()
                    Text(formatDur(targetDuration)).font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
                }
                Slider(value: $targetDuration, in: 30...300, step: 10).tint(gold)
                HStack {
                    Text("Captions").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    Spacer()
                    Toggle("", isOn: $burnCaptions).toggleStyle(.switch).tint(gold)
                }
                if burnCaptions && !captionStyles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(captionStyles.indices, id: \.self) { i in
                                Button(action: { captionStyleIndex = i }) {
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
                }
            }
            .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)

            // Export mode
            exportModeSection

            // Storyline structure
            storylineSection

            // AI-powered clip selection
            aiSettingsSection
        }
    }

    private var exportModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export as")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)

            // Three-button row — wrap to avoid clipping
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    modeButton(.reel,          icon: "film.stack")
                    modeButton(.multipleReels, icon: "rectangle.stack.fill")
                }
                HStack(spacing: 6) {
                    modeButton(.individualClips, icon: "square.stack.3d.up.fill")
                    Spacer()
                }
            }

            // Description
            Group {
                switch exportMode {
                case .reel:
                    Text("All clips are stitched together into one highlight reel.")
                case .multipleReels:
                    Text("Creates several distinct reels, each with a unique mix of the best moments.")
                case .individualClips:
                    Text("Each clip is saved as its own separate video file.")
                }
            }
            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)

            // Number of reels slider — only shown for multiple reels
            if exportMode == .multipleReels {
                HStack {
                    Text("Number of reels").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(numberOfReels))").font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
                }
                Slider(value: $numberOfReels, in: 2...4, step: 1).tint(gold)
            }
        }
        .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)
    }

    private func modeButton(_ mode: ExportMode, icon: String) -> some View {
        Button(action: { exportMode = mode }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(mode.rawValue).font(.system(size: 11, weight: exportMode == mode ? .semibold : .regular))
            }
            .foregroundColor(exportMode == mode ? .black : Color.white.opacity(0.6))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(exportMode == mode ? gold : Color.white.opacity(0.07))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    private var storylineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack").foregroundColor(gold).font(.system(size: 12))
                Text("Storyline").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            }
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
        .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)
    }

    private var aiSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(gold).font(.system(size: 12))
                Text("Smart AI Selection")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $useAI).toggleStyle(.switch).tint(gold)
            }

            if useAI {
                Text("AI understands context, complete thoughts, and emotional tone — not just sentence length.")
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                // Provider picker
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
                }

                // API key for selected provider
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

    // MARK: - Create button

    var createButton: some View {
        Group {
            if inputMode == .youtube && pickedVideoURL == nil {
                // YouTube: download first, then pipeline starts automatically
                Button(action: startYouTubeDownload) {
                    HStack(spacing: 8) {
                        if isDownloading {
                            ProgressView().scaleEffect(0.75).tint(.black)
                        } else {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold))
                        }
                        Text(isDownloading ? "Downloading…" : "Download & Create Reel")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(youtubeURL.isEmpty || isDownloading ? gold.opacity(0.4) : gold)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(youtubeURL.isEmpty || isDownloading)
            } else {
                Button(action: { startPipeline(videoURL: pickedVideoURL!) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").font(.system(size: 14, weight: .semibold))
                        Text("Create Auto Reel").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(gold).cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(store.activeJob != nil)
            }
        }
    }

    // MARK: - Right panel

    var rightPanel: some View {
        ZStack {
            if let url = previewURL, showingPreviewFor != nil {
                previewPanel(url: url)
            } else {
                historyPanel
            }
        }
    }

    var historyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Active job card
            if let job = store.activeJob {
                activeJobCard(job)
                Divider().background(Color.white.opacity(0.08))
            }

            if store.reels.isEmpty && store.activeJob == nil {
                emptyPanel
            } else if !store.reels.isEmpty {
                Text("PREVIOUS REELS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.35))
                    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.reels) { reel in reelRow(reel) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func activeJobCard(_ job: AutoReelJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    if job.isFinished && job.error == nil {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(gold).font(.system(size: 13))
                    } else if job.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 13))
                    } else {
                        ProgressView().scaleEffect(0.65).tint(gold)
                    }
                    Text(job.isFinished
                         ? (job.error != nil ? "Failed"
                            : job.outputURLs != nil ? "\((job.outputURLs?.count ?? 0)) files ready"
                            : "Reel ready")
                         : "Creating reel…")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                }
                Spacer()
                if job.isFinished {
                    Button(action: { store.clearJob() }) {
                        Image(systemName: "xmark").font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(job.error ?? job.statusMsg)
                .font(.system(size: 11))
                .foregroundColor(job.error != nil ? Color(red: 1, green: 0.45, blue: 0.45) : Color.white.opacity(0.5))
                .lineLimit(2)

            if !job.isFinished {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 3).fill(gold)
                            .frame(width: geo.size.width * job.progress, height: 4)
                            .animation(.easeOut(duration: 0.3), value: job.progress)
                    }
                }
                .frame(height: 4)
            }

            // Pending export confirmation
            if let clips = job.pendingClips {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected \(clips.count) clips · \(formatDur(clips.reduce(0) { $0 + $1.duration })) total")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(gold)

                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(Array(clips.enumerated()), id: \.offset) { i, clip in
                                HStack(spacing: 8) {
                                    Text("\(i + 1)").font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color.white.opacity(0.4)).frame(width: 16, alignment: .trailing)
                                    Text(clip.words.prefix(6).map { $0.word }.joined(separator: " "))
                                        .font(.system(size: 11)).foregroundColor(.white).lineLimit(1)
                                    Spacer()
                                    Text(formatDur(clip.duration))
                                        .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.45))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.04)).cornerRadius(5)
                            }
                        }
                    }
                    .frame(maxHeight: 140)

                    HStack(spacing: 8) {
                        Button(action: { store.cancelExport() }) {
                            Text("Cancel").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Color.white.opacity(0.08)).cornerRadius(7)
                        }.buttonStyle(.plain)
                        Button(action: { store.confirmExport() }) {
                            Text("Export Reel").font(.system(size: 12, weight: .semibold)).foregroundColor(.black)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(gold).cornerRadius(7)
                        }.buttonStyle(.plain)
                    }
                }
            }

            if job.isFinished, job.error == nil {
                if let urls = job.outputURLs, urls.count > 1 {
                    // Individual clips — show a scrollable list
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
                                            .font(.system(size: 11)).foregroundColor(.white)
                                            .lineLimit(1)
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
        .padding(16)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .padding(.horizontal, 16).padding(.top, 16)
    }

    func reelRow(_ reel: AutoReelRecord) -> some View {
        let isMulti = reel.paths.count > 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)).frame(width: 50, height: 50)
                    Image(systemName: isMulti ? "rectangle.stack.fill" : "play.rectangle.fill")
                        .font(.system(size: 18)).foregroundColor(gold.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(reel.title).font(.system(size: 13, weight: .medium)).foregroundColor(.white).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(reel.format).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                        Text("·").foregroundColor(Color.white.opacity(0.2))
                        Text(formatDur(reel.duration)).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    Button(action: {
                        let urls = reel.paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                    }) {
                        Image(systemName: "folder").font(.system(size: 13)).foregroundColor(Color.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help(isMulti ? "Show all reels in Finder" : "Show in Finder")

                    Button(action: { showPreview(url: URL(fileURLWithPath: reel.path), id: reel.id, cutPoints: reel.cutPoints, reelDuration: reel.duration) }) {
                        Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundColor(gold.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    Button(action: { store.remove(id: reel.id) }) {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                    .help("Remove from history")
                }
            }
            // Sub-list for multiple reels
            if isMulti {
                VStack(spacing: 3) {
                    ForEach(Array(reel.paths.enumerated()), id: \.offset) { i, path in
                        let url = URL(fileURLWithPath: path)
                        HStack(spacing: 8) {
                            Text("Reel \(i + 1)")
                                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                            Spacer()
                            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                                Image(systemName: "folder").font(.system(size: 11))
                                    .foregroundColor(Color.white.opacity(0.25))
                            }.buttonStyle(.plain)
                            Button(action: { showPreview(url: url, id: reel.id) }) {
                                Image(systemName: "play.circle.fill").font(.system(size: 14))
                                    .foregroundColor(gold.opacity(0.6))
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.03)).cornerRadius(5)
                    }
                }
                .padding(.top, 6).padding(.leading, 62)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { showPreview(url: URL(fileURLWithPath: reel.path), id: reel.id) }
    }

    var emptyPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 48)).foregroundColor(Color.white.opacity(0.1))
            Text("Your reels will appear here")
                .font(.system(size: 14)).foregroundColor(Color.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
            .background(Color(red: 0.09, green: 0.10, blue: 0.14))

            Divider().background(Color.white.opacity(0.08))

            VStack(spacing: 0) {
                // Video — centred 9:16
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

                // Scrubber bar
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
                            // Cut-point tick marks
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
                // Load duration
                Task {
                    if let item = player.currentItem,
                       let dur = try? await item.asset.load(.duration) {
                        previewDuration = max(1, CMTimeGetSeconds(dur))
                    }
                }
                // Periodic time observer
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

    private func startYouTubeDownload() {
        let rawURL = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return }
        guard let ytdlp = ytDlpPath() else {
            downloadError = "yt-dlp not found.\n\nInstall with: brew install yt-dlp"
            return
        }
        downloadError = nil
        isDownloading = true
        downloadProgress = 0
        downloadStatus = "Starting download…"

        guard let outDir = pickOutputDirectory() else { return }

        let fmt = selectedFormat; let captions = burnCaptions
        let styleIdx = captionStyleIndex; let dur = targetDuration
        let ai = useAI; let prov = aiProvider
        let key = apiKeys[aiProvider] ?? ""; let mode = exportMode
        let numReels = Int(numberOfReels); let sMode = storylineMode

        Task.detached(priority: .userInitiated) {
            let videosDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/AutoClip/Videos")
            try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
            let outTemplate = videosDir.appendingPathComponent("%(title)s.%(ext)s").path

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ytdlp)
            process.arguments = [
                "--extractor-args", "youtube:player_client=tv_embedded,web,android",
                "--format", "bestvideo[ext=mp4][vcodec^=avc1][height>=1080]+bestaudio[ext=m4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/bestvideo+bestaudio/best",
                "--merge-output-format", "mp4",
                "--concurrent-fragments", "4",
                "--output", outTemplate,
                "--print", "after_move:filepath",
                "--no-playlist", "--no-warnings",
                rawURL
            ]
            process.currentDirectoryURL = videosDir

            let outPipe = Pipe(); let errPipe = Pipe()
            process.standardOutput = outPipe; process.standardError = errPipe
            var stderrBuf = ""

            errPipe.fileHandleForReading.readabilityHandler = { h in
                guard let line = String(data: h.availableData, encoding: .utf8), !line.isEmpty else { return }
                stderrBuf += line
                if line.contains("%") {
                    let parts = line.split(separator: "%")
                    if let n = parts.first?.split(separator: " ").compactMap({ Double($0) }).last {
                        Task { @MainActor in self.downloadProgress = n / 100.0 }
                    }
                }
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { Task { @MainActor in self.downloadStatus = String(t.prefix(80)) } }
            }

            do {
                try process.run(); process.waitUntilExit()
                errPipe.fileHandleForReading.readabilityHandler = nil

                guard process.terminationStatus == 0 else {
                    let detail = stderrBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadError = detail.isEmpty ? "Download failed (exit \(process.terminationStatus))" : String(detail.suffix(250))
                    }
                    return
                }

                let printed = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var fileURL: URL?
                if !printed.isEmpty && FileManager.default.fileExists(atPath: printed) {
                    fileURL = URL(fileURLWithPath: printed)
                } else {
                    let files = (try? FileManager.default.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
                    fileURL = files.filter { $0.pathExtension.lowercased() == "mp4" }
                        .sorted { (try? $0.resourceValues(forKeys:[.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast > (try? $1.resourceValues(forKeys:[.creationDateKey]).creationDate ?? .distantPast) ?? .distantPast }
                        .first
                }

                guard let videoURL = fileURL else {
                    await MainActor.run { self.isDownloading = false; self.downloadError = "Download succeeded but file not found." }
                    return
                }

                await MainActor.run {
                    self.isDownloading = false
                    self.pickedVideoURL = videoURL
                }
                // Auto-start pipeline
                await self.startPipelineAsync(videoURL: videoURL, format: fmt, captions: captions,
                                              styleIdx: styleIdx, targetDur: dur,
                                              useAI: ai, provider: prov, apiKey: key,
                                              exportMode: mode, numberOfReels: numReels,
                                              storylineMode: sMode, outputDir: outDir)
            } catch {
                await MainActor.run { self.isDownloading = false; self.downloadError = error.localizedDescription }
            }
        }
    }

    // MARK: - Save location picker

    @MainActor
    private func pickOutputDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save your clips"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Reel pipeline

    private func startPipeline(videoURL: URL) {
        guard let outDir = pickOutputDirectory() else { return }
        let fmt = selectedFormat; let captions = burnCaptions
        let styleIdx = captionStyleIndex; let dur = targetDuration
        let ai = useAI; let prov = aiProvider
        let key = apiKeys[aiProvider] ?? ""; let mode = exportMode
        let numReels = Int(numberOfReels); let sMode = storylineMode
        Task.detached(priority: .userInitiated) {
            await self.startPipelineAsync(videoURL: videoURL, format: fmt, captions: captions,
                                          styleIdx: styleIdx, targetDur: dur,
                                          useAI: ai, provider: prov, apiKey: key,
                                          exportMode: mode, numberOfReels: numReels,
                                          storylineMode: sMode, outputDir: outDir)
        }
    }

    // Runs fully in background — safe to switch tabs while this executes
    private func startPipelineAsync(videoURL: URL, format: VideoExportService.ExportFormat,
                                    captions: Bool, styleIdx: Int, targetDur: Double,
                                    useAI: Bool = false,
                                    provider: LLMClipService.AIProvider = .anthropic,
                                    apiKey: String = "",
                                    exportMode: ExportMode = .reel, numberOfReels: Int = 2,
                                    storylineMode: StorylineMode = .linear,
                                    outputDir: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!) async {
        let jobID = UUID()
        let title = videoURL.deletingPathExtension().lastPathComponent

        func upd(_ progress: Double, _ msg: String, finished: Bool = false, error: String? = nil, out: URL? = nil) async {
            await MainActor.run {
                store.updateJob(AutoReelJob(id: jobID, title: title, progress: progress,
                                           statusMsg: msg, isFinished: finished, error: error, outputURL: out))
            }
        }

        await upd(0.01, "Loading AI model…")

        do {
            let whisper = WhisperService.shared
            if !whisper.modelExists {
                await upd(0.01, "Downloading speech model (first time only, ~75 MB)…")
                try await whisper.downloadModel { p, msg in
                    Task { await upd(0.01 + p * 0.08, "Downloading model: \(Int(p * 100))%") }
                }
            } else if !whisper.isModelLoaded {
                await upd(0.02, "Loading speech model…")
                try await whisper.loadModel()
            }

            let svc = VideoExportService.shared

            // Auto-convert HEVC (iPhone) videos to H.264 before transcription
            let workingURL = await svc.convertHEVCIfNeeded(videoURL) { msg in
                Task { await upd(0.10, msg) }
            }

            await upd(0.12, "Transcribing audio…")
            let words = try await whisper.transcribe(audioURL: workingURL) { p in
                Task { await upd(0.12 + p * 0.33, "Transcribing: \(Int(p * 100))%") }
            }
            guard !words.isEmpty else {
                throw NSError(domain: "AutoClip", code: 3, userInfo: [NSLocalizedDescriptionKey: "No speech detected in video."])
            }

            // Always generate clean sentence-boundary segments first.
            // This guarantees cuts land on real word boundaries regardless of mode.
            await upd(0.45, "Finding best moments…")
            let segments = svc.autoSegmentsFromWords(words)
            guard !segments.isEmpty else {
                throw NSError(domain: "AutoClip", code: 4, userInfo: [NSLocalizedDescriptionKey: "Not enough speech segments to build a reel."])
            }

            // For multiple reels each reel gets its own full targetDur budget
            let selectionBudget = exportMode == .multipleReels ? targetDur * Double(numberOfReels) : targetDur

            var clips: [Clip]
            if useAI && !apiKey.isEmpty {
                // Smart AI mode: LLM picks WHICH segments are best — cuts stay clean
                await upd(0.47, "AI choosing the best segments…")
                let selected = try await LLMClipService.shared.selectSegments(
                    from: segments, provider: provider, apiKey: apiKey, targetDuration: selectionBudget)
                clips = selected
            } else {
                // Local mode: score-based selection with hook boost
                let (hook, rest) = svc.selectHookAndClips(from: segments, targetDuration: selectionBudget)
                guard let hook else {
                    throw NSError(domain: "AutoClip", code: 4, userInfo: [NSLocalizedDescriptionKey: "Not enough speech segments to build a reel."])
                }
                clips = [hook] + rest
            }

            // Apply storyline ordering to shape the narrative structure
            clips = storylineMode.order(clips)

            // Derive reel title from the hook clip's opening words
            let hookPreview = clips.first.map {
                $0.words.prefix(7).map { $0.word }.joined(separator: " ")
            } ?? ""
            let reelTitle = hookPreview.count > 4 ? hookPreview : title

            // Show clip preview and wait for user confirmation before encoding
            let shouldExport = await store.setPendingExport(clips: clips, jobID: jobID, jobTitle: reelTitle)
            guard shouldExport else { return }

            // Clear the pending clips from the job now that export is confirmed
            await MainActor.run {
                if var job = store.activeJob, job.id == jobID {
                    job.pendingClips = nil
                    job.statusMsg = "Preparing export…"
                    store.activeJob = job
                }
            }

            let desktop = outputDir

            var opts = VideoExportService.ExportOptions()
            opts.format = format; opts.burnCaptions = captions
            if captions && styleIdx < CaptionStyle.all.count { opts.captionStyle = CaptionStyle.all[styleIdx] }

            if exportMode == .multipleReels {
                // Distribute clips round-robin across N reels so each reel gets
                // a unique variety of the best moments (not just the top chunk vs bottom chunk)
                let n = max(2, min(numberOfReels, clips.count))
                var groups: [[Clip]] = Array(repeating: [], count: n)
                for (i, clip) in clips.enumerated() { groups[i % n].append(clip) }
                // Drop any empty groups (when clips.count < n)
                let validGroups = groups.filter { !$0.isEmpty }
                var outURLs: [URL] = []
                for (i, group) in validGroups.enumerated() {
                    let pct = Double(i) / Double(validGroups.count)
                    await upd(0.50 + pct * 0.48, "Stitching reel \(i + 1) of \(validGroups.count)…")
                    let outURL = desktop.appendingPathComponent("\(reelTitle) – Reel \(i + 1).mp4")
                    try await svc.createHighlightReel(clips: group, sourceVideoURL: workingURL,
                                                      outputURL: outURL, options: opts) { _, _ in }
                    outURLs.append(outURL)
                }
                // Duration of the primary (first) reel
                let firstGroup = validGroups.first ?? []
                let firstReelDur = firstGroup.reduce(0) { $0 + $1.duration }
                // Cut points as fractions of first reel duration (for scrubber ticks)
                var cutPts: [Double] = []
                if firstReelDur > 0 {
                    var acc = 0.0
                    for clip in firstGroup.dropLast() {
                        acc += clip.duration
                        cutPts.append(acc / firstReelDur)
                    }
                }
                let record = AutoReelRecord(id: UUID(), title: "\(reelTitle) – \(validGroups.count) Reels",
                                            path: outURLs.first?.path ?? "",
                                            paths: outURLs.map { $0.path },
                                            format: fmtLabel(format), duration: firstReelDur,
                                            clipCount: clips.count, dateCreated: Date().timeIntervalSince1970,
                                            cutPoints: cutPts)
                await MainActor.run {
                    AutoReelsStore.shared.add(record)
                    store.updateJob(AutoReelJob(id: jobID, title: reelTitle, progress: 1.0,
                                               statusMsg: "\(validGroups.count) reels saved",
                                               isFinished: true, error: nil,
                                               outputURL: outURLs.first, outputURLs: outURLs,
                                               cutPoints: cutPts, reelDuration: firstReelDur))
                }
            } else if exportMode == .individualClips {
                // Export each clip as its own file
                var outURLs: [URL] = []
                for (i, clip) in clips.enumerated() {
                    let pct = Double(i) / Double(clips.count)
                    let startStr = String(format: "%dm%02ds", Int(clip.startTime) / 60, Int(clip.startTime) % 60)
                    await upd(0.50 + pct * 0.48, "Exporting clip \(i + 1) of \(clips.count)…")
                    let outURL = desktop.appendingPathComponent("\(reelTitle) – Clip \(i + 1) (\(startStr)).mp4")
                    try? FileManager.default.removeItem(at: outURL)
                    try await svc.exportClip(clip, from: workingURL, to: outURL, options: opts)
                    outURLs.append(outURL)
                }
                let record = AutoReelRecord(id: UUID(), title: "\(reelTitle) – \(clips.count) Clips",
                                            path: outURLs.first?.path ?? "",
                                            format: fmtLabel(format), duration: clips.reduce(0) { $0 + $1.duration },
                                            clipCount: clips.count, dateCreated: Date().timeIntervalSince1970)
                await MainActor.run {
                    AutoReelsStore.shared.add(record)
                    store.updateJob(AutoReelJob(id: jobID, title: reelTitle, progress: 1.0,
                                               statusMsg: "\(clips.count) clips saved to Desktop",
                                               isFinished: true, error: nil,
                                               outputURL: outURLs.first, outputURLs: outURLs))
                }
            } else {
                // Stitch all clips into one highlight reel
                await upd(0.50, "Exporting reel…")
                let outURL = desktop.appendingPathComponent("\(reelTitle) – Auto Reel.mp4")
                try await svc.createHighlightReel(clips: clips, sourceVideoURL: workingURL, outputURL: outURL, options: opts) { p, msg in
                    Task { await upd(0.50 + p * 0.50, msg) }
                }
                let asset = AVURLAsset(url: outURL)
                let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                // Compute cut points as fractions of total duration
                var cutPts: [Double] = []
                if dur > 0 {
                    var acc = 0.0
                    for clip in clips.dropLast() {
                        acc += clip.duration
                        cutPts.append(acc / dur)
                    }
                }
                let record = AutoReelRecord(id: UUID(), title: "\(reelTitle) Reel", path: outURL.path,
                                            format: fmtLabel(format), duration: dur,
                                            clipCount: clips.count, dateCreated: Date().timeIntervalSince1970,
                                            cutPoints: cutPts)
                await MainActor.run {
                    AutoReelsStore.shared.add(record)
                    store.updateJob(AutoReelJob(id: jobID, title: reelTitle, progress: 1.0,
                                               statusMsg: "Done!", isFinished: true, error: nil, outputURL: outURL,
                                               cutPoints: cutPts, reelDuration: dur))
                }
            }

        } catch {
            await upd(0, "", finished: true, error: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
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
        case .original:     return "Original"
        case .horizontal16x9: return "16:9"
        }
    }

    private func formatDur(_ s: Double) -> String {
        let t = Int(s)
        return t >= 60 ? "\(t / 60)m \(t % 60)s" : "\(t)s"
    }
}
