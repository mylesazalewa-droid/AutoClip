import Foundation
import AVFoundation
import Accelerate
import AppKit
import CoreImage
import SoundAnalysis
import Vision

/// What was measured in one service recording, plus what the team wrote about it.
struct WorshipReport: Codable, Equatable {
    var videoPath: String
    var title: String
    var date = Date()
    var analyzedAt = Date()
    var duration: Double
    /// The worship part of the recording (seconds)
    var rangeStart: Double
    var rangeEnd: Double

    /// Sound, one value per `bin` seconds
    var bin = 5.0
    var music: [Float] = []
    var singing: [Float] = []
    var speech: [Float] = []
    var clapping: [Float] = []
    var applause: [Float] = []
    var loudness: [Float] = []   // dB
    var lows: [Float] = []       // dB
    var mids: [Float] = []       // dB
    var highs: [Float] = []      // dB
    var clippedPercent = 0.0
    var feedback: [Double] = []

    var visual: Visual?
    var talks: [Talk] = []

    // The team's side
    var notes: [TeamNote] = []
    var ratings: [String: Int] = [:]
    var focus = ""
    var coach: WorshipCoach?
    var setlist: [SetSong] = []

    private enum CodingKeys: String, CodingKey {
        case videoPath, title, date, analyzedAt, duration, rangeStart, rangeEnd, bin, music, singing, speech, clapping, applause
        case loudness, lows, mids, highs, clippedPercent, feedback, visual, talks, notes, ratings, focus, coach, setlist
    }

    init(videoPath: String, title: String, duration: Double, rangeStart: Double, rangeEnd: Double) {
        self.videoPath = videoPath; self.title = title; self.duration = duration
        self.rangeStart = rangeStart; self.rangeEnd = rangeEnd
    }

    /// Reports saved before setlists existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoPath = try c.decode(String.self, forKey: .videoPath)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        analyzedAt = try c.decode(Date.self, forKey: .analyzedAt)
        duration = try c.decode(Double.self, forKey: .duration)
        rangeStart = try c.decode(Double.self, forKey: .rangeStart)
        rangeEnd = try c.decode(Double.self, forKey: .rangeEnd)
        bin = try c.decode(Double.self, forKey: .bin)
        music = try c.decode([Float].self, forKey: .music)
        singing = try c.decode([Float].self, forKey: .singing)
        speech = try c.decode([Float].self, forKey: .speech)
        clapping = try c.decode([Float].self, forKey: .clapping)
        applause = try c.decode([Float].self, forKey: .applause)
        loudness = try c.decode([Float].self, forKey: .loudness)
        lows = try c.decode([Float].self, forKey: .lows)
        mids = try c.decode([Float].self, forKey: .mids)
        highs = try c.decode([Float].self, forKey: .highs)
        clippedPercent = try c.decode(Double.self, forKey: .clippedPercent)
        feedback = try c.decode([Double].self, forKey: .feedback)
        visual = try c.decodeIfPresent(Visual.self, forKey: .visual)
        talks = try c.decode([Talk].self, forKey: .talks)
        notes = try c.decode([TeamNote].self, forKey: .notes)
        ratings = try c.decode([String: Int].self, forKey: .ratings)
        focus = try c.decode(String.self, forKey: .focus)
        coach = try c.decodeIfPresent(WorshipCoach.self, forKey: .coach)
        setlist = try c.decodeIfPresent([SetSong].self, forKey: .setlist) ?? []
    }

    /// Sampled video frames across the worship part.
    struct Visual: Codable, Equatable {
        var start: Double
        var end: Double
        var samples: [Sample]
        struct Sample: Codable, Equatable {
            var t: Double
            var people: Int
            var faces: Int
            var facing: Int
            var smile: Bool?       // nil = no face close enough to read
            var handsUp: Int       // team: facing the camera
            var energy: Double?    // body movement over a moment
            // Added later, so older reports don't have them
            var clapping: Int?     // team members clapping
            var roomPeople: Int?   // backs to the camera: the congregation
            var roomHands: Int?
            var roomClapping: Int?
        }
    }

    struct Talk: Codable, Equatable, Identifiable {
        var id: Double { start }
        var start: Double
        var end: Double
        var text: String
        var wordCount: Int
        var fillers: Int
        /// Spoken over the music rather than in a break
        var overMusic: Bool?
    }

    struct TeamNote: Codable, Equatable, Identifiable {
        var id = UUID()
        var time: Double
        var category: String
        var text: String
    }
}

struct WorshipCoach: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: String { title }
        var title: String
        var detail: String
    }
    var summary: String
    var wins: [Item]
    var improvements: [Item]
    var rehearsal: [String]
}

enum WorshipStore {
    static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Worship")
    }
    private static func file(for path: String) -> URL {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent(String(name.prefix(120)) + ".json")
    }
    static func load(for path: String) -> WorshipReport? {
        (try? Data(contentsOf: file(for: path))).flatMap { try? JSONDecoder().decode(WorshipReport.self, from: $0) }
    }
    static func save(_ r: WorshipReport) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: file(for: r.videoPath)) }
    }
    static func delete(_ r: WorshipReport) { try? FileManager.default.removeItem(at: file(for: r.videoPath)) }
    static func all() -> [WorshipReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(WorshipReport.self, from: $0) } }
            .sorted { $0.date > $1.date }
    }
}

// MARK: - Reading the report

/// Everything worked out from a report for its current worship range.
struct WorshipStats {
    struct Part: Identifiable {
        enum Kind { case song, talk, quiet }
        var id: Double { start }
        let kind: Kind
        let start: Double
        let end: Double
        var length: Double { end - start }
    }

    let report: WorshipReport
    let parts: [Part]
    var songs: [Part] { parts.filter { $0.kind == .song } }
    var quietGaps: [Part] { parts.filter { $0.kind == .quiet && $0.length >= 8 && $0.start > report.rangeStart && $0.end < report.rangeEnd } }

