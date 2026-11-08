import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Colours for one carousel style. Fixed, never following the app's light or dark theme,
/// because these are images for Instagram.
struct CarouselPalette {
    let ground: Color, ink: Color, soft: Color, accent: Color, onAccent: Color
    /// Split style's top block
    let block: Color, onBlock: Color
    let groundNS: NSColor, accentNS: NSColor, rawAccentNS: NSColor

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static func contrast(_ c: NSColor) -> NSColor { c.luminance > 0.55 ? hex(0x141414) : hex(0xFBF7F0) }

    init(_ c: SermonCarousel) {
        let a = NSColor(hexString: c.accentHex)
        let h = Self.hex
        // A pale accent would vanish on paper
        let onPaper = a.luminance > 0.62 ? a.mixed(with: .black, 0.45) : a
        var g: NSColor, i: NSColor, ac: NSColor, on: NSColor? = nil, softness = 0.66
        switch c.style {
        case .bold: g = h(0x121315); i = h(0xF6F1E8); ac = a
        case .editorial: g = h(0xF2ECE2); i = h(0x1E1B17); ac = onPaper; softness = 0.64
        case .photo: g = h(0x0B0B0C); i = .white; ac = a; softness = 0.78
        case .color: g = a; i = Self.contrast(a); ac = i; on = a; softness = 0.72
        case .minimal: g = h(0xFAFAF7); i = h(0x161616); ac = onPaper; softness = 0.58
        case .gradient: g = a.mixed(with: h(0x0E0E12), 0.6); i = .white; ac = a.mixed(with: .white, 0.5); softness = 0.8
        case .split: g = h(0xF4EFE6); i = h(0x1A1A1A); ac = onPaper; softness = 0.62
        case .film: g = h(0x17130F); i = h(0xF1E6D3); ac = a
        case .poster: g = h(0xF1EADF); i = h(0x111111); ac = a
        }
        groundNS = g; accentNS = ac; rawAccentNS = a
        ground = Color(nsColor: g); ink = Color(nsColor: i); soft = Color(nsColor: i).opacity(softness)
        accent = Color(nsColor: ac); onAccent = Color(nsColor: on ?? Self.contrast(ac))
        block = Color(nsColor: a); onBlock = Color(nsColor: Self.contrast(a))
    }

    /// The two tones the series graphic is mapped to in Two-tone.
    func artTones(_ style: SermonCarousel.Style) -> (dark: NSColor, light: NSColor) {
        let h = Self.hex
        switch style {
        case .editorial, .minimal, .poster: return (accentNS.mixed(with: .black, 0.35), groundNS)
        case .split: return (rawAccentNS.mixed(with: .black, 0.55), rawAccentNS.mixed(with: .white, 0.35))
        case .color: return (rawAccentNS.mixed(with: .black, 0.55), rawAccentNS.mixed(with: .white, 0.55))
        case .gradient: return (h(0x0E0E12), rawAccentNS.mixed(with: .white, 0.25))
        default: return (groundNS.mixed(with: .black, 0.3), rawAccentNS.mixed(with: .white, 0.3))
        }
    }
}

/// The pictures a slide may use.
struct SlideImages {
    var photo: CGImage?
    /// The series graphic, reworked for the style, filling the slide (or Split's top block)
    var art: CGImage?
    /// The series graphic untouched, for the cover
    var rawArt: CGImage?
    /// The slide's own picture (AI-made or chosen), filling the slide or Split's block
    var bg: CGImage?
}

/// What the editor needs from a slide it's showing: clicks on words and stickers, and dragging.
struct SlideInteraction {
    enum Field: Hashable { case eyebrow, headline, body, reference }
    var editing: Field?
    var selectedLayer: UUID?
    var tapField: (Field) -> Void
    var tapLayer: (UUID) -> Void
    var moveLayer: (UUID, CGSize) -> Void
    var tapEmpty: () -> Void
    /// The words were dragged up or down by this fraction of the slide's height
    var moveText: (CGFloat) -> Void = { _ in }
}

/// One slide at full size (1080 wide). Used for the live preview (scaled) and for export.
struct SlideCanvas: View {
    let carousel: SermonCarousel
    let slide: SermonCarousel.Slide
    let index: Int
    let images: SlideImages
    var interaction: SlideInteraction? = nil
    @GestureState private var textDrag: CGFloat = 0

    private var pal: CarouselPalette { CarouselPalette(carousel) }
    private var W: CGFloat { carousel.shape.size.width }
    private var H: CGFloat { carousel.shape.size.height }
    private var square: Bool { carousel.shape == .square }
    private var style: SermonCarousel.Style { carousel.style }
    private var type: SermonCarousel.TypeChoice { carousel.type }
    private var upper: Bool { type.upper }
    private var condensedWidth: Bool { type == .condensed || type == .script }
    private var single: Bool { carousel.single == true }
    private var count: Int { carousel.slides.count }
    private var photo: CGImage? { images.photo }
    private var blockH: CGFloat { (H * 0.4).rounded() }
    private var story: Bool { carousel.shape == .story }
    private var hasBG: Bool { images.bg != nil }

    /// The crop each slide's photo needs (width / height).
    static func photoAspect(_ s: SermonCarousel.Slide, in c: SermonCarousel) -> CGFloat {
        let size = c.shape.size
        if c.style == .photo { return size.width / size.height }
        if c.style == .split { return size.width / (size.height * 0.4).rounded() }
        switch s.kind {
        case .quote: return [.film, .editorial, .minimal].contains(c.style) ? 260 / 330 : 1
        case .cover, .invite: return c.shape == .square ? 900 / 400 : 900 / 600
        default: return c.shape == .square ? 900 / 300 : 900 / 400
        }
    }

