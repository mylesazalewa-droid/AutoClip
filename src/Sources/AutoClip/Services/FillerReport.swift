import Foundation

/// Finds filler words across a whole talk for the speaking report.
/// "like", "so" and "well" are only counted when used as fillers, not as real words
/// ("I like it", "so much", "as well").
enum FillerReport {
    struct Hit: Identifiable, Equatable {
        let id = UUID()
        let kind: String        // one of `kinds`
        let time: Double        // seconds into the video
        let context: String     // a few words around it
    }

    static let kinds = ["like", "um", "uh", "ah", "well", "so", "you see", "i mean"]

    private static let spellings: [String: String] = [
        "um": "um", "umm": "um", "uhm": "um", "mm": "um", "hmm": "um", "mhm": "um",
        "uh": "uh", "uhh": "uh", "er": "uh", "erm": "uh",
        "ah": "ah", "ahh": "ah"
    ]
    /// "like" after these is a verb or comparison, not a filler ("I like", "would like", "looks like")
    private static let likeAsWord: Set<String> = [
        "i", "you", "we", "they", "he", "she", "would", "don't", "didn't", "doesn't", "do", "does", "did",
        "to", "really", "look", "looks", "looked", "feel", "feels", "felt", "seem", "seems", "sound",
        "sounds", "something", "nothing", "anything", "more", "much", "be", "just", "kind", "sort", "people"]

    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// True when the word before ends a sentence or clause (or there is none).
    private static func startsClause(_ words: [Word], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        guard let last = words[i - 1].word.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".,!?;:—-".contains(last) || words[i].startTime - words[i - 1].endTime > 0.7
    }

    static func find(in words: [Word]) -> [Hit] {
        var hits: [Hit] = []
        func context(_ i: Int, _ len: Int) -> String {
            words[max(0, i - 4)..<min(words.count, i + len + 4)].map(\.word).joined(separator: " ")
        }
        var i = 0
        while i < words.count {
            let w = clean(words[i].word)
            let next = i + 1 < words.count ? clean(words[i + 1].word) : ""
            var kind: String? = nil
            var len = 1
            if let k = spellings[w] {
                kind = k
            } else if w == "you" && next == "see" {
                kind = "you see"; len = 2
            } else if w == "i" && next == "mean" {
                kind = "i mean"; len = 2
            } else if w == "like" {
                let prev = i > 0 ? clean(words[i - 1].word) : ""
                // Filler "like": between commas / pauses, or not following a verb-ish word
                let rawPrev = i > 0 ? words[i - 1].word : ""
                let commaAround = rawPrev.hasSuffix(",") || words[i].word.hasSuffix(",")
                let clauseStart = startsClause(words, i)
                if commaAround || clauseStart || !likeAsWord.contains(prev) { kind = "like" }
                // "Like I said…" means "as I said"
                let after2 = i + 2 < words.count ? clean(words[i + 2].word) : ""
                if ["i", "we", "you", "he", "she"].contains(next) && ["said", "say", "mentioned", "told"].contains(after2) {
                    kind = nil
                }
                // "like a …" / "like that" comparisons are real words unless set off by commas
                if !commaAround, ["a", "an", "the", "that", "this", "it", "him", "her", "them", "me", "us"].contains(next) {
                    kind = nil
                }
            } else if w == "so" || w == "well" {
                // Only at the start of a clause: "So, here's the thing" / "Well, …" — not "so much", "as well"
                let prev = i > 0 ? clean(words[i - 1].word) : ""
                if startsClause(words, i) && prev != "as" && !["much", "many", "good", "that", "far"].contains(next) {
                    kind = w
                }
            }
            if let kind {
                hits.append(Hit(kind: kind, time: words[i].startTime, context: context(i, len)))
            }
            i += len
        }
        return hits
    }
}
