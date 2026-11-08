import SwiftUI
import AppKit

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

    private var sermons: [AutoReelRecord] { reels.reels.filter { ReelGenerator.sourceVideoPath(for: $0) != nil } }
    private var working: [AutoReelRecord] { sermons.filter { jobs.running($0.id) } }
    private var made: [AutoReelRecord] {
        sermons.filter { carousels[$0.id] != nil && !jobs.running($0.id) }
            .sorted { (carousels[$0.id]?.made ?? .distantPast) > (carousels[$1.id]?.made ?? .distantPast) }
    }
    private var notYet: [AutoReelRecord] { sermons.filter { carousels[$0.id] == nil && !jobs.running($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Create", title: "Social Graphics",
                       subtitle: "Carousels and a week of posts from every sermon. Click any one to edit it.")
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if sermons.isEmpty { empty }
                    if !working.isEmpty {
                        group("Being made", count: working.count) {
                            grid { ForEach(working) { workingCard($0) } }
                        }
                    }
                    weekPlan
                    if !allPosts.isEmpty {
                        group("Posts", count: allPosts.count) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 14, alignment: .top)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(allPosts, id: \.post.id) { item in postTile(item.rec, item.c, item.index) }
                            }
                        }
                    }
                    if !made.isEmpty {
                        group("Carousels", count: made.count) {
                            grid { ForEach(made) { rec in if let c = carousels[rec.id] { carouselCard(rec, c) } } }
                        }
                    }
                    if !notYet.isEmpty {
                        group(made.isEmpty && working.isEmpty ? "Your sermons" : "No graphics yet", count: notYet.count) {
                            VStack(spacing: 8) { ForEach(notYet) { row($0) } }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 40)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CarouselStore.changed)) { n in
            if let id = n.object as? UUID { carousels[id] = CarouselStore.load(id) }
        }
        .onChange(of: jobs.finished) { _, _ in reload() }
        .task(id: previewKeys) { await loadPreviews() }
        .sheet(item: $graphicsFor) { SocialGraphicsView(record: $0, gold: Theme.sand) }
        .alert("Make this sermon's graphics?", isPresented: Binding(get: { confirmMake != nil }, set: { if !$0 { confirmMake = nil } })) {
            Button("Make it") { if let r = confirmMake { jobs.make(r) }; confirmMake = nil }
            Button("Cancel", role: .cancel) { confirmMake = nil }
        } message: {
            Text("AI reads the whole sermon and writes a carousel and a week of single posts. Uses one AI request. You can keep working while they're made.")
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
        let w: CGFloat = 200
        return VStack(alignment: .leading, spacing: 6) {
            ScaledSlide(carousel: p, index: 0, images: photos.images(p.slides[0], p), scale: w / size.width)
                .drawingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            Text(rec.title).font(.system(size: 11.5)).foregroundColor(Theme.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(rec, posts: true, index: i) }
        .help("Open and edit this post")
        .overlay(alignment: .topTrailing) {
            if hoveredPost == c.postList[i].id {
                Button { deletePost(rec, c.postList[i].id) } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.black.opacity(0.7)))
                }
                .buttonStyle(.plain).padding(6).help("Delete this post")
            }
        }
        .onHover { h in hoveredPost = h ? c.postList[i].id : (hoveredPost == c.postList[i].id ? nil : hoveredPost) }
        .contextMenu {
            Button("Edit") { open(rec, posts: true, index: i) }
            Button("Copy caption") { copy(c.postList[i].caption ?? "") }
            Divider()
            Button("Delete post", role: .destructive) { deletePost(rec, c.postList[i].id) }
        }
    }

    private func deletePost(_ rec: AutoReelRecord, _ id: UUID) {
        guard var c = CarouselStore.load(rec.id) else { return }
        c.postList.removeAll { $0.id == id }
        CarouselStore.save(c, for: rec.id)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
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
                                Text(d.day).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.sand)
                                ScaledSlide(carousel: pc, index: 0, images: photos.images(pc.slides[0], pc), scale: 150 / pc.shape.size.width)
                                    .drawingGroup().clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onTapGesture { open(p.rec, posts: !isCarousel, index: isCarousel ? 0 : d.post!) }
                                Text(isCarousel ? "Carousel" : p.c.postList[d.post!].kind.label).font(.system(size: 11)).foregroundColor(Theme.muted)
                                Button { copy(caption); copiedDay = d.day } label: {
                                    Label(copiedDay == d.day ? "Copied" : "Copy caption", systemImage: copiedDay == d.day ? "checkmark" : "doc.on.doc")
                                        .lineLimit(1).fixedSize()
                                }
                                .buttonStyle(.link).font(.system(size: 11.5))
                            }
                            .frame(width: 150)
                        }
                    }
                }
                Text("From \(p.rec.title). Tap a day to edit it, copy its caption, then post.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.faint)
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
                Text("\(count)").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.muted)
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
            Image(systemName: "rectangle.split.3x1").font(.system(size: 34)).foregroundColor(Theme.sand)
            Text("Add a sermon first").font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
            Text("Once a sermon is in AutoClip, you can make a carousel, quote cards and a thumbnail from it here.")
                .font(.system(size: 13)).foregroundColor(Theme.muted)
            Button { reels.requestNewReel = true; HomeNav.shared.open(.autoReels) } label: { Label("Choose a sermon", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(rec.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Text("\(c.slides.count) slides · \(c.postList.count) posts · \(c.style.label)")
                    .font(.system(size: 12)).foregroundColor(Theme.muted)
            }
            HStack(spacing: 8) {
                Button { open(rec, posts: false, index: 0) } label: { Label("Edit", systemImage: "pencil").lineLimit(1).fixedSize() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                if c.postList.isEmpty {
                    Button { jobs.makePosts(rec) } label: { Label("Write posts", systemImage: "sparkles").lineLimit(1).fixedSize() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .help("A week of single posts from this sermon (one AI request)")
                }
                Button { graphicsFor = rec } label: { Label("Thumbnail", systemImage: "photo").lineLimit(1).fixedSize() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Quote cards and a thumbnail for the full message video")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
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
                    Text(jobs.status[rec.id] ?? "Working…").font(.system(size: 12)).foregroundColor(Theme.muted)
                        .multilineTextAlignment(.center).frame(width: 170)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .contentShape(Rectangle())
            .onTapGesture { openWindow(id: "carousel-window", value: rec.id) }
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Text("Writing the graphics. You can leave this page.").font(.system(size: 12)).foregroundColor(Theme.muted)
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
                Text(rec.title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                if let e = jobs.errors[rec.id] {
                    Text(e).font(.system(size: 12)).foregroundColor(Theme.danger).lineLimit(2)
                } else {
                    Text("Added \(Date(timeIntervalSince1970: rec.dateCreated).formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                }
            }
            Spacer()
            Button { graphicsFor = rec } label: { Label("Quote cards", systemImage: "quote.opening") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Button { confirmMake = rec } label: { Label("Make graphics", systemImage: "sparkles") }
                .buttonStyle(PrimaryButtonStyle(compact: true))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
    }
}
