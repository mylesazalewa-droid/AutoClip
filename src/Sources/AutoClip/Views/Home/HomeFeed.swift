import SwiftUI
import AppKit

/// Jumps from the Home feed straight into another tab's item.
@MainActor
final class HomeNav: ObservableObject {
    static let shared = HomeNav()
    @Published var tab: HomeTab?
    /// A sermon to open in Assess
    @Published var assessPath: String?

    func open(_ tab: HomeTab) { self.tab = tab }
    func openPodcast(_ id: String) {
        UserDefaults.standard.set(id, forKey: "podcast_selected")
        tab = .podcast
    }
    func openAssess(_ path: String) {
        assessPath = path
        tab = .assess
    }
}

/// The Home tab, laid out like a streaming service: a large rotating banner of your latest work,
/// then rows of reels, podcast episodes and sermons to scroll through.
struct HomeFeed: View {
    @ObservedObject private var library = LibraryService.shared
    @ObservedObject private var reelsStore = AutoReelsStore.shared
    @ObservedObject private var podcasts = PodcastStore.shared
    var onOpenProject: (Project) -> Void
    var onOpenReel: (AutoReelRecord) -> Void

    @State private var heroIndex = 0
    @State private var sermons: [String] = []

    struct HeroItem: Identifiable {
        var id: String
        var kind: String
        var title: String
        var detail: String
        var date: Date
        var thumb: String
        /// A vertical (9:16) picture
        var tall = false
        var open: () -> Void
    }

    private var heroItems: [HeroItem] {
        var items: [HeroItem] = []
        for r in reelsStore.reels {
            items.append(.init(id: "r" + r.id.uuidString, kind: "Auto Reels", title: r.title,
                               detail: "\(r.paths.count) reel\(r.paths.count == 1 ? "" : "s") · \(r.format) · \(time(r.duration))",
                               date: Date(timeIntervalSince1970: r.dateCreated), thumb: r.sourceVideoPath ?? r.path,
                               tall: r.format.contains("9:16") || r.format.lowercased().contains("vertical"), open: { onOpenReel(r) }))
        }
        for e in podcasts.episodes where e.analyzed {
            items.append(.init(id: "p" + e.id, kind: e.isAudioOnly ? "Podcast · audio" : "Podcast",
                               title: e.title, detail: "\(time(e.editedDuration)) after the edit · \(e.people.count > 1 ? "\(e.people.count) people" : "1 voice")",
                               date: e.created, thumb: e.isAudioOnly ? "" : (e.angles.first?.path ?? ""),
                               open: { HomeNav.shared.openPodcast(e.id) }))
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                let hero = heroItems
                if hero.isEmpty { welcome } else { banner(hero) }

                startRow

                if !reelsStore.reels.isEmpty {
                    row("Auto Reels", count: reelsStore.reels.count, action: ("See all", { HomeNav.shared.open(.autoReels) })) {
                        ForEach(reelsStore.reels) { r in
                            PosterCard(path: r.path, title: r.title, meta: "\(r.paths.count) reel\(r.paths.count == 1 ? "" : "s") · \(time(r.duration))",
                                       badge: r.format) { onOpenReel(r) }
                        }
                    }
                }

                let episodes = podcasts.episodes
                if !episodes.isEmpty {
                    row("Podcast episodes", count: episodes.count, action: ("Open Podcast", { HomeNav.shared.open(.podcast) })) {
                        ForEach(episodes) { e in
                            WideCard(path: e.isAudioOnly ? nil : e.angles.first?.path, icon: e.isAudioOnly ? "mic.fill" : "video.fill",
                                     title: e.title,
                                     meta: e.analyzed ? "\(time(e.duration)) → \(time(e.editedDuration))" : "Preparing…",
                                     progress: e.analyzed ? e.editedDuration / max(1, e.duration) : nil) {
                                HomeNav.shared.openPodcast(e.id)
                            }
                        }
                    }
                }

                if !sermons.isEmpty {
                    row("Sermons to assess", count: sermons.count, action: ("Open Assess", { HomeNav.shared.open(.assess) })) {
                        ForEach(sermons.prefix(20), id: \.self) { p in
                            WideCard(path: p, icon: "waveform", title: YTDLP.title(fromFile: URL(fileURLWithPath: p)),
                                     meta: "Assess the delivery", progress: nil) { HomeNav.shared.openAssess(p) }
                        }
                    }
                }

                if !library.projects.isEmpty {
                    row("Clip projects", count: library.projects.count, action: nil) {
                        ForEach(library.projects) { p in
                            WideCard(path: p.videoPath, icon: "folder.fill", title: p.title,
                                     meta: "\(p.clipCount) clip\(p.clipCount == 1 ? "" : "s") · \(time(p.duration))", progress: nil) { onOpenProject(p) }
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
            .padding(.top, 32)
        }
        .onAppear { sermons = AssessTab.knownVideos(reels: reelsStore.reels) }
        .task {
            // The banner turns every 8 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let n = heroItems.count
                if n > 1 { withAnimation(.easeInOut(duration: 0.6)) { heroIndex = (heroIndex + 1) % n } }
            }
        }
    }

    // MARK: Banner

    private func banner(_ items: [HeroItem]) -> some View {
        let i = min(heroIndex, items.count - 1)
        let item = items[i]
        return ZStack(alignment: .bottomTrailing) {
            CinematicHero(path: item.thumb.isEmpty ? nil : item.thumb,
                          eyebrow: "\(item.kind) · \(item.date.formatted(.relative(presentation: .named)))",
                          title: item.title, detail: item.detail, height: 540, icon: "mic.and.signal.meter.fill") {
                Button(action: item.open) { Label("Open", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.thumb)]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(item.thumb.isEmpty)
            }
            .id(item.id)
            .transition(.opacity)

            // Arrows and page dots
            if items.count > 1 {
                HStack {
                    arrow("chevron.left") { heroIndex = (i - 1 + items.count) % items.count }
                    Spacer()
                    arrow("chevron.right") { heroIndex = (i + 1) % items.count }
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { k in
                        Capsule().fill(k == i ? Theme.sand : Color.white.opacity(0.3)).frame(width: k == i ? 20 : 6, height: 6)
                            .onTapGesture { withAnimation { heroIndex = k } }
                    }
                }
                .padding(26)
            }
        }
        .frame(height: 540)
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.5), value: i)
    }

