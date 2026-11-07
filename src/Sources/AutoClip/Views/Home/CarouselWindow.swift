import SwiftUI
import AppKit

/// The sermon carousel: AI writes the big picture once, then every word, photo, colour and
/// slide is yours to change. Saved with the sermon as you go.
struct CarouselWindow: View {
    let recordID: UUID

    @ObservedObject private var store = AutoReelsStore.shared
    @StateObject private var photos = CarouselPhotoCache()
    @State private var carousel: SermonCarousel?
    @State private var selected = 0
    @State private var status: String?
    @State private var error: String?
    @State private var saved: URL?
    @State private var confirmRewrite = false
    @State private var copied = false

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.line)
            if let c = carousel, !c.slides.isEmpty {
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
            } else {
                intro
            }
        }
        .frame(minWidth: 1080, minHeight: 760)
        .background(Theme.bg)
        .navigationTitle(record.map { "Carousel – \($0.title)" } ?? "Carousel")
        .onAppear { carousel = CarouselStore.load(recordID) }
        .onChange(of: carousel) { _, new in if let new { CarouselStore.save(new, for: recordID) } }
        .task(id: photoKeys) { await loadPhotos() }
        .alert("Rewrite the carousel?", isPresented: $confirmRewrite) {
            Button("Rewrite") { make() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI reads the message again and writes new slides. Your style, colour and church name stay. Your text edits are replaced.")
        }
    }

    private var photoKeys: [String] {
        guard let c = carousel else { return [] }
        return c.slides.compactMap { photos.key($0, c) }
    }

    private func loadPhotos() async {
        guard let c = carousel else { return }
        // The slide on screen first
        if c.slides.indices.contains(selected) { _ = await photos.ensure(c.slides[selected], c) }
        for s in c.slides { _ = await photos.ensure(s, c) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sermon carousel").font(Theme.display(20, weight: .medium)).foregroundColor(Theme.cream)
                Text(record?.title ?? "").font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer()
            if let status {
                ProgressView().controlSize(.small)
                Text(status).font(.system(size: 12)).foregroundColor(Theme.muted)
            }
            if let saved {
                Button { NSWorkspace.shared.activateFileViewerSelecting([saved]) } label: {
                    Label("Saved – show in Finder", systemImage: "checkmark.circle.fill")
                }.buttonStyle(.link).foregroundColor(Theme.good)
            }
            if carousel != nil {
                Button { confirmRewrite = true } label: { Label("Rewrite with AI", systemImage: "sparkles") }
                    .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(status != nil)
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
            Text("The whole message in one swipe").font(Theme.display(26, weight: .medium)).foregroundColor(Theme.cream)
            Text("AI reads the full sermon and writes a carousel: a cover, the question it answers, the big idea, the main points, the key Scripture, a quote, a question for the week and a closing slide. Then design it your way and save it for Instagram.")
                .font(.system(size: 13)).foregroundColor(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 520)
            if let status {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(status).font(.system(size: 13)).foregroundColor(Theme.muted) }
            } else {
                Button { make() } label: { Label("Make the carousel", systemImage: "sparkles") }
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

    // MARK: Stage

    private func stage(_ c: SermonCarousel) -> some View {
        GeometryReader { geo in
            let size = c.shape.size
            let s = min((geo.size.width - 140) / size.width, (geo.size.height - 40) / size.height)
            let i = min(selected, c.slides.count - 1)
            HStack(spacing: 16) {
                arrow("chevron.left", enabled: i > 0) { selected = i - 1 }
                ScaledSlide(carousel: c, index: i, photo: photos.image(c.slides[i], c), scale: max(0.1, s))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    .onDrag { dragSlide(c, i) }
                    .help("Drag this slide into Finder, Messages or a browser upload")
                arrow("chevron.right", enabled: i < c.slides.count - 1) { selected = i + 1 }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.ink.opacity(0.03))
    }

    private func arrow(_ icon: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40)
                .background(Circle().fill(Theme.raised))
        }
        .buttonStyle(.plain).foregroundColor(Theme.ink).opacity(enabled ? 1 : 0.25).disabled(!enabled)
        .keyboardShortcut(icon == "chevron.left" ? .leftArrow : .rightArrow, modifiers: [])
    }

    private func strip(_ c: SermonCarousel) -> some View {
        let size = c.shape.size
        let s: CGFloat = 116 / size.height
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(c.slides.indices, id: \.self) { i in
                    ScaledSlide(carousel: c, index: i, photo: photos.image(c.slides[i], c), scale: s)
                        .drawingGroup()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(i == selected ? Theme.sand : Theme.line, lineWidth: i == selected ? 3 : 1))
                        .onTapGesture { selected = i }
                        .contextMenu {
                            Button("Move earlier") { move(i, by: -1) }.disabled(i == 0)
                            Button("Move later") { move(i, by: 1) }.disabled(i == c.slides.count - 1)
                            Button("Duplicate") { duplicate(i) }
                            Divider()
                            Button("Delete slide", role: .destructive) { delete(i) }.disabled(c.slides.count <= 2)
                        }
                }
                Menu {
                    ForEach(SermonCarousel.Kind.allCases, id: \.self) { k in
                        Button { add(k) } label: { Label(k.label, systemImage: k.icon) }
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                        Text("Add slide").font(.system(size: 11.5))
                    }
                    .frame(width: max(70, size.width * s), height: 116)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundColor(Theme.muted)
            }
            .padding(14)
        }
        .frame(height: 146)
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let c = carousel {
            VStack(alignment: .leading, spacing: 22) {
                section("Design") {
                    HStack(spacing: 8) {
                        ForEach(SermonCarousel.Style.allCases) { st in
                            Button { carousel?.style = st } label: {
                                VStack(spacing: 5) {
                                    styleSwatch(st, c)
                                    Text(st.label).font(.system(size: 11.5, weight: c.style == st ? .semibold : .regular))
                                        .foregroundColor(c.style == st ? Theme.ink : Theme.muted)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(SermonCarousel.accents, id: \.self) { hex in
                            Circle().fill(Color(nsColor: NSColor(hexString: hex))).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(Theme.ink, lineWidth: c.accentHex == hex ? 2 : 0).padding(-3))
                                .onTapGesture { carousel?.accentHex = hex }
                        }
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: NSColor(hexString: c.accentHex)) },
                            set: { carousel?.accentHex = NSColor($0).hexString }), supportsOpacity: false)
                            .labelsHidden().help("Your church's colour")
                    }
                    Picker("", selection: Binding(get: { c.shape }, set: { carousel?.shape = $0 })) {
                        ForEach(SermonCarousel.Shape.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    field("Church name or @handle", text: Binding(get: { c.handle }, set: { carousel?.handle = $0 }))
                }

                if c.slides.indices.contains(selected) {
                    let s = c.slides[selected]
                    section("Slide \(selected + 1) · \(s.kind.label)") {
                        field("Label", text: slideBinding(\.eyebrow))
                        field(s.kind == .scripture ? "Verse" : s.kind == .quote ? "Quote" : "Headline", text: slideBinding(\.headline), lines: 4)
                        field("Words to highlight", text: slideBinding(\.emphasis))
                        if s.kind == .scripture || s.kind == .quote {
                            field(s.kind == .scripture ? "Reference" : "Who said it", text: slideBinding(\.reference))
                        }
                        if [.tension, .point, .question, .cta].contains(s.kind) {
                            field("Text", text: slideBinding(\.body), lines: 4)
                        }
                        if c.style != .photo {
                            Toggle("Photo of the speaker", isOn: slideBinding(\.photo)).font(.system(size: 13)).foregroundColor(Theme.text)
                        }
                        if SlideCanvas.needsPhoto(s, in: c) {
                            HStack {
                                Button { nudge(-8) } label: { Label("Earlier", systemImage: "backward") }
                                Button { nudge(8) } label: { Label("Later", systemImage: "forward") }
                                Spacer()
                                Text(timeLabel(s.time)).font(.system(size: 11.5).monospacedDigit()).foregroundColor(Theme.faint)
                            }
                            .controlSize(.small)
                        }
                    }
                }

                section("Caption") {
                    TextEditor(text: Binding(get: { c.caption }, set: { carousel?.caption = $0 }))
                        .font(.system(size: 13)).foregroundColor(Theme.text)
                        .scrollContentBackground(.hidden).padding(6)
                        .frame(height: 110)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
                    field("Hashtags", text: Binding(get: { c.hashtags.joined(separator: " ") },
                                                    set: { carousel?.hashtags = $0.split(whereSeparator: { $0 == " " || $0 == "," }).map { String($0).replacingOccurrences(of: "#", with: "") } }))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.captionWithTags, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: { Label(copied ? "Copied" : "Copy caption", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
                }
            }
            .padding(18)
        }
    }

    private func styleSwatch(_ st: SermonCarousel.Style, _ c: SermonCarousel) -> some View {
        var probe = c
        probe.style = st
        let p = CarouselPalette(probe)
        return RoundedRectangle(cornerRadius: 7).fill(st == .photo ? AnyShapeStyle(LinearGradient(colors: [p.accent.opacity(0.7), .black], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(p.ground))
            .frame(width: 64, height: 78)
            .overlay(
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(p.accent).frame(width: 22, height: 4)
                    Text(st == .editorial ? "Aa" : "AA").font(st == .editorial ? .system(size: 20, weight: .semibold, design: .serif) : .system(size: 20, weight: .black))
                        .fontWidth(st == .editorial ? .standard : .condensed)
                        .foregroundColor(p.ink)
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

    private func slideBinding<T>(_ kp: WritableKeyPath<SermonCarousel.Slide, T>) -> Binding<T> {
        Binding(get: { carousel!.slides[min(selected, carousel!.slides.count - 1)][keyPath: kp] },
                set: { v in
                    guard var c = carousel, c.slides.indices.contains(selected) else { return }
                    c.slides[selected][keyPath: kp] = v
                    carousel = c
                })
    }

    private func timeLabel(_ t: Double) -> String { String(format: "Photo at %d:%02d", Int(t) / 60, Int(t) % 60) }

    // MARK: Editing

    private func nudge(_ by: Double) {
        guard var c = carousel, c.slides.indices.contains(selected) else { return }
        c.slides[selected].time = max(0, c.slides[selected].time + by)
        carousel = c
    }

    private func move(_ i: Int, by d: Int) {
        guard var c = carousel, c.slides.indices.contains(i + d) else { return }
        c.slides.swapAt(i, i + d)
        carousel = c
        selected = i + d
    }

    private func duplicate(_ i: Int) {
        guard var c = carousel else { return }
        var copy = c.slides[i]; copy.id = UUID()
        c.slides.insert(copy, at: i + 1)
        carousel = c
        selected = i + 1
    }

    private func delete(_ i: Int) {
        guard var c = carousel, c.slides.count > 2 else { return }
        c.slides.remove(at: i)
        carousel = c
        selected = min(selected, c.slides.count - 1)
    }

    private func add(_ k: SermonCarousel.Kind) {
        guard var c = carousel else { return }
        let at = min(selected + 1, c.slides.count)
        var s = SermonCarousel.Slide(kind: k, eyebrow: k.defaultEyebrow, headline: "Your words here", emphasis: "words",
                                     time: c.slides.indices.contains(selected) ? c.slides[selected].time : 0)
        if k == .scripture { s.reference = "Book 1:1" }
        s.photo = k == .quote
        c.slides.insert(s, at: at)
        carousel = c
        selected = at
    }

    // MARK: Actions

    private func make() {
        guard let rec = record else { return }
        error = nil; saved = nil; status = "Starting…"
        Task {
            do {
                let c = try await CostTag.$video.withValue(rec.title) {
                    try await SermonCarousel.make(for: rec) { msg in Task { @MainActor in status = msg } }
                }
                carousel = c
                selected = 0
            } catch { self.error = error.localizedDescription }
            status = nil
        }
    }

    private func folderName(_ c: SermonCarousel) -> String {
        let t = (record?.title ?? c.title).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(t.prefix(60)) + " – Carousel"
    }

    private func exportAll() {
        guard let c = carousel, let folder = ReelExportLocation.pick(title: "Choose where to save the carousel") else { return }
        let dir = folder.appendingPathComponent(folderName(c))
        status = "Saving slides…"
        Task {
            await CarouselExport.write(c, photos: photos, to: dir)
            saved = dir
            status = nil
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private func sendToPhone() {
        guard let c = carousel else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AutoClip Carousel/" + folderName(c))
        try? FileManager.default.removeItem(at: dir)
        status = "Preparing slides…"
        Task {
            let urls = await CarouselExport.write(c, photos: photos, to: dir)
            status = nil
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        }
    }

    /// One slide as a PNG, for dragging out.
    private func dragSlide(_ c: SermonCarousel, _ i: Int) -> NSItemProvider {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(format: "Slide %02d.png", i + 1))
        if let d = CarouselExport.png(c, index: i, photo: photos.image(c.slides[i], c)) { try? d.write(to: url) }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}
