import Foundation
import AVFoundation
import CryptoKit

/// Two messages side by side: the measurements Assess makes (on this Mac, free), the differences in
/// plain words, and on request an AI read of the two preaching styles.
enum MessageCompare {

    struct Side {
        var path: String
        var report: SpeakerReport
        var words: [Word]
        var title: String { report.title.isEmpty ? YTDLP.title(fromFile: URL(fileURLWithPath: path)) : report.title }
    }

    /// Transcribes (or reuses the transcript) and measures delivery and stage presence, reusing
    /// anything Assess already worked out for this video.
    static func prepare(_ path: String, status: @escaping @Sendable (String) -> Void) async throws -> Side {
        let ws = try await TranscriptCache.transcript(for: path) { status($0) }
        let dur = CMTimeGetSeconds((try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration)) ?? .zero)
        let duration = max(1, dur.isFinite && dur > 0 ? dur : (ws.last?.endTime ?? 1))
        var r = SpeakerReportStore.load(for: path) ?? SpeakerAnalysis.newReport(videoPath: path, words: ws, duration: duration)
        r.fillerCount = FillerReport.find(in: ws).count
        r.wordCount = ws.count
        if r.delivery == nil {
            status("Listening to the voice…")
            r.delivery = try await SpeakerAnalysis.delivery(videoPath: path, words: ws) { p in status("Listening to the voice… \(Int(p * 100))%") }
            SpeakerReportStore.save(r)
        }
        if r.stage == nil {
            status("Watching the stage…")
            r.stage = await SpeakerAnalysis.stage(videoPath: path) { p in status("Watching the stage… \(Int(p * 100))%") }
        }
        SpeakerReportStore.save(r)
        return Side(path: path, report: r, words: ws)
    }

    // MARK: Side by side

    struct Row: Identifiable {
        var id: String { label }
        var label: String
        var a: Double?
        var b: Double?
        var format: String
        /// What the number means, in plain words
        var help: String
        /// For the differences list: how to say "B is more…" ("speaks faster")
        var more: String?
        var less: String?
    }

    static func rows(_ a: SpeakerReport, _ b: SpeakerReport) -> [Row] {
        func per10(_ n: Int?, _ r: SpeakerReport) -> Double? { n.map { Double($0) / max(1, r.speakingMinutes) * 10 } }
        func perMin(_ n: Int?, _ r: SpeakerReport) -> Double? { n.map { Double($0) / max(1, r.speakingMinutes) } }
        let da = a.delivery, db = b.delivery
        return [
            Row(label: "Length", a: a.speakingMinutes, b: b.speakingMinutes, format: "%.0f min", help: "Minutes of speaking",
                more: "preaches longer", less: "preaches shorter"),
            Row(label: "Pace", a: da?.averageWPM, b: db?.averageWPM, format: "%.0f wpm", help: "Words a minute",
                more: "speaks faster", less: "speaks slower"),
            Row(label: "Filler words", a: a.fillersPerMin, b: b.fillersPerMin, format: "%.1f / min", help: "Um, uh, like, so…",
                more: "uses more filler words", less: "uses fewer filler words"),
            Row(label: "Voice variety", a: da?.pitchRangeSemitones, b: db?.pitchRangeSemitones, format: "%.1f semitones",
                help: "How much the pitch moves. More is more expressive.", more: "varies the voice more", less: "keeps the voice flatter"),
            Row(label: "Flat stretches", a: per10(da?.monotoneStretches.count, a), b: per10(db?.monotoneStretches.count, b),
                format: "%.1f / 10 min", help: "Stretches on one note", more: "has more flat stretches", less: "has fewer flat stretches"),
            Row(label: "Pauses", a: perMin(da?.naturalPauses, a), b: perMin(db?.naturalPauses, b), format: "%.1f / min",
                help: "Pauses of half a second to two seconds", more: "pauses more", less: "pauses less"),
            Row(label: "Long pauses", a: per10(da?.longPauses, a), b: per10(db?.longPauses, b), format: "%.1f / 10 min",
                help: "Silences over two seconds, often for effect", more: "uses more long silences", less: "uses fewer long silences"),
            Row(label: "No-breath runs", a: per10(da?.breathlessRuns.count, a), b: per10(db?.breathlessRuns.count, b),
                format: "%.1f / 10 min", help: "30 seconds or more without a pause", more: "runs on without pausing more often", less: "runs on without pausing less often"),
            Row(label: "Trailing off", a: da?.trailingOffPercent, b: db?.trailingOffPercent, format: "%.0f%%",
                help: "Sentences whose last word drops away", more: "lets more sentences trail off", less: "finishes more sentences strongly"),
            Row(label: "Questions", a: per10(da?.questions, a), b: per10(db?.questions, b), format: "%.1f / 10 min",
                help: "Questions put to the listener", more: "asks more questions", less: "asks fewer questions"),
            Row(label: "\u{201C}You\u{201D} share", a: share(da, \.youCount), b: share(db, \.youCount), format: "%.0f%%",
                help: "Of you / we / I, how much is \u{201C}you\u{201D}: speaking straight to people", more: "says \u{201C}you\u{201D} more", less: "says \u{201C}you\u{201D} less"),
            Row(label: "\u{201C}We\u{201D} share", a: share(da, \.weCount), b: share(db, \.weCount), format: "%.0f%%",
                help: "\u{201C}We\u{201D}: standing with the listener", more: "says \u{201C}we\u{201D} more", less: "says \u{201C}we\u{201D} less"),
            Row(label: "\u{201C}I\u{201D} share", a: share(da, \.iCount), b: share(db, \.iCount), format: "%.0f%%",
                help: "\u{201C}I\u{201D}: personal story and confession", more: "talks about themselves more", less: "talks about themselves less"),
            Row(label: "Movement", a: a.stage?.movementPerMinute, b: b.stage?.movementPerMinute, format: "%.2f / min",
                help: "How much they move across the stage (frame widths a minute)", more: "moves around more", less: "stays more still"),
            Row(label: "Facing camera", a: a.stage?.facingPercent, b: b.stage?.facingPercent, format: "%.0f%%",
                help: "Of the time the face is visible", more: "faces the camera more", less: "faces the camera less"),
            Row(label: "Coach score", a: a.coach.map { Double($0.score) }, b: b.coach.map { Double($0.score) }, format: "%.0f / 10",
                help: "From the AI coach in Assess, when it's been run", more: nil, less: nil)
        ]
    }

    private static func share(_ d: SpeakerReport.Delivery?, _ k: KeyPath<SpeakerReport.Delivery, Int>) -> Double? {
        guard let d else { return nil }
        let total = d.youCount + d.weCount + d.iCount
        return total > 0 ? Double(d[keyPath: k]) / Double(total) * 100 : nil
    }

    /// The clearest differences, biggest first, said about the other message.
    static func differences(_ a: SpeakerReport, _ b: SpeakerReport, other: String) -> [String] {
        var out: [(Double, String)] = []
        for r in rows(a, b) {
            guard let x = r.a, let y = r.b, let more = r.more, let less = r.less, x > 0 || y > 0 else { continue }
            let lo = min(x, y), hi = max(x, y)
            // How different, as a share of the smaller number (a jump from nothing counts as big)
            let change = lo > 0 ? hi / lo - 1 : 9
            guard change >= 0.2 else { continue }
            // Said against this message: "57% more" is y/x - 1; "30% less" is 1 - y/x
            let amount: String
            if y > x {
                amount = x == 0 ? "" : y / x >= 2 ? String(format: "%.1f×", y / x) : "\(Int(((y / x - 1) * 100).rounded()))% more"
            } else {
                amount = y == 0 ? "" : x / y >= 2 ? "half or less" : "\(Int(((1 - y / x) * 100).rounded()))% less"
            }
            let fx = String(format: r.format, x), fy = String(format: r.format, y)
            out.append((change, "\(other) \(y > x ? more : less)\(amount.isEmpty ? "" : " (\(amount))"): \(fy) against \(fx)."))
        }
        return out.sorted { $0.0 > $1.0 }.prefix(6).map(\.1)
    }

    // MARK: AI style comparison

    struct Style: Codable, Equatable {
        struct Area: Codable, Equatable, Identifiable {
            var id: String { area }
            var area: String; var a: String; var b: String
        }
        struct Borrow: Codable, Equatable, Identifiable {
            var id: String { idea }
            var idea: String; var example: String; var sentence: Int?
            /// Where the example is in the other message (seconds), filled in from `sentence`
            var time: Double?
        }
        var summary: String
        var areas: [Area]
        var borrow: [Borrow]
        var keep: [String]
    }

    private static var folder: URL { AppPaths.folder("Compare") }
    private static func file(_ a: String, _ b: String) -> URL {
        let h = SHA256.hash(data: Data("\(a)|\(b)".utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(h.prefix(24)) + ".json")
    }
    /// A comparison already made for this pair (so it's never paid for twice)
    static func savedStyle(_ a: String, _ b: String) -> Style? {
        guard let d = try? Data(contentsOf: file(a, b)) else { return nil }
        return try? JSONDecoder().decode(Style.self, from: d)
    }

    static func styleCompare(_ a: Side, _ b: Side) async throws -> Style {
        let sa = ReelDraft.sentences(from: a.words), sb = ReelDraft.sentences(from: b.words)
        func lines(_ s: [String]) -> String {
            s.enumerated().map { i, x in "[\(i)] \(x)" }.joined(separator: "\n")
        }
        let noun = ContentKind.current == .sermon ? "sermon" : "talk"
        let prompt = """
You are an experienced preaching coach comparing two \(noun)s so the first preacher can learn from the second. Be specific, warm and honest, and quote short phrases. Don't rank one preacher as better overall; describe the differences in style.

\(noun.uppercased()) A (the preacher being coached): "\(a.title)"
\(lines(sa.map(\.text)))

\(noun.uppercased()) B (the one to compare with): "\(b.title)"
\(lines(sb.map(\.text)))

Compare them in these areas, one or two sentences each for A and for B: Opening, Structure, Stories and illustrations, Use of Scripture, Application, Tone and connection, Close and response.
Then give 3 to 5 things A could borrow from B, each with a short quote from B as the example and the number of the B sentence it comes from.
Then give 2 or 3 things A already does well that are worth keeping.

Respond with ONLY valid JSON:
{"summary":"two or three sentences","areas":[{"area":"Opening","a":"...","b":"..."}],"borrow":[{"idea":"...","example":"quote from B","sentence":12}],"keep":["..."]}
"""
        let text = try await CostTag.$video.withValue("Compare: \(a.title) / \(b.title)") {
            try await LLMClipService.shared.complete(prompt, light: false)
        }
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
              var style = try? JSONDecoder().decode(Style.self, from: Data(String(text[s...e]).utf8)) else {
            throw NSError(domain: "Compare", code: 1, userInfo: [NSLocalizedDescriptionKey: "The AI's answer couldn't be read. Try again."])
        }
        for i in style.borrow.indices {
            if let n = style.borrow[i].sentence, sb.indices.contains(n) { style.borrow[i].time = sb[n].start }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(style).write(to: file(a.path, b.path))
        return style
    }
}

