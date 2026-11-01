import AppKit
import UniformTypeIdentifiers

/// One assessment as a printable PDF, to send to a mentor or preaching coach: the numbers,
/// the AI coach's notes (when written) and how the speaker's recent messages compare.
enum SpeakerReportDocument {
    static func attributed(_ r: SpeakerReport, speaker: String?, history: [SpeakerReport]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let accent = NSColor(srgbRed: 0.72, green: 0.42, blue: 0.0, alpha: 1)
        func add(_ s: String, size: CGFloat, bold: Bool = false, italic: Bool = false, color: NSColor = .black,
                 before: CGFloat = 0, after: CGFloat = 5, indent: CGFloat = 0, tabs: [CGFloat] = []) {
            var font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = before; para.paragraphSpacing = after
            para.headIndent = indent; para.firstLineHeadIndent = indent > 0 ? indent - 12 : 0
            para.tabStops = tabs.map { NSTextTab(textAlignment: .right, location: $0) }
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        func heading(_ s: String) { add(s.uppercased(), size: 10, bold: true, color: accent, before: 14, after: 5) }
        func t(_ s: Double) -> String { assessTime(s) }
        let mins = max(1, r.speakingMinutes)

        add(r.title, size: 20, bold: true, after: 4)
        var sub = [r.videoDate.formatted(date: .long, time: .omitted), String(format: "%.0f minutes", r.speakingMinutes)]
        if let speaker { sub.insert(speaker, at: 0) }
        if r.isPractice { sub.append("practice run") }
        add(sub.joined(separator: "  ·  "), size: 11, color: .darkGray, after: 10)

        heading("At a glance")
        var glance = [String(format: "Filler words: %d (%.1f per minute)", r.fillerCount, r.fillersPerMin)]
        if let d = r.delivery {
            glance += [String(format: "Pace: %.0f words per minute", d.averageWPM),
                       String(format: "Pauses: %d natural, %d long; %d stretches of 30s+ without a pause", d.naturalPauses, d.longPauses, d.breathlessRuns.count),
                       String(format: "Voice: %.1f semitones of pitch variety, %d monotone stretches, %.0f%% of sentences trail off",
                              d.pitchRangeSemitones, d.monotoneStretches.count, d.trailingOffPercent),
                       String(format: "Crutch phrases: %d (%.1f per minute)", d.crutches.count, Double(d.crutches.count) / mins),
                       "Audience focus: “you” \(d.youCount), “we” \(d.weCount), “I” \(d.iCount); \(d.questions) questions asked"]
        }
        if let st = r.stage {
            glance.append(String(format: "On camera: face visible %.0f%% of the time, facing the camera %.0f%%", st.onScreenPercent, st.facingPercent))
        }
        if let c = r.coach { glance.insert("AI coach score: \(c.score)/10", at: 0) }
        glance.forEach { add("•  " + $0, size: 11, indent: 12) }

        if let c = r.coach {
            heading("Coach's summary")
            add(c.summary, size: 11)
            add("Big idea: \(c.bigIdea)", size: 11, bold: true, before: 4, after: 2)
            add("Clarity \(c.bigIdeaClarity)/10, stated \(c.bigIdeaMentions.count) time\(c.bigIdeaMentions.count == 1 ? "" : "s")", size: 10, color: .darkGray)
            heading("Strengths")
            for n in c.strengths {
                add(n.title + (n.time.map { "  (\(t($0)))" } ?? ""), size: 11, bold: true, before: 2, after: 1)
                add(n.detail, size: 11, after: 4)
            }
            heading("Things to work on")
            for n in c.improvements {
                add(n.title + (n.time.map { "  (\(t($0)))" } ?? ""), size: 11, bold: true, before: 2, after: 1)
                add(n.detail, size: 11, after: n.drill?.isEmpty == false ? 1 : 4)
                if let drill = n.drill, !drill.isEmpty { add("Practice: " + drill, size: 10, italic: true, color: accent, after: 4) }
            }
            if !c.best.isEmpty {
                heading("Strongest moments")
                c.best.forEach { add("\(t($0.time))  “\($0.quote)” — \($0.why)", size: 10, indent: 12) }
            }
            if !c.weakest.isEmpty {
                heading("Moments to revisit")
                c.weakest.forEach { add("\(t($0.time))  “\($0.quote)” — \($0.why)", size: 10, indent: 12) }
            }
        }

        let recent = Array(history.suffix(8))
        if recent.count >= 2 {
            heading(speaker.map { "\($0)'s recent messages" } ?? "Recent messages")
            let tabs: [CGFloat] = [330, 400, 460]
            add("Message\tFillers/min\tWPM\tCoach", size: 9, bold: true, color: .darkGray, after: 3, tabs: tabs)
            for h in recent.reversed() {
                let title = h.title.count > 44 ? String(h.title.prefix(42)) + "…" : h.title
                let wpm = h.delivery.map { String(format: "%.0f", $0.averageWPM) } ?? "–"
                let coach = h.coach.map { "\($0.score)/10" } ?? "–"
                add("\(h.videoDate.formatted(date: .numeric, time: .omitted))  \(title)\t\(String(format: "%.1f", h.fillersPerMin))\t\(wpm)\t\(coach)",
                    size: 10, bold: h.videoPath == r.videoPath, after: 2, tabs: tabs)
            }
        }
        add("Made with AutoClip", size: 8, color: .gray, before: 18)
        return out
    }

    /// Lays the text out on US Letter pages.
    static func pdf(_ text: NSAttributedString) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792), margin: CGFloat = 54
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        var drawn = 0
        while drawn < layout.numberOfGlyphs || drawn == 0 {
            let container = NSTextContainer(size: CGSize(width: page.width - margin * 2, height: page.height - margin * 2))
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0 { break }
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.height); ctx.scaleBy(x: 1, y: -1)
            let prev = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.current = prev
            ctx.restoreGState()
            ctx.endPDFPage()
            drawn = NSMaxRange(range)
        }
        ctx.closePDF()
        return data as Data
    }

    private static func fileName(_ r: SpeakerReport) -> String {
        r.title.replacingOccurrences(of: "/", with: "-") + " – Speaker report.pdf"
    }

    static func savePDF(_ r: SpeakerReport, speaker: String?, history: [SpeakerReport]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName(r)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pdf(attributed(r, speaker: speaker, history: history)).write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a new Mail message with the PDF attached; the user adds the address and sends it.
    static func email(_ r: SpeakerReport, speaker: String?, history: [SpeakerReport]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(r))
        guard (try? pdf(attributed(r, speaker: speaker, history: history)).write(to: url)) != nil,
              let mail = NSSharingService(named: .composeEmail) else { return }
        mail.subject = "Speaker report: \(r.title)"
        mail.perform(withItems: [url])
    }
}
