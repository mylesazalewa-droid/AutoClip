import Foundation

/// A sermon series taught over several weeks, and the AI's read on whether it holds together.
struct SermonSeries: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    /// Video paths in teaching order
    var videos: [String]
    var analysis: SeriesAnalysis?
}

struct SeriesAnalysis: Codable, Equatable {
    struct Link: Codable, Equatable {
        var time: Double?
        var quote: String
        /// The other part (1-based) this moment points back or forward to
        var to: Int?
    }
    struct Part: Codable, Equatable {
        var bigIdea: String
        var role: String
        var fit: Int
        var note: String
        var links: [Link]
    }
    struct Finding: Codable, Equatable {
        var title: String
        var detail: String
        var parts: [Int]
    }
    var analyzedAt = Date()
    /// The videos as they were when assessed, to notice later changes
    var videos: [String]
    var score: Int
    var verdict: String
    var summary: String
    var throughline: String
    var arc: String
    var parts: [Part]
    var strengths: [Finding]
    var gaps: [Finding]
    var overlaps: [Finding]
    var tensions: [Finding]
    var suggestions: [String]
    var recap: String
}

/// Series saved in ~/Documents/AutoClip/Series.json, plus running analyses (kept here so they
/// survive switching between videos).
@MainActor
final class SeriesStore: ObservableObject {
    static let shared = SeriesStore()

    @Published private(set) var series: [SermonSeries] = []
    @Published var status: [String: String] = [:]
    @Published var errors: [String: String] = [:]

