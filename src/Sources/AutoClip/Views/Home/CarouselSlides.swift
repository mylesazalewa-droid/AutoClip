import SwiftUI
import AppKit

/// Colours for one carousel style. Fixed, never following the app's light or dark theme,
/// because these are images for Instagram.
struct CarouselPalette {
    let ground: Color, ink: Color, soft: Color, accent: Color, onAccent: Color

    init(_ c: SermonCarousel) {
        let a = NSColor(hexString: c.accentHex)
        let lum = 0.2126 * a.redComponent + 0.7152 * a.greenComponent + 0.0722 * a.blueComponent
        func hex(_ v: UInt32) -> Color {
            Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        switch c.style {
        case .bold:
            ground = hex(0x121315); ink = hex(0xF6F1E8); soft = hex(0xF6F1E8).opacity(0.66)
            accent = Color(nsColor: a); onAccent = hex(0x121315)
        case .editorial:
            ground = hex(0xF2ECE2); ink = hex(0x1E1B17); soft = hex(0x1E1B17).opacity(0.64)
            // A pale accent would vanish on paper
            accent = lum > 0.72 ? hex(0xB4532F) : Color(nsColor: a); onAccent = hex(0xF2ECE2)
        case .photo:
            ground = hex(0x0B0B0C); ink = .white; soft = Color.white.opacity(0.78)
            accent = Color(nsColor: a); onAccent = hex(0x121315)
        case .color:
            ground = Color(nsColor: a)
            ink = lum > 0.55 ? hex(0x141414) : hex(0xFBF7F0)
            soft = ink.opacity(0.72)
            accent = ink; onAccent = Color(nsColor: a)
        }
    }
}

/// One slide at full size (1080 wide). Used for the live preview (scaled) and for export.
struct SlideCanvas: View {
    let carousel: SermonCarousel
    let slide: SermonCarousel.Slide
    let index: Int
    let photo: CGImage?

    private var pal: CarouselPalette { CarouselPalette(carousel) }
    private var W: CGFloat { carousel.shape.size.width }
    private var H: CGFloat { carousel.shape.size.height }
    private var square: Bool { carousel.shape == .square }
    private var style: SermonCarousel.Style { carousel.style }
    private var upper: Bool { style == .bold || style == .color }
    private var count: Int { carousel.slides.count }

    /// The crop each slide's photo needs (width / height).
    static func photoAspect(_ s: SermonCarousel.Slide, in c: SermonCarousel) -> CGFloat {
        let size = c.shape.size
        if c.style == .photo { return size.width / size.height }
        switch s.kind {
        case .quote: return 1
        case .cover: return c.shape == .square ? 900 / 400 : 900 / 600
        default: return c.shape == .square ? 900 / 300 : 900 / 400
        }
    }

    static func needsPhoto(_ s: SermonCarousel.Slide, in c: SermonCarousel) -> Bool { c.style == .photo || s.photo }

    var body: some View {
        ZStack(alignment: .topLeading) {
            pal.ground
            if style == .photo, let photo {
                Image(decorative: photo, scale: 1).resizable().scaledToFill().frame(width: W, height: H).clipped()
                LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black.opacity(0.25), location: 0.3),
                                       .init(color: .black.opacity(0.8), location: 0.58), .init(color: .black.opacity(0.94), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            if style != .photo { ribbon }
            VStack(alignment: .leading, spacing: 0) {
                topBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style == .photo ? .bottomLeading : .leading)
                    .padding(.top, 24)
                    .padding(.bottom, style == .photo ? 40 : (square ? 150 : 180))
                bottomBar
            }
            .padding(.horizontal, 90).padding(.top, 72).padding(.bottom, 64)
            .frame(width: W, height: H, alignment: .topLeading)
        }
        .frame(width: W, height: H)
        .clipped()
    }

