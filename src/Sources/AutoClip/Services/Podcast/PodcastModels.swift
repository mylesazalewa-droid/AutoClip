import Foundation
import SwiftUI

/// A podcast episode: one or more camera angles (or an audio file), the edit (pauses and
/// filler words to cut), who is in it, the camera plan, sound settings and show notes.
/// All times are seconds on the first file's clock ("source time") unless they say otherwise.
struct PodcastEpisode: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var created = Date()
    var angles: [Angle]
    var isAudioOnly = false
    var duration: Double = 0
    var settings = PodcastSettings()
    var cuts: [Cut] = []
    var people: [Person] = []
    /// Who is talking when (from mouth movement)
    var turns: [Turn] = []
    /// The camera plan; rebuilt from `turns` unless the user changed a shot
    var shots: [Shot] = []
    var notes: PodcastNotes?
    /// Exported files by kind ("16:9", "9:16", "1:1", "4:5", "audio", "notes", "transcript", "srt")
    var exports: [String: String] = [:]
    /// Set once transcription and analysis have finished
    var analyzed = false

    struct Angle: Codable, Equatable, Hashable {
        var path: String
        /// Where this file's 0:00 falls on the first file's clock
        var offset: Double = 0
        var duration: Double = 0
    }

    struct Cut: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case pause, filler, manual }
        var id = UUID().uuidString
        var start: Double
        var end: Double
        var kind: Kind
        /// What was cut ("um", "2.4s pause")
        var label: String
        var enabled = true
        var length: Double { end - start }
    }

    struct Person: Codable, Equatable, Identifiable {
        var id: Int
        var name: String
        /// The angle they were found in, and their usual face box there (0…1, top-left origin)
        var angle: Int
        var x: Double, y: Double, w: Double, h: Double
        /// Same person in other angles: angle → face box
        var otherAngles: [Int: [Double]] = [:]
        var color: Int { id }
    }

    struct Turn: Codable, Equatable {
        var start: Double
        var end: Double
        var person: Int
    }

    struct Shot: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var start: Double
        var end: Double
        var angle: Int
        /// The person framed, or nil for the wide shot
        var person: Int?
        /// 1 = the person's normal close-up; above 1 = tighter punch-in
        var zoom: Double = 1
        /// Set when the user picked this shot by hand
        var manual = false
    }

    var enabledCuts: [Cut] { cuts.filter(\.enabled).sorted { $0.start < $1.start } }
    var removedSeconds: Double { enabledCuts.reduce(0) { $0 + $1.length } }

    /// The parts of the source that stay, in order.
    var keptRanges: [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var t = 0.0
        for c in enabledCuts where c.end > t {
            if c.start > t + 0.02 { out.append(t...c.start) }
            t = max(t, c.end)
        }
        if duration > t + 0.02 { out.append(t...duration) }
        return out
    }

    /// Source time → time in the edited episode (without any intro lead-in).
    func editedTime(_ t: Double) -> Double {
        var acc = 0.0
        for r in keptRanges {
            if t < r.lowerBound { return acc }
            if t <= r.upperBound { return acc + (t - r.lowerBound) }
            acc += r.upperBound - r.lowerBound
        }
        return acc
    }

    /// Time in the edited episode → source time.
    func sourceTime(_ edited: Double) -> Double {
        var acc = 0.0
        for r in keptRanges {
            let len = r.upperBound - r.lowerBound
            if edited <= acc + len { return r.lowerBound + (edited - acc) }
            acc += len
        }
        return duration
    }

    var editedDuration: Double { keptRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    func person(_ id: Int?) -> Person? { id.flatMap { i in people.first { $0.id == i } } }

    /// Who is talking at a source time
    func speaker(at t: Double) -> Int? { turns.first { t >= $0.start && t < $0.end }?.person }

    var folder: URL { PodcastStore.dir.appendingPathComponent(id) }
}

