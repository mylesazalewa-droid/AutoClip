import Foundation

/// Where AutoClip keeps its own files: ~/Library/Application Support/AutoClip.
///
/// It used to be ~/Documents/AutoClip. macOS checks permission every time an app opens something in
/// Documents, and an app that isn't Apple-signed is treated as new after every update, so files there
/// opened slowly and a waiting permission prompt could freeze AutoClip. Application Support needs no
/// permission. `DataMove` moves an existing Documents folder over once.
enum AppPaths {
    static let locationKey = "data_location"

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    /// The new home for AutoClip's files
    static var support: URL { home.appendingPathComponent("Library/Application Support/AutoClip", isDirectory: true) }
    /// The old one, still used if the move couldn't happen
    static var legacy: URL { home.appendingPathComponent("Documents/AutoClip", isDirectory: true) }

    /// Where AutoClip's files are on this Mac.
    static var root: URL {
        UserDefaults.standard.string(forKey: locationKey) == "documents" ? legacy : support
    }

    /// A folder or file inside it, e.g. `AppPaths.folder("Videos")`.
    static func folder(_ name: String) -> URL { root.appendingPathComponent(name) }
}

/// Moves ~/Documents/AutoClip to Application Support once, and updates every saved location.
/// Runs at launch before anything reads AutoClip's files.
enum DataMove {
    private static let ownerKey = "owner_mac"

    /// Whether this Mac holds the licence signing key (checked during the move, then remembered,
    /// so the sidebar never has to look in Documents).
    static var isOwnerMac: Bool { UserDefaults.standard.bool(forKey: ownerKey) }