    init(_ r: WorshipReport) {
        report = r
        parts = Self.sections(r).compactMap { p in
            let a = max(p.start, r.rangeStart), b = min(p.end, r.rangeEnd)
            return b - a >= r.bin ? Part(kind: p.kind, start: a, end: b) : nil
        }
    }

    /// Splits the whole recording into music, talking and quiet.
    static func sections(_ r: WorshipReport) -> [Part] {
        let n = r.loudness.count
        guard n > 0 else { return [] }
        let top = r.loudness.sorted()[Int(Double(n - 1) * 0.95)]
        var kinds: [Part.Kind] = (0..<n).map { i in
            if r.loudness[i] < top - 28 { return .quiet }
            let sung = max(r.music[safe: i], r.singing[safe: i])
            let said = r.speech[safe: i]
            if said > 0.45 && said > sung { return .talk }
            return sung > 0.2 ? .song : said > 0.15 ? .talk : .quiet
        }
        // One odd bin inside a run isn't a change
        if n > 2 { for i in 1..<(n - 1) where kinds[i - 1] == kinds[i + 1] { kinds[i] = kinds[i - 1] } }
        var out: [Part] = []
        var start = 0
        for i in 1...n where i == n || kinds[i] != kinds[start] {
            out.append(Part(kind: kinds[start], start: Double(start) * r.bin, end: Double(i) * r.bin))
            start = i
        }
        // Short stretches of music between words are a pad under talking, not a song
        out = out.map { $0.kind == .song && $0.length < 40 ? Part(kind: .talk, start: $0.start, end: $0.end) : $0 }
        var merged: [Part] = []
        for p in out {
            if let l = merged.last, l.kind == p.kind { merged[merged.count - 1] = Part(kind: l.kind, start: l.start, end: p.end) } else { merged.append(p) }
        }
        return merged
    }

    /// The sermon: the longest run of talking, carrying across short pauses.
    static func message(_ r: WorshipReport) -> Part? {
        var runs: [Part] = []
        for p in sections(r) where p.kind == .talk {
            if let l = runs.last, p.start - l.end < 60,
               !sections(r).contains(where: { $0.kind == .song && $0.start >= l.end && $0.end <= p.start }) {
                runs[runs.count - 1] = Part(kind: .talk, start: l.start, end: p.end)
            } else { runs.append(p) }
        }
        return runs.filter { $0.length >= 480 }.max { $0.length < $1.length }
    }

    /// The worship part: everything before the sermon, when one can be found.
    static func suggestedRange(_ r: WorshipReport) -> (start: Double, end: Double) {
        let all = sections(r)
        let message = message(r)
        let before = all.filter { $0.kind == .song && $0.end <= (message?.start ?? .infinity) }
        let songs = before.isEmpty ? all.filter { $0.kind == .song } : before
        guard let first = songs.first, let last = songs.last else { return (0, r.duration) }
        return (max(0, first.start - 10), min(r.duration, last.end + 10))
    }

    private func values(_ a: [Float], in part: Part) -> [Float] {
        let i = Int(part.start / report.bin), j = Int(part.end / report.bin)
        guard i < a.count else { return [] }
        return Array(a[i..<min(j, a.count)])
    }

    private func average(_ a: [Float]) -> Float { a.isEmpty ? 0 : a.reduce(0, +) / Float(a.count) }
    func loudness(of part: Part) -> Double { Double(average(values(report.loudness, in: part))) }
    func singingShare(of part: Part) -> Double { Double(average(values(report.singing, in: part))) }
    /// Seconds of clapping in this part
    func clapSeconds(in part: Part) -> Double {
        let heard = Double(values(report.clapping, in: part).reduce(0, +)) * report.bin
        let seen = (report.visual?.samples ?? []).filter { $0.t >= part.start && $0.t < part.end && (($0.roomClapping ?? 0) + ($0.clapping ?? 0)) > 0 }
        return max(heard, Double(seen.count) * 4)
    }

    /// Times with audible clapping, or applause and cheering.
    private func marks(_ a: [Float], over threshold: Float) -> [Double] {
        a.enumerated().compactMap { i, v -> Double? in
            let t = Double(i) * report.bin
            return v > threshold && t >= report.rangeStart && t < report.rangeEnd ? t : nil
        }
    }
    var heardClaps: [Double] { marks(report.clapping, over: 0.15) }
    /// Clapping heard or seen, room or team
    var clapMarks: [Double] { thin((heardClaps + teamClapMarks).sorted(), by: 5) }
    var roomClapMarks: [Double] { samples.filter { ($0.roomClapping ?? 0) > 0 }.map(\.t) }
    var teamClapMarks: [Double] { samples.filter { ($0.clapping ?? 0) > 0 }.map(\.t) }
    var roomHandsMarks: [Double] { thin(samples.filter { ($0.roomHands ?? 0) + ($0.roomClapping ?? 0) > 0 }.map(\.t)) }
    /// Saved before clapping and raised hands were told apart
    var needsRewatch: Bool { report.visual != nil && report.visual?.samples.contains { $0.roomPeople != nil } != true }
    private var roomShots: [WorshipReport.Visual.Sample] { samples.filter { ($0.roomPeople ?? 0) > 0 } }
    var roomVisible: Bool { roomShots.count >= 10 }
    /// From behind, wrists are often hidden, so clapping and raised hands are counted together.
    var roomHandsPercent: Double? {
        roomVisible ? Double(roomShots.filter { ($0.roomHands ?? 0) + ($0.roomClapping ?? 0) > 0 }.count) / Double(roomShots.count) * 100 : nil
    }
    var roomClapPercent: Double? {
        roomVisible ? Double(roomShots.filter { ($0.roomClapping ?? 0) > 0 }.count) / Double(roomShots.count) * 100 : nil
    }
    var applauseMarks: [Double] { marks(report.applause, over: 0.15) }
    var feedback: [Double] { report.feedback.filter { $0 >= report.rangeStart && $0 < report.rangeEnd } }

