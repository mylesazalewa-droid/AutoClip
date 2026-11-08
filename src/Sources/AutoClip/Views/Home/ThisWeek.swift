import SwiftUI
import AppKit

/// The top of Home: this week's sermon, where it's up to, and the one thing to do next.
struct ThisWeekCard: View {
    @ObservedObject private var reels = AutoReelsStore.shared
    @ObservedObject private var results = ShortResultsStore.shared
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var jobs = CarouselJobs.shared
    @State private var flagged = 0
    @State private var graphics: SermonCarousel?
    @State private var confirmGraphics = false
    @AppStorage(OneClickSunday.key) private var autoGraphics = false

    private var latest: AutoReelRecord? {
        reels.reels.first { !($0.drafts ?? []).isEmpty && !SampleSermon.isSample(path: $0.sourceVideoPath ?? "") }
    }
    private var drafts: [ReelDraft] { latest?.drafts ?? [] }
    private var exported: [ReelDraft] { drafts.filter { $0.exportedPath != nil } }
    private var postedPaths: Set<String> { Set(results.shorts.compactMap(\.videoPath)) }
    private var nextToPost: ReelDraft? { exported.first { !postedPaths.contains($0.exportedPath ?? "") && FileManager.default.fileExists(atPath: $0.exportedPath ?? "") } }
    private var reviewed: Bool { latest.map { UserDefaults.standard.bool(forKey: AutoReelsStore.reviewedKey($0.id)) } ?? false }

