import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Every sermon's carousel, quote cards and thumbnail in one place, including ones the AI is
/// still writing. Click any of them to edit.
struct SocialGraphicsTab: View {
    @ObservedObject private var reels = AutoReelsStore.shared
    @ObservedObject private var jobs = CarouselJobs.shared
    @StateObject private var photos = CarouselPhotoCache()
    @Environment(\.openWindow) private var openWindow
    @State private var carousels: [UUID: SermonCarousel] = [:]
    @State private var graphicsFor: AutoReelRecord?
    @State private var confirmMake: AutoReelRecord?
    @State private var hoveredPost: UUID?
    @State private var copiedDay: String?
    @State private var dropping = false
    @State private var confirmDelete: AutoReelRecord?
    @State private var reviewFor: AutoReelRecord?
    @ObservedObject private var reviews = ReviewStore.shared
    @AppStorage("social_hidden") private var hiddenRaw = ""
    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }
    private var preparing: [AutoReelJob] { reels.activeJobs.filter { !$0.isFinished } }

    private var sermons: [AutoReelRecord] { reels.reels.filter { ReelGenerator.sourceVideoPath(for: $0) != nil } }
    private var working: [AutoReelRecord] { sermons.filter { jobs.running($0.id) } }
    private var made: [AutoReelRecord] {
        sermons.filter { carousels[$0.id] != nil && !jobs.running($0.id) }
            .sorted { (carousels[$0.id]?.made ?? .distantPast) > (carousels[$1.id]?.made ?? .distantPast) }
    }
    private var notYet: [AutoReelRecord] {
        sermons.filter { carousels[$0.id] == nil && !jobs.running($0.id) && !hidden.contains($0.id.uuidString) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Create", title: "Social Graphics",
                       subtitle: "Carousels and a week of posts from every sermon. Click any one to edit it.") {
                Button(action: addSermon) { Label("Add a sermon", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .help("Choose a sermon video, or just the audio if there's no video")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if sermons.isEmpty && preparing.isEmpty { empty }
                    if !preparing.isEmpty {
                        group("Getting the sermon ready", count: preparing.count) {
                            VStack(spacing: 8) { ForEach(preparing) { preparingRow($0) } }
                        }
                    }
                    if !working.isEmpty {
                        group("Being made", count: working.count) {
                            grid { ForEach(working) { workingCard($0) } }
                        }
                    }
                    weekPlan
                    if !made.isEmpty {
                        group("By message", count: made.count) {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(made.enumerated()), id: \.element.id) { n, rec in
                                    if let c = carousels[rec.id] { messageSection(rec, c, position: n) }
                                }
                            }
                        }
                    }
                    if !notYet.isEmpty {
                        group(made.isEmpty && working.isEmpty ? "Your sermons" : "No graphics yet", count: notYet.count) {
                            VStack(spacing: 8) { ForEach(notYet) { row($0) } }
                        }
                    }
                    let removed = sermons.filter { carousels[$0.id] == nil && hidden.contains($0.id.uuidString) }.count
                    if removed > 0 {
                        Button { hiddenRaw = "" } label: {
                            Label("Show \(removed) removed sermon\(removed == 1 ? "" : "s")", systemImage: "eye")
                        }
                        .buttonStyle(ThemedLinkStyle()).font(.ui(size: 12))
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 40)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.sand, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.sand.opacity(0.06)))
                    .overlay(Label("Drop a sermon video or audio file", systemImage: "waveform").font(.ui(size: 15, weight: .semibold)).foregroundColor(Theme.sand))
                    .padding(16).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { start(url) }
                }
            }
            return true
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CarouselStore.changed)) { n in
            if let id = n.object as? UUID { carousels[id] = CarouselStore.load(id) }
        }
        .onChange(of: jobs.finished) { _, _ in reload() }
        .task(id: previewKeys) { await loadPreviews() }
        .sheet(item: $graphicsFor) { SocialGraphicsView(record: $0, gold: Theme.sand) }
        .sheet(item: $reviewFor) { ReviewSendSheet(record: $0) }
        .alert("Delete this carousel and its posts?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let r = confirmDelete { CarouselStore.delete(r.id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("The sermon and its clips stay. Its carousel and posts go to the Trash, and you can make new ones any time.")
        }
        .alert("Make this sermon's graphics?", isPresented: Binding(get: { confirmMake != nil }, set: { if !$0 { confirmMake = nil } })) {
            Button("Make it") { if let r = confirmMake { jobs.make(r) }; confirmMake = nil }
            Button("Cancel", role: .cancel) { confirmMake = nil }
        } message: {
            Text("AI reads the whole sermon and writes a carousel and a week of single posts. Uses \(AICost.phrase()). You can keep working while they're made.")
        }
    }

    private var allPosts: [(rec: AutoReelRecord, c: SermonCarousel, index: Int, post: SermonCarousel.Slide)] {
        made.flatMap { rec -> [(rec: AutoReelRecord, c: SermonCarousel, index: Int, post: SermonCarousel.Slide)] in
            guard let c = carousels[rec.id] else { return [] }
            return c.postList.enumerated().map { (rec, c, $0.offset, $0.element) }
        }
    }

    private func open(_ rec: AutoReelRecord, posts: Bool, index: Int) {
        CarouselNav.pending[rec.id] = (posts, index)
        openWindow(id: "carousel-window", value: rec.id)
    }

    private func postTile(_ rec: AutoReelRecord, _ c: SermonCarousel, _ i: Int) -> some View {
        let p = c.post(i)
        let size = p.shape.size
        let w: CGFloat = 170
        return VStack(alignment: .leading, spacing: 6) {
            ScaledSlide(carousel: p, index: 0, images: photos.images(p.slides[0], p), scale: w / size.width)
                .drawingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            Text("\(i + 1). " + c.postList[i].kind.label).font(.ui(size: 11.5)).foregroundColor(Theme.muted).lineLimit(1)
        }
        .frame(width: w)
        .overlay(alignment: .topLeading) {
            if let r = reviews.latest(c.postList[i].id, kind: .post) { ReviewBadge(item: r).padding(6) }
        }
        .contentShape(Rectangle())
        .hoverLift()
        .onTapGesture { open(rec, posts: true, index: i) }
        .help("Open and edit this post")
        .overlay(alignment: .topTrailing) {
            Button { deletePost(rec, c.postList[i].id) } label: {
                Image(systemName: "trash").font(.ui(size: 11, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(hoveredPost == c.postList[i].id ? Theme.danger : Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain).padding(6).help("Delete this post")
        }
        .onHover { h in hoveredPost = h ? c.postList[i].id : (hoveredPost == c.postList[i].id ? nil : hoveredPost) }
        .contextMenu {
            Button("Edit") { open(rec, posts: true, index: i) }
            Button("Copy caption") { copy(c.postList[i].caption ?? "") }
            Button("Send for review…") { reviewFor = rec }
            Divider()
            Button("Delete post", role: .destructive) { deletePost(rec, c.postList[i].id) }
        }
    }

    private func deletePost(_ rec: AutoReelRecord, _ id: UUID) {
        guard var c = CarouselStore.load(rec.id) else { return }
        c.postList.removeAll { $0.id == id }
        CarouselStore.save(c, for: rec.id)
    }

    private func hide(_ rec: AutoReelRecord) {
        hiddenRaw = (hidden.union([rec.id.uuidString])).sorted().joined(separator: ",")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: By message

    @AppStorage("social_open") private var openRaw = ""
    @AppStorage("social_closed") private var closedRaw = ""

    /// The two newest messages start open; the rest fold away until clicked.
    private func isOpen(_ rec: AutoReelRecord, position: Int) -> Bool {
        let id = rec.id.uuidString
        if openRaw.contains(id) { return true }
        if closedRaw.contains(id) { return false }
        return position < 2
    }

    private func setOpen(_ rec: AutoReelRecord, _ on: Bool) {
        let id = rec.id.uuidString
        var open = Set(openRaw.split(separator: ",").map(String.init)), closed = Set(closedRaw.split(separator: ",").map(String.init))
        if on { open.insert(id); closed.remove(id) } else { closed.insert(id); open.remove(id) }
        openRaw = open.sorted().joined(separator: ","); closedRaw = closed.sorted().joined(separator: ",")
    }

    private func messageSection(_ rec: AutoReelRecord, _ c: SermonCarousel, position: Int) -> some View {
        let open = isOpen(rec, position: position)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { setOpen(rec, !open) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.ui(size: 12, weight: .bold)).foregroundColor(Theme.sand)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        if !open, let first = c.slides.first {
                            ScaledSlide(carousel: c, index: 0, images: photos.images(first, c), scale: 44 / c.shape.size.height)
                                .drawingGroup().clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.title).font(Theme.display(18, weight: .medium)).foregroundColor(Theme.cream).lineLimit(1)
                            Text("\(Date(timeIntervalSince1970: rec.dateCreated).formatted(date: .abbreviated, time: .omitted)) · \(rec.drafts?.count ?? 0) clips · \(c.slides.count) slides · \(c.postList.count) posts")
                                .font(.ui(size: 12)).foregroundColor(Theme.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let r = reviews.latest(rec.id, kind: .carousel) { ReviewBadge(item: r) }
                Spacer(minLength: 8)
                Button { openWindow(id: "reel-window", value: rec.id) } label: {
                    Label("Open message", systemImage: "rectangle.stack").lineLimit(1).fixedSize()
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("This message's clips, graphics and captions together")
            }
            if open {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 14) {
                        carouselCard(rec, c).frame(width: 340)
                        ForEach(Array(c.postList.indices), id: \.self) { i in postTile(rec, c, i) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface.opacity(open ? 1 : 0.6)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
    }

    // MARK: This week's plan

    /// A simple week for the newest sermon: a post most days, the carousel mid-week, the invite on Saturday.
    private var plan: (rec: AutoReelRecord, c: SermonCarousel, days: [(day: String, post: Int?)])? {
        guard let rec = made.first(where: { !(carousels[$0.id]?.postList.isEmpty ?? true) }), let c = carousels[rec.id] else { return nil }
        var rest = Array(c.postList.indices)
        let invite = c.postList.firstIndex { $0.kind == .invite }
        if let invite { rest.removeAll { $0 == invite } }
        func next() -> Int? { rest.isEmpty ? nil : rest.removeFirst() }
        let days: [(String, Int?)] = [("Monday", next()), ("Tuesday", next()), ("Wednesday", -1), ("Thursday", next()),
                                      ("Friday", next()), ("Saturday", invite ?? next())]
        return (rec, c, days.filter { $0.1 != nil }.map { (day: $0.0, post: $0.1) })
    }

    @ViewBuilder private var weekPlan: some View {
        if let p = plan {
            group("This week's plan", count: p.days.count) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(p.days, id: \.day) { d in
                            let isCarousel = d.post == -1
                            let pc: SermonCarousel = isCarousel ? p.c : p.c.post(d.post!)
                            let caption = isCarousel ? p.c.captionWithTags : (p.c.postList[d.post!].caption ?? "")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(d.day).font(.ui(size: 12, weight: .semibold)).foregroundColor(Theme.sand)
                                ScaledSlide(carousel: pc, index: 0, images: photos.images(pc.slides[0], pc), scale: 150 / pc.shape.size.width)
                                    .drawingGroup().clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onTapGesture { open(p.rec, posts: !isCarousel, index: isCarousel ? 0 : d.post!) }
                                Text(isCarousel ? "Carousel" : p.c.postList[d.post!].kind.label).font(.ui(size: 11)).foregroundColor(Theme.muted)
                                Button { copy(caption); copiedDay = d.day } label: {
                                    Label(copiedDay == d.day ? "Copied" : "Copy caption", systemImage: copiedDay == d.day ? "checkmark" : "doc.on.doc")
                                        .lineLimit(1).fixedSize()
                                }
                                .buttonStyle(ThemedLinkStyle()).font(.ui(size: 11.5))
                                if let i = d.post, i >= 0 {
                                    Button { deletePost(p.rec, p.c.postList[i].id) } label: { Label("Delete", systemImage: "trash").lineLimit(1).fixedSize() }
                                        .buttonStyle(ThemedLinkStyle(color: Theme.danger)).font(.ui(size: 11.5))
                                        .help("Delete this post")
                                }
                            }
                            .frame(width: 150)
                        }
                    }
                }
                Text("From \(p.rec.title). Tap a day to edit it, copy its caption, then post.")
                    .font(.ui(size: 11.5)).foregroundColor(Theme.faint)
            }
        }
    }

    private func reload() {
        var out: [UUID: SermonCarousel] = [:]
        for r in sermons { if let c = CarouselStore.load(r.id) { out[r.id] = c } }
        carousels = out
    }

    // MARK: Previews

    private var previewKeys: [String] {
        made.prefix(24).flatMap { rec -> [String] in
            guard let c = carousels[rec.id] else { return [] }
            let slides = c.slides.prefix(3).flatMap { [photos.photoKey($0, c), photos.artKey($0, c), photos.rawKey($0, c)].compactMap { $0 } }
            let posts = c.postList.indices.flatMap { photos.keys(c.post($0)) }
            return slides + posts
        }
    }

    private func loadPreviews() async {
        for rec in made.prefix(24) {
            guard let c = carousels[rec.id] else { continue }
            for s in c.slides.prefix(3) { await photos.ensure(s, c) }
            for i in c.postList.indices { let p = c.post(i); await photos.ensure(p.slides[0], p) }
        }
    }

    // MARK: Layout

    private func group<V: View>(_ title: String, count: Int, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(title).font(Theme.display(20, weight: .medium)).foregroundColor(Theme.cream)
                Text("\(count)").font(.ui(size: 12, weight: .semibold)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.ink.opacity(0.07)))
            }
            content()
        }
    }

    private func grid<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 22, alignment: .top)], alignment: .leading, spacing: 22) {
            content()
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1").font(.ui(size: 34)).foregroundColor(Theme.sand)
            Text("Add a sermon first").font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
            Text("Choose the sermon video, or just the audio if there's no video (MP3, M4A, WAV). You can also drop it here.")
                .font(.ui(size: 13)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
            Button(action: addSermon) { Label("Choose a video or audio file", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    // MARK: Adding a sermon

    private static let mediaTypes: Set<String> = Set(["mp4", "mov", "m4v", "mkv", "avi", "webm"]).union(AudioSource.types)

    private func addSermon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent, .audio]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the sermon video, or the audio if there's no video"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url)
    }

    /// Transcribes the sermon (an audio file gets a simple waveform video first) and makes its clips.
    /// It then appears below, ready for graphics, or they're made by themselves with One-click Sunday.
    private func start(_ url: URL) {
        guard Self.mediaTypes.contains(url.pathExtension.lowercased()) else { return }
        Task { await AutoImport.shared.makeReelsNow(from: url) }
    }

    private func preparingRow(_ job: AutoReelJob) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.sand.opacity(0.12))
                Image(systemName: job.sourceVideoPath.map { AudioSource.isAudioFile(URL(fileURLWithPath: $0)) || AudioSource.isCompanion($0) } == true ? "waveform" : "video.fill")
                    .foregroundColor(Theme.sand)
            }
            .frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(.ui(size: 13.5, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                ProgressView(value: min(1, max(0, job.progress))).tint(Theme.sand)
                Text(job.statusMsg).font(.ui(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
    }

    // MARK: Cards

    private func carouselCard(_ rec: AutoReelRecord, _ c: SermonCarousel) -> some View {
        let size = c.shape.size
        let s: CGFloat = 250 / size.height
        return VStack(alignment: .leading, spacing: 12) {
            ZStack {
                // A fan of the first slides
                ForEach(Array([2, 1, 0].filter { $0 < c.slides.count }), id: \.self) { i in
                    ScaledSlide(carousel: c, index: i, images: photos.images(c.slides[i], c), scale: s)
                        .drawingGroup()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                        .rotationEffect(.degrees(Double(i) * 6))
                        .offset(x: CGFloat(i) * 46, y: CGFloat(i) * 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .contentShape(Rectangle())
            .onTapGesture { open(rec, posts: false, index: 0) }
            .help("Open and edit this carousel")
            .contextMenu {
                Button("Edit") { open(rec, posts: false, index: 0) }
                Button("Send for review…") { reviewFor = rec }
                Divider()
                Button("Delete carousel and posts…", role: .destructive) { confirmDelete = rec }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(rec.title).font(.ui(size: 14, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                    if let r = reviews.latest(rec.id, kind: .carousel) { ReviewBadge(item: r) }
                }
                Text("\(c.slides.count) slides · \(c.postList.count) posts · \(c.style.label)")
                    .font(.ui(size: 12)).foregroundColor(Theme.muted)
            }
            ViewThatFits(in: .horizontal) {
                cardButtons(rec, c, labels: true)
                cardButtons(rec, c, labels: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
    }

    /// The buttons under a carousel. Without labels when the card is too narrow, so they never spill onto the next card.
    @ViewBuilder
    private func cardButtons(_ rec: AutoReelRecord, _ c: SermonCarousel, labels: Bool) -> some View {
        HStack(spacing: 8) {
            Button { open(rec, posts: false, index: 0) } label: {
                Label("Edit", systemImage: "pencil").lineLimit(1).fixedSize()
            }
            .buttonStyle(PrimaryButtonStyle(compact: true))
            if c.postList.isEmpty {
                Button { jobs.makePosts(rec) } label: { cardLabel("Write posts", "sparkles", labels) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Write posts: a week of single posts from this sermon (uses \(AICost.phrase()))")
            }
            Button { graphicsFor = rec } label: { cardLabel("Thumbnail", "photo", labels) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Thumbnail: quote cards and a thumbnail for the full message video")
            Spacer(minLength: 0)
            Button { reviewFor = rec } label: { Image(systemName: "checkmark.seal") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Send for review: a link someone can open on their phone to approve these")
            Button { confirmDelete = rec } label: { Image(systemName: "trash") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Delete this carousel and its posts")
        }
    }

    @ViewBuilder
    private func cardLabel(_ title: String, _ icon: String, _ labels: Bool) -> some View {
        if labels { Label(title, systemImage: icon).lineLimit(1).fixedSize() }
        else { Image(systemName: icon) }
    }

    private func workingCard(_ rec: AutoReelRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                ForEach([2, 1, 0], id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8).fill(Theme.raised2)
                        .frame(width: 200, height: 250)
                        .shimmer()
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                        .rotationEffect(.degrees(Double(i) * 6))
                        .offset(x: CGFloat(i) * 46, y: CGFloat(i) * 4)
                }
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(jobs.status[rec.id] ?? "Working…").font(.ui(size: 12)).foregroundColor(Theme.muted)
                        .multilineTextAlignment(.center).frame(width: 170)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .contentShape(Rectangle())
            .onTapGesture { openWindow(id: "carousel-window", value: rec.id) }
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.title).font(.ui(size: 14, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Text("Writing the graphics. You can leave this page.").font(.ui(size: 12)).foregroundColor(Theme.muted)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.sand.opacity(0.4)))
    }

    private func row(_ rec: AutoReelRecord) -> some View {
        HStack(spacing: 14) {
            ScrubThumb(draft: rec.drafts?.first, path: rec.sourceVideoPath ?? rec.path, faceAspect: 16 / 9)
                .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                .environment(\.colorScheme, .dark)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.title).font(.ui(size: 13.5, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                if let e = jobs.errors[rec.id] {
                    Text(e).font(.ui(size: 12)).foregroundColor(Theme.danger).lineLimit(2)
                } else {
                    Text("Added \(Date(timeIntervalSince1970: rec.dateCreated).formatted(.relative(presentation: .named)))")
                        .font(.ui(size: 12)).foregroundColor(Theme.muted)
                }
            }
            Spacer()
            Button { graphicsFor = rec } label: { Label("Quote cards", systemImage: "quote.opening") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Button { confirmMake = rec } label: { Label("Make graphics", systemImage: "sparkles") }
                .buttonStyle(PrimaryButtonStyle(compact: true))
            Button { hide(rec) } label: { Image(systemName: "xmark") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Remove from this page (the sermon and its clips stay in AutoClip)")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
    }
}