    static func needsPhoto(_ s: SermonCarousel.Slide, in c: SermonCarousel) -> Bool {
        if (showsArt(s, in: c) || s.bgPath != nil) && (c.style == .photo || c.style == .split) { return false }
        return c.style == .photo || s.photo
    }

    /// Whether the treated series graphic sits behind this slide.
    static func showsArt(_ s: SermonCarousel.Slide, in c: SermonCarousel) -> Bool {
        guard c.hasArt, s.bgPath == nil else { return false }
        if s.kind == .cover && c.artCover == true && c.style != .split { return false }
        return c.artOnAll == true || s.kind == .cover || s.kind == .cta
    }

    /// The size the treated graphic is made at.
    static func artSize(_ c: SermonCarousel) -> CGSize {
        let s = c.shape.size
        return c.style == .split ? CGSize(width: s.width, height: (s.height * 0.4).rounded()) : s
    }

    private var artBehind: Bool { Self.showsArt(slide, in: carousel) && images.art != nil }
    /// Cover and closing show the graphic strongly; other slides as a quiet texture
    private var artStrong: Bool { slide.kind == .cover || slide.kind == .cta }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
                .modifier(TapIf(action: interaction.map { it in { it.tapEmpty() } }))
            VStack(alignment: .leading, spacing: 0) {
                topBar
                content
                    .offset(y: CGFloat(slide.textNudge ?? 0) * H + textDrag)
                    .gesture(interaction == nil ? nil :
                        DragGesture(minimumDistance: 6)
                            // Drag distances arrive in the slide's own (full-size) units
                            .updating($textDrag) { v, s, _ in s = v.translation.height }
                            .onEnded { v in interaction?.moveText(v.translation.height / H) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
                    .padding(.top, style == .split ? blockH - 72 - 40 + 56 : 24)
                    .padding(.bottom, bottomRoom)
                bottomBar
            }
            .padding(.horizontal, 90).padding(.top, story ? 220 : 72).padding(.bottom, story ? 260 : 64)
            .frame(width: W, height: H, alignment: .topLeading)
            ForEach(slide.layerList) { l in
                LayerView(layer: l, pal: pal, W: W, H: H, interaction: interaction)
            }
        }
        .frame(width: W, height: H)
        .clipped()
    }

    /// Lets the editor click this bit of text to change it.
    private func editable<V: View>(_ v: V, _ f: SlideInteraction.Field) -> some View {
        v.modifier(EditableText(field: f, interaction: interaction, colour: pal.accent))
    }

    private var hasRibbon: Bool { [.bold, .editorial, .color, .film].contains(style) }
    private var contentAlignment: Alignment {
        switch slide.textAlign {
        case "top": return .topLeading
        case "middle": return .leading
        case "bottom": return .bottomLeading
        default: break
        }
        return style == .photo || ((artBehind && artStrong) || hasBG) && !style.light && style != .split ? .bottomLeading : .leading
    }
    private var bottomRoom: CGFloat {
        if style == .split { return 40 }
        if !hasRibbon { return 50 }
        return square ? 150 : 180
    }

    // MARK: Backgrounds