    /// Sudden volume changes inside a song.
    var jumps: [Double] {
        var out: [Double] = []
        for song in songs {
            let v = values(report.loudness, in: song)
            guard v.count > 3 else { continue }
            for i in 1..<(v.count - 1) where abs(v[i] - v[i - 1]) > 8 && abs(v[i + 1] - v[i - 1]) > 7 {
                out.append(song.start + Double(i) * report.bin)
            }
        }
        return out
    }

    var songLoudnessSpread: Double {
        let l = songs.map { loudness(of: $0) }
        return (l.max() ?? 0) - (l.min() ?? 0)
    }

    private func bandBalance() -> (lowOverMid: Double, highOverMid: Double) {
        var lows: [Float] = [], mids: [Float] = [], highs: [Float] = []
        for s in songs {
            lows += values(report.lows, in: s); mids += values(report.mids, in: s); highs += values(report.highs, in: s)
        }
        return (Double(average(lows) - average(mids)), Double(average(highs) - average(mids)))
    }

    // Visual

    private var samples: [WorshipReport.Visual.Sample] {
        (report.visual?.samples ?? []).filter { $0.t >= report.rangeStart && $0.t < report.rangeEnd }
    }
    var smileReadable: Int { samples.filter { $0.smile != nil }.count }
    var smilePercent: Double? {
        guard smileReadable >= 10 else { return nil }
        return Double(samples.filter { $0.smile == true }.count) / Double(smileReadable) * 100
    }
    var smileMarks: [Double] { thin(samples.filter { $0.smile == true }.map(\.t)) }
    var handsPercent: Double? {
        let seen = samples.filter { $0.people > 0 }
        guard seen.count >= 10 else { return nil }
        return Double(seen.filter { $0.handsUp > 0 }.count) / Double(seen.count) * 100
    }
    var handsMarks: [Double] { thin(samples.filter { $0.handsUp > 0 }.map(\.t)) }
    var facingPercent: Double? {
        let faces = samples.reduce(0) { $0 + $1.faces }
        guard faces >= 10 else { return nil }
        return Double(samples.reduce(0) { $0 + $1.facing }) / Double(faces) * 100
    }
    var averagePeople: Double? {
        let seen = samples.filter { $0.people > 0 }
        return seen.isEmpty ? nil : Double(seen.reduce(0) { $0 + $1.people }) / Double(seen.count)
    }
    /// 0…1, how much bodies move
    var movement: Double? {
        let e = samples.compactMap(\.energy)
        return e.count >= 10 ? e.reduce(0, +) / Double(e.count) : nil
    }
    private func thin(_ times: [Double], by gap: Double = 15) -> [Double] {
        var out: [Double] = []
        for t in times where t - (out.last ?? -100) >= gap { out.append(t) }
        return out
    }

    // Talking

    var talks: [WorshipReport.Talk] { report.talks.filter { $0.start >= report.rangeStart && $0.end <= report.rangeEnd + 15 } }
    var talkSeconds: Double { talks.reduce(0) { $0 + $1.end - $1.start } }
    var averageWPM: Double? {
        let w = talks.reduce(0) { $0 + $1.wordCount }
        return talkSeconds >= 20 ? Double(w) / talkSeconds * 60 : nil
    }
    var fillersPerMinute: Double? {
        talkSeconds >= 20 ? Double(talks.reduce(0) { $0 + $1.fillers }) / (talkSeconds / 60) : nil
    }
    /// Talks asking the room to join in
    var invitations: Int {
        let phrases = ["sing", "lift", "raise", "clap", "stand", "let's", "lets", "join", "with us", "together", "come on", "declare", "shout", "can we", "thank"]
        return talks.filter { t in let l = t.text.lowercased(); return phrases.contains { l.contains($0) } }.count
    }

    // MARK: Scores (nil when the recording can't show it)

    var soundScore: Int? {
        guard !songs.isEmpty else { return nil }
        let b = bandBalance()
        var s = 100.0
        s -= min(30, report.clippedPercent * 10)
        s -= min(30, Double(feedback.count) * 8)
        s -= min(20, Double(jumps.count) * 4)
        s -= min(15, max(0, songLoudnessSpread - 4) * 3)
        s -= max(0, b.lowOverMid - 6) * 2
        s -= max(0, b.highOverMid + 2) * 2
        return Self.clamp(s)
    }
    var engagementScore: Int? {
        guard !songs.isEmpty else { return nil }
        let songTime = max(1, songs.reduce(0) { $0 + $1.length })
        let heard = songs.reduce(0) { $0 + Double(values(report.clapping, in: $1).reduce(0, +)) * report.bin } / songTime
        let sound = min(1, (heard + Double(applauseMarks.count) * report.bin / songTime) / 0.15)
        if let clap = roomClapPercent, let hands = roomHandsPercent {
            // The room is in shot: what it's doing counts most
            _ = clap
            return Self.clamp((sound * 0.3 + min(1, hands / 50) * 0.7) * 100)
        }
        // Nothing heard or seen may only mean the recording can't show the room
        if clapMarks.isEmpty && applauseMarks.isEmpty && (handsPercent ?? 0) == 0 { return nil }
        guard let hands = handsPercent else { return Self.clamp(sound * 100) }
        return Self.clamp((sound * 0.6 + min(1, hands / 40) * 0.4) * 100)
    }
    var smilesScore: Int? { smilePercent.map { Self.clamp($0 / 70 * 100) } }
    var stageScore: Int? {
        guard let f = facingPercent else { return nil }
        let facing = min(1, max(0, (f - 30) / 55))
        guard let m = movement else { return Self.clamp(facing * 100) }
        return Self.clamp((facing * 0.6 + min(1, max(0, (m - 0.01) / 0.08)) * 0.4) * 100)
    }
    var communicationScore: Int? {
        guard !talks.isEmpty else { return nil }
        var s = 75.0
        if invitations > 0 { s += 15 }
        s -= Double(quietGaps.count) * 8
        s -= (fillersPerMinute ?? 0) * 2
        s -= Double(talks.filter { $0.end - $0.start > 180 }.count) * 10
        if let w = averageWPM, w > 185 || w < 90 { s -= 10 }
        return Self.clamp(s)
    }
    private static func clamp(_ v: Double) -> Int { Int(min(100, max(0, v)).rounded()) }