    private var weekLabel: String {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let end = cal.date(byAdding: .day, value: 6, to: start) ?? Date()
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("This week").font(Theme.display(30, weight: .medium)).foregroundColor(Theme.cream)
                Text(weekLabel).font(.system(size: 13)).foregroundColor(Theme.muted)
                Spacer()
            }
            if let rec = latest { sermon(rec) } else { start }
        }
        .padding(.horizontal, 32)
        .task(id: latest?.id) { graphics = latest.flatMap { CarouselStore.load($0.id) } }
        .onReceive(NotificationCenter.default.publisher(for: CarouselStore.changed)) { n in
            if let id = n.object as? UUID, id == latest?.id { graphics = CarouselStore.load(id) }
        }
        .alert("Make this sermon's social graphics?", isPresented: $confirmGraphics) {
            Button("Make them") { if let r = latest { jobs.make(r) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI writes a carousel and a week of posts, and the posting plan is set. Uses one AI request. You can keep working while it's made.")
        }
        .task(id: drafts.map(\.id)) {
            let ds = drafts
            flagged = await Task.detached(priority: .utility) { ds.filter { ContextGuard.quick($0).contains(where: \.serious) }.count }.value
        }
    }

    private var start: some View {
        HStack(spacing: 18) {
            LogoMark(size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add this week's sermon").font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
                Text("AutoClip finds the moments worth sharing and has clips ready to review.").font(.system(size: 13)).foregroundColor(Theme.muted)
            }
            Spacer()
            Button { reels.requestNewReel = true; HomeNav.shared.open(.autoReels) } label: { Label("Choose a sermon", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
    }

    private func sermon(_ rec: AutoReelRecord) -> some View {
        HStack(alignment: .top, spacing: 20) {
            ScrubThumb(draft: drafts.first, path: rec.sourceVideoPath ?? rec.path, faceAspect: 9 / 16)
                .frame(width: 120, height: 213)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .environment(\.colorScheme, .dark)
                .onTapGesture { openWindow(id: "reel-window", value: rec.id) }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rec.title).font(Theme.display(24, weight: .medium)).foregroundColor(Theme.cream).lineLimit(2)
                    Text("Added \(Date(timeIntervalSince1970: rec.dateCreated).formatted(.relative(presentation: .named)))").font(.system(size: 12)).foregroundColor(Theme.muted)
                }
                HStack(spacing: 8) {
                    chip("\(drafts.count) clip\(drafts.count == 1 ? "" : "s")", icon: "film", color: Theme.sand)
                    chip("\(exported.count) exported", icon: "square.and.arrow.up", color: exported.isEmpty ? Theme.muted : Theme.good)
                    if flagged > 0 { chip("\(flagged) to double-check", icon: "exclamationmark.shield", color: Theme.warn) }
                    let posted = exported.filter { postedPaths.contains($0.exportedPath ?? "") }.count
                    if posted > 0 { chip("\(posted) posted", icon: "checkmark.circle", color: Theme.good) }
                }
                nextStep(rec)
                sundayChecklist(rec)
                if let p = nextToPost, let path = p.exportedPath {
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane").foregroundColor(Theme.sand)
                        Text("Ready to post: \(p.title)").font(.system(size: 13)).foregroundColor(Theme.text).lineLimit(1)
                        Spacer(minLength: 8)
                        if ShareOut.canAirDrop {
                            Button { ShareOut.airDrop(path) } label: { Label("Send to iPhone", systemImage: "iphone.and.arrow.forward") }.controlSize(.small)
                        }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Label("Show in Finder", systemImage: "folder") }.controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink.opacity(0.04)))
                    .draggableClip(path)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
    }

    @ViewBuilder private func nextStep(_ rec: AutoReelRecord) -> some View {
        HStack(spacing: 10) {
            if !reviewed && exported.isEmpty {
                Button { reels.reviewOnOpen = rec.id; openWindow(id: "reel-window", value: rec.id) } label: { Label("Review the clips", systemImage: "rectangle.stack") }
                    .buttonStyle(PrimaryButtonStyle())
                Text("Keep or toss each one with the arrow keys.").font(.system(size: 12)).foregroundColor(Theme.muted)
            } else if exported.isEmpty {
                Button { openWindow(id: "reel-window", value: rec.id) } label: { Label("Polish and export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle())
            } else if nextToPost == nil && !exported.isEmpty {
                Button { HomeNav.shared.open(.results) } label: { Label("Add how they did", systemImage: "chart.line.uptrend.xyaxis") }
                    .buttonStyle(PrimaryButtonStyle())
                Text("AutoClip learns what works for your church.").font(.system(size: 12)).foregroundColor(Theme.muted)
            } else {
                Button { openWindow(id: "reel-window", value: rec.id) } label: { Label("Open the clips", systemImage: "film") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { HomeNav.shared.open(.results) } label: { Text("Add results") }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    /// Sunday's three jobs, and where each one is up to.
    private func sundayChecklist(_ rec: AutoReelRecord) -> some View {
        let running = jobs.running(rec.id)
        let posts = graphics?.postList.count ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                step("Clips", detail: "\(drafts.count) ready", state: drafts.isEmpty ? .todo : .done)
                step("Carousel and posts",
                     detail: running ? (jobs.status[rec.id] ?? "Being made…") : graphics.map { "\($0.slides.count) slides · \(posts) posts" } ?? "Not made yet",
                     state: running ? .working : graphics != nil ? .done : .todo)
                step("Week plan", detail: posts > 0 ? "Ready to post" : "After the posts", state: posts > 0 ? .done : running ? .working : .todo)
                Spacer(minLength: 0)
                if graphics != nil {
                    Button { HomeNav.shared.open(.social) } label: { Label("Open Social Graphics", systemImage: "rectangle.split.3x1") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                } else if !running {
                    Button { confirmGraphics = true } label: { Label("Make them", systemImage: "sparkles") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            if let e = jobs.errors[rec.id] {
                Text(e).font(.system(size: 12)).foregroundColor(Theme.danger).lineLimit(2)
            }
            if !autoGraphics {
                Button { autoGraphics = true } label: {
                    Label("Make these automatically for every sermon", systemImage: "wand.and.stars")
                }
                .buttonStyle(.link).font(.system(size: 12))
                .help("One-click Sunday: when a sermon's clips are ready, the carousel, posts and plan are made too (one more AI request per sermon). Turn off in Settings → Clips.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink.opacity(0.04)))
    }

    private enum StepState { case todo, working, done }

    private func step(_ title: String, detail: String, state: StepState) -> some View {
        HStack(spacing: 8) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.good)
                case .working: ProgressView().controlSize(.small)
                case .todo: Image(systemName: "circle").foregroundColor(Theme.faint)
                }
            }
            .font(.system(size: 15)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.ink)
                Text(detail).font(.system(size: 11.5)).foregroundColor(Theme.muted).lineLimit(1)
            }
        }
    }

    private func chip(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
