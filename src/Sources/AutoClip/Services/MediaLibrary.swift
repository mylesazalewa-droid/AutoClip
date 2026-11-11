import SwiftUI
import AppKit

/// Every recording already in AutoClip, wherever it came in (Clips, Podcast, Assess, Worship or a
/// YouTube download), so any page can use it again without adding it a second time.
struct LibraryMedia: Identifiable, Hashable {
    var path: String
    var title: String
    var source: String       // where it came in, e.g. "Clips" or "Podcast"
    var date: Date
    var id: String { path }
}

@MainActor
enum MediaLibrary {
    /// Everything known, with file checks done off the main thread (a video in Downloads or on a
    /// drive can make macOS check permission, which must never hold up drawing a page).
    static func load() async -> [LibraryMedia] {
        struct Candidate: Sendable { var path: String; var title: String; var source: String; var date: Date? }
        var list: [Candidate] = []
        for r in AutoReelsStore.shared.reels {
            if let p = ReelGenerator.sourceVideoPath(for: r) {
                list.append(Candidate(path: p, title: r.title, source: "Clips", date: Date(timeIntervalSince1970: r.dateCreated)))
            }
        }
        for e in PodcastStore.shared.episodes {
            for (i, a) in e.angles.enumerated() {
                list.append(Candidate(path: a.path, title: e.angles.count > 1 ? "\(e.title) (\(i + 1))" : e.title, source: "Podcast", date: e.created))
            }
        }
        let reels = AutoReelsStore.shared.reels
        let youTube = YTDLP.videosDir.path
        return await Task.detached(priority: .utility) { () -> [LibraryMedia] in
            let fm = FileManager.default
            for p in AssessTab.knownVideos(reels: reels) {
                list.append(Candidate(path: p, title: "", source: p.hasPrefix(youTube) ? "YouTube" : "Assess",
                                      date: (try? fm.attributesOfItem(atPath: p)[.creationDate] as? Date) ?? .distantPast))
            }
            var out: [LibraryMedia] = []
            for c in list where !c.path.isEmpty && !out.contains(where: { $0.path == c.path }) && fm.fileExists(atPath: c.path) {
                out.append(LibraryMedia(path: c.path, title: c.title.isEmpty ? YTDLP.title(fromFile: URL(fileURLWithPath: c.path)) : c.title,
                                        source: c.source, date: c.date ?? .distantPast))
            }
            return out.sorted { $0.date > $1.date }
        }.value
    }

    static func name(_ path: String) -> String { YTDLP.title(fromFile: URL(fileURLWithPath: path)) }
}

/// A menu of recordings already in AutoClip. Pick one instead of adding the file again.
struct LibraryMenu<Label: View>: View {
    var exclude: Set<String> = []
    let onPick: (LibraryMedia) -> Void
    @ViewBuilder var label: () -> Label
    @State private var all: [LibraryMedia] = []

    var body: some View {
        Menu {
            let items = all.filter { !exclude.contains($0.path) }
            if items.isEmpty {
                Text("Nothing added yet")
            } else {
                Section("Already in AutoClip") {
                    ForEach(items.prefix(40)) { m in
                        Button("\(m.title)  ·  \(m.source)") { onPick(m) }
                    }
                }
            }
        } label: { label() }
        .menuIndicator(.hidden)
        .fixedSize()
        .task { all = await MediaLibrary.load() }
        .help("Use a recording you've already added, without adding it again")
    }
}
