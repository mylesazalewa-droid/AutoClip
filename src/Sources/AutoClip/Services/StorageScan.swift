import Foundation

/// One file or folder AutoClip keeps.
struct StorageItem: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var bytes: Int64
    var modified: Date?
    /// The parts of AutoClip that mention this file. Empty means nothing does.
    var usedBy: [String]
    var name: String {
        // Audio uploads sit in a numbered folder, so show the video inside it
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return inside.first { $0.hasSuffix(".mp4") } ?? url.lastPathComponent
    }
    /// A download that never finished
    var isPartial: Bool { ["part", "ytdl", "temp"].contains(url.pathExtension.lowercased()) || name.contains(".part") }
}

struct StorageGroup: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var detail: String
    var icon: String
    var bytes: Int64
    var items: [StorageItem]
    /// False for things AutoClip needs, or that are cleared from their own page.
    var canClear: Bool
}

struct StorageReport: Equatable {
    var groups: [StorageGroup]
    var free: Int64
    var capacity: Int64
    var total: Int64 { groups.reduce(0) { $0 + $1.bytes } }
    var unused: [StorageItem] { groups.filter(\.canClear).flatMap(\.items).filter { $0.usedBy.isEmpty } }
}

enum StorageScan {
    private static var root: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip") }

    private static func measure(_ url: URL) -> (bytes: Int64, modified: Date?) {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        func size(_ v: URLResourceValues?) -> Int64 { Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0) }
        guard values?.isDirectory == true else { return (size(values), values?.contentModificationDate) }
        var total: Int64 = 0
        if let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let f as URL in walk { total += size(try? f.resourceValues(forKeys: keys)) }
        }
        return (total, values?.contentModificationDate)
    }

    private static func read(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 50_000_000, let d = try? Data(contentsOf: url) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    /// Everything AutoClip has saved, with the part of the app it belongs to. Searching what's
    /// really saved means a new feature's files are protected without this list knowing about them.
    private static func savedData() -> [(label: String, text: String)] {
        var out: [(String, String)] = []
        func add(_ label: String, _ files: [URL]) { for f in files { if let t = read(f) { out.append((label, t)) } } }
        add("Projects", [root.appendingPathComponent("library.json"), root.appendingPathComponent("history.json")])
        add("Series", [root.appendingPathComponent("Series.json")] + jsonFiles(in: root.appendingPathComponent("Series")))
        add("Speakers", [root.appendingPathComponent("Speakers.json")] + jsonFiles(in: root.appendingPathComponent("Speakers")))
        add("Assess", jsonFiles(in: root.appendingPathComponent("Assess")))
        add("Worship", jsonFiles(in: root.appendingPathComponent("Worship")))
        add("Improve a Short", jsonFiles(in: root.appendingPathComponent("Shorts")))
        add("Results", jsonFiles(in: root.appendingPathComponent("Results")))
        add("Podcast", jsonFiles(in: root.appendingPathComponent("Podcasts")))
        if let id = Bundle.main.bundleIdentifier, let saved = UserDefaults.standard.persistentDomain(forName: id) {
            for (key, value) in saved {
                let lower = key.lowercased()
                // Only ever looks for file names, and has no business near anything secret
                if ["key", "token", "secret", "password"].contains(where: lower.contains) { continue }
                let label = lower.hasPrefix("autoreels") ? "Auto Reels" : "Settings"
                if let d = value as? Data { out.append((label, String(decoding: d, as: UTF8.self))) }
                else if let s = value as? String { out.append((label, s)) }
                else if let list = value as? [String] { out.append((label, list.joined(separator: "\n"))) }
            }
        }
        return out
    }

    private static func users(of name: String, in saved: [(label: String, text: String)]) -> [String] {
        let forms = Set([name, name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping,
                         name.replacingOccurrences(of: "\"", with: "\\\""), name.replacingOccurrences(of: "/", with: "\\/")])
        var found: [String] = []
        for s in saved where !found.contains(s.label) && forms.contains(where: s.text.contains) { found.append(s.label) }
        return found.sorted()
    }

    private static func group(_ title: String, _ detail: String, _ icon: String, dirs: [URL], canClear: Bool, saved: [(label: String, text: String)]) -> StorageGroup {
        var items: [StorageItem] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for f in files {
                let m = measure(f)
                items.append(StorageItem(url: f, bytes: m.bytes, modified: m.modified, usedBy: users(of: f.lastPathComponent, in: saved)))
            }
        }
        items.sort { $0.bytes > $1.bytes }
        return StorageGroup(title: title, detail: detail, icon: icon, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, canClear: canClear)
    }

    /// `reelFiles` are the finished reels, which can be saved anywhere.
    static func run(reelFiles: [String]) async -> StorageReport {
        await Task.detached(priority: .utility) {
            let saved = savedData()
            func dir(_ name: String) -> URL { root.appendingPathComponent(name) }
            let movies = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/AutoClip Podcasts")
            var groups = [
                group("Sermon videos", "Imported and downloaded videos. Reels you've finished keep working without these, but you can't re-edit or make new clips from a video once it's gone.", "film", dirs: [dir("Videos")], canClear: true, saved: saved),
                group("Audio uploads", "The waveform videos made for audio files. Your original audio file isn't kept here.", "waveform", dirs: [dir("Audio")], canClear: true, saved: saved),
                group("Practice recordings", "Recordings made in Assess.", "mic", dirs: [dir("Practice")], canClear: true, saved: saved),
                group("Podcasts", "Podcast episodes and their exports.", "mic.circle", dirs: [dir("Podcasts"), movies], canClear: true, saved: saved),
                group("Content kits", "Kits made by auto-import.", "shippingbox", dirs: [dir("Content Kits")], canClear: true, saved: saved),
                group("Speech model", "Needed to transcribe on this Mac, so it stays.", "text.bubble", dirs: [dir("WhisperModels")], canClear: false, saved: saved),
                group("Transcripts and reports", "Small, and they save a lot of waiting, so they stay.", "doc.text", dirs: [dir("Transcripts"), dir("Assess"), dir("Worship"), dir("Shorts"), dir("Results")], canClear: false, saved: saved),
            ]
            // Finished reels are the user's own exports, usually elsewhere. Delete those from Auto Reels.
            let inside = root.path + "/"
            let reels = Set(reelFiles).filter { !$0.hasPrefix(inside) && !$0.hasPrefix(movies.path + "/") && FileManager.default.fileExists(atPath: $0) }
            let reelItems = reels.map { p -> StorageItem in
                let url = URL(fileURLWithPath: p), m = measure(url)
                return StorageItem(url: url, bytes: m.bytes, modified: m.modified, usedBy: ["Auto Reels"])
            }.sorted { $0.bytes > $1.bytes }
            groups.append(StorageGroup(title: "Finished reels", detail: "Your exported reels, wherever you saved them. Delete these from Auto Reels so the project stays tidy.", icon: "play.rectangle.on.rectangle",
                                       bytes: reelItems.reduce(0) { $0 + $1.bytes }, items: reelItems, canClear: false))
            let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            return StorageReport(groups: groups.filter { !$0.items.isEmpty }.sorted { $0.bytes > $1.bytes },
                                 free: values?.volumeAvailableCapacityForImportantUsage ?? 0,
                                 capacity: Int64(values?.volumeTotalCapacity ?? 0))
        }.value
    }
}
