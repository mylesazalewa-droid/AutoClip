import AppKit
import AVFoundation
import QuartzCore

/// A Bible reference spoken in the reel ("Romans 6:14") and when it was said (reel time).
struct VerseRef: Equatable {
    var text: String
    var start: Double
}

/// Finds Scripture references in transcribed speech: "Romans 6:14", "Romans chapter 6 verse 14",
/// "first John 1 9", "Psalm twenty three". A book name only counts when a chapter number follows,
/// so "John said…" or "mark my words" are ignored.
enum VerseDetector {
    private static let books: [(names: [String], display: String)] = [
        (["genesis"], "Genesis"), (["exodus"], "Exodus"), (["leviticus"], "Leviticus"), (["numbers"], "Numbers"),
        (["deuteronomy"], "Deuteronomy"), (["joshua"], "Joshua"), (["judges"], "Judges"), (["ruth"], "Ruth"),
        (["samuel"], "Samuel"), (["kings"], "Kings"), (["chronicles"], "Chronicles"), (["ezra"], "Ezra"),
        (["nehemiah"], "Nehemiah"), (["esther"], "Esther"), (["job"], "Job"), (["psalm", "psalms"], "Psalm"),
        (["proverbs", "proverb"], "Proverbs"), (["ecclesiastes"], "Ecclesiastes"), (["song of solomon", "song of songs"], "Song of Songs"),
        (["isaiah"], "Isaiah"), (["jeremiah"], "Jeremiah"), (["lamentations"], "Lamentations"), (["ezekiel"], "Ezekiel"),
        (["daniel"], "Daniel"), (["hosea"], "Hosea"), (["joel"], "Joel"), (["amos"], "Amos"), (["obadiah"], "Obadiah"),
        (["jonah"], "Jonah"), (["micah"], "Micah"), (["nahum"], "Nahum"), (["habakkuk"], "Habakkuk"),
        (["zephaniah"], "Zephaniah"), (["haggai"], "Haggai"), (["zechariah"], "Zechariah"), (["malachi"], "Malachi"),
        (["matthew"], "Matthew"), (["mark"], "Mark"), (["luke"], "Luke"), (["john"], "John"), (["acts"], "Acts"),
        (["romans"], "Romans"), (["corinthians"], "Corinthians"), (["galatians"], "Galatians"),
        (["ephesians"], "Ephesians"), (["philippians"], "Philippians"), (["colossians"], "Colossians"),
        (["thessalonians"], "Thessalonians"), (["timothy"], "Timothy"), (["titus"], "Titus"), (["philemon"], "Philemon"),
        (["hebrews"], "Hebrews"), (["james"], "James"), (["peter"], "Peter"), (["jude"], "Jude"),
        (["revelation", "revelations"], "Revelation")
    ]
    /// Books that come in numbered parts ("1 Peter", "Second Corinthians")
    private static let numbered: Set<String> = ["Samuel", "Kings", "Chronicles", "Corinthians", "Thessalonians",
                                                "Timothy", "Peter", "John"]
    private static let ordinals: [String: Int] = ["1": 1, "2": 2, "3": 3, "1st": 1, "2nd": 2, "3rd": 3,
                                                  "first": 1, "second": 2, "third": 3, "one": 1, "two": 2, "three": 3]

    private static let small: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                                              "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// Reads a number at `i` ("14", "fourteen", "twenty-three", "one hundred and nineteen").
    /// Returns the value and how many tokens it used.
    private static func number(_ t: [String], _ i: Int) -> (Int, Int)? {
        guard i < t.count else { return nil }
        if let n = Int(t[i]), n > 0, n < 200 { return (n, 1) }
        var value = 0, used = 0, j = i
        if j < t.count, let s = small[t[j]] {
            value = s; used = 1; j += 1
            if j < t.count, t[j] == "hundred" {
                value *= 100; used += 1; j += 1
                if j < t.count, t[j] == "and" { used += 1; j += 1 }
            } else { return value > 0 ? (value, used) : nil }
        }
        let parts = j < t.count ? t[j].split(separator: "-").map(String.init) : []
        if let first = parts.first, let tv = tens[first] {
            value += tv; used += 1; j += 1
            if parts.count > 1, let s = small[parts[1]] { value += s }
            else if j < t.count, let s = small[t[j]], s < 10 { value += s; used += 1 }
        } else if j < t.count, let s = small[t[j]], used > 0 {
            value += s; used += 1
        }
        return value > 0 && used > 0 ? (value, used) : nil
    }

