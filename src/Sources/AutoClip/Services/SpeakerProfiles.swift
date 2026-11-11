import SwiftUI

/// The people whose talks are assessed (the lead pastor, guest speakers, the youth pastor…) and
/// which video belongs to whom. Saved in ~/Documents/AutoClip/Speakers.json. A video nobody has
/// assigned belongs to the first speaker, so a single-speaker library needs no setup.
@MainActor
final class SpeakerProfiles: ObservableObject {
    static let shared = SpeakerProfiles()

    struct Speaker: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var color: Int
    }
    private struct Saved: Codable { var speakers: [Speaker]; var videos: [String: String] }

    @Published private(set) var speakers: [Speaker]
    /// video path → speaker id (only for videos not owned by the first speaker)
    @Published private(set) var videos: [String: String]

    static let palette: [Color] = [
        Color(red: 1.0, green: 0.75, blue: 0.0), Color(red: 0.4, green: 0.8, blue: 1.0),
        Color(red: 0.45, green: 0.9, blue: 0.55), Color(red: 0.95, green: 0.45, blue: 0.85),
        Color(red: 0.7, green: 0.6, blue: 1.0), Color(red: 1.0, green: 0.58, blue: 0.2)
    ]

    nonisolated static var file: URL {
        AppPaths.folder("Speakers.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.file), let s = try? JSONDecoder().decode(Saved.self, from: data), !s.speakers.isEmpty {
            speakers = s.speakers; videos = s.videos
        } else {
            speakers = [Speaker(id: "me", name: "Me", color: 0)]; videos = [:]
        }
    }

    var primary: Speaker { speakers[0] }

    func speaker(id: String) -> Speaker? { speakers.first { $0.id == id } }
    func speaker(for path: String) -> Speaker { videos[path].flatMap(speaker(id:)) ?? primary }
    func color(_ s: Speaker) -> Color { Self.palette[s.color % Self.palette.count] }

    func assign(_ path: String, to id: String) {
        if id == primary.id { videos.removeValue(forKey: path) } else { videos[path] = id }
        save()
    }

    @discardableResult
    func add(_ name: String) -> Speaker {
        let used = Set(speakers.map(\.color))
        let color = (0..<Self.palette.count).first { !used.contains($0) } ?? speakers.count
        let s = Speaker(id: UUID().uuidString, name: name, color: color)
        speakers.append(s)
        save()
        return s
    }

    func rename(_ id: String, to name: String) {
        guard let i = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[i].name = name
        save()
    }

    /// Removes a speaker; their videos go back to the first speaker. The first speaker stays.
    func remove(_ id: String) {
        guard id != primary.id else { return }
        speakers.removeAll { $0.id == id }
        videos = videos.filter { $0.value != id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Saved(speakers: speakers, videos: videos)) { try? data.write(to: Self.file) }
    }
}