    nonisolated static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Series.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode([SermonSeries].self, from: data) { series = s }
    }

    func series(containing path: String) -> SermonSeries? { series.first { $0.videos.contains(path) } }

    func upsert(_ s: SermonSeries) {
        // A video belongs to one series at a time
        for i in series.indices where series[i].id != s.id {
            series[i].videos.removeAll { s.videos.contains($0) }
        }
        series.removeAll { $0.videos.isEmpty && $0.id != s.id }
        if let i = series.firstIndex(where: { $0.id == s.id }) { series[i] = s } else { series.append(s) }
        save()
    }

    func remove(_ id: String) {
        series.removeAll { $0.id == id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(series) { try? data.write(to: Self.file) }
    }

    // MARK: Spotting series from titles

    /// "Baggage | Pt. 3 …" → 3
    nonisolated static func partNumber(_ title: String) -> Int? {
        guard let m = title.range(of: #"(?i)\b(?:pt|part|week|wk|session)\.?\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int(title[m].filter(\.isNumber))
    }

    /// The series name a title suggests: the part before "|", ":" or " - " when there is one.
    nonisolated static func seriesName(_ title: String) -> String {
        for sep in ["|", ":", " - ", " – "] {
            if let r = title.range(of: sep) {
                let head = title[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if head.count >= 3 { return head }
            }
        }
        return title
    }

    nonisolated static func key(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"(?i)\b(?:pt|part|week|wk)\.?\s*\d+"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }

    nonisolated static func sameSeries(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        if short.count >= 6 && long.hasPrefix(short) { return true }
        return min(a.count, b.count) >= 8 && editDistance(a, b) <= 2
    }

    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    /// Groups of 2+ videos whose titles look like one series, in teaching order (part number,
    /// then date). `titles` maps path → title; `dates` path → preached date when known.
    nonisolated static func suggestions(titles: [(path: String, title: String)], dates: [String: Date]) -> [SermonSeries] {
        // Join titles that match directly or through another title ("Our Church Keeps Unity" and
        // "Our Church Empowers People" both match "Our Church | Loves God")
        let names = titles.map { seriesName($0.title) }
        let keys = names.map(key)
        var parent = Array(keys.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        for i in keys.indices { for j in keys.indices where j > i && sameSeries(keys[i], keys[j]) { parent[root(j)] = root(i) } }
        var groups: [(name: String, paths: [String])] = []
        var slot: [Int: Int] = [:]
        for i in keys.indices {
            let r = root(i)
            if let g = slot[r] {
                groups[g].paths.append(titles[i].path)
                if names[i].count < groups[g].name.count { groups[g].name = names[i] }
            } else {
                slot[r] = groups.count
                groups.append((names[i], [titles[i].path]))
            }
        }
        let titleOf = Dictionary(titles.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
        return groups.filter { $0.paths.count >= 2 }.map { g in
            let ordered = g.paths.sorted { a, b in
                let pa = partNumber(titleOf[a] ?? ""), pb = partNumber(titleOf[b] ?? "")
                if let pa, let pb, pa != pb { return pa < pb }
                if (pa == nil) != (pb == nil) { return pa != nil }
                return (dates[a] ?? fileDate(a)) < (dates[b] ?? fileDate(b))
            }
            return SermonSeries(name: g.name, videos: ordered)
        }
    }

    nonisolated static func fileDate(_ path: String) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return [attrs?[.creationDate] as? Date, attrs?[.modificationDate] as? Date].compactMap { $0 }.min() ?? .distantFuture
    }

    // MARK: Analysis

    /// Transcribes any part that needs it, then asks the AI how well the series holds together.
    func analyze(_ id: String) {
        guard let s = series.first(where: { $0.id == id }), s.videos.count >= 2, status[id] == nil else { return }
        errors[id] = nil
        status[id] = "Getting ready…"
        Task {
            do {
                var parts: [LLMClipService.SeriesPart] = []
                for (i, path) in s.videos.enumerated() {
                    status[id] = "Reading part \(i + 1) of \(s.videos.count)…"
                    let words = try await TranscriptCache.transcript(for: path) { msg in
                        Task { @MainActor in self.status[id] = "Part \(i + 1) of \(s.videos.count): \(msg)" }
                    }
                    let report = SpeakerReportStore.load(for: path)
                    parts.append(.init(title: YTDLP.title(fromFile: URL(fileURLWithPath: path)),
                                       date: report?.videoDate ?? Self.fileDate(path),
                                       paragraphs: Self.paragraphs(words),
                                       bigIdea: report?.coach?.bigIdea ?? report?.notes?.bigIdea))
                }
                status[id] = "The AI is reading all \(parts.count) messages together…"
                let provider = LLMClipService.AIProvider(rawValue: UserDefaults.standard.string(forKey: "ar_provider") ?? "") ?? .google
                guard let key = await LLMClipService.shared.loadAPIKey(for: provider), !key.isEmpty else {
                    status[id] = nil
                    errors[id] = "Add an API key in Auto Reels → AI settings to assess a series."
                    return
                }
                var a = try await LLMClipService.shared.seriesAnalysis(name: s.name, parts: parts, provider: provider, apiKey: key)
                a.videos = s.videos
                if var cur = series.first(where: { $0.id == id }) {
                    cur.analysis = a
                    upsert(cur)
                }
                status[id] = nil
            } catch {
                status[id] = nil
                errors[id] = error.localizedDescription
            }
        }
    }

    /// The transcript as ~30-second paragraphs, each with its start time.
    nonisolated static func paragraphs(_ words: [Word]) -> [(start: Double, text: String)] {
        var out: [(Double, String)] = []
        var start: Double?, buf: [String] = []
        for w in words {
            if start == nil { start = w.startTime }
            buf.append(w.word.trimmingCharacters(in: .whitespaces))
            let ends = w.word.hasSuffix(".") || w.word.hasSuffix("?") || w.word.hasSuffix("!")
            if let s = start, (w.endTime - s >= 30 && ends) || w.endTime - s >= 45 {
                out.append((s, buf.joined(separator: " "))); start = nil; buf = []
            }
        }
        if let s = start, !buf.isEmpty { out.append((s, buf.joined(separator: " "))) }
        return out
    }
}
