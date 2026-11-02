import AppKit
import SwiftUI

/// User-customizable caption appearance (Edits-style). Presets in `CaptionStyle.all` are
/// starting points; every tweak is stored here and used by both the live preview and export,
/// which share `attributedPhrase` so the preview matches the rendered video.
struct CaptionLook: Codable, Equatable {
    struct RGBA: Codable, Equatable {
        var r: Double, g: Double, b: Double, a: Double = 1

        init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
        init(_ ns: NSColor) {
            let c = ns.usingColorSpace(.sRGB) ?? .white
            r = Double(c.redComponent); g = Double(c.greenComponent); b = Double(c.blueComponent); a = Double(c.alphaComponent)
        }
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var color: Color {
            get { Color(nsColor) }
            set { self = RGBA(NSColor(newValue)) }
        }

        static let white  = RGBA(r: 1, g: 1, b: 1)
        static let black  = RGBA(r: 0, g: 0, b: 0)
        static let gold   = RGBA(r: 1, g: 0.92, b: 0)
    }

    var fontName: String = "Impact"
    var sizeScale: Double = 1.0          // 0.5 – 2.0
    var textColor: RGBA = .white
    var highlightColor: RGBA = .gold     // the word being spoken
    var strokeColor: RGBA = .black
    var strokeWidth: Double = 0          // 0 – 10, percent of font size
    var bgEnabled: Bool = false
    var bgColor: RGBA = .black
    var bgOpacity: Double = 0.6
    var position: Double = 0.78          // 0 = top, 1 = bottom
    var wordsPerCaption: Int = 1         // 1 – 4
    var uppercase: Bool = false
    var motion: Motion = .highlight
    /// Key words (and Bible references) drawn in their own colour, slightly larger
    var emphasis: Bool = true
    var emphasisColor: RGBA = RGBA(r: 0.851, g: 0.765, b: 0.627)   // sand
    /// This reel's key words, as `key(_:)` forms. Set per reel at render time; never saved.
    var keywords: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case fontName, sizeScale, textColor, highlightColor, strokeColor, strokeWidth, bgEnabled, bgColor,
             bgOpacity, position, wordsPerCaption, uppercase, motion, emphasis, emphasisColor
    }

    /// How a word is matched against `keywords`: lowercased, outer punctuation stripped.
    static func key(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces).union(.symbols))
    }

    /// How captions move: the spoken word changes colour, the phrase pops or slides in,
    /// words appear as they're said, or a box sits behind the spoken word.
    enum Motion: String, Codable, CaseIterable, Identifiable {
        case highlight, pop, slide, reveal, box
        var id: String { rawValue }
        var label: String {
            switch self {
            case .highlight: return "Highlight"
            case .pop: return "Pop"
            case .slide: return "Slide up"
            case .reveal: return "Word by word"
            case .box: return "Box"
            }
        }
    }

    // MARK: Presets

    init() {}

    init(preset: CaptionStyle) {
        fontName = NSFont(name: preset.fontName, size: 12) != nil ? preset.fontName : "Impact"
        let text = RGBA(NSColor(preset.textColor))
        textColor = preset.isKaraoke ? .white : text
        highlightColor = preset.isKaraoke ? .gold : text
        let stroke = NSColor(preset.strokeColor).usingColorSpace(.sRGB)
        if let stroke, stroke.alphaComponent > 0.01 {
            strokeColor = RGBA(stroke); strokeWidth = 4
        } else {
            strokeColor = .black; strokeWidth = 0
        }
        if let bg = preset.backgroundColor {
            let c = NSColor(bg).usingColorSpace(.sRGB) ?? .black
            bgEnabled = true; bgColor = RGBA(c.withAlphaComponent(1)); bgOpacity = Double(c.alphaComponent)
        }
        uppercase = preset.fontName == "Impact"
    }

    // MARK: Persistence (Auto Reels)

    private static let key = "ar_captionLook"

    static func load() -> CaptionLook? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CaptionLook.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Rendering

    /// Base font size for a given output width (1080-wide → ~65pt at 1×).
    func fontSize(forRenderWidth width: CGFloat) -> CGFloat {
        max(18, width * 0.06 * CGFloat(sizeScale))
    }

    func font(size: CGFloat) -> NSFont {
        NSFont(name: fontName, size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    /// The whole phrase, with the word at `active` drawn in the highlight color.
    func attributedPhrase(_ words: [String], active: Int?, fontSize: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let f = font(size: fontSize)
        let out = NSMutableAttributedString()
        for (i, w) in words.enumerated() {
            let text = (uppercase ? w.uppercased() : w) + (i < words.count - 1 ? " " : "")
            let key = emphasis && !keywords.isEmpty && keywords.contains(Self.key(w))
            var attrs: [NSAttributedString.Key: Any] = [
                .font: key ? font(size: fontSize * 1.08) : f,
                .foregroundColor: (i == active ? activeTextColor : key ? emphasisColor : textColor).nsColor,
                .paragraphStyle: para
            ]
            if strokeWidth > 0 {
                // Negative width = fill + stroke
                attrs[.strokeWidth] = -strokeWidth
                attrs[.strokeColor] = strokeColor.nsColor
            }
            // Word by word: words not yet spoken keep their space but aren't drawn
            if motion == .reveal, let active, i > active {
                attrs[.foregroundColor] = NSColor.clear
                attrs[.strokeColor] = NSColor.clear
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    /// Colour of the spoken word's text. On a bright box it turns dark so it stays readable.
    var activeTextColor: RGBA {
        guard motion == .box else { return highlightColor }
        let lum = 0.299 * highlightColor.r + 0.587 * highlightColor.g + 0.114 * highlightColor.b
        return lum > 0.6 ? .black : .white
    }

    /// Where each word sits inside the text box (top-left origin, `maxWidth` wide, centred
    /// lines), for the box drawn behind the spoken word.
    func wordRects(_ words: [String], fontSize: CGFloat, maxWidth: CGFloat) -> [CGRect] {
        let storage = NSTextStorage(attributedString: attributedPhrase(words, active: nil, fontSize: fontSize))
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        var out: [CGRect] = []
        var loc = 0
        for (i, w) in words.enumerated() {
            let len = ((uppercase ? w.uppercased() : w) as NSString).length
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: len), actualCharacterRange: nil)
            out.append(lm.boundingRect(forGlyphRange: glyphs, in: tc))
            loc += len + (i < words.count - 1 ? 1 : 0)
        }
        return out
    }

    /// Pop and Slide entrances last this long (seconds).
    static let entryDuration = 0.18

    /// The entrance `age` seconds after a phrase appears: scale, downward offset (in font
    /// sizes) and opacity. The exporter animates the same curve with Core Animation.
    func entry(age: Double) -> (scale: CGFloat, dy: CGFloat, alpha: CGFloat) {
        let t = CGFloat(min(1, max(0, age / Self.entryDuration)))
        switch motion {
        case .pop:
            return (t < 0.6 ? 0.7 + 0.38 * t / 0.6 : 1.08 - 0.08 * (t - 0.6) / 0.4, 0, 1)
        case .slide:
            let e = 1 - (1 - t) * (1 - t)
            return (1, 0.45 * (1 - e), e)
        default:
            return (1, 0, 1)
        }
    }

    /// Draws one caption frame into the current flipped graphics context. Shared by the
    /// caption editor and the reel previews.
    func draw(_ texts: [String], active: Int, age: Double, in size: CGSize) {
        let fs = fontSize(forRenderWidth: size.width)
        let maxW = size.width * 0.86
        let m = measure(attributedPhrase(texts, active: nil, fontSize: fs), maxWidth: maxW)
        let cy = size.height * CGFloat(position)
        let top = cy - m.height / 2
        let e = entry(age: age)
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState(); defer { ctx.restoreGraphicsState() }
        let t = NSAffineTransform()
        t.translateX(by: size.width / 2, yBy: cy + e.dy * fs)
        t.scale(by: e.scale)
        t.translateX(by: -size.width / 2, yBy: -cy)
        t.concat()
        ctx.cgContext.setAlpha(e.alpha)
        if bgEnabled {
            let px = fs * 0.35, py = fs * 0.18
            bgColor.nsColor.withAlphaComponent(CGFloat(bgOpacity)).setFill()
            NSBezierPath(roundedRect: CGRect(x: (size.width - m.width) / 2 - px, y: top - py,
                                             width: m.width + px * 2, height: m.height + py * 2),
                         xRadius: fs * 0.25, yRadius: fs * 0.25).fill()
        }
        if motion == .box, active < texts.count {
            let r = wordRects(texts, fontSize: fs, maxWidth: maxW)[active]
            highlightColor.nsColor.setFill()
            NSBezierPath(roundedRect: boxRect(r, fontSize: fs).offsetBy(dx: (size.width - maxW) / 2, dy: top),
                         xRadius: fs * 0.18, yRadius: fs * 0.18).fill()
        }
        attributedPhrase(texts, active: active, fontSize: fs)
            .draw(with: CGRect(x: (size.width - maxW) / 2, y: top, width: maxW, height: m.height + 4),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// The box behind a word, padded a little around its text.
    func boxRect(_ word: CGRect, fontSize fs: CGFloat) -> CGRect {
        word.insetBy(dx: -fs * 0.1, dy: -fs * 0.02)
    }

    /// Size the phrase occupies when wrapped to `maxWidth`.
    func measure(_ s: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let r = s.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Splits words into on-screen phrases of up to `wordsPerCaption`, breaking early
    /// at sentence ends and long pauses so a phrase never spans two thoughts.
    static func phrases<W>(_ words: [W], maxWords: Int,
                           text: (W) -> String, start: (W) -> Double, end: (W) -> Double) -> [[W]] {
        var out: [[W]] = []
        var cur: [W] = []
        for w in words {
            if let last = cur.last, start(w) - end(last) > 0.6 {
                out.append(cur); cur = []
            }
            cur.append(w)
            let t = text(w)
            if cur.count >= max(1, maxWords) || t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") {
                out.append(cur); cur = []
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The caption frame for `time` in a reel whose (reel-timeline) words are `words`,
    /// drawn exactly like the export. Used by the editor and the reel window previews.
    func overlayImage(words: [Word], time: Double, size: CGSize) -> NSImage? {
        let phrases = CaptionLook.phrases(words, maxWords: wordsPerCaption,
                                          text: { $0.word }, start: { $0.startTime }, end: { $0.endTime })
        guard let phrase = phrases.first(where: { p in
            guard let s = p.first?.startTime, let e = p.last?.endTime else { return false }
            return time >= s && time <= e + 0.15
        }) else { return nil }
        let active = phrase.lastIndex(where: { $0.startTime <= time }) ?? 0
        let age = time - (phrase.first?.startTime ?? time)
        let look = self
        return NSImage(size: size, flipped: true) { _ in
            look.draw(phrase.map(\.word), active: active, age: age, in: size)
            return true
        }
    }
}

extension CaptionLook {
    /// Looks saved before a setting existed still load, with that setting's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        sizeScale = try c.decodeIfPresent(Double.self, forKey: .sizeScale) ?? sizeScale
        textColor = try c.decodeIfPresent(RGBA.self, forKey: .textColor) ?? textColor
        highlightColor = try c.decodeIfPresent(RGBA.self, forKey: .highlightColor) ?? highlightColor
        strokeColor = try c.decodeIfPresent(RGBA.self, forKey: .strokeColor) ?? strokeColor
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? strokeWidth
        bgEnabled = try c.decodeIfPresent(Bool.self, forKey: .bgEnabled) ?? bgEnabled
        bgColor = try c.decodeIfPresent(RGBA.self, forKey: .bgColor) ?? bgColor
        bgOpacity = try c.decodeIfPresent(Double.self, forKey: .bgOpacity) ?? bgOpacity
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? position
        wordsPerCaption = try c.decodeIfPresent(Int.self, forKey: .wordsPerCaption) ?? wordsPerCaption
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? uppercase
        motion = (try? c.decodeIfPresent(Motion.self, forKey: .motion)) ?? .highlight
        emphasis = try c.decodeIfPresent(Bool.self, forKey: .emphasis) ?? emphasis
        emphasisColor = try c.decodeIfPresent(RGBA.self, forKey: .emphasisColor) ?? emphasisColor
    }
}