    // MARK: Pointers

    var engagementPointers: [Pointer] {
        var p: [Pointer] = []
        if let c = roomClapPercent, let h = roomHandsPercent {
            p.append(.init(icon: "hands.clap", text: String(format: "The congregation is in shot, with hands up or clapping in %.0f%% of shots. From behind it can't always tell the two apart, so they're counted together. Clearly clapping: %.0f%%.", h, c), good: h > 15))
        }
        if clapMarks.isEmpty && applauseMarks.isEmpty && roomClapMarks.isEmpty {
            p.append(.init(icon: "hands.clap", text: "No clapping or cheering found. That may be the recording: a board feed or a loud band can hide the room. A microphone facing the room would show it.", good: false))
        } else if !heardClaps.isEmpty {
            p.append(.init(icon: "ear", text: "Clapping heard at \(heardClaps.count) moments. Clapping under a loud band can be missed, so treat this as the least it could be.", good: true))
        }
        if !teamClapMarks.isEmpty {
            p.append(.init(icon: "hands.clap", text: "The team is clapping in \(teamClapMarks.count) shots.", good: true))
        }
        if let h = handsPercent { p.append(.init(icon: "hand.raised", text: String(format: "Hands raised on the team in %.0f%% of shots.", h), good: h > 0)) }
        return p
    }

    var soundPointers: [Pointer] {
        var p: [Pointer] = []
        if report.clippedPercent > 0.3 {
            p.append(.init(icon: "waveform.badge.exclamationmark", text: String(format: "%.1f%% of the sound hits the top of the recording and distorts. Turn the feed to the recording down a little.", report.clippedPercent), good: false))
        }
        if !feedback.isEmpty {
            p.append(.init(icon: "ear", text: "\(feedback.count) possible feedback moment\(feedback.count == 1 ? "" : "s"). Listen at the marked times to check them.", good: false))
        }
        if !jumps.isEmpty {
            p.append(.init(icon: "speaker.wave.3", text: "\(jumps.count) sudden volume change\(jumps.count == 1 ? "" : "s") inside a song. Check whether they were planned.", good: false))
        }
        if songLoudnessSpread > 6 {
            p.append(.init(icon: "slider.horizontal.3", text: String(format: "Songs differ by %.0f dB in volume. Aim to hold them within about 4 dB unless it's on purpose.", songLoudnessSpread), good: false))
        }
        let b = bandBalance()
        if !songs.isEmpty, b.lowOverMid > 8 { p.append(.init(icon: "dial.low", text: "Lots of low end compared with the middle, where voices sit. It may sound muddy.", good: false)) }
        if !songs.isEmpty, b.highOverMid > 0 { p.append(.init(icon: "dial.high", text: "The top end is strong compared with the middle. It may sound harsh.", good: false)) }
        if p.isEmpty { p.append(.init(icon: "checkmark.circle", text: "No distortion, feedback or sudden volume changes found.", good: true)) }
        return p
    }

    var stagePointers: [Pointer] {
        var p: [Pointer] = []
        if let f = facingPercent {
            p.append(f < 55 ? .init(icon: "eye", text: String(format: "Faces point toward the camera %.0f%% of the time. Look up from music stands and screens more often.", f), good: false)
                            : .init(icon: "checkmark.circle", text: String(format: "Faces point toward the camera %.0f%% of the time.", f), good: true))
        }
        if let s = smilePercent {
            p.append(s < 20 ? .init(icon: "face.smiling", text: String(format: "Smiles show in %.0f%% of the close shots. Let the joyful songs reach your face.", s), good: false)
                            : .init(icon: "face.smiling", text: String(format: "Smiles show in %.0f%% of the close shots.", s), good: true))
        } else {
            p.append(.init(icon: "face.dashed", text: "The camera wasn't close enough often enough to read smiles. Close-up shots make this work.", good: false))
        }
        if let m = movement {
            p.append(m < 0.015 ? .init(icon: "figure.stand", text: "The team stays very still. Small, natural movement helps the room relax into it.", good: false)
                               : .init(icon: "checkmark.circle", text: "The team is moving with the music.", good: true))
        }
        return p
    }

    var communicationPointers: [Pointer] {
        var p: [Pointer] = []
        let exhortations = talks.filter { $0.overMusic == true }.count
        if exhortations > 0 { p.append(.init(icon: "text.bubble", text: "\(exhortations) exhortation\(exhortations == 1 ? "" : "s") spoken over the music.", good: true)) }
        if talks.isEmpty { p.append(.init(icon: "text.bubble", text: "No talking found between songs. A short welcome or invitation helps people join in.", good: false)) }
        if !talks.isEmpty && invitations == 0 {
            p.append(.init(icon: "person.2", text: "Nothing invited the room to join in. Try one clear line, such as \"Sing this with us.\"", good: false))
        } else if invitations > 0 {
            p.append(.init(icon: "checkmark.circle", text: "\(invitations) moment\(invitations == 1 ? "" : "s") invited the room to join in.", good: true))
        }
        if !quietGaps.isEmpty {
            p.append(.init(icon: "pause.circle", text: "\(quietGaps.count) quiet gap\(quietGaps.count == 1 ? "" : "s") of 8 seconds or more. A pad or a line from the leader carries people across.", good: false))
        }
        if let f = fillersPerMinute, f > 4 {
            p.append(.init(icon: "text.badge.minus", text: String(format: "%.1f filler words a minute while talking. Plan the first line of each transition.", f), good: false))
        }
        for t in talks where t.end - t.start > 180 {
            p.append(.init(icon: "timer", text: "Talking ran over 3 minutes at \(assessTime(t.start)). Check it was meant to.", good: false))
        }
        return p
    }