    static func find(in words: [Word]) -> [VerseRef] {
        // Lowercased tokens; "6:14," / "6.14" kept together, other punctuation stripped
        let raw = words.map { $0.word.lowercased() }
        let tokens = raw.map { w -> String in
            var s = w.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: ":-")))
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":-"))
            return s
        }
        var out: [VerseRef] = []
        var i = 0
        while i < tokens.count {
            var j = i
            var prefix: Int? = nil
            if let o = ordinals[tokens[j]], j + 1 < tokens.count { prefix = o; j += 1 }
            // Book (one or three words)
            var book: String? = nil
            for b in books {
                for name in b.names {
                    let parts = name.split(separator: " ").map(String.init)
                    if j + parts.count <= tokens.count, Array(tokens[j..<j + parts.count]) == parts {
                        book = b.display; j += parts.count; break
                    }
                }
                if book != nil { break }
            }
            guard let bookName = book, !(prefix != nil && !numbered.contains(bookName)) else { i += 1; continue }
            if j < tokens.count, tokens[j] == "chapter" { j += 1 }
            // "6:14" / "6.14" in one token
            var chapter: Int? = nil, verse: String? = nil
            if j < tokens.count {
                let t = tokens[j].replacingOccurrences(of: ".", with: ":")
                let cv = t.split(separator: ":")
                if cv.count == 2, let c = Int(cv[0]), c > 0, c < 151 {
                    chapter = c; verse = String(cv[1]); j += 1
                } else if let (c, n) = number(tokens, j), c < 151 {
                    chapter = c; j += n
                }
            }
            guard let ch = chapter else { i += 1; continue }
            if verse == nil {
                if j < tokens.count, tokens[j] == "verse" || tokens[j] == "verses" || tokens[j] == "vs" {
                    if let (v, n) = number(tokens, j + 1) { verse = "\(v)"; j += 1 + n }
                } else if j < tokens.count, let v = Int(tokens[j]), v > 0, v < 177 {
                    verse = "\(v)"; j += 1          // "Romans 6 14" (digits only)
                }
            }
            // Ranges: "14-16", "14 through 16", "14 to 16"
            if let v = verse, !v.contains("-"), j + 1 < tokens.count,
               ["through", "to", "thru"].contains(tokens[j]), let (e, n) = number(tokens, j + 1), e > Int(v) ?? 0 {
                verse = "\(v)-\(e)"; j += 1 + n
            }
            let name = (prefix.map { "\($0) " } ?? "") + bookName
            let text = verse.map { "\(name) \(ch):\($0)" } ?? (bookName == "Psalm" ? "Psalm \(ch)" : "\(name) \(ch)")
            let start = words[i].startTime
            if !out.contains(where: { $0.text == text && abs($0.start - start) < 30 }) {
                out.append(VerseRef(text: text, start: start))
            }
            i = max(j, i + 1)
        }
        return out
    }
}

/// On-screen hook text (first seconds) and Bible verse cards — drawn once as images so the
/// preview and the export look identical, then animated in the export.
enum ReelOverlays {
    static let hookDuration = 3.0
    static let verseDuration = 4.0

    struct Placed {
        var image: CGImage
        var frame: CGRect          // top-left origin, in render coordinates
        var start: Double
        var end: Double
        var pop: Bool              // hook pops in, verses slide in
    }