    // MARK: Pieces

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
                style: StrokeStyle(lineWidth: style == .editorial ? 3 : 12, lineCap: .round))
    }

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline) {
            let eyebrow = slide.kind == .point && slide.eyebrow.isEmpty ? "Point \(carousel.pointNumber(of: slide))" : slide.eyebrow
            if !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(.system(size: 26, weight: .bold)).tracking(4)
                    .foregroundColor(style == .color ? pal.ink : pal.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 20)
            Text(String(format: "%02d / %02d", index + 1, count))
                .font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundColor(pal.soft)
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Text(carousel.handle).font(.system(size: 28, weight: .semibold)).foregroundColor(pal.soft).lineLimit(1)
            Spacer(minLength: 20)
            if index == 0 && count > 1 {
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

    @ViewBuilder private var content: some View {
        switch slide.kind {
        case .cover:
            VStack(alignment: .leading, spacing: 44) {
                if style != .photo, let photo { print(photo, height: square ? 330 : 520) }
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
                if style != .photo, let photo { print(photo, height: square ? 300 : 400) }
            }
        case .point:
            VStack(alignment: .leading, spacing: 30) {
                Text(String(format: "%02d", carousel.pointNumber(of: slide)))
                    .font(style == .editorial ? .system(size: 210, weight: .regular, design: .serif).italic()
                                              : .system(size: 210, weight: .black))
                    .fontWidth(upper ? .condensed : .standard)
                    .foregroundColor(pal.accent)
                    .padding(.bottom, -30)
                headline(base: 118, ref: 26, lines: 4)
                bodyText(slide.body)
                if style != .photo, let photo { print(photo, height: square ? 260 : 360) }
            }
        case .scripture:
            VStack(alignment: .leading, spacing: 30) {
                Text("“").font(.system(size: 260, weight: .bold, design: .serif)).foregroundColor(pal.accent)
                    .frame(height: 150, alignment: .top).padding(.bottom, -10)
                spoken(base: 84)
                Text(slide.reference.uppercased()).font(.system(size: 32, weight: .bold)).tracking(4)
                    .foregroundColor(pal.accent)
            }
        case .quote:
            VStack(alignment: .leading, spacing: 36) {
                if style != .photo, let photo {
                    Image(decorative: photo, scale: 1).resizable().scaledToFill()
                        .frame(width: 230, height: 230).clipShape(Circle())
                        .overlay(Circle().stroke(pal.accent, lineWidth: 8))
                } else {
                    Text("“").font(.system(size: 260, weight: .bold, design: .serif)).foregroundColor(pal.accent)
                        .frame(height: 150, alignment: .top)
                }
                spoken(base: 86)
                let who = slide.reference.isEmpty ? carousel.handle : slide.reference
                if !who.isEmpty {
                    Text("— " + who).font(.system(size: 32, weight: .semibold)).foregroundColor(pal.soft)
                }
            }
        case .question:
            VStack(alignment: .leading, spacing: 40) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 84))
                    .foregroundColor(pal.accent)
                headline(base: 132, ref: 26, lines: 5)
                bodyText(slide.body.isEmpty ? "Tell us in the comments." : slide.body)
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
        if style == .editorial { s *= 0.86 }
        if style == .photo { s *= 0.9 }
        if square { s *= 0.88 }
        return max(52, s)
    }

    private func headFont(_ s: CGFloat) -> Font {
        style == .editorial ? .system(size: s, weight: .semibold, design: .serif) : .system(size: s, weight: .black)
    }

    private func styled(_ text: String, size s: CGFloat) -> AttributedString {
        var a = AttributedString(upper ? text.uppercased() : text)
        a.foregroundColor = pal.ink
        let e = slide.emphasis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty, let r = a.range(of: upper ? e.uppercased() : e, options: [.caseInsensitive, .diacriticInsensitive]) {
            switch style {
            case .bold, .photo:
                a[r].foregroundColor = pal.accent
            case .editorial:
                a[r].foregroundColor = pal.accent
                a[r].font = .system(size: s, weight: .semibold, design: .serif).italic()
            case .color:
                a[r].foregroundColor = pal.onAccent
                a[r].backgroundColor = pal.ink
            }
        }
        return a
    }

    private func headline(base: CGFloat, ref: Int, lines: Int) -> some View {
        let s = size(base, ref: ref, text: slide.headline)
        return Text(styled(slide.headline, size: s))
            .font(headFont(s))
            .fontWidth(upper ? .condensed : .standard)
            .lineSpacing(style == .editorial ? 4 : -s * 0.08)
            .lineLimit(lines).minimumScaleFactor(0.45)
    }

    /// Spoken words (a verse or a quote) stay in sentence case so they read naturally.
    private func spoken(base: CGFloat) -> some View {
        let s = size(base, ref: 70, text: slide.headline)
        var a = AttributedString(slide.headline)
        a.foregroundColor = pal.ink
        let e = slide.emphasis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty, let r = a.range(of: e, options: [.caseInsensitive]) {
            if style == .color { a[r].foregroundColor = pal.onAccent; a[r].backgroundColor = pal.ink }
            else { a[r].foregroundColor = pal.accent }
        }
        return Text(a)
            .font(style == .editorial ? .system(size: s, weight: .medium, design: .serif) : .system(size: s, weight: .bold))
            .lineSpacing(s * 0.12)
            .lineLimit(9).minimumScaleFactor(0.45)
    }

    @ViewBuilder private func bodyText(_ text: String) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(style == .editorial ? .system(size: square ? 36 : 40, design: .serif) : .system(size: square ? 36 : 40, weight: .medium))
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

    /// A photo set into the slide like a print: tilted and bordered in Bold and Colour.
    private func print(_ img: CGImage, height: CGFloat) -> some View {
        let w = W - 180
        let tilted = style == .bold || style == .color
        return Image(decorative: img, scale: 1).resizable().scaledToFill()
            .frame(width: tilted ? w - 40 : w, height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: style == .editorial ? 4 : 10, style: .continuous))
            .padding(tilted ? 14 : 0)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tilted ? Color.white : Color.clear))
            .shadow(color: .black.opacity(tilted ? 0.4 : 0), radius: 24, y: 12)
            .rotationEffect(.degrees(tilted ? -2.2 : 0))
            .padding(.leading, tilted ? 6 : 0)
    }
}