    static func runIfNeeded() {
        let d = UserDefaults.standard
        guard d.string(forKey: AppPaths.locationKey) == nil else { return }
        let fm = FileManager.default
        // A new install has no settings yet: nothing to move, and Documents is never touched
        let domain = Bundle.main.bundleIdentifier.flatMap { d.persistentDomain(forName: $0) } ?? [:]
        let usedBefore = ["autoReelsHistory", "whisper_model_size", "ar_audioSettings", "ar_lastOutputDir", "home_tab"]
            .contains { domain[$0] != nil }
        guard usedBefore else { finish(.support, owner: false); return }

        let owner = fm.fileExists(atPath: AppPaths.home.appendingPathComponent("Documents/AutoClip License Keys/private-key.txt").path)
        let old = AppPaths.legacy, new = AppPaths.support
        guard fm.fileExists(atPath: old.path) else { finish(.support, owner: owner); return }
        if let link = try? fm.destinationOfSymbolicLink(atPath: old.path), !link.isEmpty { finish(.support, owner: owner); return }

        do {
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            // Only a move on the same disk is instant and can't half-finish; otherwise stay put
            guard sameVolume(old, new) else { finish(.documents, owner: owner); return }

            // Keep the settings exactly as they were before anything is rewritten
            let keep = new.appendingPathComponent("Moved from Documents", isDirectory: true)
            try fm.createDirectory(at: keep, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
            try plist.write(to: keep.appendingPathComponent("settings-before-move.plist"))

            var moved: [String] = []
            var done: [(URL, URL)] = []
            do {
                for item in try fm.contentsOfDirectory(atPath: old.path) where item != ".DS_Store" {
                    try merge(old.appendingPathComponent(item), into: new.appendingPathComponent(item), done: &done)
                    moved.append(item)
                }
            } catch {
                // Put everything back exactly as it was and keep using Documents
                for (src, dest) in done.reversed() {
                    try? fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.moveItem(at: dest, to: src)
                }
                throw error
            }

            // The speech engine's word list used to live in ~/Documents/huggingface
            let oldWords = AppPaths.home.appendingPathComponent("Documents/huggingface/models/openai")
            let newWords = new.appendingPathComponent("WhisperModels/models/openai")
            if fm.fileExists(atPath: oldWords.path), !fm.fileExists(atPath: newWords.path) {
                try? fm.createDirectory(at: newWords.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: oldWords, to: newWords)
            }

            // Every saved location that pointed into the old folder now points into the new one
            let swaps = [(old.path, new.path)]
            rewriteSettings(domain, swaps)
            rewriteFiles(in: new, swaps)

            // The old folder becomes a shortcut, so the videos are still where you'd look in Finder
            if (try? fm.contentsOfDirectory(atPath: old.path).filter { $0 != ".DS_Store" }.isEmpty) == true {
                try? fm.removeItem(at: old)
                try? fm.createSymbolicLink(at: old, withDestinationURL: new)
            }
            let note = "AutoClip moved its files here on \(Date()) so they open faster.\n\nMoved: \(moved.joined(separator: ", "))\n"
            try? note.write(to: keep.appendingPathComponent("What happened.txt"), atomically: true, encoding: .utf8)
            finish(.support, owner: owner)
        } catch {
            NSLog("AutoClip data move stopped, files left in Documents: \(error.localizedDescription)")
            finish(.documents, owner: owner)
        }
    }

    private enum Place { case support, documents }

    private static func finish(_ place: Place, owner: Bool) {
        UserDefaults.standard.set(place == .support ? "support" : "documents", forKey: AppPaths.locationKey)
        UserDefaults.standard.set(owner, forKey: ownerKey)
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let k: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: k).volumeIdentifier as? NSObject,
              let y = try? b.resourceValues(forKeys: k).volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    /// Moves `src` to `dest`. Where a folder of the same name is already there, moves its contents in;
    /// a file of the same name is kept and the moved one gets " (from Documents)".
    private static func merge(_ src: URL, into dest: URL, done: inout [(URL, URL)]) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir) else {
            try fm.moveItem(at: src, to: dest); done.append((src, dest)); return
        }
        var srcDir: ObjCBool = false
        fm.fileExists(atPath: src.path, isDirectory: &srcDir)
        if isDir.boolValue && srcDir.boolValue {
            for item in try fm.contentsOfDirectory(atPath: src.path) {
                try merge(src.appendingPathComponent(item), into: dest.appendingPathComponent(item), done: &done)
            }
            if (try? fm.contentsOfDirectory(atPath: src.path).filter { $0 != ".DS_Store" }.isEmpty) == true {
                try? fm.removeItem(at: src)
            }
        } else {
            let ext = dest.pathExtension
            let base = dest.deletingPathExtension().lastPathComponent + " (from Documents)"
            let to = dest.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? base : base + "." + ext)
            try fm.moveItem(at: src, to: to); done.append((src, to))
        }
    }

    // MARK: Rewriting locations

    static func fix(_ s: String, _ swaps: [(String, String)]) -> String {
        var s = s
        for (a, b) in swaps {
            s = s.replacingOccurrences(of: a, with: b)
            // JSONEncoder writes "/" as "\/"
            s = s.replacingOccurrences(of: a.replacingOccurrences(of: "/", with: "\\/"), with: b.replacingOccurrences(of: "/", with: "\\/"))
        }
        return s
    }

    static func fixValue(_ v: Any, _ swaps: [(String, String)]) -> Any {
        switch v {
        case let s as String: return fix(s, swaps)
        case let d as Data:
            if let s = String(data: d, encoding: .utf8), s.first == "{" || s.first == "[" { return Data(fix(s, swaps).utf8) }
            return d
        case let a as [Any]: return a.map { fixValue($0, swaps) }
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, x) in d { out[fix(k, swaps)] = fixValue(x, swaps) }
            return out
        default: return v
        }
    }

    /// Fixes locations in AutoClip's settings, including setting names that contain a location.
    private static func rewriteSettings(_ domain: [String: Any], _ swaps: [(String, String)]) {
        let d = UserDefaults.standard
        for (k, v) in domain {
            let nk = fix(k, swaps), nv = fixValue(v, swaps)
            if nk != k { d.removeObject(forKey: k) }
            if nk != k || !(nv as AnyObject).isEqual(v) { d.set(nv, forKey: nk) }
        }
    }

    /// Fixes locations in every JSON file under `dir`.
    private static func rewriteFiles(in dir: URL, _ swaps: [(String, String)]) {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let f as URL in e {
            if f.lastPathComponent == "WhisperModels" || f.lastPathComponent == "Videos" { e.skipDescendants(); continue }
            guard f.pathExtension == "json", let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let t = fix(s, swaps)
            if t != s { try? t.write(to: f, atomically: true, encoding: .utf8) }
        }
    }
}
