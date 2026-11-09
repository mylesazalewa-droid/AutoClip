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
    static func all() -> [LibraryMedia] {
        var out: [LibraryMedia] = []
        let fm = FileManager.default
        func add(_ path: String?, _ title: String, _ source: String, _ date: Date) {
            guard let path, !path.isEmpty, fm.fileExists(atPath: path), !out.contains(where: { $0.path == path }) else { return }
            out.append(LibraryMedia(path: path, title: title.isEmpty ? name(path) : title, source: source, date: date))
        }
        for r in AutoReelsStore.shared.reels {
            add(ReelGenerator.sourceVideoPath(for: r), r.title, "Clips", Date(timeIntervalSince1970: r.dateCreated))
        }
        for e in PodcastStore.shared.episodes {
            for (i, a) in e.angles.enumerated() {
                add(a.path, e.angles.count > 1 ? "\(e.title) (\(i + 1))" : e.title, "Podcast", e.created)
            }
        }
        for p in AssessTab.knownVideos(reels: AutoReelsStore.shared.reels) {
            let d = (try? fm.attributesOfItem(atPath: p)[.creationDate] as? Date) ?? .distantPast
            add(p, name(p), p.hasPrefix(YTDLP.videosDir.path) ? "YouTube" : "Assess", d)
        }
        return out.sorted { $0.date > $1.date }
    }

    static func name(_ path: String) -> String { YTDLP.title(fromFile: URL(fileURLWithPath: path)) }
}

/// A menu of recordings already in AutoClip. Pick one instead of adding the file again.
struct LibraryMenu<Label: View>: View {
    var exclude: Set<String> = []
    let onPick: (LibraryMedia) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            let items = MediaLibrary.all().filter { !exclude.contains($0.path) }
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
        .help("Use a recording you've already added, without adding it again")
    }
}
