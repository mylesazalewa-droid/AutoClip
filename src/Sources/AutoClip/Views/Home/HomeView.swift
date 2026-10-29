import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum HomeTab { case projects, autoClips, autoReels }

struct HomeView: View {
    @ObservedObject private var library = LibraryService.shared
    @ObservedObject private var appState = AppState.shared
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .newest
    @State private var filterCategory = "All"
    @State private var isDropTargeted = false
    @State private var activeTab: HomeTab = .projects
    @State private var showAutoClipsSettings = false

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    var filteredProjects: [Project] {
        var list = library.projects
        if !searchText.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .newest: list.sort { $0.dateCreated > $1.dateCreated }
        case .oldest: list.sort { $0.dateCreated < $1.dateCreated }
        case .topScore: break
        case .duration: list.sort { $0.duration > $1.duration }
        case .trending: list.sort { $0.clipCount > $1.clipCount }
        }
        return list
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                toolbar

                // Tab bar
                tabBar

                // Tab content
                switch activeTab {
                case .autoReels:
                    AutoReelsTab()
                case .autoClips:
                    if filteredProjects.isEmpty && searchText.isEmpty {
                        landingPage
                    } else {
                        projectsContent
                    }
                case .projects:
                    CombinedProjectsView(
                        onSwitchToAutoClips: { activeTab = .autoClips },
                        onSwitchToAutoReels: { activeTab = .autoReels }
                    )
                }
            }
        }
        .onDrop(of: [.movie, .fileURL], isTargeted: $isDropTargeted) { providers in
            guard activeTab == .autoClips else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { AppState.shared.importVideo(url) }
                }
            }
            return true
        }
        .sheet(isPresented: $appState.showYouTubeSheet) {
            YouTubeURLSheet()
        }
    }

    var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Projects", icon: "square.grid.2x2.fill", tab: .projects)
            tabButton(title: "Auto Clips", icon: "folder.fill", tab: .autoClips)
            tabButton(title: "Auto Reels", icon: "play.rectangle.on.rectangle.fill", tab: .autoReels)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 0)
        .background(Color(red: 0.09, green: 0.10, blue: 0.15))
        .overlay(Divider().background(Color.white.opacity(0.08)), alignment: .bottom)
    }

    func tabButton(title: String, icon: String, tab: HomeTab) -> some View {
        Button(action: { activeTab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 13, weight: activeTab == tab ? .semibold : .regular))
            }
            .foregroundColor(activeTab == tab ? gold : Color.white.opacity(0.45))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(
                Rectangle()
                    .fill(activeTab == tab ? gold : Color.clear)
                    .frame(height: 2),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(gold)
                Text("AutoClip")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.leading, 16)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color.white.opacity(0.4))
                    .font(.system(size: 13))
                TextField("Search projects & clips...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07))
            .cornerRadius(8)
            .frame(width: 260)

            Spacer()

            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button(order.rawValue) { sortOrder = order }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                    Text(sortOrder.rawValue).font(.system(size: 13))
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .foregroundColor(Color.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .cornerRadius(7)
            }
            .buttonStyle(.plain)

            if activeTab == .autoClips {
                Button(action: { appState.triggerImport() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        Text("New Clip").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(gold)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: { appState.showYouTubeSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "link").font(.system(size: 12))
                        Text("YouTube URL").font(.system(size: 13))
                    }
                    .foregroundColor(Color.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: { showAutoClipsSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.5))
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .help("Auto Clips Settings")
                .sheet(isPresented: $showAutoClipsSettings) {
                    AutoClipsSettingsSheet()
                }
            }
            Color.clear.frame(width: 16, height: 1)
        }
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.10, blue: 0.15))
    }

    // MARK: - Landing Page (empty state)

    var landingPage: some View {
        ScrollView {
            VStack(spacing: 40) {
                Spacer(minLength: 40)

                // Drop zone
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isDropTargeted ? gold : Color.white.opacity(0.15),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isDropTargeted
                                      ? gold.opacity(0.06)
                                      : Color.white.opacity(0.03))
                        )

                    VStack(spacing: 16) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 44))
                            .foregroundColor(Color.white.opacity(isDropTargeted ? 0.7 : 0.3))

                        VStack(spacing: 6) {
                            Text("Drop your video here")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                            Text("MP4, MOV, MKV — any format works")
                                .font(.system(size: 14))
                                .foregroundColor(Color.white.opacity(0.4))
                        }

                        HStack(spacing: 12) {
                            Button(action: { appState.triggerImport() }) {
                                HStack(spacing: 7) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 13))
                                    Text("Browse Files")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(9)
                            }
                            .buttonStyle(.plain)

                            Button(action: { appState.showYouTubeSheet = true }) {
                                HStack(spacing: 7) {
                                    Image(systemName: "link")
                                        .font(.system(size: 13))
                                    Text("YouTube URL")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color(red: 0.85, green: 0.18, blue: 0.18))
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

                // Feature cards
                HStack(spacing: 14) {
                    featureCard(icon: "brain.head.profile", emoji: nil,
                                title: "On-Device AI",
                                subtitle: "Runs on Neural Engine")
                    featureCard(icon: "lock.shield", emoji: nil,
                                title: "100% Private",
                                subtitle: "Never leaves your Mac")
                    featureCard(icon: nil, emoji: "😊",
                                title: "Face Tracking",
                                subtitle: "Smart vertical reframe")
                    featureCard(icon: "text.bubble", emoji: nil,
                                title: "Auto Captions",
                                subtitle: "Viral-style text overlay")
                }
                .frame(maxWidth: 580)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
    }

    func featureCard(icon: String?, emoji: String?, title: String, subtitle: String) -> some View {
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

    // MARK: - Projects Grid

    var projectsContent: some View {
        VStack(spacing: 0) {
            // Filter tabs
            HStack(spacing: 8) {
                filterTab("All")
                filterTab("Uncategorized (\(library.projects.count))")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("My Videos")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Text("(\(filteredProjects.count))")
                            .font(.system(size: 15))
                            .foregroundColor(Color.white.opacity(0.4))
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 12)], spacing: 12) {
                        ForEach(filteredProjects) { project in
                            ProjectCard(project: project)
                                .onTapGesture {
                                    AppState.shared.selectedProject = project
                                    AppState.shared.selectedClip = nil
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    func filterTab(_ label: String) -> some View {
        let isSelected = filterCategory == label || (label.hasPrefix("All") && filterCategory == "All")
        return Button(action: { filterCategory = label }) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .black : Color.white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? gold : Color.white.opacity(0.07))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Combined Projects View

struct CombinedProjectsView: View {
    @ObservedObject private var library = LibraryService.shared
    @ObservedObject private var reelsStore = AutoReelsStore.shared
    var onSwitchToAutoClips: (() -> Void)?
    var onSwitchToAutoReels: (() -> Void)?
    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Auto Reels section
                    if !reelsStore.reels.isEmpty || !reelsStore.activeJobs.isEmpty {
                        sectionHeader(title: "Auto Reels", count: reelsStore.reels.count,
                                      icon: "play.rectangle.on.rectangle.fill")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(reelsStore.reels) { reel in
                                reelMiniCard(reel)
                                    .onTapGesture {
                                        AutoReelsStore.shared.navigateToReelID = reel.id
                                        onSwitchToAutoReels?()
                                    }
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 24)
                    }

                    // Auto Clips section
                    sectionHeader(title: "Auto Clips", count: library.projects.count,
                                  icon: "folder.fill")
                    if library.projects.isEmpty {
                        Text("No clips yet. Create one in the Auto Clips tab.")
                            .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.35))
                            .padding(.horizontal, 20).padding(.bottom, 24)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(library.projects) { project in
                                ProjectCard(project: project)
                                    .onTapGesture {
                                        AppState.shared.selectedProject = project
                                        AppState.shared.selectedClip = nil
                                        onSwitchToAutoClips?()
                                    }
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
            }
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    func sectionHeader(title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(gold)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            Text("(\(count))").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.35))
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    func reelMiniCard(_ reel: AutoReelRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                ReelThumbnailView(path: reel.path)
                    .frame(height: 140).clipped()
                Text(formatDuration(reel.duration))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.6)).cornerRadius(4)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(reel.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text("\(reel.paths.count) reel\(reel.paths.count == 1 ? "" : "s") · \(reel.format)")
                    .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.17))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    func formatDuration(_ s: Double) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - YouTube Import Sheet

struct YouTubeURLSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var url = ""
    @State private var isDownloading = false
    @State private var statusText = ""
    @State private var error: String?
    @State private var downloadProgress: Double = 0

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Import YouTube Video")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(Color.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("YouTube URL")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.5))
                TextField("https://youtube.com/watch?v=...", text: $url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                    .disabled(isDownloading)
            }

            if isDownloading {
                VStack(spacing: 6) {
                    ProgressView(value: downloadProgress > 0 ? downloadProgress : nil)
                        .accentColor(gold)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(2)
                }
            } else if let err = error {
                ScrollView {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 70)
            }

            Button(action: startDownload) {
                HStack {
                    if isDownloading { ProgressView().scaleEffect(0.7) }
                    Text(isDownloading ? "Downloading…" : "Import")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(url.isEmpty || isDownloading ? gold.opacity(0.4) : gold)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(url.isEmpty || isDownloading)
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(red: 0.1, green: 0.11, blue: 0.16))
    }

    private func ytDlpPath() -> String? {
        // Check bundled yt-dlp first (copied from 1.4.1 resources)
        if let bundled = Bundle.main.path(forResource: "yt-dlp", ofType: nil),
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // Also check next to the binary (for the .app bundle layout)
        let execDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent().path
        let siblingPath = execDir + "/../Resources/yt-dlp"
        if FileManager.default.fileExists(atPath: siblingPath) { return siblingPath }

        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/opt/homebrew/opt/yt-dlp/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["yt-dlp"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    func startDownload() {
        guard !url.isEmpty else { return }
        error = nil

        guard let ytdlp = ytDlpPath() else {
            error = "yt-dlp is not installed.\n\nInstall it with:\n  brew install yt-dlp\n\nThen try again."
            return
        }

        isDownloading = true
        downloadProgress = 0
        statusText = "Starting download…"

        Task.detached(priority: .userInitiated) {
            let videosDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/AutoClip/Videos")
            try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

            // Use a temp file to capture the output path
            let outTemplate = videosDir.appendingPathComponent("%(title)s.%(ext)s").path

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ytdlp)
            process.arguments = YTDLP.arguments(url: url, outTemplate: outTemplate)
            process.environment = YTDLP.environment
            process.currentDirectoryURL = videosDir

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Collect stderr for error reporting
            var stderrBuffer = ""

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                guard let line = String(data: handle.availableData, encoding: .utf8) else { return }
                stderrBuffer += line
                // Parse progress percentage
                if line.contains("%") {
                    let parts = line.split(separator: "%")
                    if let numStr = parts.first?.split(separator: " ").compactMap({ Double($0) }).last {
                        DispatchQueue.main.async { downloadProgress = numStr / 100.0 }
                    }
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    DispatchQueue.main.async { statusText = String(trimmed.prefix(100)) }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
                errPipe.fileHandleForReading.readabilityHandler = nil

                let exitCode = process.terminationStatus

                // Read stdout (filepath printed by --print after_move:filepath)
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let printedPath = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard exitCode == 0 else {
                    let detail = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        isDownloading = false
                        error = detail.isEmpty
                            ? "Download failed (exit code \(exitCode)). Check that the URL is valid and public."
                            : String(detail.suffix(300))
                    }
                    return
                }

                // Resolve the file
                var fileURL: URL?
                if !printedPath.isEmpty && FileManager.default.fileExists(atPath: printedPath) {
                    fileURL = URL(fileURLWithPath: printedPath)
                } else {
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: videosDir,
                        includingPropertiesForKeys: [.creationDateKey],
                        options: .skipsHiddenFiles)) ?? []
                    fileURL = files
                        .filter { $0.pathExtension.lowercased() == "mp4" && !YTDLP.isPartialStream($0) }
                        .sorted {
                            let da = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                            let db = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                            return da > db
                        }
                        .first
                }

                guard let videoURL = fileURL else {
                    await MainActor.run {
                        isDownloading = false
                        error = "Download succeeded but couldn't find the output file. Check ~/Documents/AutoClip/Videos."
                    }
                    return
                }

                // Hand off to AppState which runs the full pipeline:
                // copy → transcribe → generate clips
                await MainActor.run {
                    isDownloading = false
                    dismiss()
                    AppState.shared.importVideo(videoURL)
                }

            } catch {
                await MainActor.run {
                    isDownloading = false
                    self.error = "Could not launch yt-dlp at \(ytdlp):\n\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Auto Clips Settings Sheet

struct AutoClipsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ac_useAI")      private var useAI: Bool = false
    @AppStorage("ac_provider")   private var providerRaw: String = LLMClipService.AIProvider.anthropic.rawValue
    @AppStorage("whisper_model_size") private var whisperModelSize: String = "small"
    @State private var apiKeys: [LLMClipService.AIProvider: String] = [:]
    @State private var showKey = false

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    private var aiProvider: LLMClipService.AIProvider {
        get { LLMClipService.AIProvider(rawValue: providerRaw) ?? .anthropic }
        nonmutating set { providerRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Whisper model
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").foregroundColor(gold).font(.system(size: 11))
                            Text("Transcription Model")
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        }
                        Text("A larger model is more accurate but slower to download and transcribe.")
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 4) {
                            ForEach(WhisperService.modelSizes, id: \.key) { size in
                                Button(action: {
                                    whisperModelSize = size.key
                                    WhisperService.shared.invalidateIfVariantChanged()
                                }) {
                                    HStack {
                                        Text(size.label)
                                            .font(.system(size: 12, weight: whisperModelSize == size.key ? .semibold : .regular))
                                            .foregroundColor(whisperModelSize == size.key ? .black : .white)
                                        Spacer()
                                        if whisperModelSize == size.key {
                                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                                        }
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(whisperModelSize == size.key ? gold : Color.white.opacity(0.06))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)

                    // AI clip ranking
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").foregroundColor(gold).font(.system(size: 11))
                            Text("AI Clip Ranking")
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            Spacer()
                            Toggle("", isOn: $useAI).toggleStyle(.switch).tint(gold)
                        }
                        if useAI {
                            Text("After local analysis, an LLM re-ranks clips for viral potential.")
                                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                ForEach(LLMClipService.AIProvider.allCases) { p in
                                    Button(action: { aiProvider = p }) {
                                        Text(shortLabel(p))
                                            .font(.system(size: 11, weight: aiProvider == p ? .semibold : .regular))
                                            .foregroundColor(aiProvider == p ? .black : Color.white.opacity(0.6))
                                            .padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(aiProvider == p ? gold : Color.white.opacity(0.07))
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            HStack(spacing: 6) {
                                let binding = Binding<String>(
                                    get: { apiKeys[aiProvider] ?? "" },
                                    set: { v in
                                        apiKeys[aiProvider] = v
                                        Task { await LLMClipService.shared.saveAPIKey(v, for: aiProvider) }
                                    }
                                )
                                Group {
                                    if showKey { TextField(aiProvider.keyPlaceholder, text: binding) }
                                    else { SecureField(aiProvider.keyPlaceholder, text: binding) }
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Color.white.opacity(0.06)).cornerRadius(6)
                                Button(action: { showKey.toggle() }) {
                                    Image(systemName: showKey ? "eye.slash" : "eye")
                                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Stored in macOS Keychain.")
                                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                        }
                    }
                    .padding(14).background(Color.white.opacity(0.04)).cornerRadius(10)
                }
                .padding(20)
            }
            .background(Color(red: 0.07, green: 0.08, blue: 0.12))
            .navigationTitle("Auto Clips Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(gold)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 460)
        .preferredColorScheme(.dark)
        .task {
            var loaded: [LLMClipService.AIProvider: String] = [:]
            for p in LLMClipService.AIProvider.allCases {
                if let k = await LLMClipService.shared.loadAPIKey(for: p), !k.isEmpty { loaded[p] = k }
            }
            apiKeys = loaded
        }
    }

    private func shortLabel(_ p: LLMClipService.AIProvider) -> String {
        switch p {
        case .anthropic: return "Claude"
        case .openai:    return "GPT-4o"
        case .google:    return "Gemini"
        }
    }
}
