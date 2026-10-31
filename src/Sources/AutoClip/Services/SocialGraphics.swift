import AppKit
import AVFoundation
import CoreImage
import Vision

/// Still graphics made from a talk: quote cards and carousel slides (1080x1350) and a
/// thumbnail for the full video (1280x720). Backgrounds are frames of the speaker taken
/// from the source video; type uses the reel's caption look so everything matches.
enum SocialGraphics {
    enum Kind: String { case quote, cover, slide, end, thumbnail }

    struct Card: Identifiable, Equatable {
        var id = UUID()
        var kind: Kind
        var text: String
        /// Source-video time of the background frame
        var time: Double
        /// Position in a carousel (1-based) and its length
        var index = 0
        var count = 0

        var size: CGSize { kind == .thumbnail ? CGSize(width: 1280, height: 720) : CGSize(width: 1080, height: 1350) }
        var fileName: String {
            switch kind {
            case .quote: return "Quote \(index).png"
            case .cover, .slide, .end: return "Carousel \(index) of \(count).png"
            case .thumbnail: return "Thumbnail.png"
            }
        }
    }

    /// Turns the AI plan into cards (all editable before export).
    static func cards(from plan: LLMClipService.GraphicsPlan, sentences: [ReelDraft.Sentence]) -> [Card] {
        func time(_ i: Int) -> Double {
            guard sentences.indices.contains(i) else { return 0 }
            let s = sentences[i]
            return s.start + min(1.0, (s.end - s.start) / 2)
        }
        var out: [Card] = []
        out.append(Card(kind: .thumbnail, text: plan.thumbnailHeadline, time: time(plan.thumbnailSentence)))
        for (i, q) in plan.quotes.enumerated() {
            out.append(Card(kind: .quote, text: q.text, time: time(q.sentence), index: i + 1))
        }
        let slides = plan.carouselSlides
        if !plan.carouselTitle.isEmpty || !slides.isEmpty {
            let n = slides.count + 2
            // Carousel backgrounds walk through the quotes' moments for variety
            let times = plan.quotes.map { time($0.sentence) }
            func t(_ k: Int) -> Double { times.isEmpty ? time(plan.thumbnailSentence) : times[k % times.count] }
            out.append(Card(kind: .cover, text: plan.carouselTitle, time: t(0), index: 1, count: n))
            for (k, s) in slides.enumerated() {
                out.append(Card(kind: .slide, text: s, time: t(k + 1), index: k + 2, count: n))
            }
            out.append(Card(kind: .end, text: "Watch the full message", time: t(slides.count + 1), index: n, count: n))
        }
        return out
    }

    // MARK: Frames

