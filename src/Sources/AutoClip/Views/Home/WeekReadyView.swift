import SwiftUI
import AppKit

/// Remembers that a message has finished being made, so Home can show "Your week is ready" once.
@MainActor
final class WeekReady: ObservableObject {
    static let shared = WeekReady()
    /// The message whose week is on screen
    @Published var showing: Showing?
    struct Showing: Identifiable { var id: UUID }

    private static let key = "week_ready_pending"
    private var pending: UUID? {
        get { UserDefaults.standard.string(forKey: Self.key).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.key) }
    }

    /// Called when a message's clips are ready. Shown when its graphics (if any are on the way) are done too.
    func note(_ rec: AutoReelRecord) {
        guard !SampleSermon.isSample(path: rec.sourceVideoPath ?? "") else { return }
        pending = rec.id
        presentIfReady()
    }

    /// Shows the waiting reveal once nothing is still being made for it.
    func presentIfReady() {
        guard showing == nil, let id = pending, !CarouselJobs.shared.running(id),
              AutoReelsStore.shared.reels.contains(where: { $0.id == id }) else { return }
        pending = nil
        showing = Showing(id: id)
    }

    /// Opened by hand from Home.
    func show(_ id: UUID) { showing = Showing(id: id) }
}

/// The week laid out by day: the strongest clips first, the carousel mid-week, the invite on Saturday.
struct WeekReadyView: View {
    let recordID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduce
    @ObservedObject private var reels = AutoReelsStore.shared
    @ObservedObject private var jobs = CarouselJobs.shared
    @StateObject private var photos = CarouselPhotoCache()
    @State private var carousel: SermonCarousel?
    @State private var dealt = 0
    @State private var confirmGraphics = false

    private var record: AutoReelRecord? { reels.reels.first { $0.id == recordID } }
    private static let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private struct Day: Identifiable {
        var id: String { name }
        var name: String
        var clip: ReelDraft?
        /// -1 is the carousel; otherwise a post's place in the list
        var graphic: Int?
    }

    private var plan: [Day] {
        let clips = (record?.drafts ?? []).sorted { ClipStrength.score($0) > ClipStrength.score($1) }
        var posts = Array((carousel?.postList ?? []).indices)
        let invite = carousel?.postList.firstIndex { $0.kind == .invite }
        if let invite { posts.removeAll { $0 == invite } }
        func next() -> Int? { posts.isEmpty ? nil : posts.removeFirst() }
        let hasCarousel = !(carousel?.slides.isEmpty ?? true)
        return Self.days.enumerated().map { i, name in
            let g: Int? = name == "Wednesday" && hasCarousel ? -1 : name == "Saturday" ? (invite ?? next()) : next()
            return Day(name: name, clip: i < clips.count ? clips[i] : nil, graphic: g)
        }
    }

