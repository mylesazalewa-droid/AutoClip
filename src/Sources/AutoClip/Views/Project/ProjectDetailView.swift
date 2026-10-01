import SwiftUI

enum ClipFilter: String, CaseIterable {
    case all = "All"
    case liked = "Liked"
    case rated = "Rated"
    case trending = "Trending"
}

struct ProjectDetailView: View {
    @Binding var project: Project
    @ObservedObject private var appState = AppState.shared

    @State private var selectedClipId: UUID?
    @State private var clipFilter: ClipFilter = .all
    @State private var sortOrder: SortOrder = .topScore
    @State private var isGridView = true
    @State private var searchText = ""
    @State private var showHistory = false
    @State private var isEditingTitle = false
    @State private var editTitle = ""
    @State private var showProjectQuotes = false
    @State private var showAutoReel = false

    var selectedClip: Clip? {
        project.clips.first { $0.id == selectedClipId }
    }

    var selectedClipBinding: Binding<Clip> {
        Binding(
            get: { selectedClip ?? project.clips.first ?? Clip(id: UUID(), title: "", startTime: 0, endTime: 0, score: 0, scoreReason: "", words: [], isLiked: false, starRating: 0, captionStyleName: "Karaoke", aspectRatio: "9:16", notes: "", thumbnailData: nil) },
            set: { updated in
                if let idx = project.clips.firstIndex(where: { $0.id == updated.id }) {
                    project.clips[idx] = updated
                    LibraryService.shared.updateProject(project)
                }
            }
        )
    }

