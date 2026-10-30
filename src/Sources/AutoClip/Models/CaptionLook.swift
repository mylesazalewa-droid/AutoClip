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
            var attrs: [NSAttributedString.Key: Any] = [
                .font: f,
                .foregroundColor: (i == active ? highlightColor : textColor).nsColor,
                .paragraphStyle: para
            ]
            if strokeWidth > 0 {
                // Negative width = fill + stroke
                attrs[.strokeWidth] = -strokeWidth
                attrs[.strokeColor] = strokeColor.nsColor
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
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
        let look = self
        return NSImage(size: size, flipped: true) { _ in
            let fs = look.fontSize(forRenderWidth: size.width)
            let maxW = size.width * 0.86
            let texts = phrase.map(\.word)
            let str = look.attributedPhrase(texts, active: active, fontSize: fs)
            let m = look.measure(look.attributedPhrase(texts, active: nil, fontSize: fs), maxWidth: maxW)
            let cy = size.height * CGFloat(look.position)
            if look.bgEnabled {
                let px = fs * 0.35, py = fs * 0.18
                look.bgColor.nsColor.withAlphaComponent(CGFloat(look.bgOpacity)).setFill()
                NSBezierPath(roundedRect: CGRect(x: (size.width - m.width) / 2 - px, y: cy - m.height / 2 - py,
                                                 width: m.width + px * 2, height: m.height + py * 2),
                             xRadius: fs * 0.25, yRadius: fs * 0.25).fill()
            }
            str.draw(with: CGRect(x: (size.width - maxW) / 2, y: cy - m.height / 2, width: maxW, height: m.height + 4),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
    }
}
