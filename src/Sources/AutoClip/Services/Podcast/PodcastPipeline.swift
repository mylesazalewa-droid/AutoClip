import AVFoundation
import AppKit

/// The steps of making an episode: read it, plan the edit and the camera, write show notes, export.
extension PodcastStore {

    /// Starts a new episode from one or more recordings: camera angles sharing one sound, or
    /// (`oneFilePerPerson`) each person's own recording from Zoom, Riverside or separate mics.
    func create(title: String, paths: [String], oneFilePerPerson: Bool = false) -> String {
        var e = PodcastEpisode(title: title, angles: paths.map { .init(path: $0) })
        if oneFilePerPerson && paths.count > 1 { e.oneFilePerPerson = true }
        save(e)
        analyze(e.id)
        return e.id
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        status[id] = nil
        progress[id] = nil
    }

    private func run(_ id: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard tasks[id] == nil else { return }
        errors[id] = nil
        tasks[id] = Task { @MainActor in
            do { try await work() } catch is CancellationError {
            } catch { self.errors[id] = error.localizedDescription }
            self.status[id] = nil
            self.progress[id] = nil
            self.tasks[id] = nil
        }
    }

    private func say(_ id: String, _ msg: String, _ p: Double? = nil) {
        status[id] = msg
        progress[id] = p
    }

    // MARK: Reading the recording