    @ViewBuilder private var backdrop: some View {
        pal.ground
        if style == .gradient { glow }
        if style == .split {
            splitBlock
        } else if let bg = images.bg {
            Image(decorative: bg, scale: 1).resizable().scaledToFill().frame(width: W, height: H).clipped()
            if style.light {
                pal.ground.opacity(0.42)
                LinearGradient(colors: [pal.ground.opacity(0), pal.ground.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            } else {
                darkFade(0.0)
            }
        } else if artBehind, let art = images.art {
            Image(decorative: art, scale: 1).resizable().frame(width: W, height: H)
            artVeil
        } else if style == .photo, let photo {
            Image(decorative: photo, scale: 1).resizable().scaledToFill().frame(width: W, height: H).clipped()
            darkFade(0.25)
        }
        if style == .film { grain }
        if style == .poster { halftone }
        if hasRibbon { ribbon }
        if style == .poster || style == .film || style == .gradient { sparkles }
    }

    /// A wash over the series graphic so the words stay readable.
    @ViewBuilder private var artVeil: some View {
        if !artStrong {
            pal.ground.opacity(style.light ? 0.86 : 0.8)
        } else if style.light {
            pal.ground.opacity(carousel.treatment == .original ? 0.62 : 0.48)
        } else {
            pal.ground.opacity(carousel.treatment == .original ? 0.3 : 0.12)
            darkFade(0.0)
        }
    }

    private func darkFade(_ top: Double) -> some View {
        LinearGradient(stops: [.init(color: .black.opacity(top + 0.1), location: 0), .init(color: .black.opacity(top), location: 0.3),
                               .init(color: .black.opacity(0.8), location: 0.6), .init(color: .black.opacity(0.94), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// One wide gradient cut into slides, so colour flows across the whole set.
    private var glow: some View {
        let a = pal.rawAccentNS
        let colors = [a.mixed(with: .black, 0.1), a.mixed(with: CarouselPalette.hex(0x0E0E12), 0.62),
                      CarouselPalette.hex(0x0E0E12), a.mixed(with: CarouselPalette.hex(0x0E0E12), 0.35),
                      a.mixed(with: .black, 0.2)].map { Color(nsColor: $0) }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(width: W * CGFloat(max(1, count)), height: H)
            .offset(x: -CGFloat(index) * W)
            .overlay(
                RadialGradient(colors: [Color(nsColor: a).opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: W * 0.7)
                    .frame(width: W * 1.4, height: W * 1.4)
                    .offset(x: index.isMultiple(of: 2) ? W * 0.25 : -W * 0.35, y: index.isMultiple(of: 2) ? -H * 0.25 : H * 0.15),
                alignment: .center)
            .frame(width: W, height: H, alignment: .topLeading)
            .clipped()
    }

    /// A few hand-placed sparkles, moving slide to slide.
    private var sparkles: some View {
        let spots: [(CGFloat, CGFloat, CGFloat)] = index.isMultiple(of: 2)
            ? [(W - 150, 190, 74), (W - 240, 285, 34), (W - 120, H * 0.6, 44)]
            : [(W - 170, 240, 58), (W - 110, 340, 30), (W - 200, H * 0.66, 40)]
        let colour = style == .poster ? pal.block : style == .film ? pal.ink.opacity(0.85) : Color.white.opacity(0.9)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<spots.count, id: \.self) { i in
                Image(systemName: i == 0 ? "sparkle" : "sparkle").font(.system(size: spots[i].2, weight: .black))
                    .foregroundColor(colour)
                    .position(x: spots[i].0, y: spots[i].1)
            }
        }
        .frame(width: W, height: H)
    }

    /// A corner of print dots, like a screen-printed poster.
    private var halftone: some View {
        Canvas { ctx, size in
            let step: CGFloat = 26
            for row in 0..<Int(size.height / step) {
                for col in 0..<Int(size.width / step) {
                    let x = CGFloat(col) * step + (row.isMultiple(of: 2) ? step / 2 : 0), y = CGFloat(row) * step
                    // Dots grow towards one corner, which alternates slide to slide
                    let fx = index.isMultiple(of: 2) ? x / size.width : 1 - x / size.width
                    let r = max(0, (fx + (index.isMultiple(of: 2) ? 1 - y / size.height : y / size.height) - 1.3)) * 18
                    if r > 0.6 { ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(pal.block.opacity(0.7))) }
                }
            }
        }
        .frame(width: W, height: H)
    }

    private var grain: some View {
        ZStack {
            if let n = Self.noise {
                Image(decorative: n, scale: 1).resizable(resizingMode: .tile).opacity(0.09).blendMode(.screen)
            }
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: W * 0.35, endRadius: W * 0.95)
        }
        .frame(width: W, height: H)
    }

    static let noise: CGImage? = {
        let f = CIFilter.randomGenerator()
        guard let img = f.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)) else { return nil }
        let mono = CIFilter.colorControls(); mono.inputImage = img; mono.saturation = 0; mono.contrast = 1.3
        guard let out = mono.outputImage else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }()

    @ViewBuilder private var splitBlock: some View {
        ZStack {
            pal.block
            if let bg = images.bg {
                Image(decorative: bg, scale: 1).resizable().scaledToFill()
            } else if artBehind, let art = images.art {
                Image(decorative: art, scale: 1).resizable().scaledToFill()
            } else if let photo {
                Image(decorative: photo, scale: 1).resizable().scaledToFill()
            }
            LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
            if slide.kind == .point && images.photo == nil && !artBehind {
                Text(String(format: "%02d", carousel.pointNumber(of: slide)))
                    .font(.system(size: blockH * 0.9, weight: .black)).fontWidth(.condensed)
                    .foregroundColor(pal.onBlock.opacity(0.18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 60).offset(y: blockH * 0.12)
            }
        }
        .frame(width: W, height: blockH).clipped()
    }

    /// A line that runs on from slide to slide, so the set reads as one piece when swiped.
    private var ribbon: some View {
        let x0 = CGFloat(index) * W
        let base = H - 200
        return Path { p in
            var first = true
            for gx in stride(from: x0 - 20, through: x0 + W + 20, by: 6) {
                let y = base + sin(gx / W * .pi * 0.9) * 42 + sin(gx / W * .pi * 2.3) * 12
                let pt = CGPoint(x: gx - x0, y: y)
                if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
            }
        }
        .stroke(pal.accent.opacity(style == .color ? 0.28 : 0.9),
                style: StrokeStyle(lineWidth: style == .editorial || style == .film ? 3 : 12, lineCap: .round))
    }

    // MARK: Pieces

    private var sticker: Bool { style == .poster }

    private var topBar: some View {
        let onBlock = style == .split
        return HStack(alignment: .firstTextBaseline) {
            let eyebrow = slide.kind == .point && slide.eyebrow.isEmpty ? "Point \(carousel.pointNumber(of: slide))" : slide.eyebrow
            if !eyebrow.isEmpty {
                editable(Text(eyebrow.uppercased())
                    .font(.system(size: 26, weight: .bold)).tracking(4)
                    .foregroundColor(onBlock || sticker ? pal.onBlock : style == .color ? pal.ink : pal.accent)
                    .lineLimit(1)
                    .padding(.horizontal, onBlock || sticker ? 16 : 0).padding(.vertical, onBlock || sticker ? 8 : 0)
                    .background(onBlock ? AnyView(Capsule().fill(pal.block.opacity(0.85)))
                                : sticker ? AnyView(RoundedRectangle(cornerRadius: 6).fill(pal.block)) : AnyView(EmptyView()))
                    .rotationEffect(.degrees(sticker ? -3 : 0)), .eyebrow)
            }
            Spacer(minLength: 20)
            if !single {
                Text(String(format: "%02d / %02d", index + 1, count))
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundColor(onBlock ? pal.onBlock.opacity(0.85) : pal.soft)
            }
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Text(carousel.handle).font(.system(size: 28, weight: .semibold)).foregroundColor(pal.soft).lineLimit(1)
            Spacer(minLength: 20)
            if single {
                EmptyView()
            } else if index == 0 && count > 1 {
                HStack(spacing: 12) {
                    Text("Swipe").font(.system(size: 28, weight: .bold))
                    Image(systemName: "arrow.right").font(.system(size: 26, weight: .bold))
                }
                .foregroundColor(pal.onAccent)
                .padding(.horizontal, 30).padding(.vertical, 16)
                .background(Capsule().fill(pal.accent))
            } else {
                HStack(spacing: 10) {
                    ForEach(0..<min(count, 12), id: \.self) { i in
                        Capsule().fill(i == index ? pal.accent : pal.soft.opacity(0.35))
                            .frame(width: i == index ? 34 : 12, height: 12)
                    }
                }
            }
        }
    }

    /// The speaker's photo inside the slide (not used where the photo fills the slide or block)
    private var insetPhoto: CGImage? { style == .photo || style == .split ? nil : photo }

    @ViewBuilder private var content: some View {
        switch slide.kind {
        case .cover:
            VStack(alignment: .leading, spacing: 44) {
                if carousel.artCover == true, style != .split, let raw = images.rawArt {
                    artPrint(raw)
                } else if let p = insetPhoto, !artBehind || style.light {
                    print(p, height: square ? 330 : 520)
                }
                headline(base: 172, ref: 18, lines: 5)
            }
        case .tension:
            VStack(alignment: .leading, spacing: 36) {
                headline(base: 128, ref: 24, lines: 5)
                bodyText(slide.body)
            }
        case .bigIdea:
            VStack(alignment: .leading, spacing: 44) {
                Capsule().fill(pal.accent).frame(width: 140, height: 16)
                headline(base: 140, ref: 28, lines: 6)
                if let p = insetPhoto { print(p, height: square ? 300 : 400) }
            }
        case .point:
            VStack(alignment: .leading, spacing: 30) {
                if style != .split {
                    Text(String(format: "%02d", carousel.pointNumber(of: slide)))
                        .font(numeralFont)
                        .fontWidth(condensedWidth ? .condensed : .standard)
                        .foregroundColor(pal.accent)
                        .padding(.bottom, -30)
                }
                headline(base: 118, ref: 26, lines: 4)
                bodyText(slide.body)
                if let p = insetPhoto { print(p, height: square ? 260 : 360) }
            }
        case .scripture:
            VStack(alignment: .leading, spacing: 30) {
                Text("“").font(.system(size: 260, weight: .bold, design: .serif)).foregroundColor(pal.accent)
                    .frame(height: 150, alignment: .top).padding(.bottom, -10)
                spoken(base: 84)
                editable(Text(slide.reference.uppercased()).font(.system(size: 32, weight: .bold)).tracking(4)
                    .foregroundColor(pal.accent), .reference)
            }
        case .quote:
            VStack(alignment: .leading, spacing: 36) {
                if let p = insetPhoto {
                    if [.film, .editorial, .minimal].contains(style) {
                        let arch = UnevenRoundedRectangle(topLeadingRadius: 130, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 130)
                        Image(decorative: p, scale: 1).resizable().scaledToFill()
                            .frame(width: 260, height: 330).clipShape(arch)
                            .overlay(arch.stroke(pal.accent, lineWidth: 4).padding(-10))
                            .padding(10)
                    } else {
                        Image(decorative: p, scale: 1).resizable().scaledToFill()
                            .frame(width: 230, height: 230).clipShape(Circle())
                            .overlay(Circle().stroke(pal.accent, lineWidth: 8))
                    }
                } else {
                    Text("“").font(.system(size: 260, weight: .bold, design: .serif)).foregroundColor(pal.accent)
                        .frame(height: 150, alignment: .top)
                }
                spoken(base: 86)
                let who = slide.reference.isEmpty ? carousel.handle : slide.reference
                if !who.isEmpty {
                    editable(Text("— " + who).font(.system(size: 32, weight: .semibold)).foregroundColor(pal.soft), .reference)
                }
            }
        case .question:
            VStack(alignment: .leading, spacing: 40) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 84))
                    .foregroundColor(pal.accent)
                headline(base: 132, ref: 26, lines: 5)
                bodyText(slide.body.isEmpty ? "Tell us in the comments." : slide.body)
            }
        case .invite:
            VStack(alignment: .leading, spacing: 40) {
                if let p = insetPhoto { print(p, height: square ? 300 : 440) }
                headline(base: 168, ref: 16, lines: 4)
                if !slide.body.isEmpty {
                    Text(slide.body).font(.system(size: square ? 38 : 44, weight: .bold))
                        .foregroundColor(pal.onAccent)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(Capsule().fill(pal.accent))
                        .lineLimit(2).minimumScaleFactor(0.6)
                }
            }
        case .cta:
            VStack(alignment: .leading, spacing: 44) {
                headline(base: 160, ref: 18, lines: 4)
                bodyText(slide.body)
                HStack(spacing: 18) {
                    action("bookmark.fill", "Save")
                    action("paperplane.fill", "Share")
                    action("play.fill", "Watch")
                }
            }
        }
    }

    // MARK: Type

    private func size(_ base: CGFloat, ref: Int, text: String) -> CGFloat {
        let n = max(1, text.count)
        var s = base * min(1, sqrt(CGFloat(ref) / CGFloat(n)))
        switch type {
        case .serif, .classic: s *= 0.86
        case .rounded, .modern, .slab: s *= 0.88
        default: break
        }
        if style == .minimal { s *= 0.9 }
        if style == .split { s *= 0.82 }
        if square { s *= 0.88 }
        return max(50, s)
    }

    private func headFont(_ s: CGFloat) -> Font {
        switch type {
        case .classic: return .custom("Didot-Bold", size: s)
        case .geometric: return .custom("Futura-CondensedExtraBold", size: s)
        case .slab: return .custom("Rockwell-Bold", size: s * 0.92)
        case .serif: return .system(size: s, weight: .semibold, design: .serif)
        case .rounded: return .system(size: s, weight: .heavy, design: .rounded)
        case .modern: return .system(size: s, weight: style == .minimal ? .bold : .heavy)
        default: return .system(size: s, weight: .black)
        }
    }

    private var numeralFont: Font {
        switch type {
        case .classic: return .custom("Didot-Italic", size: 210)
        case .script: return .custom("SnellRoundhand-Black", size: 220)
        case .geometric: return .custom("Futura-CondensedExtraBold", size: 220)
        case .slab: return .custom("Rockwell-Bold", size: 200)
        case .serif: return .system(size: 210, weight: .regular, design: .serif).italic()
        case .rounded: return .system(size: 200, weight: .black, design: .rounded)
        case .modern: return .system(size: 200, weight: style == .minimal ? .light : .black)
        default: return .system(size: 210, weight: .black)
        }
    }

    private func emphasise(_ a: inout AttributedString, _ r: Range<AttributedString.Index>, size s: CGFloat, spoken: Bool) {
        if style == .color {
            a[r].foregroundColor = pal.onAccent
            a[r].backgroundColor = pal.ink
            return
        }
        if style == .poster {
            // Marker-pen highlight
            a[r].foregroundColor = Color(nsColor: CarouselPalette.contrast(pal.rawAccentNS))
            a[r].backgroundColor = pal.block
            return
        }
        a[r].foregroundColor = pal.accent
        if type == .serif && !spoken {
            a[r].font = .system(size: s, weight: .semibold, design: .serif).italic()
        }
        if type == .classic { a[r].font = .custom("Didot-Italic", size: s * 1.04) }
        if style == .minimal { a[r].underlineStyle = .single }
    }

    private func styled(_ text: String, size s: CGFloat) -> AttributedString {
        var a = AttributedString(upper ? text.uppercased() : text)
        a.foregroundColor = pal.ink
        let e = slide.emphasis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty, let r = a.range(of: upper ? e.uppercased() : e, options: [.caseInsensitive, .diacriticInsensitive]) {
            if type == .script {
                // The highlighted words switch to handwriting, in their own case
                let original = slide.headline.range(of: e, options: [.caseInsensitive]).map { String(slide.headline[$0]) } ?? e
                var w = AttributedString(original)
                w.font = .custom("SnellRoundhand-Black", size: s * 1.3)
                w.foregroundColor = style == .poster || style.light ? pal.block : pal.accent
                a.replaceSubrange(r, with: w)
            } else {
                emphasise(&a, r, size: s, spoken: false)
            }
        }
        return a
    }

    private func headline(base: CGFloat, ref: Int, lines: Int) -> some View {
        editable(rawHeadline(base: base, ref: ref, lines: lines), .headline)
    }

    private func rawHeadline(base: CGFloat, ref: Int, lines: Int) -> some View {
        let s = size(base, ref: ref, text: slide.headline)
        return Text(styled(slide.headline, size: s))
            .font(headFont(s))
            .fontWidth(condensedWidth ? .condensed : .standard)
            .lineSpacing(type == .serif || type == .classic ? 4 : type == .script || type == .slab ? 2 : upper ? -s * 0.08 : -s * 0.03)
            .lineLimit(lines).minimumScaleFactor(0.45)
    }

    /// Spoken words (a verse or a quote) stay in sentence case so they read naturally.
    private func spoken(base: CGFloat) -> some View {
        editable(rawSpoken(base: base), .headline)
    }

    private func rawSpoken(base: CGFloat) -> some View {
        let s = size(base, ref: 70, text: slide.headline)
        var a = AttributedString(slide.headline)
        a.foregroundColor = pal.ink
        let e = slide.emphasis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty, let r = a.range(of: e, options: [.caseInsensitive]) { emphasise(&a, r, size: s, spoken: true) }
        let font: Font = switch type {
        case .classic: .custom("Didot", size: s)
        case .slab: .custom("Rockwell", size: s * 0.95)
        case .geometric: .custom("Futura-Medium", size: s * 0.95)
        case .serif: .system(size: s, weight: .medium, design: .serif)
        case .rounded: .system(size: s, weight: .bold, design: .rounded)
        default: .system(size: s, weight: style == .minimal ? .semibold : .bold)
        }
        return Text(a).font(font)
            .lineSpacing(s * 0.12)
            .lineLimit(9).minimumScaleFactor(0.45)
    }

    @ViewBuilder private func bodyText(_ text: String) -> some View {
        if !text.isEmpty {
            editable(rawBody(text), .body)
        } else if interaction != nil && [.tension, .point, .question, .cta, .invite].contains(slide.kind) {
            editable(Text("Add text").font(.system(size: 34, weight: .medium)).foregroundColor(pal.soft.opacity(0.5)), .body)
        }
    }

    @ViewBuilder private func rawBody(_ text: String) -> some View {
        if !text.isEmpty {
            let sz: CGFloat = square ? 36 : 40
            Text(text)
                .font(type == .serif || type == .classic ? .system(size: sz, design: .serif)
                      : type == .rounded ? .system(size: sz, weight: .medium, design: .rounded) : .system(size: sz, weight: .medium))
                .foregroundColor(pal.soft)
                .lineSpacing(10)
                .lineLimit(6).minimumScaleFactor(0.6)
        }
    }

    private func action(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28, weight: .bold))
            Text(label).font(.system(size: 30, weight: .bold))
        }
        .foregroundColor(pal.ink)
        .padding(.horizontal, 30).padding(.vertical, 18)
        .background(Capsule().stroke(pal.ink.opacity(0.4), lineWidth: 3))
    }

    private var tilted: Bool { style == .bold || style == .color || style == .poster }

    /// A photo set into the slide like a print: tilted and bordered in Bold and Colour.
    private func print(_ img: CGImage, height: CGFloat) -> some View {
        let w = W - 180
        return Image(decorative: img, scale: 1).resizable().scaledToFill()
            .frame(width: tilted ? w - 40 : w, height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: style.light ? 4 : 10, style: .continuous))
            .padding(tilted ? 14 : 0)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tilted ? Color.white : Color.clear))
            .shadow(color: .black.opacity(tilted ? 0.4 : 0), radius: 24, y: 12)
            .overlay(alignment: .top) { tape }
            .rotationEffect(.degrees(tilted ? -2.2 : 0))
            .padding(.leading, tilted ? 6 : 0)
    }

    @ViewBuilder private var tape: some View {
        if style == .poster {
            HStack {
                Rectangle().fill(Color(white: 0.95).opacity(0.75)).frame(width: 150, height: 44).rotationEffect(.degrees(-28)).offset(x: -40, y: -10)
                Spacer()
                Rectangle().fill(Color(white: 0.95).opacity(0.75)).frame(width: 150, height: 44).rotationEffect(.degrees(24)).offset(x: 40, y: -10)
            }
        }
    }

    /// The whole series graphic, uncropped, on the cover.
    private func artPrint(_ img: CGImage) -> some View {
        let w = W - 180 - (tilted ? 40 : 0)
        let aspect = CGFloat(img.width) / CGFloat(max(1, img.height))
        let h = min(w / aspect, square ? 360 : 560)
        return Image(decorative: img, scale: 1).resizable().scaledToFill()
            .frame(width: min(w, h * aspect), height: h).clipped()
            .clipShape(RoundedRectangle(cornerRadius: style.light ? 4 : 10, style: .continuous))
            .padding(tilted ? 14 : 0)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tilted ? Color.white : Color.clear))
            .shadow(color: .black.opacity(style.light ? 0.12 : 0.4), radius: 24, y: 12)
            .overlay(alignment: .top) { tape }
            .rotationEffect(.degrees(tilted ? -2.2 : 0))
            .padding(.leading, tilted ? 6 : 0)
    }
}