    /// Plain text to paste into an email or team chat.
    var summaryText: String {
        var t = "\(report.title) — \(report.date.formatted(date: .abbreviated, time: .omitted))\n\n"
        func line(_ n: String, _ v: Int?) -> String { "\(n): \(v.map(String.init) ?? "not readable")\n" }
        t += line("Sound", soundScore) + line("Engagement", engagementScore) + line("Smiles", smilesScore)
        t += line("Stage presence", stageScore) + line("Communication", communicationScore)
        t += "\nSONGS\n"
        for (i, s) in namedSongs.enumerated() { t += "\(i + 1). \(s.name): \(assessTime(s.part.start)), \(assessTime(s.part.length)) long\n" }
        let pointers = soundPointers + engagementPointers + stagePointers + communicationPointers
        t += "\nPOINTERS\n" + pointers.map { "• \($0.text)" }.joined(separator: "\n") + "\n"
        if !report.notes.isEmpty {
            t += "\nTEAM NOTES\n" + report.notes.sorted { $0.time < $1.time }.map { "\(assessTime($0.time)) [\($0.category)] \($0.text)" }.joined(separator: "\n") + "\n"
        }
        if !report.focus.isEmpty { t += "\nFOCUS FOR NEXT TIME\n\(report.focus)\n" }
        return t
    }

    /// The measurements, for the AI coach.
    var coachFacts: String {
        var t = "Worship part: \(assessTime(report.rangeEnd - report.rangeStart)) long, \(namedSongs.count) songs: \(namedSongs.map(\.name).joined(separator: ", ")).\n"
        t += "Scores out of 100 (nil = couldn't be read): sound \(soundScore.map(String.init) ?? "nil"), engagement \(engagementScore.map(String.init) ?? "nil"), smiles \(smilesScore.map(String.init) ?? "nil"), stage \(stageScore.map(String.init) ?? "nil"), communication \(communicationScore.map(String.init) ?? "nil").\n"
        t += (soundPointers + engagementPointers + stagePointers + communicationPointers).map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        if !report.notes.isEmpty { t += "Team notes:\n" + report.notes.map { "- \($0.category): \($0.text)" }.joined(separator: "\n") + "\n" }
        if !report.ratings.isEmpty { t += "Team's own ratings out of 5: \(report.ratings.map { "\($0.key) \($0.value)" }.joined(separator: ", "))\n" }
        if !talks.isEmpty { t += "What was said between songs:\n" + talks.map { "[\(assessTime($0.start))] \($0.text)" }.joined(separator: "\n") }
        return t
    }
}

private extension Array where Element == Float {
    subscript(safe i: Int) -> Float { indices.contains(i) ? self[i] : 0 }
}

// MARK: - Measuring

enum WorshipAnalysis {
    private static func fail(_ m: String) -> NSError { NSError(domain: "AutoClip", code: 80, userInfo: [NSLocalizedDescriptionKey: m]) }

