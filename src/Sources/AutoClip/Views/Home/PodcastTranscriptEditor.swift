import SwiftUI
import AppKit

private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

/// Edit the episode by editing its transcript: select words and delete them, and the video and
/// sound are cut to match. Words already cut are struck out; click one to put it back.
struct PodcastTranscriptEditor: View {
    let id: String
    let seek: (Double) -> Void
    @ObservedObject private var store = PodcastStore.shared
    @State private var anchor: Int?
    @State private var selection: ClosedRange<Int>?
    @State private var shown = 40
    @FocusState private var focused: Bool

    struct Paragraph: Identifiable { var id: Int { range.lowerBound }; var range: Range<Int>; var speaker: Int?; var start: Double }

    var body: some View {
        if let e = store.episode(id) {
            let words = store.words(e)
            let paras = paragraphs(e, words)
            let cutBy = cutIndex(e, words)
            AssessCard(title: "Edit by text", subtitle: "Click a word, shift-click another to select everything between, then press Delete. Struck-out words are cut — click one to put it back.") {
                HStack(spacing: 8) {
                    if let sel = selection {
                        Text("\(sel.count) word\(sel.count == 1 ? "" : "s") selected").font(.system(size: 11, weight: .medium)).foregroundColor(gold)
                        Button { cutSelection() } label: { Label("Cut", systemImage: "scissors") }
                        Button { seek(e.editedTime(words[sel.lowerBound].startTime) - 0.5) } label: { Label("Play", systemImage: "play.fill") }
                        Button("Clear") { selection = nil; anchor = nil }
                    } else {
                        Text("\(cutBy.count) of \(words.count) words cut").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                    }
                    Spacer()
                    let manual = e.cuts.filter { $0.kind == .manual }
                    if !manual.isEmpty {
                        Button("Put back all \(manual.count) text cut\(manual.count == 1 ? "" : "s")") {
                            store.update(id) { $0.cuts.removeAll { $0.kind == .manual } }
                        }
                    }
                }
                .controlSize(.small)
                .frame(minHeight: 22)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(paras.prefix(shown)) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if let sp = p.speaker, let person = e.person(sp) {
                                    Circle().fill(PodcastStore.palette[person.id % PodcastStore.palette.count]).frame(width: 7, height: 7)
                                    Text(person.name).font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.7))
                                }
                                Button(podcastTime(e.editedTime(p.start))) { seek(e.editedTime(p.start)) }
                                    .buttonStyle(.borderless).font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.4))
                            }
                            PodcastFlow(spacing: 0, lineSpacing: 3) {
                                ForEach(Array(p.range), id: \.self) { i in word(words[i], i, cutBy: cutBy) }
                            }
                        }
                    }
                }
                if paras.count > shown {
                    Button("Show more (\(paras.count - shown) paragraphs left)") { shown += 60 }.controlSize(.small)
                }
                if words.isEmpty { Text("The transcript isn't ready yet.").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.5)) }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard selection != nil else { return .ignored }
                cutSelection()
                return .handled
            }
        }
    }

    private func word(_ w: Word, _ i: Int, cutBy: [Int: String]) -> some View {
        let cut = cutBy[i] != nil
        let selected = selection?.contains(i) ?? false
        return Text(w.word.trimmingCharacters(in: .whitespaces) + " ")
            .font(.system(size: 13))
            .strikethrough(cut, color: Color.red.opacity(0.8))
            .foregroundColor(selected ? .black : cut ? Color.white.opacity(0.3) : Color.white.opacity(0.9))
            .padding(.vertical, 1)
            .background(selected ? gold : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { tap(i, cutID: cutBy[i]) }
            .help(cut ? "Cut — click to put back" : podcastTime(w.startTime))
    }

    // MARK: Actions

    private func tap(_ i: Int, cutID: String?) {
        focused = true
        if let cutID {
            // Put it back: text cuts are removed; automatic ones are kept in the list, unticked
            store.update(id) { e in
                guard let k = e.cuts.firstIndex(where: { $0.id == cutID }) else { return }
                if e.cuts[k].kind == .manual { e.cuts.remove(at: k) } else { e.cuts[k].enabled = false }
            }
            selection = nil; anchor = nil
            return
        }
        if NSEvent.modifierFlags.contains(.shift), let a = anchor {
            selection = min(a, i)...max(a, i)
        } else {
            anchor = i
            selection = i...i
        }
    }

    private func cutSelection() {
        guard let sel = selection, let e = store.episode(id) else { return }
        let words = store.words(e)
        guard sel.upperBound < words.count else { selection = nil; return }
        let first = words[sel.lowerBound], last = words[sel.upperBound]
        let prevEnd = sel.lowerBound > 0 ? words[sel.lowerBound - 1].endTime : 0
        // From just before the first word to just before the next one (so the pause before stays)
        let start = max(prevEnd + 0.02, first.startTime - 0.04)
        let end = sel.upperBound + 1 < words.count ? max(last.endTime, words[sel.upperBound + 1].startTime - 0.04) : min(e.duration, last.endTime + 0.3)
        let text = words[sel].map { $0.word.trimmingCharacters(in: .whitespaces) }
        let label = text.count <= 6 ? text.joined(separator: " ") : text.prefix(3).joined(separator: " ") + " … " + text.suffix(2).joined(separator: " ")
        store.update(id) { e in
            e.cuts.append(.init(start: start, end: end, kind: .manual, label: "“\(label)”"))
            e.cuts.sort { $0.start < $1.start }
        }
        selection = nil; anchor = nil
    }

    // MARK: Words and paragraphs

    /// Word index → the id of the cut that removes it.
    private func cutIndex(_ e: PodcastEpisode, _ words: [Word]) -> [Int: String] {
        let cuts = e.enabledCuts
        var out: [Int: String] = [:], ci = 0
        for (i, w) in words.enumerated() {
            let mid = (w.startTime + w.endTime) / 2
            while ci < cuts.count && cuts[ci].end < mid { ci += 1 }
            // Cuts can overlap (a text cut over a pause), so look a little further
            var k = ci
            while k < cuts.count && cuts[k].start <= mid {
                if mid <= cuts[k].end { out[i] = cuts[k].id; break }
                k += 1
            }
        }
        return out
    }

    /// New paragraph at a change of speaker, a long pause, or after ~70 words at a sentence end.
    private func paragraphs(_ e: PodcastEpisode, _ words: [Word]) -> [Paragraph] {
        var out: [Paragraph] = []
        var start = 0
        var who: Int? = words.first.map { e.speaker(at: $0.startTime) } ?? nil
        for i in words.indices.dropFirst() {
            let w = words[i], prev = words[i - 1]
            let sp = e.people.count > 1 ? e.speaker(at: (w.startTime + w.endTime) / 2) : nil
            let sentenceEnd = prev.word.hasSuffix(".") || prev.word.hasSuffix("?") || prev.word.hasSuffix("!")
            if sp != who || w.startTime - prev.endTime > 2.5 || (i - start > 70 && sentenceEnd) {
                out.append(.init(range: start..<i, speaker: e.people.count > 1 ? who : nil, start: words[start].startTime))
                start = i; who = sp
            }
        }
        if start < words.count { out.append(.init(range: start..<words.count, speaker: e.people.count > 1 ? who : nil, start: words[start].startTime)) }
        return out
    }
}