    /// Hook: bold text on a highlight-coloured box near the top.
    static func hookImage(_ text: String, look: CaptionLook, width: CGFloat) -> NSImage {
        let fs = max(22, width * 0.066)
        let maxW = width * 0.84
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
        let str = NSAttributedString(string: text.uppercased(), attributes: [
            .font: look.font(size: fs), .foregroundColor: NSColor.black, .paragraphStyle: para])
        let r = str.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padX = fs * 0.5, padY = fs * 0.3
        let size = CGSize(width: ceil(r.width) + padX * 2, height: ceil(r.height) + padY * 2)
        return NSImage(size: size, flipped: true) { _ in
            look.highlightColor.nsColor.setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: fs * 0.3, yRadius: fs * 0.3).fill()
            str.draw(with: CGRect(x: padX, y: padY, width: ceil(r.width), height: ceil(r.height) + 2),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
    }

    /// Verse card: 📖 + reference on a dark pill.
    static func verseImage(_ ref: String, look: CaptionLook, width: CGFloat) -> NSImage {
        let fs = max(18, width * 0.05)
        let str = NSMutableAttributedString(string: "📖  ", attributes: [.font: NSFont.systemFont(ofSize: fs * 0.9)])
        str.append(NSAttributedString(string: ref.uppercased(), attributes: [
            .font: look.font(size: fs), .foregroundColor: look.highlightColor.nsColor]))
        let r = str.boundingRect(with: CGSize(width: width, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let padX = fs * 0.6, padY = fs * 0.32
        let size = CGSize(width: ceil(r.width) + padX * 2, height: ceil(r.height) + padY * 2)
        return NSImage(size: size, flipped: true) { _ in
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: size.height / 2, yRadius: size.height / 2).fill()
            look.highlightColor.nsColor.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5),
                                      xRadius: size.height / 2, yRadius: size.height / 2)
            border.lineWidth = 3; border.stroke()
            str.draw(with: CGRect(x: padX, y: padY, width: ceil(r.width) + 2, height: ceil(r.height) + 2),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
    }

    private static func cg(_ img: NSImage) -> CGImage? {
        img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Everything to show, laid out for `size`. Verses that would collide with the hook wait for it.
    static func layout(hook: String?, verses: [VerseRef], look: CaptionLook, size: CGSize, duration: Double) -> [Placed] {
        var out: [Placed] = []
        // Sit just above the captions (faces are usually in the top third of a vertical crop);
        // if captions are placed high, go just below them instead.
        let capY = size.height * CGFloat(look.position)
        let gap = size.height * 0.08
        func y(_ h: CGFloat) -> CGFloat {
            look.position >= 0.5 ? max(size.height * 0.4, capY - gap - h) : min(size.height * 0.95 - h, capY + gap)
        }
        if let hook, !hook.trimmingCharacters(in: .whitespaces).isEmpty,
           let img = cg(hookImage(hook, look: look, width: size.width)) {
            let w = CGFloat(img.width), h = CGFloat(img.height)
            out.append(Placed(image: img, frame: CGRect(x: (size.width - w) / 2, y: y(h), width: w, height: h),
                              start: 0, end: min(duration, hookDuration), pop: true))
        }
        let hookEnd = out.first?.end ?? 0
        var lastEnd = 0.0
        for v in verses {
            guard let img = cg(verseImage(v.text, look: look, width: size.width)) else { continue }
            let start = max(v.start, hookEnd + 0.1, lastEnd + 0.1)
            guard start < duration - 0.5 else { continue }
            let end = min(duration, start + verseDuration)
            let w = CGFloat(img.width), h = CGFloat(img.height)
            out.append(Placed(image: img, frame: CGRect(x: (size.width - w) / 2, y: y(h), width: w, height: h),
                              start: start, end: end, pop: false))
            lastEnd = end
        }
        return out
    }

    // MARK: Export (Core Animation)

    static func layer(for items: [Placed], size: CGSize, duration: Double) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: size)
        for p in items {
            let l = CALayer()
            l.contents = p.image
            l.frame = p.frame
            l.contentsGravity = .resize
            l.opacity = 0
            l.add(fade(p.start, p.end, duration), forKey: "opacity")
            l.add(p.pop ? popScale(p.start, duration) : slide(p.start, p.frame, duration), forKey: p.pop ? "scale" : "slide")
            container.addSublayer(l)
        }
        return container
    }

    private static func keyframes(_ path: String, _ points: [(Double, Any)], total: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: path)
        var pts = points.map { (max(0, min(total, $0.0)) / total, $0.1) }
        if pts.first!.0 > 0 { pts.insert((0, pts.first!.1), at: 0) }
        if pts.last!.0 < 1 { pts.append((1, pts.last!.1)) }
        a.keyTimes = pts.map { NSNumber(value: $0.0) }
        a.values = pts.map(\.1)
        a.duration = total
        a.beginTime = AVCoreAnimationBeginTimeAtZero
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        return a
    }

    private static func fade(_ s: Double, _ e: Double, _ total: Double) -> CAKeyframeAnimation {
        keyframes("opacity", [(s - 0.001, 0.0), (s + 0.15, 1.0), (e - 0.25, 1.0), (e, 0.0)], total: total)
    }

    private static func popScale(_ s: Double, _ total: Double) -> CAKeyframeAnimation {
        keyframes("transform.scale", [(s, 0.6), (s + 0.16, 1.08), (s + 0.28, 1.0)], total: total)
    }

    private static func slide(_ s: Double, _ frame: CGRect, _ total: Double) -> CAKeyframeAnimation {
        let y = frame.midY
        return keyframes("position.y", [(s, y - frame.height * 0.6), (s + 0.25, y)], total: total)
    }

    // MARK: Preview

    /// The overlays at `time`, drawn into an image of `size` (approximating the export's animation).
    static func previewImage(_ items: [Placed], time: Double, size: CGSize) -> NSImage? {
        let live = items.filter { time >= $0.start && time <= $0.end }
        guard !live.isEmpty else { return nil }
        return NSImage(size: size, flipped: true) { _ in
            for p in live {
                let t = time - p.start, left = p.end - time
                let alpha = min(1, t / 0.15, left / 0.25)
                var f = p.frame
                if p.pop {
                    let sc = t < 0.16 ? 0.6 + 0.48 * t / 0.16 : (t < 0.28 ? 1.08 - 0.08 * (t - 0.16) / 0.12 : 1)
                    f = f.insetBy(dx: f.width * (1 - sc) / 2, dy: f.height * (1 - sc) / 2)
                } else if t < 0.25 {
                    f.origin.y -= f.height * 0.6 * (1 - t / 0.25)
                }
                NSImage(cgImage: p.image, size: f.size)
                    .draw(in: f, from: .zero, operation: .sourceOver, fraction: max(0, alpha), respectFlipped: true, hints: nil)
            }
            return true
        }
    }
}
