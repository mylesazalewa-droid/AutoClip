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
                               date: Date(timeIntervalSince1970: r.dateCreated), thumb: r.path,
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
            VStack(alignment: .leading, spacing: 30) {
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
            .padding(.top, 20)
        }
        .background(Theme.bg)
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
        return ZStack(alignment: .bottomLeading) {
            Group {
                if item.thumb.isEmpty {
                    LinearGradient(colors: [Theme.navy, Theme.olive.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "mic.and.signal.meter.fill").font(.system(size: 120)).foregroundColor(Theme.sand.opacity(0.12)).offset(x: 220))
                } else {
                    // A soft, dimmed backdrop from the same picture
                    ReelThumbnailView(path: item.thumb).blur(radius: 40).opacity(0.55)
                }
            }
            .frame(height: 340).frame(maxWidth: .infinity).clipped()
            .id(item.id)
            .transition(.opacity)
            // Shade so the words read over any picture
            LinearGradient(colors: [Theme.bg.opacity(0.95), Theme.bg.opacity(0.55), Theme.bg.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, Theme.bg.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            // The picture itself, at its real shape
            if !item.thumb.isEmpty {
                ReelThumbnailView(path: item.thumb)
                    .frame(width: item.tall ? 160 : 460, height: item.tall ? 284 : 259).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 70)
                    .id("pic" + item.id)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "diamond.fill").font(.system(size: 6)).foregroundColor(Theme.sand)
                    Text(item.kind.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
                    Text("· \(item.date.formatted(.relative(presentation: .named)))").font(.system(size: 10)).foregroundColor(Theme.muted)
                }
                Text(item.title.uppercased())
                    .font(Theme.display(38)).tracking(3).foregroundColor(Theme.cream)
                    .lineLimit(2).frame(maxWidth: 520, alignment: .leading)
                Text(item.detail).font(.system(size: 13)).foregroundColor(Theme.text.opacity(0.8))
                HStack(spacing: 10) {
                    Button(action: item.open) { Label("Open", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.thumb)]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(item.thumb.isEmpty)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 36).padding(.leading, 64).padding(.trailing, 36)

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
                        Capsule().fill(k == i ? Theme.sand : Color.white.opacity(0.25)).frame(width: k == i ? 18 : 6, height: 6)
                            .onTapGesture { withAnimation { heroIndex = k } }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(24)
            }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .padding(.horizontal, 28)
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
        .padding(.horizontal, 28)
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
            .padding(.horizontal, 28)
        }
    }

    private func rowTitle(_ title: String, count: Int?, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.display(20, weight: .medium)).foregroundColor(Theme.cream)
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
        .padding(.horizontal, 28)
    }

    private func row<Content: View>(_ title: String, count: Int, action: (String, () -> Void)?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            rowTitle(title, count: count, action: action)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal, 28).padding(.vertical, 6)
            }
        }
    }

    private func time(_ s: Double) -> String { PodcastExports.stamp(s) }
}

// MARK: - Cards

/// A tall 9:16 card, like a film poster.
struct PosterCard: View {
    let path: String
    let title: String
    let meta: String
    var badge: String?
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topLeading) {
                    ReelThumbnailView(path: path).frame(width: 150, height: 250).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    if let badge {
                        Text(badge).font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.cream)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.55))).padding(8)
                    }
                    if hover {
                        Image(systemName: "play.fill").font(.system(size: 18)).foregroundColor(Theme.cream)
                            .frame(width: 44, height: 44).background(Circle().fill(Theme.terracotta.opacity(0.9)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 150, height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(hover ? Theme.sand.opacity(0.7) : Theme.line, lineWidth: hover ? 1.5 : 1))
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1).frame(width: 150, alignment: .leading)
                Text(meta).font(.system(size: 10)).foregroundColor(Theme.muted).lineLimit(1)
            }
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A wide 16:9 card with an optional "how much is left after the edit" bar, like Continue Watching.
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
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .bottomLeading) {
                    if let path { ReelThumbnailView(path: path).frame(width: 250, height: 140).clipped() }
                    else {
                        LinearGradient(colors: [Theme.navy, Theme.charcoal], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: icon).font(.system(size: 34)).foregroundColor(Theme.sand.opacity(0.35)))
                    }
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
                        Image(systemName: "play.fill").font(.system(size: 16)).foregroundColor(Theme.cream)
                            .frame(width: 40, height: 40).background(Circle().fill(Theme.terracotta.opacity(0.9)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 250, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(hover ? Theme.sand.opacity(0.7) : Theme.line, lineWidth: hover ? 1.5 : 1))
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 9)).foregroundColor(Theme.sand)
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1)
                }
                .frame(width: 250, alignment: .leading)
                Text(meta).font(.system(size: 10)).foregroundColor(Theme.muted).lineLimit(1)
            }
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
            ZStack(alignment: .leading) {
                LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon).font(.system(size: 54)).foregroundColor(Color.white.opacity(0.08))
                    .frame(maxWidth: .infinity, alignment: .trailing).offset(x: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased()).font(Theme.display(17)).tracking(2.5).foregroundColor(Theme.cream)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(Theme.cream.opacity(0.7))
                }
                .padding(.horizontal, 18)
            }
            .frame(height: 84).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(hover ? 0.25 : 0.08), lineWidth: 1))
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
