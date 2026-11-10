import SwiftUI
import AppKit

/// What a message's window shows: its clips, its graphics, or every caption to copy.
enum MessagePane: String, CaseIterable { case clips = "Clips", graphics = "Graphics", captions = "Captions", audio = "Audio" }

/// One message's carousel and posts, in its own window.
struct MessageGraphicsPane: View {
    let recordID: UUID
    @ObservedObject private var jobs = CarouselJobs.shared
    @ObservedObject private var reels = AutoReelsStore.shared
    @StateObject private var photos = CarouselPhotoCache()
    @Environment(\.openWindow) private var openWindow
    @State private var carousel: SermonCarousel?
    @State private var showGraphics = false

    private var record: AutoReelRecord? { reels.reels.first { $0.id == recordID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if jobs.running(recordID) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(jobs.status[recordID] ?? "Writing the graphics…").font(.ui(size: 13)).foregroundColor(Theme.muted)
                    }
                } else if let c = carousel {
                    section("Carousel", "\(c.slides.count) slides · \(c.style.label)") {
                        Button { open(posts: false, index: 0) } label: {
                            ZStack {
                                ForEach(Array([2, 1, 0].filter { $0 < c.slides.count }), id: \.self) { i in
                                    ScaledSlide(carousel: c, index: i, images: photos.images(c.slides[i], c), scale: 210 / c.shape.size.height)
                                        .drawingGroup().clipShape(RoundedRectangle(cornerRadius: 7))
                                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                                        .rotationEffect(.degrees(Double(i) * 5)).offset(x: CGFloat(i) * 36, y: CGFloat(i) * 3)
                                }
                            }
                            .frame(width: 260, height: 230, alignment: .leading)
                        }
                        .buttonStyle(.plain).help("Open and edit the carousel")
                    }
                    section("Posts", c.postList.isEmpty ? "None yet" : "\(c.postList.count) posts for the week") {
                        if c.postList.isEmpty {
                            Button { if let r = record { jobs.makePosts(r) } } label: { Label("Write a week of posts", systemImage: "sparkles") }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                                .help("Uses \(AICost.phrase())")
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                                ForEach(Array(c.postList.indices), id: \.self) { i in
                                    let p = c.post(i)
                                    VStack(alignment: .leading, spacing: 4) {
                                        ScaledSlide(carousel: p, index: 0, images: photos.images(p.slides[0], p), scale: 150 / p.shape.size.width)
                                            .drawingGroup().clipShape(RoundedRectangle(cornerRadius: 6))
                                        Text("\(i + 1). " + c.postList[i].kind.label).font(.ui(size: 11)).foregroundColor(Theme.muted)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(posts: true, index: i) }
                                    .help("Open and edit this post")
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No graphics for this message yet").font(.ui(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                        Text("AI reads the whole message and writes a carousel and a week of posts. Uses \(AICost.phrase()).")
                            .font(.ui(size: 12.5)).foregroundColor(Theme.muted)
                        Button { if let r = record { jobs.make(r) } } label: { Label("Make the graphics", systemImage: "sparkles") }
                            .buttonStyle(PrimaryButtonStyle(compact: true))
                    }
                }
                section("Thumbnail and quote cards", "For the full message video") {
                    Button { showGraphics = true } label: { Label("Open", systemImage: "photo.on.rectangle.angled") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CarouselStore.changed)) { n in
            if (n.object as? UUID) == recordID { reload() }
        }
        .onChange(of: jobs.finished) { _, _ in reload() }
        .task(id: carousel?.postList.count ?? -1) {
            guard let c = carousel else { return }
            for s in c.slides.prefix(3) { await photos.ensure(s, c) }
            for i in c.postList.indices { let p = c.post(i); await photos.ensure(p.slides[0], p) }
        }
        .sheet(isPresented: $showGraphics) { if let r = record { SocialGraphicsView(record: r, gold: Theme.sand) } }
    }

    private func reload() { carousel = CarouselStore.load(recordID) }

    private func open(posts: Bool, index: Int) {
        CarouselNav.pending[recordID] = (posts, index)
        openWindow(id: "carousel-window", value: recordID)
    }

    private func section<V: View>(_ title: String, _ detail: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.display(17, weight: .medium)).foregroundColor(Theme.cream)
                Text(detail).font(.ui(size: 12)).foregroundColor(Theme.muted)
            }
            content()
        }
    }
}

