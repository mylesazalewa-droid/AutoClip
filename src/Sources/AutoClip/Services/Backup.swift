import Foundation
import AppKit

/// One-file backups of everything AutoClip knows: settings, sermons and their edits, brand kit,
/// graphics, reviews, reports. Restoring on a new Mac fixes file locations so it all lines up.
/// API keys stay in the Keychain and are not included.
enum Backup {
    struct Manifest: Codable {
        var version: String
        var date: Date
        var home: String
        /// Original video path → its file inside the backup's Media folder
        var media: [String: String]
    }

    enum Failure: LocalizedError {
        case notABackup, zip(String)
        var errorDescription: String? {
            switch self {
            case .notABackup: return "That file isn't an AutoClip backup."
            case .zip(let m): return "Couldn't pack or unpack the backup: \(m)"
            }
        }
    }

    static var home: String { NSHomeDirectory() }
    static var support: URL { URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/AutoClip") }
    /// Where AutoClip's own files are (its folder in Application Support, or Documents on older setups)
    static var documents: URL { AppPaths.root }
    /// True when everything lives in one folder, so the "Documents" part of a backup is empty
    private static var oneFolder: Bool { documents.standardizedFileURL == support.standardizedFileURL }
    private static var domain: String { Bundle.main.bundleIdentifier ?? "com.autoclip.app.dev" }

    /// Big folders that can be downloaded or made again, left out of every backup.
    private static let skipAlways: Set<String> = ["WhisperModels", "running", "Samples"]
    /// Media folders, included only with "Include videos".
    private static let mediaFolders: Set<String> = ["Videos", "Shorts", "Podcasts", "Practice", "Audio"]

    // MARK: Size

    @MainActor
    static func sourceVideos() -> [String] {
        Array(Set(AutoReelsStore.shared.reels.compactMap { ReelGenerator.sourceVideoPath(for: $0) }))
            .filter { FileManager.default.fileExists(atPath: $0) && !$0.hasPrefix(documents.path) && !$0.hasPrefix(support.path) }
    }

    static func size(of url: URL, skipping: Set<String> = []) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if skipping.contains(f.lastPathComponent), (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                e.skipDescendants(); continue
            }
            total += Int64((try? f.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Rough sizes without and with videos.
    @MainActor
    static func estimate() async -> (small: Int64, withVideos: Int64) {
        let videos = sourceVideos()
        return await Task.detached {
            let base = oneFolder ? size(of: support, skipping: skipAlways.union(mediaFolders))
                : size(of: support, skipping: skipAlways) + size(of: documents, skipping: skipAlways.union(mediaFolders))
            let media = mediaFolders.reduce(Int64(0)) { $0 + size(of: documents.appendingPathComponent($1)) }
            let outside = videos.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0) }
            return (base, base + media + outside)
        }.value
    }

    // MARK: Making a backup

    @MainActor
    static func make(to zip: URL, includeVideos: Bool, progress: @escaping (String) -> Void) async throws {
        let videos = includeVideos ? sourceVideos() : []
        AutoReelsStore.shared.saveNow()   // a change from the last half second is in the backup too
        let settings = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let version = AppInfo.version
        try await Task.detached {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("AutoClip Backup \(UUID().uuidString.prefix(6))")
            let root = work.appendingPathComponent("AutoClip Backup")
            defer { try? fm.removeItem(at: work) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            progress("Saving settings…")
            let plist = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
            try plist.write(to: root.appendingPathComponent("settings.plist"))

            progress("Copying your sermons and graphics…")
            try copy(support, to: root.appendingPathComponent("Support"),
                     skipping: oneFolder ? (includeVideos ? skipAlways : skipAlways.union(mediaFolders)) : skipAlways)
            if !oneFolder {
                try copy(documents, to: root.appendingPathComponent("Documents"),
                         skipping: includeVideos ? skipAlways : skipAlways.union(mediaFolders))
            }

            var media: [String: String] = [:]
            if !videos.isEmpty {
                progress("Copying \(videos.count) sermon video\(videos.count == 1 ? "" : "s")…")
                let dir = root.appendingPathComponent("Media")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, v) in videos.enumerated() {
                    let name = "\(i + 1) " + URL(fileURLWithPath: v).lastPathComponent
                    try fm.copyItem(at: URL(fileURLWithPath: v), to: dir.appendingPathComponent(name))
                    media[v] = "Media/" + name
                }
            }
            let m = Manifest(version: version, date: Date(), home: home, media: media)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
            try enc.encode(m).write(to: root.appendingPathComponent("manifest.json"))

            progress("Packing it into one file…")
            try? fm.removeItem(at: zip)
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, zip.path])
        }.value
    }

    private static func copy(_ from: URL, to: URL, skipping: Set<String>) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) where !skipping.contains(item.lastPathComponent) {
            try fm.copyItem(at: item, to: to.appendingPathComponent(item.lastPathComponent))
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.zip(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Restoring

    /// Replaces this Mac's AutoClip data with the backup's. What was here goes to the Trash first.
    static func restore(from zip: URL, progress: @escaping (String) -> Void) async throws {
        try await Task.detached {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("AutoClip Restore \(UUID().uuidString.prefix(6))")
            defer { try? fm.removeItem(at: work) }
            progress("Unpacking…")
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let root = work.appendingPathComponent("AutoClip Backup")
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
                  let m = try? dec.decode(Manifest.self, from: data) else { throw Failure.notABackup }

            // Where everything moves to on this Mac
            var swaps: [(String, String)] = []
            let videosDir = documents.appendingPathComponent("Videos")
            for (old, rel) in m.media {
                swaps.append((old, videosDir.appendingPathComponent(URL(fileURLWithPath: rel).lastPathComponent).path))
            }
            // Backups made before AutoClip moved out of Documents point there
            swaps.append((m.home + "/Documents/AutoClip", documents.path))
            if m.home != home { swaps.append((m.home, home)) }

            progress("Putting your current AutoClip data in the Trash…")
            for dir in [support, documents] where fm.fileExists(atPath: dir.path) {
                try? fm.trashItem(at: dir, resultingItemURL: nil)
            }
            progress("Restoring sermons and graphics…")
            for (name, dest) in [("Support", support), ("Documents", documents)] {
                let src = root.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                // Item by item, so a backup's two parts can go into one folder
                for item in try fm.contentsOfDirectory(atPath: src.path) where !fm.fileExists(atPath: dest.appendingPathComponent(item).path) {
                    try fm.copyItem(at: src.appendingPathComponent(item), to: dest.appendingPathComponent(item))
                }
                rewrite(in: dest, swaps)
            }
            // A model folder we skipped may still be in the Trash copy; it downloads again if not.
            if !m.media.isEmpty {
                progress("Restoring sermon videos…")
                try fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
                for rel in m.media.values {
                    let src = root.appendingPathComponent(rel)
                    let dest = videosDir.appendingPathComponent(URL(fileURLWithPath: rel).lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
                }
            }
            progress("Restoring settings…")
            if let d = try? Data(contentsOf: root.appendingPathComponent("settings.plist")),
               let dict = try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                var fixed = DataMove.fixValue(dict, swaps) as? [String: Any] ?? dict
                // Where files live on this Mac stays as it is: the backup was just put there
                let here = UserDefaults.standard.string(forKey: AppPaths.locationKey) ?? "support"
                fixed[AppPaths.locationKey] = here
                fixed["owner_mac"] = UserDefaults.standard.bool(forKey: "owner_mac")
                UserDefaults.standard.setPersistentDomain(fixed, forName: domain)
                UserDefaults.standard.synchronize()
            }
        }.value
    }

    /// Fixes file locations in every JSON file under `dir`.
    private static func rewrite(in dir: URL, _ swaps: [(String, String)]) {
        guard !swaps.isEmpty, let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let f as URL in e where f.pathExtension == "json" {
            guard var s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let before = s
            for (a, b) in swaps {
                s = s.replacingOccurrences(of: a, with: b)
                // JSONEncoder writes "/" as "\/"
                s = s.replacingOccurrences(of: a.replacingOccurrences(of: "/", with: "\\/"), with: b.replacingOccurrences(of: "/", with: "\\/"))
            }
            if s != before { try? s.write(to: f, atomically: true, encoding: .utf8) }
        }
    }

    private static func swapValue(_ v: Any, _ swaps: [(String, String)]) -> Any {
        func fix(_ s: String) -> String {
            var s = s
            for (a, b) in swaps {
                s = s.replacingOccurrences(of: a, with: b)
                s = s.replacingOccurrences(of: a.replacingOccurrences(of: "/", with: "\\/"), with: b.replacingOccurrences(of: "/", with: "\\/"))
            }
            return s
        }
        switch v {
        case let s as String: return fix(s)
        case let d as Data:
            if let s = String(data: d, encoding: .utf8), s.first == "{" || s.first == "[" { return Data(fix(s).utf8) }
            return d
        case let a as [Any]: return a.map { swapValue($0, swaps) }
        case let d as [String: Any]: return d.mapValues { swapValue($0, swaps) }
        default: return v
        }
    }
}