/// Words on a slide the editor can click: a dashed outline on hover and while editing.
struct EditableText: ViewModifier {
    let field: SlideInteraction.Field
    let interaction: SlideInteraction?
    let colour: Color
    @State private var hover = false

    func body(content: Content) -> some View {
        if let it = interaction {
            content
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(colour, style: StrokeStyle(lineWidth: 5, dash: [16, 10]))
                        .padding(-14)
                        .opacity(it.editing == field ? 1 : hover ? 0.6 : 0)
                        .allowsHitTesting(false))
                .onHover { hover = $0 }
                .onTapGesture { it.tapField(field) }
        } else {
            content
        }
    }
}

/// A sticker or drawing on a slide. Drag it in the editor to move it.
struct LayerView: View {
    let layer: SermonCarousel.Layer
    let pal: CarouselPalette
    let W: CGFloat
    let H: CGFloat
    let interaction: SlideInteraction?
    @GestureState private var drag: CGSize = .zero

    private var colour: Color {
        switch layer.colour {
        case nil: return pal.accent
        case "ink": return pal.ink
        case "white": return .white
        case let h?: return Color(nsColor: NSColor(hexString: h))
        }
    }

    private var aspect: CGFloat {
        switch SermonCarousel.Doodle(rawValue: layer.name) {
        case .arrow?, .circle?: return 0.62
        case .underline?, .squiggle?: return 0.26
        default: return 1
        }
    }

