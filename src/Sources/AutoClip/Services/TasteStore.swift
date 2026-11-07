import Foundation

/// Learns what the user likes from what they do with reels: the ones they export are good,
/// the ones they throw out with "Not for me" aren't, and edits show whether the AI tends to
/// end too early or run too long. The summary goes into every reel prompt.
@MainActor
final class TasteStore: ObservableObject {
    static let shared = TasteStore()

    struct Example: Codable, Equatable {
        var title: String
        var opening: String
        var duration: Double
        var kind: String
        var date: Double
    }

    struct Taste: Codable, Equatable {
        var kept: [Example] = []
        var rejected: [Example] = []
        /// Edits: sentences added after / before the AI's pick, and sentences switched off
        var addedAfter = 0
        var addedBefore = 0
        var removed = 0
    }

    @Published private(set) var taste: Taste

    private static let key = "taste_profile"
    private static let keep = 30

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let t = try? JSONDecoder().decode(Taste.self, from: d) {
            taste = t
        } else { taste = Taste() }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(taste) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    private static func example(_ d: ReelDraft, kind: ContentKind) -> Example {
        let words = d.pieces.flatMap { $0.sentences.flatMap(\.keptWords) }.prefix(22).map(\.word)
        return Example(title: d.title, opening: words.joined(separator: " "), duration: d.duration,
                       kind: kind.rawValue, date: Date().timeIntervalSince1970)
    }

    /// The user exported this reel, so it's the kind they want.
    /// The sample sermon says nothing about what this person likes.
    private func isSample(_ d: ReelDraft) -> Bool {
        d.pieces.first.map { SampleSermon.isSample(path: $0.sourceVideoPath) } ?? false
    }

    func liked(_ d: ReelDraft, kind: ContentKind) {
        guard !isSample(d) else { return }
        taste.kept.removeAll { $0.title == d.title }
        taste.kept.append(Self.example(d, kind: kind))
        taste.kept = Array(taste.kept.suffix(Self.keep))
        save()
    }

    /// The user threw this reel out.
    func rejected(_ d: ReelDraft, kind: ContentKind) {
        guard !isSample(d) else { return }
        taste.kept.removeAll { $0.title == d.title }
        taste.rejected.append(Self.example(d, kind: kind))
        taste.rejected = Array(taste.rejected.suffix(Self.keep))
        save()
    }

    /// Undo of `liked` / `rejected` (quick review's Z).
    func unliked(_ d: ReelDraft) { taste.kept.removeAll { $0.title == d.title }; save() }
    func unrejected(_ d: ReelDraft) {
        if let i = taste.rejected.lastIndex(where: { $0.title == d.title }) { taste.rejected.remove(at: i); save() }
    }

    func addedSentence(before: Bool) {
        if before { taste.addedBefore += 1 } else { taste.addedAfter += 1 }
        save()
    }

    func removedSentence() { taste.removed += 1; save() }

    func reset() { taste = Taste(); save() }

    var signalCount: Int { taste.kept.count + taste.rejected.count + taste.addedAfter + taste.addedBefore + taste.removed }

    /// Plain-language lines about what's been learned, for the app and for prompts.
    func lessons(for kind: ContentKind) -> [String] {
        let kept = taste.kept.filter { $0.kind == kind.rawValue }
        var out: [String] = []
        if kept.count >= 3 {
            let ds = kept.map(\.duration).sorted()
            let mid = ds[ds.count / 2]
            out.append("Clips they keep usually run about \(Int(mid.rounded()))s (\(Int(ds.first!.rounded()))–\(Int(ds.last!.rounded()))s).")
        }
        let edits = taste.addedAfter + taste.addedBefore + taste.removed
        if edits >= 3 {
            if taste.addedAfter >= max(2, taste.removed) {
                out.append("They often add the sentence after the ending you picked — let the speaker finish; end a sentence or two later.")
            }
            if taste.addedBefore >= 2 && taste.addedBefore >= taste.removed {
                out.append("They often add the sentence before a clip — include a little more setup so it makes sense on its own.")
            }
            if taste.removed > taste.addedAfter + taste.addedBefore {
                out.append("They often cut sentences out — keep clips tight and skip side comments.")
            }
        }
        return out
    }

    /// The block added to reel prompts. Empty until there's something to go on.
    func promptBlock(for kind: ContentKind) -> String {
        let kept = taste.kept.filter { $0.kind == kind.rawValue }.suffix(6)
        let rejected = taste.rejected.filter { $0.kind == kind.rawValue }.suffix(6)
        let lessons = lessons(for: kind)
        guard !kept.isEmpty || !rejected.isEmpty || !lessons.isEmpty else { return "" }
        var s = "\nWHAT THIS CREATOR LIKES (learned from clips they exported or threw out — follow it):\n"
        for l in lessons { s += "- \(l)\n" }
        if !kept.isEmpty {
            s += "Clips they kept:\n" + kept.map { "- \"\($0.title)\" (\(Int($0.duration))s) — opens: \"\($0.opening)…\"" }.joined(separator: "\n") + "\n"
        }
        if !rejected.isEmpty {
            s += "Clips they threw out (avoid this kind of pick):\n" + rejected.map { "- \"\($0.title)\" — opens: \"\($0.opening)…\"" }.joined(separator: "\n") + "\n"
        }
        return s
    }

    /// Thread-safe read for prompt building off the main actor.
    nonisolated static func promptBlock(for kind: ContentKind) async -> String {
        await MainActor.run { TasteStore.shared.promptBlock(for: kind) }
    }
}
