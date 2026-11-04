import Foundation
import CoreGraphics
import ImageIO
import Vision

/// A short that's been posted, and how it did.
struct PostedShort: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var platform = "YouTube"
    var link = ""
    var postedAt = Date()
    var videoPath: String?
    /// "improved" or "original", when it came from a review
    var version: String?
    var opening = ""
    /// The length of the version that was posted
    var length: Double?
    var views: Int?
    var likes: Int?
    var comments: Int?
    var shares: Int?
    var saves: Int?
    var averageWatched: Double?
    /// Percent of viewers still watching
    var heldAt3s: Double?
    var heldAtHalf: Double?
    var heldAtEnd: Double?
    var updatedAt: Date?

    var percentWatched: Double? {
        guard let averageWatched, let length, length > 0 else { return nil }
        return averageWatched / length * 100
    }
}

/// A pattern across posted shorts.
struct ResultInsight: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var detail: String
    /// Percent difference against the others
    var difference: Int
    var count: Int
    var others: Int
    /// Set when this is about a kind of opening
    var hookKind: String?
}

enum ShortResults {
    static let platforms = ["YouTube", "Instagram", "TikTok", "Facebook", "Other"]
    /// Below this many on each side, a difference is mostly chance.
    static let enough = 3

    static func hookKind(_ raw: String) -> String {
        let text = " " + raw.lowercased() + " "
        if text.contains("?") { return "question" }
        if text.rangeOfCharacter(from: .decimalDigits) != nil { return "number" }
        if [" never ", " stop ", " nobody ", " wrong ", " mistake", " truth ", " secret ", " most people ", " always ", " everyone "].contains(where: text.contains) { return "bold claim" }
        if [" i ", " i'm ", " i’m ", " my ", " when i ", " me "].contains(where: text.contains) { return "personal story" }
        if [" you ", " your ", " you're ", " you’re "].contains(where: text.contains) { return "speaking to you" }
        return "statement"
    }

