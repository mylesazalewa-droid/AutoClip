import SwiftUI
import AppKit

struct Quote: Identifiable {
    let id = UUID()
    let text: String
    let startTime: Double
    let score: Int
    let type: QuoteType

    enum QuoteType: String {
        case insight = "💡 Insight"
        case challenge = "🔥 Challenge"
        case story = "📖 Story"
        case question = "❓ Question"
        case truth = "⚡ Truth"
    }
}

struct QuotesPanel: View {
    // Project-level: pass all clips, seekAction receives absolute video time
    let clips: [Clip]
    var seekAction: ((Double) -> Void)?

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    var quotes: [Quote] { extractQuotes(from: clips) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if quotes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 32))
                        .foregroundColor(Color.white.opacity(0.15))
                    Text("No quotes found")
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.35))
                    Text("Add a transcript to generate quotes")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.2))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(quotes.count) high-impact quotes")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.4))
                        Spacer()
                        Text("Tap to seek")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.25))
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                    ForEach(quotes) { quote in
                        QuoteCard(quote: quote, seekAction: seekAction)
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Quote Extraction

    private func extractQuotes(from clips: [Clip]) -> [Quote] {
        // Gather all words across every clip, sorted by start time in the original video
        let allWords = clips
            .flatMap { $0.words }
            .filter { !$0.word.hasPrefix("<|") && !$0.word.hasSuffix("|>") }
            .sorted { $0.startTime < $1.startTime }

        guard allWords.count > 20 else { return [] }

        // Build sentences across the whole transcript
        var sentences: [(text: String, startTime: Double, words: [Word])] = []
        var currentWords: [Word] = []

        for word in allWords {
            currentWords.append(word)
            let w = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let endsStatement = w.hasSuffix(".") || w.hasSuffix("!") || w.hasSuffix("?")
            if endsStatement {
                if currentWords.count >= 10 {
                    let text = currentWords.map(\.word).joined(separator: " ")
                    // startTime is absolute video time so seeking works from project level
                    sentences.append((text: text, startTime: currentWords.first!.startTime, words: currentWords))
                }
                currentWords = []
            }
        }
        if currentWords.count >= 12 {
            let text = currentWords.map(\.word).joined(separator: " ")
            sentences.append((text: text, startTime: currentWords.first!.startTime, words: currentWords))
        }

        let totalDuration = allWords.last.map { $0.endTime } ?? 1

        // Score each sentence for standalone quotability
        typealias Scored = (sentence: (text: String, startTime: Double, words: [Word]), score: Int, type: Quote.QuoteType)
        var scored: [Scored] = []

        for sentence in sentences {
            let lower = sentence.text.lowercased()
            var score = 0
            var type: Quote.QuoteType = .insight
            let wordCount = sentence.words.count

            // Strong declarative sentences (10–22 words are ideal tweet/caption length)
            if wordCount >= 10 && wordCount <= 22 { score += 30 }
            else if wordCount >= 23 && wordCount <= 35 { score += 15 }
            else if wordCount > 35 { score -= 10 } // too long to be quotable

            // Ends with strong punctuation
            if sentence.text.hasSuffix("?") { score += 30; type = .question }
            if sentence.text.hasSuffix("!") { score += 20 }

            // Must feel like a complete thought — penalize if starts with a conjunction
            let firstWord = lower.components(separatedBy: " ").first ?? ""
            if ["and", "but", "so", "or", "yet", "nor", "because", "that", "then", "also"].contains(firstWord) {
                score -= 25 // fragments that start mid-thought
            }

            // First-person statements of belief/experience read well as quotes
            let firstPersonBeliefs = ["i believe", "i know", "i've learned", "i realized", "i think", "i feel", "i've seen", "i found", "i discovered", "i used to", "i can tell"]
            if firstPersonBeliefs.contains(where: { lower.contains($0) }) { score += 18; type = .story }

            // Challenge / call-to-action
            let challengePhrases = ["you need to", "you have to", "stop letting", "never let", "you must", "don't wait", "start now", "decide to", "make the choice", "you can't", "you don't have to"]
            if challengePhrases.contains(where: { lower.contains($0) }) { score += 22; type = .challenge }

            // Insight / revelation
            let insightPhrases = ["the truth is", "what most people", "here's the thing", "the reason", "here's why", "the secret", "the key is", "what i've learned", "what nobody tells", "nobody talks about"]
            if insightPhrases.contains(where: { lower.contains($0) }) { score += 25; type = .insight }

            // Truth / declaration
            let truthPhrases = ["that's why", "the problem is", "the issue is", "what matters", "the fact is", "this is why", "this is what", "what changes everything", "it all comes down"]
            if truthPhrases.contains(where: { lower.contains($0) }) { score += 20; type = .truth }

            // Story opening
            let storyPhrases = ["one day", "i remember when", "there was a moment", "it was a", "years ago", "when i was", "at that point"]
            if storyPhrases.contains(where: { lower.contains($0) }) { score += 12; type = .story }

            // Emotional depth — multiple power words = better quote
            let powerWords = ["love", "fear", "pain", "freedom", "purpose", "broken", "healing", "transform", "believe", "hope", "shame", "guilt", "worth", "value", "identity", "faith", "burden", "hurt", "anger", "joy", "peace", "trust", "courage", "sacrifice", "legacy", "meaning", "truth", "real", "honest"]
            let powerCount = powerWords.filter { lower.contains($0) }.count
            score += powerCount * 10

            // Prefer sentences from across the whole video, not just the start
            let relPos = sentence.startTime / max(totalDuration, 1)
            if relPos > 0.1 && relPos < 0.9 { score += 5 } // avoid very first/last lines

            // Penalise filler-heavy sentences hard
            let fillers = [" um ", " uh ", "you know what i mean", "kind of", "sort of", "i guess", "i mean", "like i said", "right?", "you know?"]
            let fillerCount = fillers.filter { lower.contains($0) }.count
            score -= fillerCount * 15

            // High score threshold — only keep genuinely strong sentences
            if score >= 30 {
                scored.append((sentence: sentence, score: score, type: type))
            }
        }

        // Sort by score descending
        var sorted = scored.sorted { $0.score > $1.score }

        // Temporal deduplication — enforce at least 20-second gap between selected quotes
        var selected: [Scored] = []
        for candidate in sorted {
            let tooClose = selected.contains(where: { abs($0.sentence.startTime - candidate.sentence.startTime) < 20 })
            if !tooClose {
                selected.append(candidate)
                if selected.count == 10 { break }
            }
        }

        // Return in chronological order
        return selected.sorted { $0.sentence.startTime < $1.sentence.startTime }.map { item in
            Quote(
                text: item.sentence.text.trimmingCharacters(in: .whitespaces),
                startTime: max(0, item.sentence.startTime),
                score: min(100, item.score),
                type: item.type
            )
        }
    }
}

struct QuoteCard: View {
    let quote: Quote
    var seekAction: ((Double) -> Void)?
    @State private var copied = false
    @State private var isHovered = false

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(quote.type.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(gold.opacity(0.8))

                Spacer()

                // Seek button
                if let seek = seekAction {
                    Button(action: { seek(quote.startTime) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.forward.circle")
                                .font(.system(size: 11))
                            Text(formatTime(quote.startTime))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Color.white.opacity(0.4))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(quote.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                // Copy button
                Button(action: copyQuote) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copied!" : "Copy")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(copied ? Color(red: 0.2, green: 0.8, blue: 0.4) : Color.white.opacity(0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(12)
        .background(Color.white.opacity(isHovered ? 0.07 : 0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }

    private func copyQuote() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func formatTime(_ t: Double) -> String {
        let secs = Int(t)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