/// Every caption from one message (clips, carousel, posts), ready to copy.
struct MessageCaptionsPane: View {
    let recordID: UUID
    @ObservedObject private var reels = AutoReelsStore.shared
    @State private var carousel: SermonCarousel?
    @State private var copied: String?

    private struct Item: Identifiable { var id: String; var group: String; var title: String; var text: String }

    private var items: [Item] {
        var out: [Item] = []
        for (i, d) in (reels.reels.first { $0.id == recordID }?.drafts ?? []).enumerated() {
            let name = d.title.isEmpty ? "Clip \(i + 1)" : d.title
            out.append(Item(id: "clip-\(d.id)", group: "Clips", title: name, text: d.seo?.asText ?? ""))
        }
        if let c = carousel {
            if !c.slides.isEmpty { out.append(Item(id: "carousel", group: "Carousel", title: c.title.isEmpty ? "Carousel" : c.title, text: c.captionWithTags)) }
            for (i, p) in c.postList.enumerated() {
                out.append(Item(id: "post-\(p.id)", group: "Posts", title: "Post \(i + 1): \(p.kind.label)", text: p.caption ?? ""))
            }
        }
        return out
    }

    var body: some View {
        let all = items
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("\(all.filter { !$0.text.isEmpty }.count) captions from this message").font(.ui(size: 12.5)).foregroundColor(Theme.muted)
                    Spacer()
                    Button { copy(allText(all), "all") } label: {
                        Label(copied == "all" ? "Copied" : "Copy all", systemImage: copied == "all" ? "checkmark" : "doc.on.doc").lineLimit(1).fixedSize()
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    Button { save(allText(all)) } label: { Label("Save as text…", systemImage: "square.and.arrow.down").lineLimit(1).fixedSize() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                ForEach(["Clips", "Carousel", "Posts"], id: \.self) { g in
                    let group = all.filter { $0.group == g }
                    if !group.isEmpty {
                        Text(g.uppercased()).font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                        ForEach(group) { item in card(item) }
                    }
                }
                if all.isEmpty {
                    Text("Captions appear here once the clips or graphics are made.").font(.ui(size: 13)).foregroundColor(Theme.muted)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { carousel = CarouselStore.load(recordID) }
        .onReceive(NotificationCenter.default.publisher(for: CarouselStore.changed)) { n in
            if (n.object as? UUID) == recordID { carousel = CarouselStore.load(recordID) }
        }
    }

    private func card(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title).font(.ui(size: 13, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Spacer()
                if !item.text.isEmpty {
                    Button { copy(item.text, item.id) } label: {
                        Label(copied == item.id ? "Copied" : "Copy", systemImage: copied == item.id ? "checkmark" : "doc.on.doc").lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.link).font(.ui(size: 12))
                }
            }
            Text(item.text.isEmpty ? "No caption yet." : item.text)
                .font(.ui(size: 12.5)).foregroundColor(item.text.isEmpty ? Theme.faint : Theme.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    private func allText(_ all: [Item]) -> String {
        all.filter { !$0.text.isEmpty }.map { "\($0.title.uppercased())\n\n\($0.text)" }.joined(separator: "\n\n———\n\n")
    }

    private func copy(_ s: String, _ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == id { copied = nil } }
    }

    private func save(_ s: String) {
        let p = NSSavePanel()
        let title = reels.reels.first { $0.id == recordID }?.title ?? "Captions"
        p.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + " captions.txt"
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}
