import AppKit
import UniformTypeIdentifiers

/// One assessment as a printable PDF, to send to a mentor or preaching coach: the numbers,
/// the AI coach's notes (when written) and how the speaker's recent messages compare.
enum SpeakerReportDocument {
    /// What each filler word is, for the key.
    static let fillerMeaning: [String: String] = [
        "um": "a thinking sound", "uh": "a thinking sound", "ah": "a thinking sound",
        "like": "used as a pause, not a comparison", "so": "starting a sentence out of habit",
        "well": "starting a sentence out of habit", "you see": "a habit lead-in", "i mean": "a habit lead-in"]

    static func attributed(_ r: SpeakerReport, speaker: String?, history: [SpeakerReport],
                           fillers: [(kind: String, time: Double)] = []) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let accent = NSColor(srgbRed: 0.72, green: 0.42, blue: 0.0, alpha: 1)
        let goodColor = NSColor(srgbRed: 0.1, green: 0.5, blue: 0.2, alpha: 1)
        let warnColor = NSColor(srgbRed: 0.75, green: 0.3, blue: 0.05, alpha: 1)
        func add(_ s: String, size: CGFloat, bold: Bool = false, italic: Bool = false, color: NSColor = .black,
                 before: CGFloat = 0, after: CGFloat = 5, indent: CGFloat = 0, tabs: [CGFloat] = [], leftTabs: [CGFloat] = []) {
            var font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = before; para.paragraphSpacing = after
            para.headIndent = indent; para.firstLineHeadIndent = indent > 0 ? indent - 12 : 0
            para.tabStops = leftTabs.map { NSTextTab(textAlignment: .left, location: $0) } + tabs.map { NSTextTab(textAlignment: .right, location: $0) }
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        func heading(_ s: String) { add(s.uppercased(), size: 10, bold: true, color: accent, before: 14, after: 5) }
        func note(_ s: String) { add(s, size: 9, italic: true, color: .darkGray, after: 6) }
        func t(_ s: Double) -> String { assessTime(s) }
        func times(_ ts: [Double], max n: Int = 5) -> String {
            let shown = ts.sorted().prefix(n).map(t).joined(separator: ", ")
            return ts.count > n ? shown + " …" : shown
        }
        /// A measurement with its target and whether it's on track
        func measure(_ label: String, _ value: String, target: String, ok: Bool?) {
            let mark = ok == nil ? "" : ok! ? "  ✓" : "  ▲"
            let line = NSMutableAttributedString(string: "\(label)\t\(value)\(mark)\t\(target)\n")
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .left, location: 190), NSTextTab(textAlignment: .left, location: 300)]
            para.paragraphSpacing = 3
            line.addAttributes([.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.black, .paragraphStyle: para],
                               range: NSRange(location: 0, length: line.length))
            let valueAt = (label as NSString).length + 1
            let markAt = valueAt + (value as NSString).length
            let targetAt = markAt + (mark as NSString).length + 1
            line.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 10.5), range: NSRange(location: valueAt, length: (value as NSString).length))
            if let ok { line.addAttribute(.foregroundColor, value: ok ? goodColor : warnColor, range: NSRange(location: markAt, length: (mark as NSString).length)) }
            line.addAttributes([.foregroundColor: NSColor.darkGray, .font: NSFont.systemFont(ofSize: 9.5)],
                               range: NSRange(location: targetAt, length: (target as NSString).length))
            out.append(line)
        }
        let mins = max(1, r.speakingMinutes)

        // Title
        add(r.title, size: 20, bold: true, after: 4)
        var sub = [r.videoDate.formatted(date: .long, time: .omitted), String(format: "%.0f minutes", r.speakingMinutes)]
        if let speaker { sub.insert(speaker, at: 0) }
        if r.isPractice { sub.append("practice run") }
        add(sub.joined(separator: "  ·  "), size: 11, color: .darkGray, after: 10)

        // Focus for next time
        var focus: String?
        if let c = r.coach, let first = c.improvements.first {
            focus = first.title + (first.drill.map { " — \($0)" } ?? "")
        } else if let d = r.delivery {
            if r.fillersPerMin >= 4 { focus = "Cut filler words: when you feel an “um” coming, pause silently instead." }
            else if d.averageWPM > 175 { focus = "Slow down to 140–160 words a minute at your key points so they land." }
            else if Double(d.naturalPauses) / mins < 3 { focus = "Pause for a beat after each big truth." }
            else if d.pitchRangeSemitones < 3 { focus = "Vary your voice: rise for questions, drop low for weighty moments." }
        }
        if let focus {
            heading("One thing to focus on next time")
            add(focus, size: 11.5, bold: true, after: 4)
        }

        // At a glance, with targets
        heading("At a glance")
        let tabsNote = "Measure\tThis message\tTarget"
        add(tabsNote, size: 9, bold: true, color: .darkGray, after: 3, leftTabs: [190, 300])
        if let c = r.coach { measure("AI coach score", "\(c.score)/10", target: "7+ is strong", ok: c.score >= 7) }
        measure("Filler words", String(format: "%.1f / min", r.fillersPerMin), target: "under 2 very clean · 2–4 typical", ok: r.fillersPerMin < 4)
        if let d = r.delivery {
            let pauses = Double(d.naturalPauses) / mins
            let crutch = Double(d.crutches.count) / mins
            let total = max(1, d.youCount + d.weCount + d.iCount)
            let iShare = Double(d.iCount) / Double(total) * 100
            measure("Pace", String(format: "%.0f wpm", d.averageWPM), target: "115–175 overall · 140–160 at key points",
                    ok: d.averageWPM >= 115 && d.averageWPM <= 175)
            measure("Natural pauses", String(format: "%.1f / min", pauses), target: "3+ a minute", ok: pauses >= 3)
            measure("30s+ without a pause", "\(d.breathlessRuns.count)", target: "0", ok: d.breathlessRuns.isEmpty)
            measure("Pitch variety", String(format: "%.1f semitones", d.pitchRangeSemitones), target: "3–5 is lively", ok: d.pitchRangeSemitones >= 3)
            measure("Monotone stretches", "\(d.monotoneStretches.count)", target: "0", ok: d.monotoneStretches.isEmpty)
            measure("Sentences trailing off", String(format: "%.0f%%", d.trailingOffPercent), target: "under 20%", ok: d.trailingOffPercent <= 20)
            measure("Crutch phrases", String(format: "%.1f / min", crutch), target: "under 0.5 a minute", ok: crutch <= 0.5)
            measure("Talking about “I”", String(format: "%.0f%%", iShare), target: "under 45% of you/we/I", ok: iShare <= 45)
            measure("Questions asked", "\(d.questions)", target: "a few draw people in", ok: nil)
        }
        if let st = r.stage {
            measure("Facing the camera", String(format: "%.0f%%", st.facingPercent), target: "most of the time", ok: st.facingPercent >= 60)
        }
        note("✓ on track   ▲ worth working on")

        // Filler words key
        heading("Filler words")
        note("Sounds or words that fill a gap while you think and carry no meaning. A few are natural in live speaking; many make you sound unsure and distract from the message.")
        if fillers.isEmpty {
            add("\(r.fillerCount) in total", size: 10.5)
        } else {
            let groups = Dictionary(grouping: fillers, by: \.kind).sorted { $0.value.count > $1.value.count }
            add("Word\tCount\tWhere (first few)", size: 9, bold: true, color: .darkGray, after: 3, leftTabs: [110, 160])
            for (kind, hits) in groups {
                add("“\(kind)”\t\(hits.count)\t\(times(hits.map(\.time)))", size: 10.5, after: 1, leftTabs: [110, 160])
                if let m = fillerMeaning[kind] { add(m, size: 9, color: .gray, after: 4, indent: 12) }
            }
        }
        note("Transcription drops some “um”s and “uh”s, so those counts may be low.")

        // Crutch phrases key
        if let d = r.delivery {
            heading("Crutch phrases")
            note("Real words and phrases used out of habit — “you know”, “right?”, “amen?”, “actually”, “basically”, “kind of”. Each is fine once; repeated, they lose their force and can make a point sound less certain. Try a pause instead.")
            if d.crutches.isEmpty {
                add("None found — nice.", size: 10.5)
            } else {
                add("Phrase\tCount\tWhere (first few)", size: 9, bold: true, color: .darkGray, after: 3, leftTabs: [140, 190])
                for (kind, marks) in Dictionary(grouping: d.crutches, by: \.kind).sorted(by: { $0.value.count > $1.value.count }) {
                    add("“\(kind)”\t\(marks.count)\t\(times(marks.map(\.time)))", size: 10.5, after: 2, leftTabs: [140, 190])
                }
                if let ex = d.crutches.first(where: { !$0.context.isEmpty }) {
                    add("Example (\(t(ex.time))): “…\(ex.context)…”", size: 9.5, italic: true, color: .darkGray, before: 3)
                }
            }

            // Where to listen
            let spans: [(String, String, [SpeakerReport.Span])] = [
                ("Fast stretches", "over 180 words a minute", d.fastStretches),
                ("Slow stretches", "under 110 words a minute", d.slowStretches),
                ("No pause for 30s+", "long thoughts without a breath", d.breathlessRuns),
                ("Monotone stretches", "pitch stays flat", d.monotoneStretches)]
            if spans.contains(where: { !$0.2.isEmpty }) {
                heading("Where to listen back")
                note("Moments in the video worth replaying.")
                for (title, what, list) in spans where !list.isEmpty {
                    let shown = list.prefix(6).map { "\(t($0.start))–\(t($0.end))" }.joined(separator: ", ")
                    add("\(title) (\(what)): \(shown)\(list.count > 6 ? " …" : "")", size: 10, after: 3, indent: 12)
                }
            }
        }

        // AI coach
        if let c = r.coach {
            heading("Coach's summary")
            add(c.summary, size: 11)
            add("Big idea: \(c.bigIdea)", size: 11, bold: true, before: 4, after: 2)
            add("Clarity \(c.bigIdeaClarity)/10, stated \(c.bigIdeaMentions.count) time\(c.bigIdeaMentions.count == 1 ? "" : "s")"
                + (c.bigIdeaMentions.isEmpty ? "" : " (at \(times(c.bigIdeaMentions)))"), size: 10, color: .darkGray)
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
            if !c.sections.isEmpty {
                heading("Sermon map")
                note("How the message was built, section by section.")
                for sec in c.sections {
                    add("\(t(sec.start))\t\(sec.kind.capitalized)\t\(sec.title)", size: 10, after: 2, leftTabs: [50, 130])
                }
            }
            if !c.best.isEmpty {
                heading("Strongest moments")
                c.best.forEach { add("\(t($0.time))  “\($0.quote)” — \($0.why)", size: 10, indent: 12) }
            }
            if !c.weakest.isEmpty {
                heading("Moments to revisit")
                c.weakest.forEach { add("\(t($0.time))  “\($0.quote)” — \($0.why)", size: 10, indent: 12) }
            }
            if !c.jargon.isEmpty {
                heading("Words a newcomer might not know")
                add(c.jargon.joined(separator: ", "), size: 10.5)
                note("Church words that could use a quick explanation for guests.")
            }
        }

        // Recent messages
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
        add("Times are minutes:seconds into the video.  Made with AutoClip", size: 8, color: .gray, before: 18)
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

    static func savePDF(_ r: SpeakerReport, speaker: String?, history: [SpeakerReport], fillers: [(kind: String, time: Double)]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName(r)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pdf(attributed(r, speaker: speaker, history: history, fillers: fillers)).write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a new Mail message with the PDF attached; the user adds the address and sends it.
    static func email(_ r: SpeakerReport, speaker: String?, history: [SpeakerReport], fillers: [(kind: String, time: Double)]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(r))
        guard (try? pdf(attributed(r, speaker: speaker, history: history, fillers: fillers)).write(to: url)) != nil,
              let mail = NSSharingService(named: .composeEmail) else { return }
        mail.subject = "Speaker report: \(r.title)"
        mail.perform(withItems: [url])
    }
}