    private func arrow(_ icon: String, _ go: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.4)) { go() } } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.cream)
                .frame(width: 34, height: 34).background(Circle().fill(Color.black.opacity(0.45)))
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var welcome: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Theme.navy, Theme.charcoal], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 12) {
                DisplayTitle(text: "Welcome to AutoClip", size: 30)
                Text("Turn a sermon into reels, make a podcast, or get feedback on your delivery.")
                    .font(.system(size: 14)).foregroundColor(Theme.text.opacity(0.8))
                HStack(spacing: 10) {
                    Button { HomeNav.shared.open(.autoReels) } label: { Label("Make reels", systemImage: "play.rectangle.on.rectangle.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { HomeNav.shared.open(.podcast) } label: { Label("Start a podcast", systemImage: "mic.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(36)
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 32)
    }

    // MARK: Rows

    /// Quick starts, as colour tiles in the fabric palette.
    private var startRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            rowTitle("Start something", count: nil, action: nil)
            HStack(spacing: 12) {
                StartTile(title: "Reels", subtitle: "Shorts from a sermon", icon: "play.rectangle.on.rectangle.fill", color: Theme.terracotta) { HomeNav.shared.open(.autoReels) }
                StartTile(title: "Podcast", subtitle: "Edit an episode", icon: "mic.and.signal.meter.fill", color: Theme.navy) { HomeNav.shared.open(.podcast) }
                StartTile(title: "Assess", subtitle: "Feedback on delivery", icon: "waveform.badge.magnifyingglass", color: Theme.olive) { HomeNav.shared.open(.assess) }
                StartTile(title: "Search", subtitle: "Find any moment", icon: "magnifyingglass", color: Theme.charcoal) { HomeNav.shared.open(.search) }
            }
            .padding(.horizontal, 32)
        }
    }

    private func rowTitle(_ title: String, count: Int?, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
            if let count { Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.faint) }
            Spacer()
            if let action {
                Button(action: action.1) {
                    HStack(spacing: 4) { Text(action.0); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                        .font(.system(size: 12, weight: .medium)).foregroundColor(Theme.sand)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 32)
    }

    private func row<Content: View>(_ title: String, count: Int, action: (String, () -> Void)?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            rowTitle(title, count: count, action: action)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal, 32).padding(.vertical, 6)
            }
        }
    }

    private func time(_ s: Double) -> String { PodcastExports.stamp(s) }
}

// MARK: - Cards

/// A tall 9:16 card, like a film poster, with its title on the picture.
struct PosterCard: View {
    let path: String
    let title: String
    let meta: String
    var badge: String?
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                ReelThumbnailView(path: path, faceAspect: 200 / 340).frame(width: 200, height: 340).clipped()
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(2)
                    Text(meta).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7)).lineLimit(1)
                }
                .padding(12)
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.cream)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
                }
                if hover { playBadge }
            }
            .frame(width: 200, height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hover ? Color.white.opacity(0.75) : Color.white.opacity(0.08), lineWidth: hover ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.55 : 0.3), radius: hover ? 18 : 8, y: 6)
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var playBadge: some View {
        Image(systemName: "play.fill").font(.system(size: 18)).foregroundColor(Theme.bg)
            .frame(width: 48, height: 48).background(Circle().fill(Color.white.opacity(0.92)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A wide 16:9 card with its title on the picture, and an optional "how much is left after the
/// edit" bar, like Continue Watching.
struct WideCard: View {
    let path: String?
    let icon: String
    let title: String
    let meta: String
    let progress: Double?
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                if let path { ReelThumbnailView(path: path).frame(width: 340, height: 192).clipped() }
                else {
                    LinearGradient(colors: [Theme.navy, Theme.charcoal], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: icon).font(.system(size: 40)).foregroundColor(Theme.sand.opacity(0.5)))
                }
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(meta).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7)).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.bottom, progress == nil ? 11 : 15)
                if let progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.18))
                            Rectangle().fill(Theme.terracottaLight).frame(width: g.size.width * min(1, max(0, progress)))
                        }
                    }
                    .frame(height: 3)
                }
                if hover {
                    Image(systemName: "play.fill").font(.system(size: 16)).foregroundColor(Theme.bg)
                        .frame(width: 44, height: 44).background(Circle().fill(Color.white.opacity(0.92)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 340, height: 192)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(hover ? Color.white.opacity(0.75) : Color.white.opacity(0.08), lineWidth: hover ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.55 : 0.3), radius: hover ? 18 : 8, y: 6)
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A colour tile for starting something, like a genre tile.
struct StartTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(Theme.cream)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.display(17, weight: .medium)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.muted)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundColor(hover ? Theme.sand : Theme.faint)
            }
            .padding(.horizontal, 16)
            .frame(height: 84).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(hover ? 0.22 : 0.09), lineWidth: 1))
            .contentShape(Rectangle())
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