    func analyze(_ id: String) {
        run(id) { [self] in
            guard var e = episode(id), let master = e.angles.first else { return }
            say(id, "Reading the recording…")
            for i in e.angles.indices {
                let asset = AVURLAsset(url: URL(fileURLWithPath: e.angles[i].path))
                e.angles[i].duration = CMTimeGetSeconds(try await asset.load(.duration))
                e.angles[i].hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
            }
            let remote = e.separateTracks
            e.isAudioOnly = remote ? !e.angles.contains { $0.hasVideo == true } : e.angles[0].hasVideo != true
            var trackEnergy: [[Float]] = []
            if e.angles.count > 1 {
                for i in 1..<e.angles.count {
                    say(id, remote ? "Lining up \(i + 1) recordings…" : "Lining up camera \(i + 1) with camera 1 by their sound…")
                    // Separate mics mostly hear different voices; they usually start together
                    e.angles[i].offset = try await PodcastAnalysis.offset(of: e.angles[i].path, against: master.path,
                                                                          minScore: remote ? 0.35 : nil) ?? 0
                }
            }
            e.duration = remote ? e.angles.map { $0.offset + $0.duration }.max() ?? 0 : e.angles[0].duration
            save(e)

            if remote {
                for (k, a) in e.angles.enumerated() {
                    let label = "Listening to recording \(k + 1) of \(e.angles.count)…"
                    say(id, label, 0)
                    trackEnergy.append(try await PodcastVoice.trackEnergy(a.path, offset: a.offset, duration: a.duration) { p in
                        Task { @MainActor in self.say(id, label, p) }
                    })
                }
                say(id, "Mixing everyone's recordings…", 0)
                try FileManager.default.createDirectory(at: e.folder, withIntermediateDirectories: true)
                try await PodcastVoice.mix(paths: e.angles.map(\.path), offsets: e.angles.map(\.offset), energy: trackEnergy,
                                           duration: e.duration, to: URL(fileURLWithPath: e.soundPath)) { p in
                    Task { @MainActor in self.say(id, "Mixing everyone's recordings…", p) }
                }
            }

            forgetWords(e)
            let words = try await TranscriptCache.transcript(for: e.soundPath) { msg in
                Task { @MainActor in self.say(id, msg) }
            }
            say(id, "Listening for “um”s and telling voices apart…", 0)
            let features = try await PodcastVoice.features(e.soundPath, mfcc: true, voicingIn: PodcastVoice.gaps(words),
                                                           duration: e.duration) { p in
                Task { @MainActor in self.say(id, "Listening for “um”s and telling voices apart…", p) }
            }
            e.heardFillers = PodcastVoice.fillers(words: words, features: features).map { [$0.lowerBound, $0.upperBound] }
            let voices = PodcastVoice.segments(words: words, features: features)
            if let data = try? JSONEncoder().encode(voices) { try? data.write(to: e.folder.appendingPathComponent("voices.json")) }
            e.cuts = PodcastAnalysis.cuts(words: e.withHeardFillers(words), duration: e.duration, settings: e.settings, previous: e.cuts)
            save(e)

            let old = e.people
            if remote {
                try await findPeopleByTrack(&e, words: words, energy: trackEnergy)
            } else if e.isAudioOnly {
                peopleByVoice(&e, words: words, voices: voices)
            } else {
                try await findPeople(&e, words: words, voices: voices)
            }
            // Keep names given before
            for i in e.people.indices where old.indices.contains(i) { e.people[i].name = old[i].name }
            if !e.isAudioOnly {
                e.shots = PodcastAnalysis.planShots(e, words: words)
                for p in e.people where p.w > 0 {
                    if let img = await PodcastVideo.faceThumbnail(e, p) {
                        thumbnails["\(id)-\(p.id)"] = img
                        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: e.folder.appendingPathComponent("person-\(p.id).png"))
                        }
                    }
                }
            }
            e.analyzed = true
            save(e)
        }
    }

    /// One file per person: each recording is one person, and whoever is loudest on their own
    /// microphone is talking. Their face (if the file has video) is found for framing.
    private func findPeopleByTrack(_ e: inout PodcastEpisode, words: [Word], energy: [[Float]]) async throws {
        let id = e.id
        var people: [PodcastEpisode.Person] = []
        for (k, a) in e.angles.enumerated() {
            var box = [0.0, 0, 0, 0]
            if a.hasVideo == true {
                let label = "Finding \(k == 0 ? "the first" : "the next") face…"
                say(id, label, 0)
                let track = try await PodcastAnalysis.faces(path: a.path, cache: e.folder.appendingPathComponent("faces-\(k).json")) { p in
                    Task { @MainActor in self.say(id, label, p) }
                }
                if let main = PodcastAnalysis.people(in: track, keepAll: true).max(by: { $0.seen < $1.seen }) { box = PodcastAnalysis.medianBox(main.boxes) }
            }
            people.append(.init(id: k, name: "Person \(k + 1)", angle: k, x: box[0], y: box[1], w: box[2], h: box[3]))
        }
        e.people = people
        let act = PodcastVoice.trackActivity(energy)
        let activity = act.enumerated().map { (person: $0.offset, angleOffset: 0.0, step: 0.4, values: $0.element) }
        e.turns = PodcastAnalysis.turns(activity: activity, duration: e.duration, speech: Self.speechSpans(words))
    }

    /// Audio only: the people are the voices.
    private func peopleByVoice(_ e: inout PodcastEpisode, words: [Word], voices: [PodcastVoice.Segment]) {
        var labels = PodcastVoice.cluster(voices, k: e.speakerCount)
        // Number the voices in the order they first speak
        var order: [Int: Int] = [:]
        for l in labels where order[l] == nil { order[l] = order.count }
        labels = labels.map { order[$0]! }
        let n = order.count
        guard n > 1 else { e.people = []; e.turns = []; return }
        e.people = (0..<n).map { .init(id: $0, name: "Person \($0 + 1)", angle: 0, x: 0, y: 0, w: 0, h: 0) }
        let series = PodcastVoice.series(voices, labels: labels, people: n, duration: e.duration)
        e.turns = PodcastAnalysis.turns(activity: [], duration: e.duration, speech: Self.speechSpans(words),
                                        voice: Dictionary(uniqueKeysWithValues: series.enumerated().map { ($0.offset, $0.element) }))
    }

    /// Audio only: tell this many voices apart (nil = work it out), keeping the names given.
    func setSpeakerCount(_ id: String, _ n: Int?) {
        guard var e = episode(id), let words = TranscriptCache.load(for: e.soundPath),
              let data = try? Data(contentsOf: e.folder.appendingPathComponent("voices.json")),
              let voices = try? JSONDecoder().decode([PodcastVoice.Segment].self, from: data) else { return }
        e.speakerCount = n
        let old = e.people
        peopleByVoice(&e, words: words, voices: voices)
        for i in e.people.indices where old.indices.contains(i) { e.people[i].name = old[i].name }
        save(e)
    }

    private func findPeople(_ e: inout PodcastEpisode, words: [Word], voices: [PodcastVoice.Segment]) async throws {
        let id = e.id
        var tracks: [Int: PodcastAnalysis.FaceTrack] = [:]
        for (k, a) in e.angles.enumerated() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: a.path))
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { continue }
            let label = e.angles.count > 1 ? "Finding faces in camera \(k + 1)…" : "Finding faces and who is talking…"
            say(id, label, 0)
            tracks[k] = try await PodcastAnalysis.faces(path: a.path, cache: e.folder.appendingPathComponent("faces-\(k).json")) { p in
                Task { @MainActor in self.say(id, label, p) }
            }
        }
        say(id, "Working out who is talking…")
        let clusters = tracks.mapValues { PodcastAnalysis.people(in: $0) }
        let wide = clusters.max { $0.value.count < $1.value.count }?.key ?? 0
        var people: [PodcastEpisode.Person] = []
        var activity: [(person: Int, angleOffset: Double, step: Double, values: [Double])] = []
        let step = PodcastAnalysis.faceStep
        for c in clusters[wide] ?? [] {
            let b = PodcastAnalysis.medianBox(c.boxes)
            let pid = people.count
            people.append(.init(id: pid, name: "Person \(pid + 1)", angle: wide, x: b[0], y: b[1], w: b[2], h: b[3]))
            activity.append((pid, e.angles[wide].offset, step, PodcastAnalysis.activity(c.mouth)))
        }
        let wideActs = activity
        for (k, cs) in clusters where k != wide {
            var taken = Set<Int>()
            for c in cs {
                let act = PodcastAnalysis.activity(c.mouth)
                let b = PodcastAnalysis.medianBox(c.boxes)
                // Same person seen by the wide camera? Their mouths move together.
                let shift = Int(((e.angles[k].offset - e.angles[wide].offset) / step).rounded())
                let best = wideActs.map { w -> (Int, Double) in
                    let aligned = w.values.indices.compactMap { i -> (Double, Double)? in
                        let j = i - shift
                        return act.indices.contains(j) ? (w.values[i], act[j]) : nil
                    }
                    return (w.person, PodcastAnalysis.correlation(aligned.map(\.0), aligned.map(\.1)))
                }.filter { !taken.contains($0.0) }.max { $0.1 < $1.1 }
                if let best, best.1 > 0.25, let i = people.firstIndex(where: { $0.id == best.0 }) {
                    people[i].otherAngles[k] = b
                    taken.insert(best.0)
                    activity.append((best.0, e.angles[k].offset, step, act))
                } else {
                    let pid = people.count
                    people.append(.init(id: pid, name: "Person \(pid + 1)", angle: k, x: b[0], y: b[1], w: b[2], h: b[3]))
                    activity.append((pid, e.angles[k].offset, step, act))
                }
            }
        }
        e.people = people
        let voice = people.count > 1 ? voiceForFaces(voices, people: people.map(\.id), activity: activity, duration: e.duration) : [:]
        e.turns = PodcastAnalysis.turns(activity: activity, duration: e.duration, speech: Self.speechSpans(words), voice: voice)
    }

    /// Speech spans from the transcript (words with gaps under 0.6s joined)
    static func speechSpans(_ words: [Word]) -> [ClosedRange<Double>] {
        var speech: [ClosedRange<Double>] = []
        for w in words.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = speech.last, w.startTime - last.upperBound < 0.6 { speech[speech.count - 1] = last.lowerBound...max(last.upperBound, w.endTime) }
            else { speech.append(w.startTime...max(w.startTime, w.endTime)) }
        }
        return speech
    }

    /// Groups the voices into as many as there are faces and matches each voice to the face whose
    /// mouth moves most while it speaks. Used only when the match is clear, so it can carry the
    /// moments a face is turned away or hidden.
    private func voiceForFaces(_ segs: [PodcastVoice.Segment], people: [Int],
                               activity: [(person: Int, angleOffset: Double, step: Double, values: [Double])],
                               duration: Double) -> [Int: [Double]] {
        guard segs.count >= 20 else { return [:] }
        let labels = PodcastVoice.cluster(segs, k: people.count)
        func face(_ p: Int, _ t: Double) -> Double {
            activity.filter { $0.person == p }.map { a -> Double in
                let i = Int(((t - a.angleOffset) / a.step).rounded())
                return a.values.indices.contains(i) ? a.values[i] : 0
            }.max() ?? 0
        }
        // How much each face moves while each voice talks
        var table: [[Double]] = Array(repeating: Array(repeating: 0, count: people.count), count: people.count)
        var counts = [Int](repeating: 0, count: people.count)
        for (seg, l) in zip(segs, labels) where l < people.count {
            counts[l] += 1
            for (j, p) in people.enumerated() {
                var sum = 0.0, n = 0.0
                var t = seg.start
                while t < seg.end { sum += face(p, t); n += 1; t += 0.4 }
                table[l][j] += n > 0 ? sum / n : 0
            }
        }
        var pairs: [(c: Int, p: Int, v: Double)] = []
        for c in 0..<people.count where counts[c] > 0 {
            for j in 0..<people.count { pairs.append((c, j, table[c][j] / Double(counts[c]))) }
        }
        var voiceOf: [Int: Int] = [:], usedP = Set<Int>()
        for pr in pairs.sorted(by: { $0.v > $1.v }) where voiceOf[pr.c] == nil && !usedP.contains(pr.p) {
            voiceOf[pr.c] = pr.p; usedP.insert(pr.p)
        }
        // Each voice's face must move clearly more than the others while it speaks
        for (c, j) in voiceOf {
            let mine = table[c][j] / Double(max(1, counts[c]))
            let others = (0..<people.count).filter { $0 != j }.map { table[c][$0] / Double(max(1, counts[c])) }.max() ?? 0
            if mine < others * 1.2 + 0.02 { return [:] }
        }
        let series = PodcastVoice.series(segs, labels: labels, people: people.count, duration: duration)
        var out: [Int: [Double]] = [:]
        for (c, j) in voiceOf { out[people[j]] = series[c] }
        return out
    }


    func thumbnail(_ e: PodcastEpisode, _ p: PodcastEpisode.Person) -> NSImage? {
        let key = "\(e.id)-\(p.id)"
        if let img = thumbnails[key] { return img }
        if let img = NSImage(contentsOf: e.folder.appendingPathComponent("person-\(p.id).png")) {
            DispatchQueue.main.async { self.thumbnails[key] = img }
            return img
        }
        return nil
    }

    // MARK: Edit and camera plan

    /// Rebuilds the pause and filler cuts after the edit settings change.
    func refreshCuts(_ id: String) {
        guard var e = episode(id), let words = TranscriptCache.load(for: e.soundPath) else { return }
        e.cuts = PodcastAnalysis.cuts(words: e.withHeardFillers(words), duration: e.duration, settings: e.settings, previous: e.cuts)
        save(e)
    }

    /// Re-plans the camera. Shots chosen by hand stay unless `resetManual`.
    func replanShots(_ id: String, resetManual: Bool = false) {
        guard var e = episode(id) else { return }
        let words = TranscriptCache.load(for: e.soundPath) ?? []
        let manual = resetManual ? [] : e.shots.filter(\.manual)
        var shots = PodcastAnalysis.planShots(e, words: words)
        for m in manual { shots = override(shots, with: m) }
        e.shots = shots
        save(e)
    }

    /// Replaces whatever covers `m`'s time with `m`.
    func override(_ shots: [PodcastEpisode.Shot], with m: PodcastEpisode.Shot) -> [PodcastEpisode.Shot] {
        var out: [PodcastEpisode.Shot] = []
        for s in shots {
            if s.end <= m.start || s.start >= m.end { out.append(s); continue }
            if s.start < m.start { var a = s; a.end = m.start; out.append(a) }
            if s.end > m.end { var b = s; b.start = m.end; b.id = UUID().uuidString; out.append(b) }
        }
        out.append(m)
        return out.sorted { $0.start < $1.start }
    }

    /// Changes the framing of one shot.
    func setShot(_ id: String, shotID: String, angle: Int, person: Int?, zoom: Double) {
        update(id) { e in
            guard let i = e.shots.firstIndex(where: { $0.id == shotID }) else { return }
            e.shots[i].angle = angle; e.shots[i].person = person; e.shots[i].zoom = zoom; e.shots[i].manual = true
        }
    }

    // MARK: Show notes

    func writeNotes(_ id: String) {
        run(id) { [self] in
            guard let e = episode(id), let words = TranscriptCache.load(for: e.soundPath) else { return }
            say(id, "Writing show notes and chapters…")
            let provider = LLMClipService.AIProvider(rawValue: UserDefaults.standard.string(forKey: "ar_provider") ?? "") ?? .google
            guard let key = await LLMClipService.shared.loadAPIKey(for: provider), !key.isEmpty else {
                throw PodcastAudio.Failure(message: "Add an API key in AutoClip → Settings → AI to write show notes.")
            }
            let paras = PodcastExports.paragraphs(e, words: words)
            let notes = try await CostTag.$video.withValue(e.title) {
                try await LLMClipService.shared.podcastNotes(title: e.title, paragraphs: paras,
                                                             people: e.people.map(\.name), provider: provider, apiKey: key)
            }
            update(id) { $0.notes = notes }
        }
    }

    // MARK: Export

    static var exportRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/AutoClip Podcasts")
    }

    func exportFolder(_ e: PodcastEpisode) -> URL {
        let name = e.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return Self.exportRoot.appendingPathComponent(name.isEmpty ? "Episode" : name)
    }

    func export(_ id: String) {
        run(id) { [self] in
            guard let e = episode(id) else { return }
            let folder = exportFolder(e)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = folder.appendingPathComponent(folder.lastPathComponent).path
            let program = try await PodcastAudio.program(e) { msg, p in
                Task { @MainActor in self.say(id, msg, p) }
            }
            var done: [String: String] = [:]
            let words = TranscriptCache.load(for: e.soundPath) ?? []

            if !e.isAudioOnly {
                for f in PodcastVideo.formats where e.settings.formats.contains(f) {
                    let out = URL(fileURLWithPath: base + " (\(f.replacingOccurrences(of: ":", with: "x"))).mp4")
                    let label = "Exporting \(PodcastVideo.formatNames[f] ?? f) video…"
                    say(id, label, 0)
                    try await PodcastVideo.export(e, format: f, program: program, to: out) { p in
                        Task { @MainActor in self.say(id, label, p) }
                    }
                    done[f] = out.path
                }
            }
            if e.settings.exportAudio || e.isAudioOnly {
                say(id, "Saving the podcast audio…")
                let fmt = e.settings.audioFormat
                var out = URL(fileURLWithPath: base + "." + fmt)
                let chapters = (e.notes?.chapters ?? []).map { (start: $0.time <= 1 ? 0 : program.lead + e.editedTime($0.time), title: $0.title) }
                try await PodcastAudio.encode(program.url, to: out, format: fmt, title: e.title, artist: nil,
                                              chapters: chapters, total: program.total, cover: e.settings.coverPath.map { URL(fileURLWithPath: $0) })
                if !FileManager.default.fileExists(atPath: out.path) { out = out.deletingPathExtension().appendingPathExtension("m4a") }
                done["audio"] = out.path
            }
            say(id, "Saving the transcript and show notes…")
            let transcript = URL(fileURLWithPath: base + " – Transcript.txt")
            try PodcastExports.transcript(e, words: words, lead: program.lead).write(to: transcript, atomically: true, encoding: .utf8)
            done["transcript"] = transcript.path
            let srt = URL(fileURLWithPath: base + " – Captions.srt")
            try PodcastExports.srt(e, words: words, lead: program.lead).write(to: srt, atomically: true, encoding: .utf8)
            done["srt"] = srt.path
            if let n = e.notes {
                let md = URL(fileURLWithPath: base + " – Show notes.txt")
                try PodcastExports.showNotes(e, n, lead: program.lead).write(to: md, atomically: true, encoding: .utf8)
                done["notes"] = md.path
            }
            update(id) { $0.exports = done }
            NSWorkspace.shared.activateFileViewerSelecting(done.values.map { URL(fileURLWithPath: $0) })
        }
    }
}