    /// A full-resolution still from the source video.
    static func frame(at time: Double, source: String) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: source)))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        return try? await gen.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
    }

    /// Normalised centre of the largest face (top-left origin), if any.
    static func faceCenter(in image: CGImage) -> CGPoint? {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let f = (req.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        return CGPoint(x: f.boundingBox.midX, y: 1 - f.boundingBox.midY)
    }

    // MARK: Rendering

    static func render(_ card: Card, background: CGImage?, look: CaptionLook, footer: String) -> NSImage {
        let size = card.size
        let face = background.flatMap { faceCenter(in: $0) }
        return NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.06, alpha: 1).setFill()
            CGRect(origin: .zero, size: size).fill()
            switch card.kind {
            case .thumbnail: drawThumbnail(card, bg: background, face: face, look: look, size: size)
            case .quote: drawQuote(card, bg: background, face: face, look: look, footer: footer, size: size)
            case .cover: drawCover(card, bg: background, face: face, look: look, size: size)
            case .slide, .end: drawSlide(card, bg: background, look: look, footer: footer, size: size)
            }
            return true
        }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func drawQuote(_ c: Card, bg: CGImage?, face: CGPoint?, look: CaptionLook, footer: String, size: CGSize) {
        if let bg { drawFill(bg, in: CGRect(origin: .zero, size: size), focus: face, faceAt: CGPoint(x: 0.5, y: 0.26)) }
        gradient(in: CGRect(origin: .zero, size: size), from: 0.15, to: 0.92, vertical: true)
        let box = CGRect(x: 90, y: 560, width: size.width - 180, height: 600)
        let fs = fit(c.text, look: look, in: box, maxSize: 92, minSize: 40, align: .left)
        // Big opening quote mark sits just above the text block
        let mark = NSAttributedString(string: "“", attributes: [
            .font: NSFont(name: "Georgia-Bold", size: 230) ?? NSFont.boldSystemFont(ofSize: 230),
            .foregroundColor: look.highlightColor.nsColor])
        mark.draw(at: CGPoint(x: 70, y: box.minY - 150 + (box.height - fs.height)))
        draw(c.text, look: look, size: fs.size, in: CGRect(x: box.minX, y: box.maxY - fs.height, width: box.width, height: fs.height), align: .left)
        label("— " + footer, at: CGPoint(x: 90, y: size.height - 120), size: 30, color: look.highlightColor.nsColor)
    }

    private static func drawCover(_ c: Card, bg: CGImage?, face: CGPoint?, look: CaptionLook, size: CGSize) {
        if let bg { drawFill(bg, in: CGRect(origin: .zero, size: size), focus: face, faceAt: CGPoint(x: 0.5, y: 0.26)) }
        gradient(in: CGRect(origin: .zero, size: size), from: 0.1, to: 0.9, vertical: true)
        let text = c.text.uppercased()
        let box = CGRect(x: 80, y: 640, width: size.width - 160, height: 520)
        let fs = fit(text, look: look, in: box, maxSize: 130, minSize: 56, align: .left, highlightLast: true)
        draw(text, look: look, size: fs.size, in: CGRect(x: box.minX, y: box.maxY - fs.height, width: box.width, height: fs.height),
             align: .left, highlightLast: true)
        label("\(c.index)/\(c.count)", at: CGPoint(x: size.width - 140, y: 60), size: 30, color: .white.withAlphaComponent(0.8))
        label("Swipe →", at: CGPoint(x: size.width - 230, y: size.height - 110), size: 36, color: look.highlightColor.nsColor)
    }

    private static func drawSlide(_ c: Card, bg: CGImage?, look: CaptionLook, footer: String, size: CGSize) {
        if let bg, let soft = blurred(bg, radius: 28) {
            drawFill(soft, in: CGRect(origin: .zero, size: size), focus: nil, faceAt: .zero)
            NSColor.black.withAlphaComponent(0.72).setFill()
            CGRect(origin: .zero, size: size).fill(using: .sourceOver)
        }
        label("\(c.index)/\(c.count)", at: CGPoint(x: size.width - 140, y: 60), size: 30, color: .white.withAlphaComponent(0.7))
        let box = CGRect(x: 100, y: 300, width: size.width - 200, height: 760)
        if c.kind == .end {
            let fs = fit(c.text.uppercased(), look: look, in: box, maxSize: 110, minSize: 50, align: .center, highlightLast: true)
            draw(c.text.uppercased(), look: look, size: fs.size,
                 in: CGRect(x: box.minX, y: box.midY - fs.height / 2, width: box.width, height: fs.height),
                 align: .center, highlightLast: true)
            let sub = NSAttributedString(string: footer, attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                .paragraphStyle: para(.center)])
            sub.draw(with: CGRect(x: box.minX, y: box.midY + fs.height / 2 + 40, width: box.width, height: 120),
                     options: [.usesLineFragmentOrigin])
            return
        }
        // Slide number as a big accent
        let num = NSAttributedString(string: "\(c.index - 1)", attributes: [
            .font: look.font(size: 150), .foregroundColor: look.highlightColor.nsColor])
        num.draw(at: CGPoint(x: 100, y: 120))
        let fs = fit(c.text, look: look, in: box, maxSize: 84, minSize: 40, align: .left)
        draw(c.text, look: look, size: fs.size, in: CGRect(x: box.minX, y: box.midY - fs.height / 2 + 60, width: box.width, height: fs.height), align: .left)
    }

    private static func drawThumbnail(_ c: Card, bg: CGImage?, face: CGPoint?, look: CaptionLook, size: CGSize) {
        let full = CGRect(origin: .zero, size: size)
        // Put the speaker on the right third if the frame allows; otherwise text goes opposite them
        var textOnLeft = true
        if let bg {
            let p = placement(bg, in: full, focus: face, faceAt: CGPoint(x: 0.7, y: 0.4), zoom: 1.35)
            if let f = face, (p.rect.minX + f.x * p.rect.width - full.minX) / full.width < 0.5 {
                textOnLeft = false
                drawFill(bg, in: full, focus: face, faceAt: CGPoint(x: 0.3, y: 0.4), zoom: 1.35)
            } else {
                drawFill(bg, in: full, focus: face, faceAt: CGPoint(x: 0.7, y: 0.4), zoom: 1.35)
            }
        }
        gradient(in: full, from: 0.9, to: 0.0, vertical: false, stop: 0.6, reversed: !textOnLeft)
        let text = c.text.uppercased()
        let w = size.width * 0.56
        let box = CGRect(x: textOnLeft ? 56 : size.width - 56 - w, y: 90, width: w, height: size.height - 180)
        var thumbLook = look
        thumbLook.strokeColor = .black
        thumbLook.strokeWidth = max(look.strokeWidth, 5)
        let align: NSTextAlignment = textOnLeft ? .left : .right
        let fs = fit(text, look: thumbLook, in: box, maxSize: 190, minSize: 70, align: align, highlightLast: true)
        draw(text, look: thumbLook, size: fs.size, in: CGRect(x: box.minX, y: box.midY - fs.height / 2, width: box.width, height: fs.height),
             align: align, highlightLast: true)
    }

    // MARK: Drawing helpers

    /// Where an aspect-filled `image` lands so its face (if any) sits at `faceAt` (fractions of rect).
    private static func placement(_ image: CGImage, in rect: CGRect, focus: CGPoint?, faceAt: CGPoint,
                                  zoom: CGFloat = 1) -> (rect: CGRect, size: CGSize) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(rect.width / iw, rect.height / ih) * zoom
        let w = iw * scale, h = ih * scale
        var x = rect.midX - w / 2, y = rect.midY - h / 2
        if let f = focus {
            x = rect.minX + rect.width * faceAt.x - f.x * w
            y = rect.minY + rect.height * faceAt.y - f.y * h
        }
        x = min(rect.minX, max(rect.maxX - w, x))
        y = min(rect.minY, max(rect.maxY - h, y))
        return (CGRect(x: x, y: y, width: w, height: h), CGSize(width: iw, height: ih))
    }

    private static func drawFill(_ image: CGImage, in rect: CGRect, focus: CGPoint?, faceAt: CGPoint, zoom: CGFloat = 1) {
        let p = placement(image, in: rect, focus: focus, faceAt: faceAt, zoom: zoom)
        NSImage(cgImage: image, size: p.size)
            .draw(in: p.rect, from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    private static func gradient(in rect: CGRect, from a: CGFloat, to b: CGFloat, vertical: Bool,
                                 stop: CGFloat = 1, reversed: Bool = false) {
        let g = NSGradient(colorsAndLocations: (NSColor.black.withAlphaComponent(a), 0),
                           (NSColor.black.withAlphaComponent(b), stop),
                           (NSColor.black.withAlphaComponent(b), 1))
        // NSImage(flipped:) contexts are flipped, so 90° runs top → bottom
        g?.draw(in: rect, angle: vertical ? 90 : (reversed ? 180 : 0))
    }

    private static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let ci = CIImage(cgImage: image).clampedToExtent()
            .applyingGaussianBlur(sigma: radius).cropped(to: CIImage(cgImage: image).extent)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    private static func para(_ align: NSTextAlignment) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        p.lineHeightMultiple = 0.95
        return p
    }

    private static func attributed(_ text: String, look: CaptionLook, size: CGFloat,
                                   align: NSTextAlignment, highlightLast: Bool) -> NSAttributedString {
        let words = text.split(separator: " ").map(String.init)
        let out = NSMutableAttributedString()
        // Highlight the final word or two, like a caption's active word
        let hl = highlightLast ? max(1, min(2, words.count / 3)) : 0
        for (i, w) in words.enumerated() {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: look.font(size: size),
                .foregroundColor: (i >= words.count - hl ? look.highlightColor : look.textColor).nsColor,
                .paragraphStyle: para(align)
            ]
            if look.strokeWidth > 0 {
                attrs[.strokeWidth] = -look.strokeWidth
                attrs[.strokeColor] = look.strokeColor.nsColor
            }
            attrs[.shadow] = {
                let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.5)
                s.shadowBlurRadius = size * 0.12; s.shadowOffset = .zero; return s
            }()
            out.append(NSAttributedString(string: w + (i < words.count - 1 ? " " : ""), attributes: attrs))
        }
        return out
    }

    /// Largest font size whose wrapped text fits `box`.
    private static func fit(_ text: String, look: CaptionLook, in box: CGRect, maxSize: CGFloat, minSize: CGFloat,
                            align: NSTextAlignment, highlightLast: Bool = false) -> (size: CGFloat, height: CGFloat) {
        var size = maxSize
        while size > minSize {
            let h = attributed(text, look: look, size: size, align: align, highlightLast: highlightLast)
                .boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if h <= box.height { return (size, ceil(h)) }
            size -= 4
        }
        let h = attributed(text, look: look, size: minSize, align: align, highlightLast: highlightLast)
            .boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return (minSize, min(box.height, ceil(h)))
    }

    private static func draw(_ text: String, look: CaptionLook, size: CGFloat, in rect: CGRect,
                             align: NSTextAlignment, highlightLast: Bool = false) {
        attributed(text, look: look, size: size, align: align, highlightLast: highlightLast)
            .draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + size),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func label(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                   .foregroundColor: color]).draw(at: p)
    }
}