    private static func middle(_ list: [Double]) -> Double {
        let s = list.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Each short against the usual for its platform, because a good share of a TikTok
    /// and a good share of a YouTube Short aren't the same number.
    private static func relative(_ list: [PostedShort]) -> [(short: PostedShort, value: Double)] {
        let usable = list.filter { $0.percentWatched != nil }
        let usual = Dictionary(grouping: usable, by: \.platform).mapValues { middle($0.compactMap(\.percentWatched)) }
        return usable.compactMap { s in
            guard let p = s.percentWatched, let u = usual[s.platform], u > 0 else { return nil }
            return (s, p / u)
        }
    }

    /// How many more shorts with watch time are needed before patterns can show.
    static func neededForPatterns(_ list: [PostedShort]) -> Int {
        max(0, enough * 2 - list.filter { $0.percentWatched != nil }.count)
    }

    static func insights(_ list: [PostedShort]) -> [ResultInsight] {
        let rows = relative(list)
        var out: [ResultInsight] = []
        func compare(_ name: (String) -> String, by key: (PostedShort) -> String?, kind: Bool = false) {
            let keyed = rows.compactMap { row in key(row.short).map { (key: $0, value: row.value) } }
            for group in Set(keyed.map(\.key)) {
                let inside = keyed.filter { $0.key == group }.map(\.value)
                let others = keyed.filter { $0.key != group }.map(\.value)
                guard inside.count >= enough, others.count >= enough else { continue }
                let a = middle(inside), b = middle(others)
                guard b > 0 else { continue }
                let difference = Int(((a / b - 1) * 100).rounded())
                guard abs(difference) >= 10 else { continue }
                out.append(.init(title: name(group),
                                 detail: difference > 0 ? "Watched about \(difference)% longer than your other shorts." : "Watched about \(-difference)% less than your other shorts.",
                                 difference: difference, count: inside.count, others: others.count, hookKind: kind ? group : nil))
            }
        }
        compare({ "Openings: \($0)" }, by: { $0.opening.isEmpty ? nil : hookKind($0.opening) }, kind: true)
        compare({ "Length: \($0)" }, by: { s in
            guard let l = s.length else { return nil }
            return l < 30 ? "under 30 seconds" : l <= 60 ? "30–60 seconds" : "over a minute"
        })
        compare({ "\($0 == "improved" ? "Improved" : "Original") versions" }, by: { $0.version })
        return out.sorted { abs($0.difference) > abs($1.difference) }
    }

    // MARK: Numbers people type or photograph

    /// "3,401", "1.2K", "2.5M"
    static func number(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "")
        var scale = 1.0
        if s.hasSuffix("k") { scale = 1_000; s.removeLast() }
        else if s.hasSuffix("m") { scale = 1_000_000; s.removeLast() }
        else if s.hasSuffix("b") { scale = 1_000_000_000; s.removeLast() }
        guard let n = Double(s.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return Int((n * scale).rounded())
    }

    /// "0:34", "1:02", "34", "34s", "34.2 sec"
    static func seconds(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard !parts.contains(where: { $0 == nil }), (2...3).contains(parts.count) else { return nil }
            return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
        }
        let cleaned = s.replacingOccurrences(of: #"\s*(seconds|second|secs|sec|s)$"#, with: "", options: .regularExpression)
        return Double(cleaned).flatMap { $0 >= 0 ? $0 : nil }
    }

    static func percent(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)).flatMap { (0...100).contains($0) ? $0 : nil }
    }

    /// Fills in what it can from text read off an analytics screenshot, where a label
    /// has its number beside it or on the next line. Anything else stays as it was.
    static func fill(_ s: inout PostedShort, fromLines lines: [String]) -> Int {
        var found = 0
        // Some apps put the number above its label, others below. The first label tells which.
        let labels = ["views", "plays", "likes", "comments", "shares", "saves"]
        let firstLabel = lines.firstIndex { line in labels.contains { line.lowercased().contains($0) } }
        let aboveFirst = firstLabel.map { $0 > 0 && number(lines[$0 - 1]) != nil && lines[$0].lowercased().rangeOfCharacter(from: .decimalDigits) == nil } ?? false
        func value(after label: String, at i: Int, _ read: (String) -> Bool) -> Bool {
            let rest = lines[i].lowercased().components(separatedBy: label).dropFirst().joined().trimmingCharacters(in: CharacterSet(charactersIn: " :·-"))
            if !rest.isEmpty, read(rest) { return true }
            let before = lines[i].lowercased().components(separatedBy: label).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !before.isEmpty, read(before) { return true }
            for k in (aboveFirst ? [i - 1, i + 1] : [i + 1, i - 1]) where lines.indices.contains(k) && read(lines[k]) { return true }
            return false
        }
        for i in lines.indices {
            let text = lines[i].lowercased()
            if s.averageWatched == nil, ["average view duration", "average watch time", "avg. watch time", "avg watch time", "average percentage"].first(where: text.contains) != nil,
               let label = ["average view duration", "average watch time", "avg. watch time", "avg watch time"].first(where: text.contains) {
                if value(after: label, at: i, { t in if let v = seconds(t) { s.averageWatched = v; return true }; return false }) { found += 1 }
            }
            if s.views == nil, let label = ["total play", "video views", "views", "plays"].first(where: text.contains), !text.contains("average") {
                if value(after: label, at: i, { t in if let v = number(t) { s.views = v; return true }; return false }) { found += 1 }
            }
            if s.likes == nil, let label = ["likes", "like"].first(where: text.contains) {
                if value(after: label, at: i, { t in if let v = number(t) { s.likes = v; return true }; return false }) { found += 1 }
            }
            if s.comments == nil, let label = ["comments", "comment"].first(where: text.contains) {
                if value(after: label, at: i, { t in if let v = number(t) { s.comments = v; return true }; return false }) { found += 1 }
            }
            if s.shares == nil, let label = ["shares", "share"].first(where: text.contains) {
                if value(after: label, at: i, { t in if let v = number(t) { s.shares = v; return true }; return false }) { found += 1 }
            }
            if s.saves == nil, let label = ["saves", "favorites", "saved"].first(where: text.contains) {
                if value(after: label, at: i, { t in if let v = number(t) { s.saves = v; return true }; return false }) { found += 1 }
            }
        }
        return found
    }

    /// The lines of text in an image, top to bottom. Runs on this Mac.
    static func readText(in url: URL) async -> [String] {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { c.resume(returning: []); return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let found = (request.results ?? []).sorted {
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
                }
                c.resume(returning: found.compactMap { $0.topCandidates(1).first?.string })
            }
        }
    }
}

// MARK: - Keeping results

@MainActor
final class ShortResultsStore: ObservableObject {
    static let shared = ShortResultsStore()
    @Published private(set) var shorts: [PostedShort] = []
    @Published var refreshing = false
    @Published var refreshNote: String?

    private var file: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Results/posted.json") }

    init() {
        if let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([PostedShort].self, from: d) { shorts = list }
    }

    private func write() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(shorts) { try? d.write(to: file, options: .atomic) }
    }

    func save(_ s: PostedShort) {
        if let i = shorts.firstIndex(where: { $0.id == s.id }) { shorts[i] = s } else { shorts.insert(s, at: 0) }
        shorts.sort { $0.postedAt > $1.postedAt }
        write()
    }

    func delete(_ s: PostedShort) {
        shorts.removeAll { $0.id == s.id }
        write()
    }

    func latest(forVideo path: String) -> PostedShort? { shorts.first { $0.videoPath == path } }

    /// The pattern this opening falls into, if the results show one.
    func insight(forOpening text: String) -> ResultInsight? {
        let kind = ShortResults.hookKind(text)
        return ShortResults.insights(shorts).first { $0.hookKind == kind }
    }

    /// Updates the public numbers for every short with a link.
    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        refreshNote = nil
        var updated = 0, failed = 0
        for s in shorts where !s.link.isEmpty {
            do {
                var copy = s
                try YTDLP.PublicStats.apply(await YTDLP.publicStats(s.link), to: &copy)
                save(copy)
                updated += 1
            } catch { failed += 1 }
        }
        refreshNote = failed == 0 ? "Updated \(updated) \(updated == 1 ? "short" : "shorts")." : "Updated \(updated). \(failed) couldn't be read, so they kept their numbers."
        refreshing = false
    }
}