struct PodcastSettings: Codable, Equatable {
    // Edit
    var tightenPauses = true
    /// Pauses longer than this are shortened
    var maxPause = 0.8
    var removeFillers = true
    // Sound
    var cleanVoice = true
    var strength = 0.8
    /// Evens out a loud host and a quiet guest, and loud and quiet moments
    var levelVoices = true
    /// Integrated loudness target (−16 is the podcast standard)
    var loudness = -16.0
    var introPath: String?
    var outroPath: String?
    var musicBedPath: String?
    var musicVolume = 0.08
    /// Seconds the intro plays before anyone speaks
    var introLead = 6.0
    /// Seconds the outro plays after the last word
    var outroTail = 8.0
    // Camera
    /// "calm", "balanced" or "lively"
    var cameraStyle = "balanced"
    var zoomShots = true
    var showNames = true
    var titleCard = true
    var coverPath: String?
    // Export
    var formats: [String] = ["16:9"]
    var exportAudio = true
    /// "mp3", "m4a" or "wav"
    var audioFormat = "mp3"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PodcastSettings()
        tightenPauses = try c.decodeIfPresent(Bool.self, forKey: .tightenPauses) ?? d.tightenPauses
        maxPause = try c.decodeIfPresent(Double.self, forKey: .maxPause) ?? d.maxPause
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        cleanVoice = try c.decodeIfPresent(Bool.self, forKey: .cleanVoice) ?? d.cleanVoice
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        levelVoices = try c.decodeIfPresent(Bool.self, forKey: .levelVoices) ?? d.levelVoices
        loudness = try c.decodeIfPresent(Double.self, forKey: .loudness) ?? d.loudness
        introPath = try c.decodeIfPresent(String.self, forKey: .introPath)
        outroPath = try c.decodeIfPresent(String.self, forKey: .outroPath)
        musicBedPath = try c.decodeIfPresent(String.self, forKey: .musicBedPath)
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? d.musicVolume
        introLead = try c.decodeIfPresent(Double.self, forKey: .introLead) ?? d.introLead
        outroTail = try c.decodeIfPresent(Double.self, forKey: .outroTail) ?? d.outroTail
        cameraStyle = try c.decodeIfPresent(String.self, forKey: .cameraStyle) ?? d.cameraStyle
        zoomShots = try c.decodeIfPresent(Bool.self, forKey: .zoomShots) ?? d.zoomShots
        showNames = try c.decodeIfPresent(Bool.self, forKey: .showNames) ?? d.showNames
        titleCard = try c.decodeIfPresent(Bool.self, forKey: .titleCard) ?? d.titleCard
        coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        formats = try c.decodeIfPresent([String].self, forKey: .formats) ?? d.formats
        exportAudio = try c.decodeIfPresent(Bool.self, forKey: .exportAudio) ?? d.exportAudio
        audioFormat = try c.decodeIfPresent(String.self, forKey: .audioFormat) ?? d.audioFormat
    }
}

struct PodcastNotes: Codable, Equatable {
    struct Chapter: Codable, Equatable {
        /// Source time
        var time: Double
        var title: String
    }
    var titles: [String]
    var summary: String
    var description: String
    var chapters: [Chapter]
    var keywords: [String]
    var quotes: [String]
    var guests: [String]
    var socialPost: String
}

/// Episodes saved in ~/Documents/AutoClip/Podcasts/<id>/episode.json, plus the work in progress.
@MainActor
final class PodcastStore: ObservableObject {
    static let shared = PodcastStore()

    @Published private(set) var episodes: [PodcastEpisode] = []
    /// Episode id → what is happening ("Transcribing… 40%")
    @Published var status: [String: String] = [:]
    @Published var progress: [String: Double] = [:]
    @Published var errors: [String: String] = [:]
    /// Running work per episode, so it can be stopped
    var tasks: [String: Task<Void, Never>] = [:]
    /// Face stills for naming people: "episode-person" → image
    @Published var thumbnails: [String: NSImage] = [:]

    nonisolated static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Podcasts")
    }

    init() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        episodes = folders.compactMap { f in
            (try? Data(contentsOf: f.appendingPathComponent("episode.json"))).flatMap { try? JSONDecoder().decode(PodcastEpisode.self, from: $0) }
        }
        .sorted { $0.created > $1.created }
    }

    func episode(_ id: String) -> PodcastEpisode? { episodes.first { $0.id == id } }

    func save(_ e: PodcastEpisode) {
        if let i = episodes.firstIndex(where: { $0.id == e.id }) { episodes[i] = e } else { episodes.insert(e, at: 0) }
        try? FileManager.default.createDirectory(at: e.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: e.folder.appendingPathComponent("episode.json")) }
    }

    func update(_ id: String, _ change: (inout PodcastEpisode) -> Void) {
        guard var e = episode(id) else { return }
        change(&e)
        save(e)
    }

    /// Removes the episode from AutoClip (its working files too); the original recordings stay.
    func delete(_ id: String) {
        guard let e = episode(id) else { return }
        episodes.removeAll { $0.id == id }
        try? FileManager.default.trashItem(at: e.folder, resultingItemURL: nil)
    }

    static let palette: [Color] = SpeakerProfiles.palette
}