    var body: some View {
        let days = plan
        let clipCount = record?.drafts?.count ?? 0
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                ZStack {
                    if dealt > 0 { CelebrationBurst(size: 40) }
                }
                .frame(height: 44)
                Text("Your week is ready").font(Theme.display(34, weight: .medium)).foregroundColor(Theme.cream)
                Text(record?.title ?? "").font(.ui(size: 14)).foregroundColor(Theme.muted).lineLimit(1)
                Text(summary(clipCount)).font(.ui(size: 12.5, weight: .semibold)).foregroundColor(Theme.sand)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                    dayColumn(d)
                        .opacity(dealt > i ? 1 : 0)
                        .offset(y: dealt > i || reduce ? 0 : 36)
                        .rotationEffect(.degrees(dealt > i || reduce ? 0 : (i % 2 == 0 ? -5 : 5)))
                        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: dealt)
                }
            }

            if carousel == nil {
                HStack(spacing: 10) {
                    if jobs.running(recordID) {
                        ProgressView().controlSize(.small)
                        Text(jobs.status[recordID] ?? "Writing the graphics…").font(.ui(size: 12.5)).foregroundColor(Theme.muted)
                    } else {
                        Text("No graphics yet for this message.").font(.ui(size: 12.5)).foregroundColor(Theme.muted)
                        Button { confirmGraphics = true } label: { Label("Make the carousel and posts", systemImage: "sparkles") }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Later") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button { open(.clips, review: true) } label: { Label("Review the clips", systemImage: "rectangle.stack") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Go through the clips one at a time and keep the ones you like")
                Button { open(.clips, review: false) } label: { Label("Open the message", systemImage: "arrow.right") }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 1020)
        .background(Theme.bg)
        .appLook()
        .onAppear {
            carousel = CarouselStore.load(recordID)
            deal()
        }
        .onReceive(NotificationCenter.default.publisher(for: CarouselStore.changed)) { n in
            if (n.object as? UUID) == recordID { carousel = CarouselStore.load(recordID) }
        }
        .task(id: carousel?.postList.count ?? -1) {
            guard let c = carousel else { return }
            if let s = c.slides.first { await photos.ensure(s, c) }
            for i in c.postList.indices { let p = c.post(i); await photos.ensure(p.slides[0], p) }
        }
        .alert("Make this message's graphics?", isPresented: $confirmGraphics) {
            Button("Make them") { if let r = record { jobs.make(r) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI writes a carousel and a week of posts. Uses \(AICost.phrase()).")
        }
    }

    private func summary(_ clips: Int) -> String {
        var parts = ["\(clips) clip\(clips == 1 ? "" : "s")"]
        if let c = carousel {
            if !c.slides.isEmpty { parts.append("a carousel") }
            if !c.postList.isEmpty { parts.append("\(c.postList.count) posts") }
        }
        let captioned = (record?.drafts ?? []).filter { $0.seo != nil }.count
        if captioned > 0 { parts.append("\(captioned) captions") }
        return parts.joined(separator: " · ")
    }

    /// Deals the days in one after another.
    private func deal() {
        guard dealt == 0 else { return }
        if reduce { dealt = Self.days.count; return }
        for i in 1...Self.days.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(i) * 0.11) { dealt = i }
        }
    }

    private func dayColumn(_ d: Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(d.name.uppercased()).font(.ui(size: 11, weight: .semibold)).tracking(1.2).foregroundColor(Theme.sand)
            if let clip = d.clip {
                VStack(alignment: .leading, spacing: 4) {
                    ScrubThumb(draft: clip, path: clip.pieces.first?.sourceVideoPath ?? "", faceAspect: 9 / 16)
                        .frame(width: 140, height: 249).clipShape(RoundedRectangle(cornerRadius: 9))
                        .environment(\.colorScheme, .dark)
                        .overlay(alignment: .topLeading) {
                            Label("Clip", systemImage: "play.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.55))).padding(6)
                        }
                        .hoverLift()
                        .onTapGesture { open(.clips, review: false) }
                    Text(clip.title).font(.ui(size: 11.5, weight: .medium)).foregroundColor(Theme.ink).lineLimit(2)
                        .frame(width: 140, alignment: .leading)
                }
            } else {
                RoundedRectangle(cornerRadius: 9).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .frame(width: 140, height: 120)
                    .overlay(Text("No clip").font(.ui(size: 11.5)).foregroundColor(Theme.faint))
            }
            if let g = d.graphic, let c = carousel {
                let pc: SermonCarousel = g == -1 ? c : c.post(g)
                VStack(alignment: .leading, spacing: 4) {
                    ScaledSlide(carousel: pc, index: 0, images: photos.images(pc.slides[0], pc), scale: 140 / pc.shape.size.width)
                        .drawingGroup().clipShape(RoundedRectangle(cornerRadius: 7))
                        .hoverLift()
                        .onTapGesture { open(.graphics, review: false) }
                    Text(g == -1 ? "Carousel" : c.postList[g].kind.label).font(.ui(size: 11)).foregroundColor(Theme.muted)
                }
            }
        }
        .frame(width: 140, alignment: .topLeading)
    }

    private func open(_ pane: MessagePane, review: Bool) {
        UserDefaults.standard.set(pane.rawValue, forKey: "message_pane")
        if review { AutoReelsStore.shared.reviewOnOpen = recordID }
        openWindow(id: "reel-window", value: recordID)
        dismiss()
    }
}
