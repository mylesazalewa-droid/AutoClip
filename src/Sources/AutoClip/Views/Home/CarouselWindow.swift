import SwiftUI
import AppKit

/// Where the next carousel window should open (set by the Social Graphics page).
@MainActor enum CarouselNav {
    static var pending: [UUID: (posts: Bool, index: Int)] = [:]
}

/// A sermon's social graphics: the carousel (the whole message in one swipe) and single posts
/// for the week. AI writes them once; every word, photo, colour and slide is yours to change.
/// Saved with the sermon as you go.
struct CarouselWindow: View {
    let recordID: UUID

    enum Mode: Hashable { case carousel, posts }

    @ObservedObject private var store = AutoReelsStore.shared
    @StateObject private var photos = CarouselPhotoCache()
    @State private var carousel: SermonCarousel?
    @State private var mode: Mode = .carousel
    @State private var selectedSlide = 0
    @State private var selectedPost = 0
    @State private var localStatus: String?
    @ObservedObject private var jobs = CarouselJobs.shared
    /// Saving here, or the AI writing (which carries on if this window closes)
    private var status: String? { localStatus ?? jobs.status[recordID] }
    @State private var error: String?
    @State private var saved: URL?
    @State private var confirmRewrite = false
    @State private var copied = false
    @State private var hovered: UUID?
    @State private var savedDefault = false
    @State private var editingField: SlideInteraction.Field?
    @State private var selectedLayer: UUID?
    @State private var showBG = false
    @State private var bgScene: GraphicsAI.Scene = .auto
    @State private var bgPrompt = ""
    @State private var bgBusy = false
    @State private var bgError: String?
    @State private var rewriting = false
    @FocusState private var editorFocus: Bool

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }
    private var isPosts: Bool { mode == .posts }
    private var selected: Int { isPosts ? selectedPost : selectedSlide }
    private func select(_ i: Int) {
        if isPosts { selectedPost = i } else { selectedSlide = i }
        editingField = nil; selectedLayer = nil
    }
    private func items(_ c: SermonCarousel) -> [SermonCarousel.Slide] { isPosts ? c.postList : c.slides }
    /// What draws item `i`: the carousel itself, or a one-slide copy in the post's own look
    private func display(_ c: SermonCarousel, _ i: Int) -> (c: SermonCarousel, i: Int) { isPosts ? (c.post(i), 0) : (c, i) }
    private var minCount: Int { isPosts ? 0 : 2 }
    private var noun: String { isPosts ? "post" : "slide" }

    /// Changes the list being edited.
    private func update(_ f: (inout [SermonCarousel.Slide]) -> Void) {
        guard var c = carousel else { return }
        if isPosts { var p = c.postList; f(&p); c.postList = p } else { f(&c.slides) }
        carousel = c
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.line)
            if let c = carousel, !c.slides.isEmpty {
                if items(c).isEmpty {
                    postsIntro
                } else {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            stage(c)
                            Divider().background(Theme.line)
                            strip(c)
                        }
                        Divider().background(Theme.line)
                        ScrollView { inspector }
                            .frame(width: 340)
                            .background(Theme.surface)
                    }
                }
            } else {
                intro
            }
        }
        .frame(minWidth: 1080, minHeight: 760)
        .background(Theme.bg)
        .navigationTitle(record.map { "Social graphics – \($0.title)" } ?? "Social graphics")
        .onAppear {
            carousel = CarouselStore.load(recordID)
            if let p = CarouselNav.pending.removeValue(forKey: recordID) {
                mode = p.posts ? .posts : .carousel
                select(p.index)
            }
        }
        .onChange(of: jobs.finished[recordID]) { _, _ in
            carousel = CarouselStore.load(recordID)
            if let c = carousel { selectedSlide = min(selectedSlide, max(0, c.slides.count - 1)) }
        }
        .onChange(of: jobs.errors[recordID]) { _, e in if let e { error = e } }
        .onChange(of: carousel) { _, new in if let new { CarouselStore.save(new, for: recordID) } }
        .task(id: photoKeys) { await loadPhotos() }
        .sheet(isPresented: $showBG) { bgSheet }
        .alert("Rewrite the carousel?", isPresented: $confirmRewrite) {
            Button("Rewrite") { make() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI reads the message again and writes new slides. Your style, colour, church name and posts stay. Your slide edits are replaced.")
        }
    }

    private var photoKeys: [String] {
        guard let c = carousel else { return [] }
        return photos.keys(c) + c.postList.indices.flatMap { photos.keys(c.post($0)) }
    }

    private func loadPhotos() async {
        guard let c = carousel else { return }
        // What's on screen first
        let n = items(c).count
        if n > 0 { let d = display(c, min(selected, n - 1)); await photos.ensure(d.c.slides[d.i], d.c) }
        for s in c.slides { await photos.ensure(s, c) }
        for i in c.postList.indices { let p = c.post(i); await photos.ensure(p.slides[0], p) }
    }

    private func images(_ c: SermonCarousel, _ i: Int) -> SlideImages {
        let d = display(c, i)
        return photos.images(d.c.slides[d.i], d.c)
    }

    private func slideView(_ c: SermonCarousel, _ i: Int, scale: CGFloat, interactive: Bool = false) -> ScaledSlide {
        let d = display(c, i)
        return ScaledSlide(carousel: d.c, index: d.i, images: photos.images(d.c.slides[d.i], d.c), scale: scale,
                           interaction: interactive ? interaction : nil)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Social graphics").font(Theme.display(20, weight: .medium)).foregroundColor(Theme.cream)
                Text(record?.title ?? "").font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
            if let c = carousel {
                Picker("", selection: $mode) {
                    Text("Carousel · \(c.slides.count)").tag(Mode.carousel)
                    Text("Posts · \(c.postList.count)").tag(Mode.posts)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.leading, 16)
            }
            Spacer()
            if let status {
                ProgressView().controlSize(.small)
                Text(status).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
            if let saved {
                Button { NSWorkspace.shared.activateFileViewerSelecting([saved]) } label: {
                    Label("Saved – show in Finder", systemImage: "checkmark.circle.fill")
                }.buttonStyle(.link).foregroundColor(Theme.good)
            }
            if let c = carousel, !items(c).isEmpty {
                if isPosts {
                    Button { jobs.makePosts(record!) } label: { Label("Write more posts", systemImage: "sparkles") }
                        .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(status != nil || record == nil)
                        .help("AI writes another set of posts from this sermon (one AI request)")
                } else {
                    Button { confirmRewrite = true } label: { Label("Rewrite with AI", systemImage: "sparkles") }
                        .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(status != nil)
                }
                if ShareOut.canAirDrop {
                    Button { sendToPhone() } label: { Label("Send to iPhone", systemImage: "iphone.and.arrow.forward") }
                        .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(status != nil)
                }
                Button { exportAll() } label: { Label("Save images…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(status != nil)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Empty

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            fan
            Text("The whole message in one swipe").font(Theme.display(26, weight: .medium)).foregroundColor(Theme.cream)
            Text("AI reads the full sermon and writes a carousel (a cover, the question it answers, the big idea, the main points, the key Scripture, a quote, a question for the week and a closing slide) plus a week of single posts. Then design them your way and save them for Instagram.")
                .font(.system(size: 13)).foregroundColor(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 540)
            if let status {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.system(size: 13)).foregroundColor(Theme.muted) }
                Text("You can close this window. It keeps going and shows up in Social Graphics.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.faint)
            } else {
                Button { make() } label: { Label("Make the graphics", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(record == nil)
                Text("Uses one AI request.").font(.system(size: 11.5)).foregroundColor(Theme.faint)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(Theme.danger).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var postsIntro: some View {
        VStack(spacing: 16) {
            Spacer()
            fan
            Text("A week of posts from this sermon").font(Theme.display(24, weight: .medium)).foregroundColor(Theme.cream)
            Text("Quotes, Scripture, a question for the comments, encouragement and an invite for Sunday. Each one in its own look.")
                .font(.system(size: 13)).foregroundColor(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 480)
            if let status {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.system(size: 13)).foregroundColor(Theme.muted) }
            } else {
                Button { if let r = record { jobs.makePosts(r) } } label: { Label("Write the posts", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(record == nil)
                Text("Uses one AI request.").font(.system(size: 11.5)).foregroundColor(Theme.faint)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundColor(Theme.danger) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var fan: some View {
        HStack(spacing: -40) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 12).fill(i == 1 ? Theme.terracotta : Theme.raised2)
                    .frame(width: 110, height: 138)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                    .rotationEffect(.degrees(Double(i - 1) * 7))
                    .zIndex(i == 1 ? 1 : 0)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Stage

    private func stage(_ c: SermonCarousel) -> some View {
        GeometryReader { geo in
            let size = c.shape.size
            let s = min((geo.size.width - 140) / size.width, (geo.size.height - 40) / size.height)
            let n = items(c).count
            let i = min(selected, n - 1)
            HStack(spacing: 16) {
                arrow("chevron.left", enabled: i > 0) { select(i - 1) }
                slideView(c, i, scale: max(0.1, s), interactive: true)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    .onDrag { dragSlide(c, i) }
                    .help("Drag this \(noun) into Finder, Messages or a browser upload")
                arrow("chevron.right", enabled: i < n - 1) { select(i + 1) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.ink.opacity(0.03))
        .overlay(alignment: .bottom) { if editingField != nil { inlineEditor.padding(.bottom, 16) } }
        .overlay(alignment: .topLeading) {
            Text("Click words to edit them · drag the words up or down · drag stickers to move them")
                .font(.system(size: 11.5)).foregroundColor(Theme.faint).padding(10)
        }
    }

    private var interaction: SlideInteraction {
        SlideInteraction(
            editing: editingField, selectedLayer: selectedLayer,
            tapField: { f in selectedLayer = nil; editingField = f; editorFocus = true },
            tapLayer: { id in editingField = nil; selectedLayer = id },
            moveLayer: { id, d in
                let i = selected
                update { list in
                    guard list.indices.contains(i), let j = list[i].layerList.firstIndex(where: { $0.id == id }) else { return }
                    var ls = list[i].layerList
                    ls[j].x = min(1, max(0, ls[j].x + d.width)); ls[j].y = min(1, max(0, ls[j].y + d.height))
                    list[i].layerList = ls
                }
                selectedLayer = id
            },
            tapEmpty: { editingField = nil; selectedLayer = nil },
            moveText: { dy in
                let i = selected
                update { list in
                    guard list.indices.contains(i) else { return }
                    list[i].textNudge = min(0.45, max(-0.45, (list[i].textNudge ?? 0) + Double(dy)))
                }
            })
    }

    /// The box that appears over the slide when you click its words.
    @ViewBuilder private var inlineEditor: some View {
        if let f = editingField {
            let label: String = switch f {
            case .eyebrow: "Label"
            case .headline: "Words"
            case .body: "Text"
            case .reference: "Reference"
            }
            let kp: WritableKeyPath<SermonCarousel.Slide, String> = switch f {
            case .eyebrow: \.eyebrow
            case .headline: \.headline
            case .body: \.body
            case .reference: \.reference
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(label.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                    Spacer()
                    Button("Done") { editingField = nil }.buttonStyle(.link).keyboardShortcut(.defaultAction)
                }
                TextField(label, text: itemBinding(kp), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 15)).foregroundColor(Theme.ink)
                    .lineLimit(1...5).focused($editorFocus)
                if f == .headline {
                    HStack(spacing: 6) {
                        Image(systemName: "highlighter").foregroundColor(Theme.sand).font(.system(size: 12))
                        TextField("Words to highlight", text: itemBinding(\.emphasis))
                            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.text)
                    }
                }
            }
            .padding(14)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.sand.opacity(0.5)))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        }
    }

    private func arrow(_ icon: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40)
                .background(Circle().fill(Theme.raised))
        }
        .buttonStyle(.plain).foregroundColor(Theme.ink).opacity(enabled ? 1 : 0.25).disabled(!enabled)
    }

    private var addKinds: [SermonCarousel.Kind] {
        isPosts ? [.quote, .scripture, .question, .bigIdea, .invite, .point] : SermonCarousel.Kind.allCases.filter { $0 != .invite }
    }

    private func strip(_ c: SermonCarousel) -> some View {
        let size = c.shape.size
        let s: CGFloat = 116 / size.height
        let list = items(c)
        let i = min(selected, list.count - 1)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Drag to reorder").font(.system(size: 11.5)).foregroundColor(Theme.faint)
                Spacer()
                Button { move(i, by: -1) } label: { Label("Earlier", systemImage: "arrow.left") }.disabled(i == 0)
                Button { move(i, by: 1) } label: { Label("Later", systemImage: "arrow.right") }.disabled(i >= list.count - 1)
                Button { duplicate(i) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { delete(i) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(list.count <= minCount)
                Menu {
                    ForEach(addKinds, id: \.self) { k in
                        Button { add(k) } label: { Label(k.label, systemImage: k.icon) }
                    }
                } label: { Label("Add \(noun)", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.top, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { idx, slide in
                        thumb(c, idx, slide, scale: s, count: list.count)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .frame(height: 176)
    }

    private func thumb(_ c: SermonCarousel, _ idx: Int, _ slide: SermonCarousel.Slide, scale s: CGFloat, count: Int) -> some View {
        slideView(c, idx, scale: s)
            .drawingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(idx == selected ? Theme.sand : Theme.line, lineWidth: idx == selected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if hovered == slide.id && count > minCount {
                    Button { delete(idx) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                            .frame(width: 18, height: 18).background(Circle().fill(Color.black.opacity(0.75)))
                    }
                    .buttonStyle(.plain).padding(4).help("Delete this \(noun)")
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(idx + 1)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.6))).padding(4)
            }
            .onHover { hovered = $0 ? slide.id : (hovered == slide.id ? nil : hovered) }
            .onTapGesture { select(idx) }
            .draggable(slide.id.uuidString) {
                slideView(c, idx, scale: s)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                moveItem(id, to: idx)
                return true
            } isTargeted: { _ in }
            .contextMenu {
                Button("Move earlier") { move(idx, by: -1) }.disabled(idx == 0)
                Button("Move later") { move(idx, by: 1) }.disabled(idx == count - 1)
                Button("Duplicate") { duplicate(idx) }
                Divider()
                Button("Delete \(noun)", role: .destructive) { delete(idx) }.disabled(count <= minCount)
            }
    }

    // MARK: Inspector

    /// The look being edited: the carousel's, or the selected post's own
    private var look: SermonCarousel? {
        guard let c = carousel else { return nil }
        if isPosts, c.postList.indices.contains(selectedPost) { return c.post(selectedPost) }
        return c
    }

    private func setStyle(_ st: SermonCarousel.Style) {
        if isPosts { update { if $0.indices.contains(selectedPost) { $0[selectedPost].style = st; $0[selectedPost].font = nil } } }
        else { carousel?.style = st }
    }
    private func setAccent(_ hex: String) {
        if isPosts { update { if $0.indices.contains(selectedPost) { $0[selectedPost].accentHex = hex } } }
        else { carousel?.accentHex = hex }
    }
    private func setFont(_ t: SermonCarousel.TypeChoice) {
        if isPosts { update { if $0.indices.contains(selectedPost) { $0[selectedPost].font = t } } }
        else { carousel?.font = t }
    }

    private func useBrand(_ b: BrandKit) {
        if isPosts {
            update { if $0.indices.contains(selectedPost) {
                $0[selectedPost].accentHex = b.primaryHex
                if b.font != .auto { $0[selectedPost].font = b.font }
            } }
            if !b.signature.isEmpty { carousel?.handle = b.signature }
        } else {
            carousel?.applyBrand(b, posts: false)
        }
    }

    @ViewBuilder private var inspector: some View {
        if let c = carousel, let l = look {
            VStack(alignment: .leading, spacing: 22) {
                section(isPosts ? "This post's look" : "Design") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 8), count: 4), spacing: 10) {
                        ForEach(SermonCarousel.Style.allCases) { st in
                            Button { setStyle(st) } label: {
                                VStack(spacing: 5) {
                                    styleSwatch(st, l)
                                    Text(st.label).font(.system(size: 11.5, weight: l.style == st ? .semibold : .regular))
                                        .foregroundColor(l.style == st ? Theme.ink : Theme.muted)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(SermonCarousel.swatches, id: \.self) { hex in
                            Circle().fill(Color(nsColor: NSColor(hexString: hex))).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(Theme.ink, lineWidth: l.accentHex == hex ? 2 : 0).padding(-3))
                                .onTapGesture { setAccent(hex) }
                        }
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: NSColor(hexString: l.accentHex)) },
                            set: { setAccent(NSColor($0).hexString) }), supportsOpacity: false)
                            .labelsHidden().help("Your church's colour")
                    }
                    HStack {
                        Text("Type").font(.system(size: 11.5)).foregroundColor(Theme.muted)
                        Picker("", selection: Binding(get: { l.font ?? .auto }, set: { setFont($0) })) {
                            ForEach(SermonCarousel.TypeChoice.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    if isPosts {
                        Button { applyLookToAllPosts() } label: { Label("Use this look for every post", systemImage: "square.on.square") }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                    if let b = BrandKit.load() {
                        Button { useBrand(b) } label: { Label("Use our brand colour and type", systemImage: "paintpalette") }
                            .buttonStyle(.link).font(.system(size: 12))
                            .help("From the Brand kit page")
                    }
                }

                section("For all graphics") {
                    Picker("", selection: Binding(get: { c.shape }, set: { carousel?.shape = $0 })) {
                        ForEach(SermonCarousel.Shape.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    field("Church name or @handle", text: Binding(get: { c.handle }, set: { carousel?.handle = $0 }))
                    if !isPosts {
                        Button {
                            CarouselStore.saveDefault(c)
                            savedDefault = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { savedDefault = false }
                        } label: {
                            Label(savedDefault ? "Saved as your default" : "Use this design for new carousels",
                                  systemImage: savedDefault ? "checkmark" : "star")
                        }
                        .buttonStyle(.link).font(.system(size: 12))
                        .help("New carousels start with this style, colour, type, size and church name")
                    }
                }

                section("Series graphic") {
                    if c.hasArt, let p = c.artPath {
                        HStack(spacing: 10) {
                            if let img = NSImage(contentsOfFile: p) {
                                Image(nsImage: img).resizable().scaledToFill().frame(width: 72, height: 44).clipped().cornerRadius(5)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Button("Replace…") { pickArt() }.buttonStyle(.link)
                                Button("Remove") { carousel?.artPath = nil }.buttonStyle(.link).foregroundColor(Theme.danger)
                            }
                            .font(.system(size: 12))
                        }
                        Picker("", selection: Binding(get: { c.treatment }, set: { carousel?.artTreatment = $0 })) {
                            ForEach(SermonCarousel.ArtTreatment.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                        Toggle(isPosts ? "Behind every post" : "Behind every slide",
                               isOn: Binding(get: { c.artOnAll ?? false }, set: { carousel?.artOnAll = $0 }))
                        if !isPosts {
                            Toggle("Whole graphic on the cover", isOn: Binding(get: { c.artCover ?? false }, set: { carousel?.artCover = $0 }))
                                .disabled(c.style == .split)
                        }
                        Button { matchArtColour() } label: { Label("Match colour to the graphic", systemImage: "eyedropper") }
                            .buttonStyle(.link).font(.system(size: 12))
                    } else {
                        Text("Add the series artwork. AutoClip recolours or softens it to match each style, and uses it for every sermon in the series.")
                            .font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Button { pickArt() } label: { Label("Add series graphic…", systemImage: "photo.badge.plus") }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
                .toggleStyle(.checkbox).font(.system(size: 13)).foregroundColor(Theme.text)

                let list = items(c)
                if list.indices.contains(selected) {
                    let s = list[selected]
                    section("\(isPosts ? "Post" : "Slide") \(selected + 1) · \(s.kind.label)") {
                        HStack(spacing: 8) {
                            Text("Type").font(.system(size: 11.5)).foregroundColor(Theme.muted)
                            Picker("", selection: Binding(get: { s.kind }, set: { changeKind(selected, to: $0) })) {
                                ForEach(SermonCarousel.Kind.allCases, id: \.self) { k in
                                    Label(k.label, systemImage: k.icon).tag(k)
                                }
                            }
                            .labelsHidden().fixedSize()
                            .help("Turn this \(isPosts ? "post" : "slide") into another kind. The words stay.")
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Text("Words").font(.system(size: 11.5)).foregroundColor(Theme.muted)
                            Picker("", selection: Binding(get: { s.textAlign ?? "auto" }, set: { v in
                                let i = selected
                                update { list in
                                    guard list.indices.contains(i) else { return }
                                    list[i].textAlign = v == "auto" ? nil : v
                                    list[i].textNudge = nil
                                }
                            })) {
                                Text("Auto").tag("auto")
                                Image(systemName: "arrow.up.to.line").help("Top").tag("top")
                                Image(systemName: "arrow.up.and.down").help("Middle").tag("middle")
                                Image(systemName: "arrow.down.to.line").help("Bottom").tag("bottom")
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            Button { nudgeText(-0.03) } label: { Image(systemName: "chevron.up") }.help("Move the words up a little")
                            Button { nudgeText(0.03) } label: { Image(systemName: "chevron.down") }.help("Move the words down a little")
                        }
                        .controlSize(.small)
                        field("Label", text: itemBinding(\.eyebrow))
                        field(s.kind == .scripture ? "Verse" : s.kind == .quote ? "Quote" : "Headline", text: itemBinding(\.headline), lines: 4)
                        field("Words to highlight", text: itemBinding(\.emphasis))
                        if s.kind == .scripture || s.kind == .quote {
                            field(s.kind == .scripture ? "Reference" : "Who said it", text: itemBinding(\.reference))
                        }
                        if [.tension, .point, .question, .cta, .invite].contains(s.kind) {
                            field(s.kind == .invite ? "Times or details" : "Text", text: itemBinding(\.body), lines: 4)
                        }
                        if l.style != .photo {
                            Toggle("Photo of the speaker", isOn: itemBinding(\.photo)).font(.system(size: 13)).foregroundColor(Theme.text)
                        }
                        if SlideCanvas.needsPhoto(s, in: display(c, selected).c) {
                            HStack {
                                Button { nudge(-8) } label: { Label("Earlier", systemImage: "backward") }
                                Button { nudge(8) } label: { Label("Later", systemImage: "forward") }
                                Spacer()
                                Text(timeLabel(s.time)).font(.system(size: 11.5).monospacedDigit()).foregroundColor(Theme.faint)
                            }
                            .controlSize(.small)
                        }
                    }
                    if ![.quote, .scripture].contains(s.kind) {
                        section("Rewrite with AI") {
                            HStack(spacing: 6) {
                                ForEach(GraphicsAI.Rewrite.allCases) { how in
                                    Button(how.label) { rewrite(how) }.disabled(rewriting)
                                }
                            }
                            .controlSize(.small)
                            if rewriting { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Rewriting…").font(.system(size: 11.5)).foregroundColor(Theme.muted) } }
                        }
                    }
                    section("Background picture") {
                        if let p = s.bgPath, let img = NSImage(contentsOfFile: p) {
                            HStack(spacing: 10) {
                                Image(nsImage: img).resizable().scaledToFill().frame(width: 60, height: 74).clipped().cornerRadius(5)
                                VStack(alignment: .leading, spacing: 4) {
                                    Button("Make another with AI…") { openBG(s, c) }.buttonStyle(.link)
                                    Button("Choose a photo…") { choosePhoto() }.buttonStyle(.link)
                                    Button("Use on every \(noun)") { bgOnAll(p) }.buttonStyle(.link)
                                    Button("Remove") { setBG(nil) }.buttonStyle(.link).foregroundColor(Theme.danger)
                                }.font(.system(size: 12))
                            }
                        } else {
                            Text("A picture behind the words: made by AI (Nano Banana) to suit this \(noun), or one of your own photos. The words stay editable on top.")
                                .font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button { openBG(s, c) } label: { Label("Make with AI…", systemImage: "wand.and.stars") }
                                    .buttonStyle(SecondaryButtonStyle(compact: true))
                                Button { choosePhoto() } label: { Label("Your photo…", systemImage: "photo") }
                                    .buttonStyle(SecondaryButtonStyle(compact: true))
                            }
                        }
                    }
                    stickersSection(s, l)
                    if isPosts {
                        section("Caption") {
                            TextEditor(text: Binding(get: { s.caption ?? "" }, set: { v in update { if $0.indices.contains(selectedPost) { $0[selectedPost].caption = v } } }))
                                .font(.system(size: 13)).foregroundColor(Theme.text)
                                .scrollContentBackground(.hidden).padding(6)
                                .frame(height: 90)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
                            copyButton((s.caption ?? "") + (c.hashtags.isEmpty ? "" : "\n\n" + c.hashtags.map { "#" + $0 }.joined(separator: " ")))
                        }
                    }
                }

                if !isPosts {
                    section("Caption") {
                        TextEditor(text: Binding(get: { c.caption }, set: { carousel?.caption = $0 }))
                            .font(.system(size: 13)).foregroundColor(Theme.text)
                            .scrollContentBackground(.hidden).padding(6)
                            .frame(height: 110)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
                        field("Hashtags", text: Binding(get: { c.hashtags.joined(separator: " ") },
                                                        set: { carousel?.hashtags = $0.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).replacingOccurrences(of: "#", with: "") } }))
                        copyButton(c.captionWithTags)
                    }
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
                }
            }
            .padding(18)
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: { Label(copied ? "Copied" : "Copy caption", systemImage: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(SecondaryButtonStyle(compact: true))
    }

    private func styleSwatch(_ st: SermonCarousel.Style, _ c: SermonCarousel) -> some View {
        var probe = c
        probe.style = st
        if c.style != st { probe.font = nil }
        let p = CarouselPalette(probe)
        let t = probe.type
        let fill: AnyShapeStyle = switch st {
        case .photo: AnyShapeStyle(LinearGradient(colors: [p.block.opacity(0.7), .black], startPoint: .top, endPoint: .bottom))
        case .gradient: AnyShapeStyle(LinearGradient(colors: [p.block, p.ground, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .split: AnyShapeStyle(LinearGradient(stops: [.init(color: p.block, location: 0), .init(color: p.block, location: 0.4),
                                                          .init(color: p.ground, location: 0.4), .init(color: p.ground, location: 1)],
                                                  startPoint: .top, endPoint: .bottom))
        default: AnyShapeStyle(p.ground)
        }
        let font: Font = switch t {
        case .serif: .system(size: 20, weight: .semibold, design: .serif)
        case .classic: .custom("Didot-Bold", size: 20)
        case .script: .custom("SnellRoundhand-Black", size: 22)
        case .geometric: .custom("Futura-CondensedExtraBold", size: 20)
        case .slab: .custom("Rockwell-Bold", size: 19)
        case .rounded: .system(size: 20, weight: .heavy, design: .rounded)
        case .modern: .system(size: 20, weight: .bold)
        default: .system(size: 20, weight: .black)
        }
        return RoundedRectangle(cornerRadius: 7).fill(fill)
            .frame(width: 64, height: 78)
            .overlay(
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(p.accent).frame(width: 22, height: 4)
                    Text(t.upper ? "AA" : "Aa").font(font).fontWidth(t == .condensed ? .condensed : .standard)
                        .foregroundColor(t == .script ? p.accent : p.ink)
                }.padding(8), alignment: .bottomLeading)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(c.style == st ? Theme.sand : Theme.line, lineWidth: c.style == st ? 2.5 : 1))
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
            content()
        }
    }

    private func field(_ label: String, text: Binding<String>, lines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundColor(Theme.muted)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.text)
                .lineLimit(1...max(1, lines))
                .padding(8).background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.05)))
        }
    }

    private func itemBinding<T>(_ kp: WritableKeyPath<SermonCarousel.Slide, T>) -> Binding<T> {
        Binding(get: {
                    let list = items(carousel!)
                    return list[min(selected, list.count - 1)][keyPath: kp]
                },
                set: { v in
                    let i = selected
                    update { if $0.indices.contains(i) { $0[i][keyPath: kp] = v } }
                })
    }

    private func timeLabel(_ t: Double) -> String { String(format: "Photo at %d:%02d", Int(t) / 60, Int(t) % 60) }

    // MARK: Editing

    private func nudgeText(_ by: Double) {
        let i = selected
        update { list in
            guard list.indices.contains(i) else { return }
            list[i].textNudge = min(0.45, max(-0.45, (list[i].textNudge ?? 0) + by))
        }
    }

    private func nudge(_ by: Double) {
        let i = selected
        update { if $0.indices.contains(i) { $0[i].time = max(0, $0[i].time + by) } }
    }

    private func move(_ i: Int, by d: Int) {
        guard let c = carousel, items(c).indices.contains(i + d), items(c).indices.contains(i) else { return }
        update { $0.swapAt(i, i + d) }
        select(i + d)
    }

    /// Drops a dragged item where another one is.
    private func moveItem(_ id: UUID, to target: Int) {
        guard let c = carousel, let from = items(c).firstIndex(where: { $0.id == id }), from != target else { return }
        update { list in
            let s = list.remove(at: from)
            list.insert(s, at: min(target, list.count))
        }
        select(min(target, items(carousel!).count - 1))
    }

    private func duplicate(_ i: Int) {
        guard let c = carousel, items(c).indices.contains(i) else { return }
        update { list in var copy = list[i]; copy.id = UUID(); list.insert(copy, at: i + 1) }
        select(i + 1)
    }

    /// Changes one slide or post into another kind, keeping its words.
    private func changeKind(_ i: Int, to k: SermonCarousel.Kind) {
        update { list in
            guard list.indices.contains(i), list[i].kind != k else { return }
            let old = list[i].kind
            var s = list[i]
            s.kind = k
            // A label that was only the old kind's default follows the new kind
            if s.eyebrow.isEmpty || s.eyebrow == old.defaultEyebrow { s.eyebrow = k.defaultEyebrow }
            if k == .scripture && s.reference.isEmpty { s.reference = "Book 1:1" }
            if k == .invite && s.body.isEmpty {
                let times = BrandKit.load()?.serviceTimes ?? ""
                s.body = times.isEmpty ? "Sundays at 9 and 11" : times
            }
            if k == .quote && old != .quote { s.photo = true }
            list[i] = s
        }
    }

    private func delete(_ i: Int) {
        guard let c = carousel, items(c).count > minCount, items(c).indices.contains(i) else { return }
        update { $0.remove(at: i) }
        select(max(0, min(selected, items(carousel!).count - 1)))
    }

    private func add(_ k: SermonCarousel.Kind) {
        guard let c = carousel else { return }
        let list = items(c)
        let at = min(selected + 1, list.count)
        var s = SermonCarousel.Slide(kind: k, eyebrow: k.defaultEyebrow, headline: k == .invite ? "See you Sunday" : "Your words here",
                                     emphasis: k == .invite ? "Sunday" : "words",
                                     time: list.indices.contains(selected) ? list[selected].time : 0)
        if k == .scripture { s.reference = "Book 1:1" }
        if k == .invite {
            let times = BrandKit.load()?.serviceTimes ?? ""
            s.body = times.isEmpty ? "Sundays at 9 and 11" : times
        }
        s.photo = k == .quote
        if isPosts {
            let look = SermonCarousel.postLooks[list.count % SermonCarousel.postLooks.count]
            s.style = look.0; s.font = look.1
        }
        update { $0.insert(s, at: at) }
        select(at)
    }

    // MARK: Stickers

    @ViewBuilder private func stickersSection(_ s: SermonCarousel.Slide, _ l: SermonCarousel) -> some View {
        section("Stickers and drawings") {
            let pal = CarouselPalette(l)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                ForEach(SermonCarousel.Doodle.allCases, id: \.self) { d in
                    Button { addLayer(.doodle, d.rawValue) } label: {
                        LayerView(layer: SermonCarousel.Layer(kind: .doodle, name: d.rawValue, x: 0.5, y: 0.5, size: 0.8, text: "Sunday • "),
                                  pal: pal, W: 30, H: 30, interaction: nil)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain).frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.06))).help(d.label)
                }
                ForEach(SermonCarousel.stickerSymbols, id: \.self) { name in
                    Button { addLayer(.symbol, name) } label: {
                        Image(systemName: name).font(.system(size: 16)).foregroundColor(Theme.ink).frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.06)))
                }
            }
            if let id = selectedLayer, let layer = s.layerList.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Size").font(.system(size: 11.5)).foregroundColor(Theme.muted).frame(width: 46, alignment: .leading)
                        Slider(value: layerBinding(id, \.size), in: 0.04...0.8)
                    }
                    HStack {
                        Text("Turn").font(.system(size: 11.5)).foregroundColor(Theme.muted).frame(width: 46, alignment: .leading)
                        Slider(value: layerBinding(id, \.rotation), in: -180...180)
                    }
                    HStack(spacing: 8) {
                        Text("Colour").font(.system(size: 11.5)).foregroundColor(Theme.muted).frame(width: 46, alignment: .leading)
                        ForEach([("Accent", nil as String?), ("Text", "ink"), ("White", "white")], id: \.0) { item in
                            Button(item.0) { setLayerColour(id, item.1) }
                                .buttonStyle(.link).font(.system(size: 12, weight: layer.colour == item.1 ? .bold : .regular))
                        }
                        ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hexString: layer.colour ?? l.accentHex)) },
                                                           set: { setLayerColour(id, NSColor($0).hexString) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                    if layer.name == SermonCarousel.Doodle.badge.rawValue {
                        field("Words around the badge", text: Binding(get: { layer.text ?? "" }, set: { v in editLayer(id) { $0.text = v } }))
                    }
                    HStack {
                        Button { duplicateLayer(id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { removeLayer(id) } label: { Label("Remove", systemImage: "trash") }
                    }
                    .controlSize(.small)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.04)))
            } else if !s.layerList.isEmpty {
                Text("Click a sticker on the slide to size, turn, recolour or remove it.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.faint)
            }
        }
    }

    private func editLayer(_ id: UUID, _ f: (inout SermonCarousel.Layer) -> Void) {
        let i = selected
        update { list in
            guard list.indices.contains(i), let j = list[i].layerList.firstIndex(where: { $0.id == id }) else { return }
            var ls = list[i].layerList; f(&ls[j]); list[i].layerList = ls
        }
    }

    private func layerBinding(_ id: UUID, _ kp: WritableKeyPath<SermonCarousel.Layer, Double>) -> Binding<Double> {
        Binding(get: {
            guard let c = carousel, items(c).indices.contains(selected) else { return 0 }
            return items(c)[selected].layerList.first { $0.id == id }?[keyPath: kp] ?? 0
        }, set: { v in editLayer(id) { $0[keyPath: kp] = v } })
    }

    private func setLayerColour(_ id: UUID, _ c: String?) { editLayer(id) { $0.colour = c } }

    private func addLayer(_ kind: SermonCarousel.Layer.Kind, _ name: String) {
        var l = SermonCarousel.Layer(kind: kind, name: name)
        let n = Double((carousel.map { items($0) }?[safe: selected]?.layerList.count) ?? 0)
        l.x = 0.72 - n * 0.06; l.y = 0.2 + n * 0.06
        if [.underline, .squiggle, .arrow].contains(SermonCarousel.Doodle(rawValue: name)) { l.size = 0.34; l.x = 0.4; l.y = 0.62 }
        if name == SermonCarousel.Doodle.badge.rawValue { l.size = 0.3; l.text = "See you Sunday • see you Sunday • " }
        let i = selected
        update { list in if list.indices.contains(i) { list[i].layerList.append(l) } }
        selectedLayer = l.id
    }

    private func duplicateLayer(_ id: UUID) {
        let i = selected
        var newID: UUID?
        update { list in
            guard list.indices.contains(i), let l = list[i].layerList.first(where: { $0.id == id }) else { return }
            var copy = l; copy.id = UUID(); copy.x = min(1, l.x + 0.05); copy.y = min(1, l.y + 0.05)
            list[i].layerList.append(copy); newID = copy.id
        }
        selectedLayer = newID
    }

    private func removeLayer(_ id: UUID) {
        let i = selected
        update { list in if list.indices.contains(i) { list[i].layerList.removeAll { $0.id == id } } }
        selectedLayer = nil
    }

    // MARK: Backgrounds

    private func openBG(_ s: SermonCarousel.Slide, _ c: SermonCarousel) {
        bgError = nil
        bgPrompt = GraphicsAI.prompt(for: s, in: display(c, selected).c, scene: bgScene)
        showBG = true
    }

    private var bgSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make a background with AI").font(Theme.display(20, weight: .medium)).foregroundColor(Theme.cream)
            Text("Google's image AI (Nano Banana) paints a picture to sit behind this \(noun). It's told not to draw any words, so your text stays sharp and editable on top.")
                .font(.system(size: 12.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Picker("Scene", selection: $bgScene) {
                ForEach(GraphicsAI.Scene.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: bgScene) { _, sc in
                if let c = carousel, items(c).indices.contains(selected) {
                    bgPrompt = GraphicsAI.prompt(for: items(c)[selected], in: display(c, selected).c, scene: sc)
                }
            }
            Text("What to paint (you can change this)").font(.system(size: 11.5)).foregroundColor(Theme.muted)
            TextEditor(text: $bgPrompt)
                .font(.system(size: 12.5)).scrollContentBackground(.hidden).padding(6)
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
            if let bgError { Text(bgError).font(.system(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Uses one image request on your Google key (or OpenAI's if that's the one you have).")
                    .font(.system(size: 11)).foregroundColor(Theme.faint)
                Spacer()
                Button("Cancel") { showBG = false }.disabled(bgBusy)
                Button { generateBG() } label: {
                    if bgBusy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Painting…") } }
                    else { Label("Make it", systemImage: "wand.and.stars") }
                }
                .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(bgBusy || bgPrompt.isEmpty)
            }
        }
        .padding(22).frame(width: 540)
        .background(Theme.bg)
    }

    private func generateBG() {
        guard let c = carousel else { return }
        bgBusy = true; bgError = nil
        let ratio = c.shape.ratio, prompt = bgPrompt
        let i = selected, list = isPosts
        Task {
            do {
                let path = try await GraphicsAI.generate(prompt: prompt, ratio: ratio)
                // The same item, even if the user moved on while it painted
                guard var cur = carousel else { return }
                if list { if cur.postList.indices.contains(i) { cur.postList[i].bgPath = path } }
                else if cur.slides.indices.contains(i) { cur.slides[i].bgPath = path }
                carousel = cur
                showBG = false
            } catch { bgError = error.localizedDescription }
            bgBusy = false
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.title = "Choose a photo for this \(noun)"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let path = GraphicsAI.importPhoto(url) else { return }
        setBG(path)
    }

    private func setBG(_ path: String?) {
        let i = selected
        update { list in if list.indices.contains(i) { list[i].bgPath = path } }
    }

    private func bgOnAll(_ path: String) {
        update { list in for j in list.indices { list[j].bgPath = path } }
    }

    private func rewrite(_ how: GraphicsAI.Rewrite) {
        guard let c = carousel, items(c).indices.contains(selected) else { return }
        let i = selected, s = items(c)[i], title = record?.title ?? c.title
        rewriting = true; error = nil
        Task {
            do {
                let new = try await GraphicsAI.rewrite(s, how: how, title: title)
                update { list in if list.indices.contains(i) && list[i].id == s.id { list[i] = new } }
            } catch { self.error = error.localizedDescription }
            rewriting = false
        }
    }

    private func applyLookToAllPosts() {
        guard let c = carousel, c.postList.indices.contains(selectedPost) else { return }
        let p = c.postList[selectedPost]
        update { list in for j in list.indices { list[j].style = p.style; list[j].accentHex = p.accentHex; list[j].font = p.font } }
    }

    private func pickArt() {
        let panel = NSOpenPanel()
        panel.title = "Choose the series graphic"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let path = CarouselStore.importArt(url) else { return }
        let first = carousel?.artPath == nil
        carousel?.artPath = path
        if first { matchArtColour() }
        // Every sermon in the series gets it
        if let src = carousel?.source, var series = SeriesStore.shared.series(containing: src) {
            series.art = path
            SeriesStore.shared.upsert(series)
        }
    }

    private func matchArtColour() {
        guard let p = carousel?.artPath else { return }
        Task {
            if let img = await photos.source(p), let col = CarouselArt.mainColour(img) { carousel?.accentHex = col.hexString }
        }
    }

    // MARK: Actions

    private func make() {
        guard let rec = record else { return }
        error = nil; saved = nil
        jobs.make(rec)
    }

    private func folderName(_ c: SermonCarousel) -> String {
        let t = (record?.title ?? c.title).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(t.prefix(60)) + (isPosts ? " – Posts" : " – Carousel")
    }

    private func write(_ c: SermonCarousel, to dir: URL) async -> [URL] {
        isPosts ? await CarouselExport.writePosts(c, photos: photos, to: dir) : await CarouselExport.write(c, photos: photos, to: dir)
    }

    private func exportAll() {
        guard let c = carousel, let folder = ReelExportLocation.pick(title: "Choose where to save the \(noun)s") else { return }
        let dir = folder.appendingPathComponent(folderName(c))
        localStatus = "Saving \(noun)s…"
        Task {
            _ = await write(c, to: dir)
            saved = dir
            localStatus = nil
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private func sendToPhone() {
        guard let c = carousel else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutoClip Graphics/" + folderName(c))
        try? FileManager.default.removeItem(at: dir)
        localStatus = "Preparing \(noun)s…"
        Task {
            let urls = await write(c, to: dir)
            localStatus = nil
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        }
    }

    /// One slide or post as a PNG, for dragging out.
    private func dragSlide(_ c: SermonCarousel, _ i: Int) -> NSItemProvider {
        let d = display(c, i)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(format: "%@ %02d.png", isPosts ? "Post" : "Slide", i + 1))
        if let data = CarouselExport.png(d.c, index: d.i, images: images(c, i)) { try? data.write(to: url) }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}