    var body: some View {
        let w = CGFloat(layer.size) * W
        let selected = interaction?.selectedLayer == layer.id
        drawing(w: w)
            .frame(width: w, height: w * aspect)
            .rotationEffect(.degrees(layer.rotation))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(Color.white, style: StrokeStyle(lineWidth: 4, dash: [12, 8]))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(-14).opacity(selected ? 1 : 0).allowsHitTesting(false))
            .contentShape(Rectangle())
            // Clicks and drags belong to the sticker itself, set before it's positioned on the slide
            .gesture(interaction == nil ? nil :
                DragGesture(minimumDistance: 2)
                    // Drag distances arrive in the slide's own (full-size) units, so they follow the pointer as is
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in interaction?.moveLayer(layer.id, CGSize(width: v.translation.width / W, height: v.translation.height / H)) })
            .modifier(TapIf(action: interaction.map { it in { it.tapLayer(layer.id) } }))
            .allowsHitTesting(interaction != nil)
            .position(x: CGFloat(layer.x) * W + drag.width, y: CGFloat(layer.y) * H + drag.height)
    }

    @ViewBuilder private func drawing(w: CGFloat) -> some View {
        if layer.kind == .symbol {
            Image(systemName: layer.name).resizable().scaledToFit().foregroundColor(colour)
        } else {
            switch SermonCarousel.Doodle(rawValue: layer.name) ?? .arrow {
            case .burst:
                Burst(points: 14, inner: 0.62).fill(colour)
            case .star4:
                Burst(points: 4, inner: 0.22).fill(colour)
            case .heart:
                Image(systemName: "heart").resizable().scaledToFit().fontWeight(.bold).foregroundColor(colour)
            case .badge:
                Badge(text: layer.text ?? "See you Sunday • ", colour: colour, ink: pal.onAccent, w: w)
            default:
                Doodle(kind: SermonCarousel.Doodle(rawValue: layer.name) ?? .arrow)
                    .stroke(colour, style: StrokeStyle(lineWidth: max(6, w * 0.05), lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// A click handler only in the editor, so slides elsewhere pass clicks through to their card.
struct TapIf: ViewModifier {
    let action: (() -> Void)?
    func body(content: Content) -> some View {
        if let action { content.contentShape(Rectangle()).onTapGesture(perform: action) } else { content }
    }
}

/// A star or starburst.
struct Burst: Shape {
    let points: Int
    let inner: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2
        for i in 0..<(points * 2) {
            let a = Double(i) / Double(points * 2) * 2 * .pi - .pi / 2
            let rad = i.isMultiple(of: 2) ? R : R * inner
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Hand-drawn marks: arrows, underlines, circles, squiggles, rays.
struct Doodle: Shape {
    let kind: SermonCarousel.Doodle
    func path(in r: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        switch kind {
        case .arrow:
            p.move(to: pt(0.04, 0.85))
            p.addCurve(to: pt(0.9, 0.22), control1: pt(0.25, 0.1), control2: pt(0.6, 0.05))
            p.move(to: pt(0.72, 0.1)); p.addLine(to: pt(0.92, 0.2)); p.addLine(to: pt(0.8, 0.42))
        case .underline:
            p.move(to: pt(0.02, 0.6))
            p.addCurve(to: pt(0.98, 0.4), control1: pt(0.35, 0.2), control2: pt(0.65, 0.85))
            p.move(to: pt(0.12, 0.85)); p.addQuadCurve(to: pt(0.86, 0.72), control: pt(0.5, 0.6))
        case .circle:
            p.addEllipse(in: CGRect(x: r.minX + r.width * 0.04, y: r.minY + r.height * 0.08, width: r.width * 0.9, height: r.height * 0.82))
            p.move(to: pt(0.78, 0.1)); p.addQuadCurve(to: pt(0.98, 0.32), control: pt(0.95, 0.12))
        case .squiggle:
            p.move(to: pt(0, 0.5))
            for i in 0..<6 {
                let x0 = CGFloat(i) / 6, x1 = CGFloat(i + 1) / 6
                p.addQuadCurve(to: pt(x1, 0.5), control: pt((x0 + x1) / 2, i.isMultiple(of: 2) ? 0.0 : 1.0))
            }
        case .rays:
            for (a, b) in [(CGPoint(x: 0.15, y: 0.55), CGPoint(x: 0.02, y: 0.3)), (CGPoint(x: 0.42, y: 0.4), CGPoint(x: 0.42, y: 0.05)),
                           (CGPoint(x: 0.68, y: 0.55), CGPoint(x: 0.85, y: 0.3))] {
                p.move(to: pt(a.x, a.y)); p.addLine(to: pt(b.x, b.y))
            }
        default:
            break
        }
        return p
    }
}

/// A round badge with words running around its edge and a smile in the middle.
struct Badge: View {
    let text: String
    let colour: Color
    let ink: Color
    let w: CGFloat
    var body: some View {
        let chars = Array(text.uppercased())
        let n = max(1, chars.count)
        ZStack {
            Circle().fill(colour)
            Circle().stroke(ink.opacity(0.5), lineWidth: w * 0.01).padding(w * 0.2)
            Image(systemName: "face.smiling").resizable().scaledToFit().fontWeight(.semibold).foregroundColor(ink).padding(w * 0.3)
            ForEach(0..<n, id: \.self) { i in
                Text(String(chars[i])).font(.system(size: w * 0.085, weight: .black)).foregroundColor(ink)
                    .offset(y: -w * 0.39)
                    .rotationEffect(.degrees(Double(i) / Double(n) * 360))
            }
        }
    }
}

/// A slide drawn at any size for the editor.
struct ScaledSlide: View {
    let carousel: SermonCarousel
    let index: Int
    let images: SlideImages
    let scale: CGFloat
    var interaction: SlideInteraction? = nil

    var body: some View {
        let size = carousel.shape.size
        SlideCanvas(carousel: carousel, slide: carousel.slides[index], index: index, images: images,
                    interaction: interaction)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .clipped()
    }
}

// MARK: Pictures and export

@MainActor
final class CarouselPhotoCache: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var loading: Set<String> = []
    private var sources: [String: CGImage] = [:]

    func photoKey(_ s: SermonCarousel.Slide, _ c: SermonCarousel) -> String? {
        guard SlideCanvas.needsPhoto(s, in: c) else { return nil }
        let tint = c.style == .photo ? c.accentHex : "-"
        return "p|\(Int(s.time * 10))|\(Int(SlideCanvas.photoAspect(s, in: c) * 100))|\(tint)"
    }

    func artKey(_ s: SermonCarousel.Slide, _ c: SermonCarousel) -> String? {
        guard SlideCanvas.showsArt(s, in: c), let p = c.artPath else { return nil }
        return "a|\(p)|\(c.treatment.rawValue)|\(c.style.rawValue)|\(c.accentHex)|\(c.shape.rawValue)"
    }

    func rawKey(_ s: SermonCarousel.Slide, _ c: SermonCarousel) -> String? {
        guard s.kind == .cover, c.artCover == true, c.hasArt, let p = c.artPath else { return nil }
        return "r|\(p)"
    }

    func bgKey(_ s: SermonCarousel.Slide, _ c: SermonCarousel) -> String? {
        guard let p = s.bgPath, FileManager.default.fileExists(atPath: p) else { return nil }
        return "b|\(p)|\(c.shape.rawValue)|\(c.style == .split)"
    }

    func keys(_ c: SermonCarousel) -> [String] {
        c.slides.flatMap { [photoKey($0, c), artKey($0, c), rawKey($0, c), bgKey($0, c)].compactMap { $0 } }
    }

    func images(_ s: SermonCarousel.Slide, _ c: SermonCarousel) -> SlideImages {
        SlideImages(photo: photoKey(s, c).flatMap { images[$0] },
                    art: artKey(s, c).flatMap { images[$0] },
                    rawArt: rawKey(s, c).flatMap { images[$0] },
                    bg: bgKey(s, c).flatMap { images[$0] })
    }

    /// Loads (once) the pictures a slide needs.
    @discardableResult
    func ensure(_ s: SermonCarousel.Slide, _ c: SermonCarousel) async -> SlideImages {
        if let k = photoKey(s, c), images[k] == nil, !loading.contains(k) {
            loading.insert(k)
            let framing: CarouselPhotos.Framing = c.style == .photo || c.style == .split ? .body : s.kind == .quote ? .face : .wide
            let img = await CarouselPhotos.photo(source: c.source, time: s.time, aspect: SlideCanvas.photoAspect(s, in: c),
                                                 framing: framing, tint: c.style == .photo ? NSColor(hexString: c.accentHex) : nil)
            loading.remove(k)
            if let img { images[k] = img }
        }
        if let k = bgKey(s, c), images[k] == nil, !loading.contains(k), let p = s.bgPath {
            loading.insert(k)
            let size = SlideCanvas.artSize(c)
            let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CarouselArt.load(p) else { return nil }
                return CarouselPhotos.crop(src, aspect: size.width / size.height, face: nil, framing: .wide)
            }.value
            loading.remove(k)
            if let img { images[k] = img }
        }
        if let p = c.artPath, (artKey(s, c) != nil || rawKey(s, c) != nil), sources[p] == nil {
            sources[p] = await Task.detached { CarouselArt.load(p) }.value
        }
        if let k = rawKey(s, c), images[k] == nil, let p = c.artPath, let src = sources[p] { images[k] = src }
        if let k = artKey(s, c), images[k] == nil, !loading.contains(k), let p = c.artPath, let src = sources[p] {
            loading.insert(k)
            let tones = CarouselPalette(c).artTones(c.style)
            let size = SlideCanvas.artSize(c), t = c.treatment
            let img = await Task.detached(priority: .userInitiated) {
                CarouselArt.treated(src, size: size, treatment: t, dark: tones.dark, light: tones.light)
            }.value
            loading.remove(k)
            if let img { images[k] = img }
        }
        return images(s, c)
    }

    /// The untouched series graphic, for picking colours.
    func source(_ path: String) async -> CGImage? {
        if let s = sources[path] { return s }
        let img = await Task.detached { CarouselArt.load(path) }.value
        sources[path] = img
        return img
    }
}

@MainActor
enum CarouselExport {
    static func png(_ c: SermonCarousel, index: Int, images: SlideImages) -> Data? {
        let size = c.shape.size
        let r = ImageRenderer(content: SlideCanvas(carousel: c, slide: c.slides[index], index: index, images: images)
            .frame(width: size.width, height: size.height))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    @discardableResult
    static func write(_ c: SermonCarousel, to dir: URL) async -> [URL] {
        await write(c, photos: CarouselPhotoCache(), to: dir)
    }

    /// Writes each single post as "Post 01.png" with its caption beside it.
    @discardableResult
    static func writePosts(_ c: SermonCarousel, photos: CarouselPhotoCache, to dir: URL) async -> [URL] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        var captions = ""
        for i in c.postList.indices {
            let p = c.post(i)
            let imgs = await photos.ensure(p.slides[0], p)
            let name = String(format: "Post %02d", i + 1)
            let url = dir.appendingPathComponent(name + ".png")
            if let d = png(p, index: 0, images: imgs) { try? d.write(to: url); out.append(url) }
            captions += "\(name)\n\(c.postList[i].caption ?? "")\n\n"
        }
        try? captions.write(to: dir.appendingPathComponent("Captions.txt"), atomically: true, encoding: .utf8)
        return out
    }

    /// Writes "01.png"… and the caption into `dir`. Returns the image files.
    @discardableResult
    static func write(_ c: SermonCarousel, photos: CarouselPhotoCache, to dir: URL) async -> [URL] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for i in c.slides.indices {
            let imgs = await photos.ensure(c.slides[i], c)
            let url = dir.appendingPathComponent(String(format: "%02d.png", i + 1))
            if let d = png(c, index: i, images: imgs) { try? d.write(to: url); out.append(url) }
        }
        try? c.captionWithTags.write(to: dir.appendingPathComponent("Caption.txt"), atomically: true, encoding: .utf8)
        return out
    }
}
