import Foundation
import AVFoundation

/// Finds where the sermon starts and ends in a whole service recording, by listening for music,
/// singing and talking on this Mac. Clips are then picked from the sermon only, so worship,
/// announcements and the offering are left out.
enum SermonFinder {
    struct Found: Codable, Equatable { var start: Double; var end: Double }

    /// On unless turned off in the Auto Reels settings
    static var enabled: Bool { UserDefaults.standard.object(forKey: "ar_findSermon") as? Bool ?? true }
    /// Recordings shorter than this are taken to be the sermon alone
    static let minimumService: Double = 30 * 60

    private static var file: URL {
        AppPaths.folder("sermon-ranges.json")
    }
    private static let lock = NSLock()

    /// A recording's answer: a range, or nil when it was checked and is the sermon throughout.
    private static func load() -> [String: Found?] {
        lock.withLock { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Found?].self, from: $0) } ?? [:] }
    }

    private static func store(_ path: String, _ found: Found?) {
        var all = load()
        all[path] = .some(found)
        lock.withLock {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
        }
    }

    static func cached(_ path: String) -> Found? { load()[path] ?? nil }

    /// Works it out once per recording. Nil when it's short, can't be read, or is all sermon.
    static func find(_ path: String, progress: @escaping (Double) -> Void) async -> Found? {
        if let known = load()[path] { return known }
        let duration = (try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration).seconds) ?? 0
        guard duration >= minimumService else { return nil }
        guard let range = try? await WorshipAnalysis.locateMessage(path: path, duration: duration, progress: progress) else { return nil }
        // Less than three minutes outside it: it was the sermon all along
        let outside = range.start + (duration - range.end)
        let found: Found? = outside < 180 ? nil : Found(start: max(0, range.start - 20), end: min(duration, range.end + 20))
        store(path, found)
        return found
    }

    /// Only the words inside the sermon.
    static func trim(_ words: [Word], to r: Found?) -> [Word] {
        guard let r else { return words }
        let kept = words.filter { $0.startTime >= r.start && $0.endTime <= r.end }
        return kept.count > 200 ? kept : words
    }

    /// For later work on the same video ("Generate more", Fire Short): uses what's already known.
    static func trimCached(_ words: [Word], path: String) -> [Word] {
        enabled ? trim(words, to: cached(path)) : words
    }

    static func label(_ r: Found) -> String {
        func t(_ s: Double) -> String { let i = Int(s); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60) }
        return "\(t(r.start))–\(t(r.end))"
    }
}
