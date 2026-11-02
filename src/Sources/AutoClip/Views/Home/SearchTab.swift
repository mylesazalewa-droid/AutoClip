import SwiftUI
import AVKit

/// Search everything you've preached: every transcribed video in AutoClip, by word or topic.
/// "forgive" finds forgive, forgiven, forgiveness and forgiving. Click a result to hear it.
struct SearchTab: View {
    @ObservedObject private var reelsStore = AutoReelsStore.shared
    @State private var query = ""
    @State private var library: [Talk] = []
    @State private var untranscribed: [String] = []
    @State private var loading = true
    @State private var transcribing: String?
    @State private var stopTranscribing = false
    @State private var playing: (path: String, title: String)?
    @State private var player = AVPlayer()
    @State private var includePractice = false
    @FocusState private var focused: Bool
    private let gold = Theme.sand

    struct Talk {
        let path: String
        let title: String
        let date: Date
        let sentences: [ReelDraft.Sentence]
        /// Lowercased words of each sentence, punctuation stripped
        let tokens: [[String]]
        var isPractice: Bool { PracticeRecorder.isPractice(path) }
    }

    struct Hit: Identifiable {
        let id: String
        let time: Double
        let text: String
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                searchBar
                Divider().background(Color.white.opacity(0.08))
                results
            }
            Divider().background(Color.white.opacity(0.08))
            sidePanel.frame(width: 380)
        }
        .background(Theme.bg)
        .task { await load() }
        .onDisappear { stopTranscribing = true; player.pause() }
    }

    // MARK: Search bar

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(gold)
                TextField("Search everything you've preached: forgiveness, Romans 8, \"grace upon grace\"", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(.white)
                    .focused($focused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Color.white.opacity(0.4)) }
                        .buttonStyle(.plain)
                }
            }
            .padding(10).background(Color.white.opacity(0.06)).cornerRadius(8)
            HStack(spacing: 6) {
                ForEach(["forgiveness", "grace", "fear", "prayer", "purpose", "identity"], id: \.self) { s in
                    Button(s) { query = s }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.white.opacity(0.06)).cornerRadius(10)
                }
                Spacer()
                if library.contains(where: \.isPractice) {
                    Toggle("Include practice runs", isOn: $includePractice).toggleStyle(.checkbox)
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6))
                }
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }

    // MARK: Results

    private var searched: [(talk: Talk, hits: [Hit])] {
        let terms = TranscriptSearch.terms(query)
        guard !terms.words.isEmpty || !terms.phrases.isEmpty else { return [] }
        return library
            .filter { includePractice || !$0.isPractice }
            .compactMap { talk in
                var hits: [Hit] = []
                for (i, s) in talk.sentences.enumerated() where TranscriptSearch.matches(terms, tokens: talk.tokens[i], text: s.text) {
                    hits.append(Hit(id: "\(talk.path)#\(i)", time: s.start, text: s.text))
                }
                return hits.isEmpty ? nil : (talk, hits)
            }
            .sorted { $0.talk.date > $1.talk.date }
    }

    @ViewBuilder
    private var results: some View {
        let found = searched
        let total = found.reduce(0) { $0 + $1.hits.count }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small)
                        Text("Reading your transcripts…").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)) }
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    intro
                } else if found.isEmpty {
                    Text("Nothing found for “\(query)” in \(library.count) transcribed video\(library.count == 1 ? "" : "s").")
                        .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.6))
                } else {
                    Text("\(total) mention\(total == 1 ? "" : "s") in \(found.count) message\(found.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    ForEach(found, id: \.talk.path) { group in
                        talkResults(group.talk, group.hits)
                    }
                }
            }
            .padding(16)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find any moment across all your sermons")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Text("Search \(library.count) transcribed video\(library.count == 1 ? "" : "s") for a word, a topic or a Bible passage. Useful for avoiding repeats, building a series or pulling clips. Words match their other forms, so “forgive” also finds “forgiven” and “forgiveness”. Put a phrase in quotes to match it exactly.")
                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func talkResults(_ talk: Talk, _ hits: [Hit]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if talk.isPractice { Image(systemName: "mic.fill").font(.system(size: 10)).foregroundColor(gold) }
                Text(talk.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(talk.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
                Spacer()
                Text("\(hits.count)×").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(gold)
            }
            ForEach(hits.prefix(40)) { h in
                Button { play(talk, at: h.time) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(assessTime(h.time)).font(.system(size: 11, design: .monospaced)).foregroundColor(gold)
                            .frame(width: 56, alignment: .leading)
                        Text(highlighted(h.text)).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.8))
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if hits.count > 40 {
                Text("+ \(hits.count - 40) more").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4)).padding(.leading, 6)
            }
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(10)
    }

    /// The sentence with the matched words in gold.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let terms = TranscriptSearch.terms(query)
        for phrase in terms.phrases {
            var range = out.startIndex..<out.endIndex
            while let r = out[range].range(of: phrase, options: .caseInsensitive) {
                out[r].foregroundColor = gold; out[r].font = .system(size: 12, weight: .semibold)
                range = r.upperBound..<out.endIndex
            }
        }
        // Single words: highlight each whole word whose cleaned form matches a stem
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { sub, r, _, _ in
            guard let sub, TranscriptSearch.wordMatches(terms.words, TranscriptSearch.clean(sub)),
                  let range = Range(r, in: text),
                  let lo = AttributedString.Index(range.lowerBound, within: out),
                  let hi = AttributedString.Index(range.upperBound, within: out) else { return }
            out[lo..<hi].foregroundColor = gold
            out[lo..<hi].font = .system(size: 12, weight: .semibold)
        }
        return out
    }

    // MARK: Side panel: player + library

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = playing {
                VideoPlayer(player: player).frame(height: 214).cornerRadius(8)
                Text(p.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle").font(.system(size: 28)).foregroundColor(gold.opacity(0.7))
                        Text("Click a result to hear it").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                    }
                }
                .frame(height: 214)
            }
            Divider().background(Color.white.opacity(0.08))
            Text("LIBRARY").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
            Text("\(library.count) video\(library.count == 1 ? "" : "s") searchable")
                .font(.system(size: 12)).foregroundColor(.white)
            if !untranscribed.isEmpty {
                Text("\(untranscribed.count) more \(untranscribed.count == 1 ? "isn't" : "aren't") transcribed yet, so \(untranscribed.count == 1 ? "it isn't" : "they aren't") searched.")
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                if let transcribing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small)
                        Text(transcribing).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6)).lineLimit(2) }
                    Button("Stop after this one") { stopTranscribing = true }.controlSize(.small)
                } else {
                    Button { transcribeRest() } label: { Label("Transcribe them", systemImage: "text.bubble") }
                        .controlSize(.small)
                        .help("Runs on your Mac, one video at a time (a few minutes each)")
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.surface)
    }

    private func play(_ talk: Talk, at t: Double) {
        if playing?.path != talk.path {
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: talk.path)))
            playing = (talk.path, talk.title)
        }
        player.seek(to: CMTime(seconds: max(0, t - 1), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: Loading

    private func load() async {
        loading = true
        let paths = AssessTab.knownVideos(reels: reelsStore.reels)
        let loaded = await Task.detached(priority: .userInitiated) { () -> ([Talk], [String]) in
            var talks: [Talk] = [], missing: [String] = []
            for p in paths {
                if let t = Self.talk(p) { talks.append(t) } else { missing.append(p) }
            }
            return (talks, missing)
        }.value
        library = loaded.0; untranscribed = loaded.1
        loading = false
    }

    private nonisolated static func talk(_ path: String) -> Talk? {
        guard let words = TranscriptCache.load(for: path) else { return nil }
        let sentences = ReelDraft.sentences(from: words)
        let date = SpeakerReportStore.load(for: path)?.videoDate
            ?? ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? Date()
        return Talk(path: path, title: YTDLP.title(fromFile: URL(fileURLWithPath: path)), date: date,
                    sentences: sentences,
                    tokens: sentences.map { $0.text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "—" }).map { TranscriptSearch.clean(String($0)) } })
    }

    private func transcribeRest() {
        stopTranscribing = false
        Task {
            for path in untranscribed {
                if stopTranscribing { break }
                let title = YTDLP.title(fromFile: URL(fileURLWithPath: path))
                transcribing = "Transcribing “\(title)”…"
                _ = try? await TranscriptCache.transcript(for: path) { msg in
                    Task { @MainActor in transcribing = "\(msg.replacingOccurrences(of: "…", with: "")) “\(title)”…" }
                }
                if let t = await Task.detached(operation: { Self.talk(path) }).value {
                    library.append(t)
                    untranscribed.removeAll { $0 == path }
                }
            }
            transcribing = nil
        }
    }
}