/// Text files that go with an episode: transcript, captions and show notes.
enum PodcastExports {
    static func stamp(_ t: Double) -> String {
        let i = Int(max(0, t))
        return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }

    /// Words that survive the edit, with who said them.
    static func keptWords(_ e: PodcastEpisode, _ words: [Word]) -> [(word: Word, out: Double, speaker: String?)] {
        let cuts = e.enabledCuts
        var ci = 0
        return words.sorted { $0.startTime < $1.startTime }.compactMap { w in
            let mid = (w.startTime + w.endTime) / 2
            while ci < cuts.count && cuts[ci].end < mid { ci += 1 }
            if ci < cuts.count && cuts[ci].start <= mid && mid <= cuts[ci].end { return nil }
            let name = e.people.count > 1 ? e.person(e.speaker(at: mid))?.name : nil
            return (w, e.editedTime(w.startTime), name)
        }
    }

    /// The transcript in ~30-second paragraphs on the source clock (for the AI), with speakers.
    static func paragraphs(_ e: PodcastEpisode, words: [Word]) -> [(start: Double, speaker: String?, text: String)] {
        var out: [(Double, String?, String)] = []
        var start: Double?, who: String?, buf: [String] = []
        for (w, _, sp) in keptWords(e, words) {
            if start != nil, sp != who || (w.startTime - start! > 30 && buf.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") } == true) {
                out.append((start!, who, buf.joined(separator: " "))); start = nil; buf = []
            }
            if start == nil { start = w.startTime; who = sp }
            buf.append(w.word.trimmingCharacters(in: .whitespaces))
        }
        if let start, !buf.isEmpty { out.append((start, who, buf.joined(separator: " "))) }
        return out
    }