    var filteredClips: [Clip] {
        var clips = project.clips

        // Search
        if !searchText.isEmpty {
            clips = clips.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.transcriptText.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Filter
        switch clipFilter {
        case .all: break
        case .liked: clips = clips.filter { $0.isLiked }
        case .rated: clips = clips.filter { $0.starRating > 0 }
        case .trending: clips = clips.filter { $0.isTrending }
        }

        // Sort
        switch sortOrder {
        case .topScore: clips.sort { $0.score > $1.score }
        case .newest: break
        case .oldest: clips.sort { $0.startTime < $1.startTime }
        case .duration: clips.sort { $0.duration > $1.duration }
        case .trending: clips.sort { ($0.isTrending ? 1 : 0) > ($1.isTrending ? 1 : 0) }
        }

        return clips
    }

    var likedCount: Int { project.clips.filter { $0.isLiked }.count }
    var trendingCount: Int { project.clips.filter { $0.isTrending }.count }
    var avgScore: Int { project.clips.isEmpty ? 0 : Int(project.clips.map(\.score).reduce(0, +) / Double(project.clips.count)) }
    var wordCount: Int { project.clips.flatMap { $0.words }.count }

    var body: some View {
        HSplitView {
            // Left panel: clips browser
            leftPanel

            // Right panel: quotes (project-level) OR clip detail
            if showProjectQuotes {
                VStack(spacing: 0) {
                    HStack {
                        Text("Best Quotes")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: { showProjectQuotes = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.09, green: 0.10, blue: 0.15))

                    Divider().background(Color.white.opacity(0.08))

                    ScrollView {
                        QuotesPanel(clips: project.clips, seekAction: nil)
                    }
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
                .background(Color(red: 0.07, green: 0.08, blue: 0.12))
            } else if let _ = selectedClip {
                ClipDetailPanel(clip: selectedClipBinding, project: project)
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
            }
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
        .sheet(isPresented: $showHistory) {
            ExportHistoryView()
        }
        .sheet(isPresented: $showAutoReel) {
            AutoReelSheet(project: project, isPresented: $showAutoReel)
        }
    }

    var leftPanel: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                // Back
                Button(action: {
                    appState.selectedProject = nil
                    appState.selectedClip = nil
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.7))
                }
                .buttonStyle(.plain)

                // Project title
                if isEditingTitle {
                    TextField("", text: $editTitle, onCommit: {
                        var updated = project
                        updated.title = editTitle
                        project = updated
                        LibraryService.shared.updateProject(updated)
                        isEditingTitle = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: 240)
                    .onAppear { editTitle = project.title }
                } else {
                    Text(project.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                Button(action: {
                    editTitle = project.title
                    isEditingTitle = true
                }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)

                Spacer()

                // Search
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.3))
                    TextField("Find keywords or moments...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.07))
                .cornerRadius(7)
                .frame(maxWidth: 240)

                Text("⌘K")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.2))

                Spacer()

                // Sort
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button(order.rawValue) { sortOrder = order }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 10))
                        Text(sortOrder.rawValue)
                            .font(.system(size: 12))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Best Quotes
                Button(action: { showProjectQuotes.toggle() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                        Text("Best Quotes")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(showProjectQuotes ? Color(red: 1.0, green: 0.75, blue: 0.0) : Color.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(showProjectQuotes ? Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.15) : Color.white.opacity(0.07))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // History
                Button(action: { showHistory = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                        Text("History")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Auto Reel
                Button(action: { showAutoReel = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 11))
                        Text("Auto Reel")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(red: 1.0, green: 0.75, blue: 0.0))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(project.clips.isEmpty)

                // Reanalyze
                Button(action: { appState.reanalyzeProject(project) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("Reanalyze")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 0.09, green: 0.10, blue: 0.15))

            // Stats bar
            statsBar

            Divider().background(Color.white.opacity(0.08))

            // Filter + secondary stats row
            HStack(spacing: 8) {
                filterTab(for: .all)
                filterTab(for: .liked)
                filterTab(for: .rated)
                filterTab(for: .trending)
                Spacer()

                Text("\(filteredClips.count) clips")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))
                Text("\(avgScore) avg score")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))
                Text("\(likedCount) liked")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))

                // View toggle
                HStack(spacing: 0) {
                    Button(action: { isGridView = true }) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 13))
                            .foregroundColor(isGridView ? .white : Color.white.opacity(0.3))
                            .padding(6)
                            .background(isGridView ? Color.white.opacity(0.12) : Color.clear)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)

                    Button(action: { isGridView = false }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13))
                            .foregroundColor(!isGridView ? .white : Color.white.opacity(0.3))
                            .padding(6)
                            .background(!isGridView ? Color.white.opacity(0.12) : Color.clear)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider().background(Color.white.opacity(0.06))

            // Analysis progress overlay
            if appState.isAnalyzing {
                analysisProgressView
            } else if filteredClips.isEmpty {
                emptyClipsView
            } else {
                // Clips grid or list
                if isGridView {
                    clipsGrid
                } else {
                    clipsList
                }
            }
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    var statsBar: some View {
        HStack(spacing: 0) {
            // Thumbnail
            if let thumb = project.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .cornerRadius(4)
                    .clipped()
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
            }

            statItem(icon: "film", value: "\(project.clipCount)", label: "clips")
            statItem(icon: "clock", value: project.formattedDuration, label: "duration")
            statItem(icon: "bolt.fill", value: "\(avgScore)", label: "avg score")
            statItem(icon: "heart.fill", value: "\(likedCount)", label: "liked")
            statItem(icon: "text.bubble", value: "\(wordCount)", label: "words")

            Spacer()
        }
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.10, blue: 0.14))
    }

    func statItem(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.3))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 10)
    }

    func filterTab(for filter: ClipFilter) -> some View {
        let count: Int
        switch filter {
        case .all: count = project.clips.count
        case .liked: count = likedCount
        case .rated: count = project.clips.filter { $0.starRating > 0 }.count
        case .trending: count = trendingCount
        }

        let isSelected = clipFilter == filter
        let label = filter == .all ? "All \(count)" : "\(filter.rawValue) \(count)"

        return Button(action: { clipFilter = filter }) {
            HStack(spacing: 4) {
                if filter == .trending {
                    Text("🔥")
                        .font(.system(size: 10))
                }
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? Color(red: 1.0, green: 0.75, blue: 0.0) : Color.white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.12) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    var clipsGrid: some View {
        let cols = selectedClip != nil ? 2 : 5
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: cols)

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(filteredClips) { clip in
                    ClipCard(clip: clip, project: project, isSelected: selectedClipId == clip.id)
                        .onTapGesture {
                            selectedClipId = selectedClipId == clip.id ? nil : clip.id
                        }
                }
            }
            .padding(12)
        }
    }

    var clipsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredClips) { clip in
                    ClipListRow(clip: clip, project: project, isSelected: selectedClipId == clip.id)
                        .onTapGesture {
                            selectedClipId = selectedClipId == clip.id ? nil : clip.id
                        }
                }
            }
            .padding(.vertical, 6)
        }
    }

    var analysisProgressView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: appState.analyzeProgress)
                .accentColor(Color(red: 1.0, green: 0.75, blue: 0.0))
                .padding(.horizontal, 60)
            Text(appState.analyzeStatus)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.6))
            Spacer()
        }
    }

    var emptyClipsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 40))
                .foregroundColor(Color.white.opacity(0.15))
            Text("No clips found")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.4))
            Text("Try a different filter or reanalyze the video")
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.25))
            Spacer()
        }
    }
}

struct ExportHistoryView: View {
    @ObservedObject private var library = LibraryService.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export History")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text("\(library.exportHistory.count) exports")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white.opacity(0.4))
                    .padding(.leading, 8)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().background(Color.white.opacity(0.08))

            if library.exportHistory.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 44))
                        .foregroundColor(Color.white.opacity(0.15))
                    Text("No exports yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.4))
                    Text("Exported clips will appear here")
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.25))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(library.exportHistory) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.clipTitle)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(record.format)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.white.opacity(0.4))
                                }
                                Spacer()
                                Text(record.exportDate, style: .relative)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.white.opacity(0.4))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 480)
        .background(Color(red: 0.09, green: 0.10, blue: 0.15))
    }
}