    /// Runs blocking work off the shared task threads.
    private static func offThread<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                do { c.resume(returning: try work()) } catch { c.resume(throwing: error) }
            }
        }
    }

    /// OBS recordings (MKV) can't be read by the system, so they're rewrapped once with ffmpeg.
    static func playable(_ url: URL) async throws -> URL {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []
        if !tracks.isEmpty { return url }
        guard let ffmpeg = YTDLP.ffmpegPath() else { throw fail("AutoClip can't read this file type. Save it as MP4 or MOV and try again.") }
        let folder = WorshipStore.dir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", url.path, "-c", "copy", "-movflags", "+faststart", out.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        try await offThread { p.waitUntilExit() }
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: out)
            throw fail("Couldn't read this recording. Save it as MP4 or MOV and try again.")
        }
        return out
    }

    /// Only the sermon's start and end, from the sound alone (no transcript or picture).
    static func locateMessage(path: String, duration: Double, progress: @escaping (Double) -> Void) async throws -> (start: Double, end: Double)? {
        let url = URL(fileURLWithPath: path)
        var r = WorshipReport(videoPath: path, title: YTDLP.title(fromFile: url), duration: duration, rangeStart: 0, rangeEnd: duration)
        try await classify(url, duration: duration, into: &r) { progress($0 * 0.75) }
        try Task.checkCancellation()
        try await measureSound(AVURLAsset(url: url), into: &r) { progress(0.75 + $0 * 0.25) }
        return WorshipStats.message(r).map { ($0.start, $0.end) }
    }

    /// The whole job: sound, then talking, then the picture for the worship part.
    static func run(path: String, progress: @escaping (Double, String) -> Void) async throws -> WorshipReport {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 5 else { throw fail("This recording is too short to assess.") }
        var r = WorshipReport(videoPath: path, title: YTDLP.title(fromFile: url), duration: duration, rangeStart: 0, rangeEnd: duration)

        progress(0.01, "Listening for music, singing and clapping…")
        try await classify(url, duration: duration, into: &r) { progress(0.01 + $0 * 0.27, "Listening for music, singing and clapping…") }
        try Task.checkCancellation()
        progress(0.28, "Measuring the sound…")
        try await measureSound(asset, into: &r) { progress(0.28 + $0 * 0.12, "Measuring the sound…") }
        try Task.checkCancellation()
        let range = WorshipStats.suggestedRange(r)
        r.rangeStart = range.start; r.rangeEnd = range.end

        progress(0.40, "Transcribing what's said between songs…")
        let words = try await TranscriptCache.transcript(for: path) { _ in }
        r.talks = talks(in: r, words: words)
        try Task.checkCancellation()
        r.visual = try await watch(asset, from: r.rangeStart, to: r.rangeEnd) { progress(0.65 + $0 * 0.35, "Watching the stage…") }
        return r
    }

    private final class Listener: NSObject, SNResultsObserving {
        struct Window { var t: Double; var values: [String: Float] }
        var windows: [Window] = []
        var failure: Error?
        let onTime: (Double) -> Void
        init(onTime: @escaping (Double) -> Void) { self.onTime = onTime }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let c = result as? SNClassificationResult else { return }
            var v: [String: Float] = [:]
            for k in ["music", "singing", "choir_singing", "speech", "clapping", "applause", "cheering"] {
                v[k] = c.classification(forIdentifier: k).map { Float($0.confidence) } ?? 0
            }
            let t = c.timeRange.start.seconds
            windows.append(Window(t: t, values: v))
            onTime(t)
        }
        func request(_ request: SNRequest, didFailWithError error: Error) { failure = error }
    }

    private static func classify(_ url: URL, duration: Double, into r: inout WorshipReport,
                                 progress: @escaping (Double) -> Void) async throws {
        let listener = Listener { progress(min(1, $0 / duration)) }
        try await offThread {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: listener)
            analyzer.analyze()
        }
        if let f = listener.failure { throw f }
        guard !listener.windows.isEmpty else { throw fail("Couldn't find any sound in this recording.") }
        let n = Int((duration / r.bin).rounded(.up))
        var totals = Array(repeating: [String: Float](), count: n)
        var counts = Array(repeating: 0, count: n)
        var claps = Array(repeating: Float(0), count: n), cheers = Array(repeating: Float(0), count: n)
        for w in listener.windows {
            let i = min(n - 1, Int(w.t / r.bin))
            counts[i] += 1
            for (k, v) in w.values { totals[i][k, default: 0] += v }
            // Clapping under a band only ever scores low, so the bar is low too
            if (w.values["clapping"] ?? 0) > 0.25 { claps[i] += 1 }
            if max(w.values["applause"] ?? 0, w.values["cheering"] ?? 0) > 0.35 { cheers[i] += 1 }
        }
        func mean(_ k: String, _ i: Int) -> Float { counts[i] == 0 ? 0 : (totals[i][k] ?? 0) / Float(counts[i]) }
        r.music = (0..<n).map { mean("music", $0) }
        r.singing = (0..<n).map { max(mean("singing", $0), mean("choir_singing", $0)) }
        r.speech = (0..<n).map { mean("speech", $0) }
        r.clapping = (0..<n).map { counts[$0] == 0 ? 0 : claps[$0] / Float(counts[$0]) }
        r.applause = (0..<n).map { counts[$0] == 0 ? 0 : cheers[$0] / Float(counts[$0]) }
    }

    /// Loudness and tone per bin, distortion, and sustained pure tones that may be feedback.
    private static func measureSound(_ asset: AVAsset, into r: inout WorshipReport, progress: @escaping (Double) -> Void) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw fail("This recording has no sound.") }
        let bin = r.bin, duration = r.duration
        let result: (loud: [Float], low: [Float], mid: [Float], high: [Float], clipped: Double, feedback: [Double]) = try await offThread {
            let rate = 48000
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? fail("Couldn't read the sound.") }

            let log2n = vDSP_Length(13), size = 8192
            guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw fail("Couldn't measure the sound.") }
            defer { vDSP_destroy_fftsetup(setup) }
            var window = [Float](repeating: 0, count: size)
            vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
            var real = [Float](repeating: 0, count: size / 2), imag = real, power = real

            let perBin = Int(bin) * rate
            var loud: [Float] = [], low: [Float] = [], mid: [Float] = [], high: [Float] = []
            var sum = 0.0, count = 0, clipped = 0, total = 0
            var lowSum: Float = 0, midSum: Float = 0, highSum: Float = 0, spectra = 0
            var frame = [Float](), secondCount = 0
            frame.reserveCapacity(size)
            var feedback: [Double] = []
            var toneBin = -1, toneRun = 0
            let hz = Float(rate) / Float(size)

            func band(_ a: Float, _ b: Float) -> Float {
                var s: Float = 0
                vDSP_sve(Array(power[Int(a / hz)..<min(power.count, Int(b / hz))]), 1, &s, vDSP_Length(Int(b / hz) - Int(a / hz)))
                return s
            }

            while let buffer = out.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                  dataPointerOut: &pointer) == noErr, let pointer else { continue }
                let n = length / 4
                pointer.withMemoryRebound(to: Float.self, capacity: n) { samples in
                    for i in 0..<n {
                        let x = samples[i]
                        sum += Double(x * x); count += 1; total += 1
                        if abs(x) >= 0.99 { clipped += 1 }
                        if frame.count < size { frame.append(x) }
                        secondCount += 1
                        if secondCount == rate {
                            secondCount = 0
                            if frame.count == size {
                                var windowed = [Float](repeating: 0, count: size)
                                vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(size))
                                real.withUnsafeMutableBufferPointer { rp in
                                    imag.withUnsafeMutableBufferPointer { ip in
                                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                        windowed.withUnsafeBytes { raw in
                                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                                        }
                                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
                                    }
                                }
                                lowSum += band(40, 250); midSum += band(250, 4000); highSum += band(4000, 12000)
                                spectra += 1
                                // A pure tone standing far above everything else, with no harmonics, held for 2s+
                                let from = Int(1000 / hz), to = Int(6000 / hz)
                                let slice = Array(power[from..<to])
                                var peak: Float = 0
                                var at: vDSP_Length = 0
                                vDSP_maxvi(slice, 1, &peak, &at, vDSP_Length(slice.count))
                                let k = from + Int(at)
                                let median = slice.sorted()[slice.count / 2]
                                let double = k * 2 < power.count ? power[k * 2] : 0
                                let half = power[k / 2]
                                let isTone = peak > 1e-3 && peak / max(median, 1e-12) > 10_000 && double < peak * 0.01 && half < peak * 0.01
                                if isTone, abs(k - toneBin) <= 2 {
                                    toneRun += 1
                                    if toneRun == 2 {
                                        let t = Double(total) / Double(rate)
                                        if t - (feedback.last ?? -100) > 10 { feedback.append(t) }
                                    }
                                } else {
                                    toneRun = isTone ? 1 : 0
                                }
                                toneBin = isTone ? k : -1
                            }
                            frame.removeAll(keepingCapacity: true)
                        }
                        if count == perBin {
                            let db = { (v: Double) -> Float in Float(10 * log10(max(v, 1e-10))) }
                            loud.append(db(sum / Double(perBin)))
                            let s = Float(max(1, spectra))
                            low.append(db(Double(lowSum / s))); mid.append(db(Double(midSum / s))); high.append(db(Double(highSum / s)))
                            sum = 0; count = 0; lowSum = 0; midSum = 0; highSum = 0; spectra = 0
                            progress(min(1, Double(total) / Double(rate) / max(duration, 1)))
                        }
                    }
                }
            }
            if let e = reader.error { throw e }
            return (loud, low, mid, high, total == 0 ? 0 : Double(clipped) / Double(total) * 100, feedback)
        }
        r.loudness = result.loud; r.lows = result.low; r.mids = result.mid; r.highs = result.high
        r.clippedPercent = result.clipped; r.feedback = result.feedback
        // Every list covers the same bins
        let n = r.loudness.count
        r.music = Array(r.music.prefix(n)); r.singing = Array(r.singing.prefix(n)); r.speech = Array(r.speech.prefix(n))
        r.clapping = Array(r.clapping.prefix(n)); r.applause = Array(r.applause.prefix(n))
    }

    static func talks(in r: WorshipReport, words: [Word]) -> [WorshipReport.Talk] {
        let message = WorshipStats.message(r)
        let breaks: [WorshipReport.Talk] = WorshipStats.sections(r).filter { part in
            part.kind == .talk && part.length >= 5 && !(message.map { part.start >= $0.start && part.end <= $0.end } ?? false)
        }.compactMap { part in
            let w = words.filter { $0.startTime >= part.start && $0.startTime < part.end }
            guard w.count >= 4 else { return nil }
            return .init(start: part.start, end: part.end, text: spokenText(w), wordCount: w.count, fillers: FillerReport.find(in: w).count)
        }
        let over = exhortations(in: r, words: words).filter { e in
            !breaks.contains { e.start < $0.end && e.end > $0.start } && !(message.map { e.start >= $0.start && e.end <= $0.end } ?? false)
        }
        return (breaks + over).sorted { $0.start < $1.start }
    }

    private static func spokenText(_ w: [Word]) -> String {
        w.map(\.word).joined(separator: " ")
            .replacingOccurrences(of: #"[♪♫♩♬]+|>>|\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }

    /// Words the leader says over the music ("Come on, can we thank Him, church?"). The speech
    /// model marks sung lines with ♪, so lines without it are candidates. Lyrics it failed to mark
    /// repeat, and real exhortations don't, or they carry a cue or sound like speech.
    static func exhortations(in r: WorshipReport, words: [Word]) -> [WorshipReport.Talk] {
        let cues = ["come on", "let's", "lets", "can we", "church", "everybody", "sing that", "sing this", "we say", "say it", "one more time",
                    "lift your", "lift up", "clap", "good morning", "you guys", "this morning", "together", "repeat"]
        func clean(_ w: String) -> String { w.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
        let plain = words.map { clean($0.word) }
        var trigrams: [String: Int] = [:]
        if plain.count > 2 { for i in 0..<(plain.count - 2) { trigrams["\(plain[i]) \(plain[i + 1]) \(plain[i + 2])", default: 0] += 1 } }

        struct Line { var from: Int; var to: Int; var sung: Bool }
        var lines: [Line] = []
        var inside = false
        var from: Int?
        func close(_ i: Int, sung: Bool) { if let f = from, i > f { lines.append(Line(from: f, to: i - 1, sung: sung)) }; from = nil }
        for (i, w) in words.enumerated() {
            let notes = w.word.filter { "♪♫♩♬".contains($0) }.count
            let gap = i > 0 ? w.startTime - words[i - 1].endTime : 0
            if from != nil, gap > 1.5 || notes > 0 || w.word.hasPrefix(">>") { close(i, sung: inside) }
            if notes >= 2 { inside = false } else if notes == 1 { inside.toggle() }
            // A note on the last word of a line belongs to the line just closed
            let bare = clean(w.word)
            if !bare.isEmpty, from == nil { from = i }
        }
        close(words.count, sung: inside)

        var out: [WorshipReport.Talk] = []
        for l in lines {
            let slice = Array(words[l.from...l.to])
            let spoken = slice.filter { !clean($0.word).isEmpty }
            guard spoken.count >= 3 else { continue }
            let start = slice[0].startTime, end = slice[slice.count - 1].endTime
            guard start >= r.rangeStart - 5, end <= r.rangeEnd + 5 else { continue }
            let text = spokenText(slice)
            let low = " \(text.lowercased()) "
            let hasCue = cues.contains { low.contains($0) }
            if l.sung && !hasCue { continue }
            // Mostly phrases heard over and over: lyrics
            var repeated = 0
            let keys = slice.map { clean($0.word) }
            if keys.count > 2 { for i in 0..<(keys.count - 2) where (trigrams["\(keys[i]) \(keys[i + 1]) \(keys[i + 2])"] ?? 0) >= 3 { repeated += 1 } }
            if keys.count > 2, Double(repeated) / Double(keys.count - 2) > 0.4, !hasCue { continue }
            let i = Int(start / r.bin)
            let sounds = r.speech.indices.contains(i) && r.speech[i] >= 0.4
            guard hasCue || sounds else { continue }
            let talk = WorshipReport.Talk(start: start, end: max(end, start + 1), text: text, wordCount: spoken.count,
                                          fillers: FillerReport.find(in: spoken).count, overMusic: true)
            // Lines straight after each other are one thought
            if let last = out.last, start - last.end < 3 {
                out[out.count - 1].end = talk.end
                out[out.count - 1].text += " " + talk.text
                out[out.count - 1].wordCount += talk.wordCount
                out[out.count - 1].fillers += talk.fillers
            } else { out.append(talk) }
        }
        return out
    }

    /// Looks at the stage every few seconds: faces, smiles, raised hands and how bodies are moving.
    static func watch(_ asset: AVAsset, from start: Double, to end: Double, progress: @escaping (Double) -> Void) async throws -> WorshipReport.Visual? {
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let smiles = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let step = 4.0
        let total = Int((end - start) / step)
        var samples: [WorshipReport.Visual.Sample] = []
        for i in 0..<max(total, 0) {
            try Task.checkCancellation()
            let t = start + Double(i) * step
            guard let a = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            // A burst of frames: a clap shows as wrists meeting and parting
            var burst: [CGImage] = []
            for k in 1...4 {
                if let b = try? await gen.image(at: CMTime(seconds: t + Double(k) * 0.12, preferredTimescale: 600)).image { burst.append(b) }
            }
            let frames = burst
            let sample = try await offThread { look(at: a, next: frames, time: t, smiles: smiles) }
            samples.append(sample)
            if i % 5 == 0 { progress(Double(i) / Double(max(total, 1))) }
        }
        return .init(start: start, end: end, samples: samples)
    }

    private static func look(at image: CGImage, next: [CGImage], time: Double, smiles: CIDetector?) -> WorshipReport.Visual.Sample {
        let faceRequest = VNDetectFaceRectanglesRequest()
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        let poseRequest = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([faceRequest, poseRequest])
        let faces = (faceRequest.results ?? []).filter { $0.boundingBox.height >= 0.04 }
        let facing = faces.filter { abs($0.yaw?.doubleValue ?? 1) < 0.45 }.count
        // Smiles can only be read on faces close to the camera
        var smile: Bool?
        if let biggest = faces.map({ $0.boundingBox.height }).max(), biggest >= 0.06, let smiles {
            let found = smiles.features(in: CIImage(cgImage: image), options: [CIDetectorSmile: true]).compactMap { $0 as? CIFaceFeature }
            if !found.isEmpty { smile = found.contains { $0.hasSmile } }
        }
        let poses = people(poseRequest.results ?? [])
        let later: [[Person]] = next.map { frame in
            let request = VNDetectHumanBodyPoseRequest()
            try? VNImageRequestHandler(cgImage: frame, options: [:]).perform([request])
            return people(request.results ?? [])
        }
        var moves: [Double] = []
        var teamHands = 0, teamClaps = 0, room = 0, roomHands = 0, roomClaps = 0
        for p in poses {
            var gaps = [p.wristGap].compactMap { $0 }
            var previous = p
            for frame in later {
                guard let q = frame.min(by: { p.neckDistance(to: $0) < p.neckDistance(to: $1) }), p.neckDistance(to: q) < 0.08 else { continue }
                if let g = q.wristGap { gaps.append(g) }
                let d = previous.distance(to: q) / max(p.size, 0.01)
                if d < 1 { moves.append(d) }   // bigger than that is a camera cut
                previous = q
            }
            let clapping = isClapping(gaps)
            let raised = p.handsUp && !clapping
            if p.showsFace {
                if clapping { teamClaps += 1 }
                if raised { teamHands += 1 }
            } else {
                room += 1
                if clapping { roomClaps += 1 }
                if raised { roomHands += 1 }
            }
        }
        let energy = moves.isEmpty ? nil : moves.reduce(0, +) / Double(moves.count)
        return .init(t: time, people: poses.filter(\.showsFace).count, faces: faces.count, facing: facing, smile: smile,
                     handsUp: teamHands, energy: energy, clapping: teamClaps, roomPeople: room, roomHands: roomHands, roomClapping: roomClaps)
    }

    /// Wrists that meet and part within half a second. Hands held together or held up don't count.
    static func isClapping(_ gaps: [Double]) -> Bool {
        guard gaps.count >= 2, let low = gaps.min(), let high = gaps.max() else { return false }
        return low < 0.15 && high - low > 0.3
    }

    private struct Person {
        let points: [VNHumanBodyPoseObservation.JointName: CGPoint]
        let size: Double
        let handsUp: Bool
        let showsFace: Bool
        let wristGap: Double?
        func distance(to other: Person) -> Double {
            let shared = points.keys.filter { other.points[$0] != nil }
            guard !shared.isEmpty else { return .infinity }
            return shared.reduce(0.0) { s, k in
                let a = points[k]!, b = other.points[k]!
                return s + hypot(Double(a.x - b.x), Double(a.y - b.y))
            } / Double(shared.count)
        }
        func neckDistance(to other: Person) -> Double {
            guard let a = points[.neck], let b = other.points[.neck] else { return .infinity }
            return hypot(Double(a.x - b.x), Double(a.y - b.y))
        }
    }

    private static func people(_ observations: [VNHumanBodyPoseObservation]) -> [Person] {
        observations.compactMap { o in
            guard let all = try? o.recognizedPoints(.all) else { return nil }
            let good = all.filter { $0.value.confidence > 0.25 }.mapValues { $0.location }
            guard good.count >= 5, let neck = good[.neck] else { return nil }
            let hip = good[.root] ?? good[.leftHip] ?? good[.rightHip]
            var size = hip.map { hypot(Double(neck.x - $0.x), Double(neck.y - $0.y)) } ?? 0
            if let l = good[.leftShoulder], let r = good[.rightShoulder] { size = max(size, hypot(Double(l.x - r.x), Double(l.y - r.y)) * 1.5) }
            guard size > 0.02 else { return nil }
            let head = good[.nose]?.y ?? neck.y
            let wrists = [good[.leftWrist], good[.rightWrist]].compactMap { $0 }
            var gap: Double?
            if let l = good[.leftWrist], let r = good[.rightWrist] { gap = hypot(Double(l.x - r.x), Double(l.y - r.y)) / size }
            // Someone with their back to the camera shows no nose
            return Person(points: good, size: size, handsUp: wrists.contains { $0.y > head }, showsFace: good[.nose] != nil, wristGap: gap)
        }
    }
}
