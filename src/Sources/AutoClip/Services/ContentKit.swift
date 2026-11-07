import Foundation
import AppKit

/// Everything a week of posting needs from one video, in one folder: every reel rendered, a
/// caption and hashtags for each, notes (sermon notes, or companion notes for other talks),
/// quote cards, a carousel and a thumbnail, the transcript and captions file, and a
/// suggested posting plan. AI parts are skipped (and said so) when there's no API key.
enum ContentKit {
    struct Options {
        var reels = true
        var posts = true
        var notes = true
        var graphics = true
        var transcript = true
    }

    struct Result {
        var folder: URL
        var skipped: [String]
        /// Post copy written for each reel (by draft id), to keep on the drafts
        var seo: [UUID: ReelDraft.SEO]
    }

    private static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return String(s.components(separatedBy: bad).joined(separator: "-").prefix(70)).trimmingCharacters(in: .whitespaces)
    }

    private static func stamp(_ t: Double) -> String {
        let i = Int(t); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }

    private static func srtTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    static func build(record: AutoReelRecord, in parent: URL, options o: Options,
                      progress: @escaping @MainActor (String) -> Void) async throws -> Result {
        try await CostTag.$video.withValue(record.title) {
            try await make(record: record, in: parent, options: o, progress: progress)
        }
    }

    private static func make(record: AutoReelRecord, in parent: URL, options o: Options,
                             progress: @escaping @MainActor (String) -> Void) async throws -> Result {
        let kind = record.kind
        let folder = parent.appendingPathComponent(safe(record.title) + " – Content Kit")
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var skipped: [String] = []
        var seoByID: [UUID: ReelDraft.SEO] = [:]
        let drafts = record.drafts ?? []

        guard let source = ReelGenerator.sourceVideoPath(for: record) else {
            throw NSError(domain: "AutoClip", code: 40, userInfo: [NSLocalizedDescriptionKey: "Can't find this video's source file."])
        }
        let words = try await TranscriptCache.transcript(for: source) { msg in Task { @MainActor in progress(msg) } }
        let sentences = ReelDraft.sentences(from: words)

        let st = ReelGenerator.settings(for: record)
        let wantsAI = o.posts || o.notes || o.graphics
        let key = wantsAI ? (await LLMClipService.shared.loadAPIKey(for: st.provider) ?? "") : ""
        let hasAI = !key.isEmpty
        // Post captions are a simple job, so on-device AI can write them without a key
        let localReady = o.posts && !hasAI ? await LocalAI.ready() : false
        let canPost = hasAI || localReady
        if !hasAI && wantsAI {
            skipped.append(canPost ? "Notes and graphics need an AI key (AutoClip → Settings → AI)."
                                   : "Captions, notes and graphics need an AI key (AutoClip → Settings → AI).")
        }

        // Transcript + captions file for the full video
        if o.transcript {
            await progress("Writing the transcript…")
            let text = SeriesStore.paragraphs(words).map { "[\(stamp($0.start))] \($0.text)" }.joined(separator: "\n\n")
            try? ("\(record.title)\n\n" + text).write(to: folder.appendingPathComponent("Transcript.txt"), atomically: true, encoding: .utf8)
            let srt = sentences.enumerated().map { i, s in
                "\(i + 1)\n\(srtTime(s.start)) --> \(srtTime(s.end))\n\(s.text)\n"
            }.joined(separator: "\n")
            try? srt.write(to: folder.appendingPathComponent("Captions (full video).srt"), atomically: true, encoding: .utf8)
        }

        // Post copy for each reel
        if o.posts && canPost && !drafts.isEmpty {
            await progress("Writing captions and hashtags…")
            do {
                let reels = drafts.map { d in
                    (title: d.title, text: d.pieces.flatMap { $0.sentences.flatMap(\.keptWords) }.map(\.word).joined(separator: " "))
                }
                let posts = try await LLMClipService.shared.postCopy(reels: reels, videoTitle: record.title, kind: kind,
                                                                     provider: st.provider, apiKey: key)
                for (d, p) in zip(drafts, posts) {
                    var seo = p; seo.hookText = d.hook ?? ""
                    seoByID[d.id] = seo
                }
                var md = "# Posts — \(record.title)\n\nOne post per clip. Copy the caption, then the hashtags.\n"
                for (i, d) in drafts.enumerated() {
                    guard let p = seoByID[d.id] else { continue }
                    md += "\n---\n\n## \(i + 1). \(d.title)  (\(Int(d.duration.rounded()))s)\n\n"
                    md += "**YouTube Shorts title:** \(p.title)\n\n\(p.description)\n\n\(p.hashtags.joined(separator: " "))\n"
                }
                try? md.write(to: folder.appendingPathComponent("Posts.md"), atomically: true, encoding: .utf8)
            } catch { skipped.append("Captions: \(error.localizedDescription)") }
        }

        // Notes
        if o.notes && hasAI {
            await progress(kind == .sermon ? "Writing sermon notes…" : "Writing notes…")
            do {
                var notes = SpeakerReportStore.load(for: source)?.notes
                if notes == nil {
                    let verses = kind.usesScripture ? VerseDetector.find(in: words).map(\.text) : []
                    var seen = Set<String>()
                    notes = try await LLMClipService.shared.sermonNotes(
                        sentences: sentences.map { ($0.start, $0.end, $0.text) }, title: record.title,
                        verses: verses.filter { seen.insert($0).inserted }, kind: kind,
                        provider: st.provider, apiKey: key)
                }
                if let n = notes {
                    try? n.plainText.write(to: folder.appendingPathComponent(kind == .sermon ? "Sermon notes.txt" : "Notes.txt"),
                                           atomically: true, encoding: .utf8)
                }
            } catch { skipped.append("Notes: \(error.localizedDescription)") }
        }

        // Quote cards, carousel, thumbnail
        if o.graphics && hasAI {
            await progress("Designing quote cards and a thumbnail…")
            do {
                let g = try await ReelGenerator.graphics(for: record) { msg in Task { @MainActor in progress(msg) } }
                let cards = SocialGraphics.cards(from: g.plan, sentences: g.sentences)
                let dir = folder.appendingPathComponent("Graphics")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let look = drafts.first?.look ?? CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0])
                let footer = record.title
                for (i, c) in cards.enumerated() {
                    await progress("Drawing graphic \(i + 1) of \(cards.count)…")
                    let bg = await SocialGraphics.frame(at: c.time, source: g.source)
                    let data = await Task.detached(priority: .userInitiated) {
                        SocialGraphics.png(SocialGraphics.render(c, background: bg, look: look, footer: footer))
                    }.value
                    try? data?.write(to: dir.appendingPathComponent(c.fileName))
                }
            } catch { skipped.append("Graphics: \(error.localizedDescription)") }
        }

        // Every reel, rendered (or copied when its export is up to date)
        if o.reels && !drafts.isEmpty {
            let dir = folder.appendingPathComponent("Clips")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, d) in drafts.enumerated() {
                let name = String(format: "%02d ", i + 1) + safe(d.title)
                let url = dir.appendingPathComponent(name + ".mp4")
                try? fm.removeItem(at: url)
                if let p = d.exportedPath, !d.editedSinceExport, fm.fileExists(atPath: p) {
                    await progress("Copying clip \(i + 1) of \(drafts.count)…")
                    try? fm.copyItem(at: URL(fileURLWithPath: p), to: url)
                } else {
                    var copy = d
                    copy.seo = nil   // the posts file has the copy; no stray .txt per reel
                    do {
                        try await copy.render(to: url) { p, _ in
                            Task { @MainActor in progress("Rendering clip \(i + 1) of \(drafts.count) — \(Int(p * 100))%") }
                        }
                    } catch { skipped.append("Clip \(i + 1): \(error.localizedDescription)") }
                }
            }
        }

        // A simple week plan
        if !drafts.isEmpty {
            let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            var plan = "# Posting plan — \(record.title)\n\nOne clip a day. Clips you already exported (your picks) come first. Move days around to suit you.\n\n"
            let ordered = drafts.filter { $0.exportedPath != nil } + drafts.filter { $0.exportedPath == nil }
            for (i, d) in ordered.enumerated() {
                let day = i < days.count ? days[i] : "Week \(i / 7 + 1), \(days[i % 7])"
                plan += "- **\(day):** \(d.title) (\(Int(d.duration.rounded()))s)\n"
            }
            if o.graphics && hasAI { plan += "\nPost the carousel mid-week and a quote card on the days without a clip.\n" }
            try? plan.write(to: folder.appendingPathComponent("Posting plan.md"), atomically: true, encoding: .utf8)
        }

        return Result(folder: folder, skipped: skipped, seo: seoByID)
    }
}
