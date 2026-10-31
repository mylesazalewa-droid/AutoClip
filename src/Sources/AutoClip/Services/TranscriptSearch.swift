import Foundation

/// Word and phrase matching for the Search tab. Quoted phrases match exactly; other words
/// match any form ("forgive" finds forgiven, forgiveness, forgiving).
enum TranscriptSearch {
    struct Terms { var words: [String]; var phrases: [String] }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "about", "every", "time", "times", "i",
        "talked", "talk", "said", "say", "when", "where", "what", "is", "was", "it", "my", "me", "we", "you", "that"]

    /// Quoted phrases match exactly; other words match by stem.
    static func terms(_ q: String) -> Terms {
        var phrases: [String] = []
        var rest = q
        while let a = rest.firstIndex(of: "\""), let b = rest[rest.index(after: a)...].firstIndex(of: "\"") {
            let p = rest[rest.index(after: a)..<b].trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { phrases.append(p) }
            rest.removeSubrange(a...b)
        }
        let raw = rest.split(whereSeparator: { $0 == " " || $0 == "," }).map { clean(String($0)) }.filter { !$0.isEmpty }
        // "Romans 8" style searches: keep the number next to the book as a phrase
        if raw.count >= 2, raw.contains(where: { $0.allSatisfy(\.isNumber) }) {
            return Terms(words: [], phrases: phrases + [raw.joined(separator: " ")])
        }
        let words = raw.filter { !stopWords.contains($0) || raw.count == 1 }.map(stem)
        return Terms(words: words, phrases: phrases)
    }

    static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
            .replacingOccurrences(of: "’", with: "'")
    }

    /// A rough English stem: forgiveness/forgiven/forgiving → forgiv, prayers → pray.
    static func stem(_ w: String) -> String {
        guard w.count > 4 else { return w }
        var out = w
        for suffix in ["fulness", "fully", "ness", "ings", "ing", "edly", "ful", "ers", "ies", "ied", "ous", "ity", "ed", "en", "es", "ly", "er", "s"] {
            if out.hasSuffix(suffix), out.count - suffix.count >= 4 { out = String(out.dropLast(suffix.count)); break }
        }
        if out.hasSuffix("e"), out.count > 4 { out.removeLast() }
        return out
    }

    static func wordMatches(_ stems: [String], _ token: String) -> Bool {
        stems.contains { s in
            s.count >= 4 ? token.hasPrefix(s) || stem(token) == s
                         : token == s || token == s + "s" || token == s + "'s"
        }
    }

    /// A sentence matches when it has every word (any form) and every quoted phrase.
    static func matches(_ t: Terms, tokens: [String], text: String) -> Bool {
        for w in t.words where !tokens.contains(where: { wordMatches([w], $0) }) { return false }
        for p in t.phrases {
            let flat = tokens.joined(separator: " ")
            if !flat.contains(clean(p)) && text.range(of: p, options: .caseInsensitive) == nil { return false }
        }
        return true
    }
}