/// Lays words out left to right, wrapping like text.
struct PodcastFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, p) in r.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            lineH = max(lineH, s.height)
            maxW = max(maxW, x)
        }
        return (points, CGSize(width: min(maxW, width), height: y + lineH))
    }
}

/// Audio-only episodes: the voices AutoClip told apart, to name them, and how many there are.
struct PodcastSpeakersCard: View {
    let id: String
    @ObservedObject private var store = PodcastStore.shared

    var body: some View {
        if let e = store.episode(id) {
            AssessCard(title: "Speakers", subtitle: e.separateTracks ? "One for each recording. Names go in the transcript and show notes."
                       : "Told apart by the sound of their voices. Names go in the transcript and show notes.") {
                if !e.separateTracks {
                    Picker("How many people talk", selection: Binding(get: { e.speakerCount ?? 0 }, set: { store.setSpeakerCount(id, $0 == 0 ? nil : $0) })) {
                        Text("Work it out").tag(0)
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .fixedSize()
                }
                if e.people.isEmpty && !e.separateTracks {
                    Text(e.speakerCount == 1 ? "One voice." : "Only one voice was found. If more people talk, choose how many above.")
                        .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
                }
                ForEach(e.people) { p in
                    HStack(spacing: 10) {
                        Circle().fill(PodcastStore.palette[p.id % PodcastStore.palette.count]).frame(width: 12, height: 12)
                        TextField("Name", text: Binding(get: { p.name }, set: { n in
                            store.update(id) { e in if let i = e.people.firstIndex(where: { $0.id == p.id }) { e.people[i].name = n } }
                        })).textFieldStyle(.roundedBorder).frame(width: 200)
                        let talk = e.turns.filter { $0.person == p.id }.reduce(0) { $0 + $1.end - $1.start }
                        Text("talks \(Int(talk / max(1, e.duration) * 100))% of the time").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                        if let first = e.turns.first(where: { $0.person == p.id }) {
                            Text("first at \(podcastTime(e.editedTime(first.start)))").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.4))
                        }
                    }
                }
            }
        }
    }
}
