import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Manage → Brand kit: the church's name, logo, colours and type, set once for every graphic and clip.
struct BrandKitTab: View {
    @State private var kit = BrandKit.load() ?? BrandKit()
    @State private var saved = BrandKit.load()
    @State private var dropping = false
    @State private var note: String?
    @State private var confirmUpdate = false

    private var dirty: Bool { saved != kit }

    var body: some View {
        ScrollView {
            PageHeader(eyebrow: "Manage", title: "Brand kit",
                       subtitle: "Your church's look, set once. New carousels, posts and clips use it.") {
                if saved != nil && !dirty {
                    Label("Saved", systemImage: "checkmark").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.good)
                }
                Button { save() } label: { Label("Save brand kit", systemImage: "checkmark.circle") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(!dirty && saved != nil)
            }
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 18) {
                    nameCard
                    logoCard
                    colourCard
                    clipsCard
                    if saved != nil { existingCard }
                }
                .frame(maxWidth: 560)
                preview
                    .frame(width: 330)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.bottom, 28).padding(.top, 8)
        }
        .alert("Update every sermon's graphics?", isPresented: $confirmUpdate) {
            Button("Update") { updateExisting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Carousels and posts you've already made change to the brand colour, type and handle. Their words, photos and series graphics stay the same.")
        }
    }

    // MARK: Cards

    private var nameCard: some View {
        AssessCard(title: "Name", subtitle: "Shown in the corner of every graphic.") {
            field("Church name", "Grace Community Church", $kit.name)
            field("Instagram handle", "@gracecommunity", $kit.handle)
            field("Website", "gracecommunity.church", $kit.website)
            field("Service times", "Sundays at 9 and 11am", $kit.serviceTimes)
            Text("Invite posts mention your service times.").font(.system(size: 11.5)).foregroundColor(Theme.faint)
        }
    }

    private var logoCard: some View {
        AssessCard(title: "Logo", subtitle: "A PNG with a see-through background works best.") {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                    if let img = BrandLogo.image(onDark: true, kit: kit) {
                        Image(decorative: img, scale: 1).resizable().scaledToFit().padding(14)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 22))
                            Text("Drop a logo").font(.system(size: 11.5))
                        }.foregroundColor(.white.opacity(0.6))
                    }
                    if dropping { RoundedRectangle(cornerRadius: 10).stroke(Theme.sand, style: StrokeStyle(lineWidth: 2, dash: [6])) }
                }
                .frame(width: 130, height: 90)
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { setLogo(url) } }
                    }
                    return true
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(kit.hasLogo ? "Change…" : "Choose a logo…") { chooseLogo() }.buttonStyle(SecondaryButtonStyle(compact: true))
                        if kit.hasLogo {
                            Button("Remove") { kit.logoPath = nil }.buttonStyle(.link).font(.system(size: 12))
                        }
                    }
                    if kit.hasLogo {
                        HStack {
                            Text("Colour").font(.system(size: 12)).foregroundColor(Theme.muted)
                            Picker("", selection: $kit.logoColour) {
                                ForEach(BrandKit.LogoColour.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 170)
                        }
                        Button { colourFromLogo() } label: { Label("Take the colour from the logo", systemImage: "eyedropper") }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
            Toggle("Put the logo on graphics", isOn: $kit.logoOnGraphics).disabled(!kit.hasLogo)
            Toggle("Put the logo on clips (top left)", isOn: $kit.logoOnClips).disabled(!kit.hasLogo)
        }
    }

    private var colourCard: some View {
        AssessCard(title: "Colours and type", subtitle: "The main colour leads. A second colour alternates across the week's posts.") {
            HStack(spacing: 22) {
                colourWell("Main", Binding(get: { kit.primaryHex }, set: { kit.primaryHex = $0 }))
                if let second = kit.secondaryHex {
                    colourWell("Second", Binding(get: { second }, set: { kit.secondaryHex = $0 }))
                    Button("Remove") { kit.secondaryHex = nil }.buttonStyle(.link).font(.system(size: 12))
                } else {
                    Button { kit.secondaryHex = "F1E9DC" } label: { Label("Add a second colour", systemImage: "plus") }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(SermonCarousel.accents, id: \.self) { hex in
                    Circle().fill(Color(nsColor: NSColor(hexString: hex))).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Theme.ink, lineWidth: kit.primaryHex == hex ? 2 : 0).padding(-3))
                        .onTapGesture { kit.primaryHex = hex }
                        .help("Use as the main colour")
                }
            }
            HStack {
                Text("Headline type").font(.system(size: 12)).foregroundColor(Theme.muted)
                Picker("", selection: $kit.font) {
                    ForEach(SermonCarousel.TypeChoice.allCases) { t in
                        Text(t == .auto ? "Each style's own" : t.label).tag(t)
                    }
                }.labelsHidden().frame(width: 180)
            }
        }
    }

    private var clipsCard: some View {
        AssessCard(title: "Clips", subtitle: "Captions for new clips use your colours: the main colour for the word being said, the second for key words.") {
            Toggle("Use the brand colours in captions", isOn: $kit.captionColours)
        }
    }

    private var existingCard: some View {
        AssessCard(title: "Graphics you've already made", subtitle: "New ones use the brand on their own. Bring older ones in line too.") {
            Button { confirmUpdate = true } label: { Label("Update existing graphics…", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(dirty)
                .help(dirty ? "Save the brand kit first" : "")
            if let note { Text(note).font(.system(size: 12.5)).foregroundColor(Theme.good) }
        }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PREVIEW").font(.system(size: 11.5, weight: .semibold)).tracking(1.6).foregroundColor(Theme.sand.opacity(0.85))
            HStack(spacing: 12) {
                sample(.bold, kind: .bigIdea, headline: "Grace meets you where you are", emphasis: "Grace", accent: kit.primaryHex)
                sample(.editorial, kind: .question, headline: "Where do you need rest this week?", emphasis: "rest",
                       accent: kit.secondaryHex ?? kit.primaryHex)
            }
            captionSample
            Text("Graphics show your logo and handle in the bottom corner.").font(.system(size: 11.5)).foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sample(_ style: SermonCarousel.Style, kind: SermonCarousel.Kind, headline: String, emphasis: String, accent: String) -> some View {
        var c = SermonCarousel(title: "", bigIdea: "", slides: [SermonCarousel.Slide(kind: kind, eyebrow: kind.defaultEyebrow, headline: headline, emphasis: emphasis)],
                               caption: "", hashtags: [], source: "", style: style, accentHex: accent)
        c.single = true
        c.handle = kit.signature.isEmpty ? "@yourchurch" : kit.signature
        if kit.font != .auto { c.font = kit.font }
        // Draw with the kit being edited, not the saved one
        let scale: CGFloat = 0.148
        return PreviewSlide(carousel: c, kit: kit, scale: scale)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private var captionSample: some View {
        let main = Color(nsColor: NSColor(hexString: kit.primaryHex))
        let second = Color(nsColor: NSColor(hexString: kit.secondaryHex ?? kit.primaryHex))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            if kit.logoOnClips, let img = BrandLogo.image(onDark: true, kit: kit) {
                Image(decorative: img, scale: 1).resizable().scaledToFit().frame(maxWidth: 70, maxHeight: 18).padding(10)
            }
            VStack {
                Spacer()
                (Text("HE ").foregroundColor(.white) + Text("NEVER ").foregroundColor(kit.captionColours ? main : .yellow)
                 + Text("LETS ").foregroundColor(.white) + Text("GO").foregroundColor(kit.captionColours ? second : .white))
                    .font(.custom("Impact", size: 22))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(.bottom, 22)
            }.frame(maxWidth: .infinity)
        }
        .frame(height: 120)
    }

    // MARK: Pieces

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.muted).frame(width: 120, alignment: .leading)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func colourWell(_ label: String, _ hex: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hexString: hex.wrappedValue)) },
                                               set: { hex.wrappedValue = NSColor($0).hexString }), supportsOpacity: false)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.ink)
                Text("#" + hex.wrappedValue).font(.system(size: 11).monospaced()).foregroundColor(Theme.faint)
            }
        }
    }

    // MARK: Actions

    private func chooseLogo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        p.message = "Choose your church's logo"
        if p.runModal() == .OK, let url = p.url { setLogo(url) }
    }

    private func setLogo(_ url: URL) {
        guard NSImage(contentsOf: url) != nil, let path = BrandKit.importLogo(url) else { return }
        kit.logoPath = path
        BrandLogo.forget()
    }

    private func colourFromLogo() {
        guard let p = kit.logoPath, let img = CarouselArt.load(p), let c = CarouselArt.mainColour(img) else { return }
        kit.primaryHex = c.hexString
    }

    private func save() {
        kit.save()
        if kit.captionColours {
            var l = CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0])
            l.applyBrand(kit)
            l.save()
        }
        saved = kit
        note = nil
    }

    private func updateExisting() {
        var n = 0
        for id in CarouselStore.allIDs() {
            guard var c = CarouselStore.load(id) else { continue }
            c.applyBrand(kit)
            CarouselStore.save(c, for: id)
            n += 1
        }
        note = n == 0 ? "No graphics to update yet." : "Updated \(n) sermon\(n == 1 ? "" : "s")."
    }
}

/// A slide drawn with a brand kit that hasn't been saved yet.
private struct PreviewSlide: View {
    let carousel: SermonCarousel
    let kit: BrandKit
    let scale: CGFloat
    var body: some View {
        ScaledSlide(carousel: carousel, index: 0, images: SlideImages(), scale: scale, kit: kit)
    }
}