/// A slide drawn at any size for the editor.
struct ScaledSlide: View {
    let carousel: SermonCarousel
    let index: Int
    let photo: CGImage?
    let scale: CGFloat

    var body: some View {
        let size = carousel.shape.size
        SlideCanvas(carousel: carousel, slide: carousel.slides[index], index: index, photo: photo)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .clipped()
    }
}

// MARK: Photos and export

@MainActor
final class CarouselPhotoCache: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var loading: Set<String> = []

    func key(_ s: SermonCarousel.Slide, _ c: SermonCarousel) -> String? {
        guard SlideCanvas.needsPhoto(s, in: c) else { return nil }
        let tint = c.style == .photo ? c.accentHex : "-"
        return "\(Int(s.time * 10))|\(Int(SlideCanvas.photoAspect(s, in: c) * 100))|\(tint)"
    }

    func image(_ s: SermonCarousel.Slide, _ c: SermonCarousel) -> CGImage? {
        key(s, c).flatMap { images[$0] }
    }

    /// Loads (once) the photo a slide needs.
    func ensure(_ s: SermonCarousel.Slide, _ c: SermonCarousel) async -> CGImage? {
        guard let k = key(s, c) else { return nil }
        if let i = images[k] { return i }
        guard !loading.contains(k) else { return nil }
        loading.insert(k)
        let framing: CarouselPhotos.Framing = c.style == .photo ? .body : s.kind == .quote ? .face : .wide
        let img = await CarouselPhotos.photo(source: c.source, time: s.time, aspect: SlideCanvas.photoAspect(s, in: c),
                                             framing: framing, tint: c.style == .photo ? NSColor(hexString: c.accentHex) : nil)
        loading.remove(k)
        if let img { images[k] = img }
        return img
    }
}

@MainActor
enum CarouselExport {
    static func png(_ c: SermonCarousel, index: Int, photo: CGImage?) -> Data? {
        let size = c.shape.size
        let r = ImageRenderer(content: SlideCanvas(carousel: c, slide: c.slides[index], index: index, photo: photo)
            .frame(width: size.width, height: size.height))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    @discardableResult
    static func write(_ c: SermonCarousel, to dir: URL) async -> [URL] {
        await write(c, photos: CarouselPhotoCache(), to: dir)
    }

    /// Writes "01.png"… and the caption into `dir`. Returns the image files.
    @discardableResult
    static func write(_ c: SermonCarousel, photos: CarouselPhotoCache, to dir: URL) async -> [URL] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for i in c.slides.indices {
            let photo = await photos.ensure(c.slides[i], c) ?? photos.image(c.slides[i], c)
            let url = dir.appendingPathComponent(String(format: "%02d.png", i + 1))
            if let d = png(c, index: i, photo: photo) { try? d.write(to: url); out.append(url) }
        }
        try? c.captionWithTags.write(to: dir.appendingPathComponent("Caption.txt"), atomically: true, encoding: .utf8)
        return out
    }
}