    static func transcript(_ e: PodcastEpisode, words: [Word], lead: Double) -> String {
        var t = "\(e.title)\n\n"
        for p in paragraphs(e, words: words) {
            let at = stamp(lead + e.editedTime(p.start))
            t += p.speaker.map { "[\(at)] \($0): " } ?? "[\(at)] "
            t += p.text + "\n\n"
        }
        return t
    }

    /// Captions: up to 7 words or 3.5 seconds per line.
    static func srt(_ e: PodcastEpisode, words: [Word], lead: Double) -> String {
        func ts(_ s: Double) -> String {
            let ms = Int((max(0, s) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        let kept = keptWords(e, words)
        var out = "", n = 1, i = 0
        while i < kept.count {
            var j = i
            let s = kept[i].out
            while j < kept.count && j - i < 7 && kept[j].out - s < 3.5 {
                j += 1
                if kept[j - 1].word.word.hasSuffix(".") || kept[j - 1].word.word.hasSuffix("?") { break }
            }
            let line = kept[i..<j].map { $0.word.word.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let end = e.editedTime(kept[j - 1].word.endTime)
            out += "\(n)\n\(ts(lead + s)) --> \(ts(lead + max(end, s + 0.5)))\n\(line)\n\n"
            n += 1; i = j
        }
        return out
    }

    static func showNotes(_ e: PodcastEpisode, _ n: PodcastNotes, lead: Double) -> String {
        var t = "\(n.titles.first ?? e.title)\n\n\(n.description)\n"
        if !n.chapters.isEmpty {
            t += "\nChapters\n"
            for c in n.chapters { t += "\(stamp(c.time <= 1 ? 0 : lead + e.editedTime(c.time))) \(c.title)\n" }
        }
        if !n.guests.isEmpty { t += "\nIn this episode: \(n.guests.joined(separator: ", "))\n" }
        if !n.quotes.isEmpty { t += "\nQuotes\n" + n.quotes.map { "“\($0)”" }.joined(separator: "\n") + "\n" }
        if !n.keywords.isEmpty { t += "\nKeywords: \(n.keywords.joined(separator: ", "))\n" }
        if n.titles.count > 1 { t += "\nOther title ideas\n" + n.titles.dropFirst().map { "• \($0)" }.joined(separator: "\n") + "\n" }
        if !n.socialPost.isEmpty { t += "\nSocial post\n\(n.socialPost)\n" }
        return t
    }
}

/// Hands a video to the Auto Reels tab (from the Podcast tab's "Make clips").
@MainActor
final class AutoReelsHandoff: ObservableObject {
    static let shared = AutoReelsHandoff()
    @Published var pending: URL?
    @Published var showTab = false
}
