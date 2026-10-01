import Foundation
import AVFoundation
import AppKit

// Analyzes transcript and video to generate scored clips
class AIService {
    static let shared = AIService()
    private init() {}

    // Filler words to detect
    private let fillerWords = Set(["um", "uh", "like", "you know", "sort of", "kind of", "basically", "literally", "actually", "so", "well", "right", "okay"])

    // Strong opener phrases
    private let strongOpeners = ["the reason", "here's why", "most people", "nobody talks about", "i learned", "the truth", "what if", "stop", "you need to", "this is why", "the problem", "the biggest"]

    func generateClips(from words: [Word], videoDuration: TimeInterval, videoURL: URL, progress: @escaping (Double, String) -> Void) async -> [Clip] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let segments = self.segmentIntoClips(words: words, videoDuration: videoDuration)
                var clips: [Clip] = []

                for (i, seg) in segments.enumerated() {
                    DispatchQueue.main.async {
                        progress(Double(i) / Double(segments.count) * 0.8, "Analyzing clip \(i + 1) of \(segments.count)...")
                    }

                    var clip = self.scoreSegment(seg, videoURL: videoURL, index: i)
                    clip.title = self.generateTitle(fromWords: seg.words)
                    clips.append(clip)
                }

                // Sort by score
                clips.sort { $0.score > $1.score }

                DispatchQueue.main.async {
                    progress(1.0, "Done")
                    continuation.resume(returning: clips)
                }
            }
        }
    }

    private func segmentIntoClips(words: [Word], videoDuration: TimeInterval) -> [(startTime: Double, endTime: Double, words: [Word])] {
        guard !words.isEmpty else { return [] }

        var segments: [(startTime: Double, endTime: Double, words: [Word])] = []
        var currentStart = words[0].startTime
        var currentWords: [Word] = []
        var sentenceWords: [Word] = []

        for word in words {
            sentenceWords.append(word)
            currentWords.append(word)

            let elapsed = word.endTime - currentStart
            let text = word.word

            let isSentenceEnd = text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!")
            let isLongEnough = elapsed >= 20
            let isTooLong = elapsed >= 65

            if (isSentenceEnd && isLongEnough) || isTooLong {
                // Check for natural break (pause)
                let nextWordIdx = words.firstIndex(where: { $0.id == word.id }).map { $0 + 1 }
                let pause = nextWordIdx.flatMap { $0 < words.count ? words[$0].startTime - word.endTime : nil } ?? 0

                if isTooLong || (isSentenceEnd && (isLongEnough || pause > 0.5)) {
                    let endTime = min(word.endTime + 0.3, videoDuration)
                    if endTime - currentStart >= 15 {
                        segments.append((currentStart, endTime, currentWords))
                    }
                    currentStart = words[nextWordIdx ?? 0].startTime
                    currentWords = []
                    sentenceWords = []
                }
            }
        }

        // Add remaining words if they form a reasonable clip
        if !currentWords.isEmpty {
            let endTime = min(currentWords.last!.endTime + 0.3, videoDuration)
            if endTime - currentStart >= 10 {
                segments.append((currentStart, endTime, currentWords))
            }
        }

        // Limit to reasonable number
        return Array(segments.prefix(50))
    }

    private func scoreSegment(_ segment: (startTime: Double, endTime: Double, words: [Word]), videoURL: URL, index: Int) -> Clip {
        let words = segment.words
        let text = words.map(\.word).joined(separator: " ").lowercased()
        let duration = segment.endTime - segment.startTime

        var score = 50.0
        var reasons: [String] = []

        // Opening strength
        let firstFive = words.prefix(5).map { $0.word.lowercased() }.joined(separator: " ")
        if strongOpeners.contains(where: { firstFive.contains($0) }) {
            score += 20
            reasons.append("strong opener")
        }

        // Emotional words
        let emotionalWords = ["love", "hate", "fear", "anger", "joy", "amazing", "terrible", "never", "always", "change", "believe", "truth", "secret", "fail", "success", "money", "god", "life", "death"]
        let emotionCount = emotionalWords.filter { text.contains($0) }.count
        score += min(Double(emotionCount) * 3, 15)

        // Question hooks drive engagement
        if text.contains("?") { score += 5; reasons.append("drives comments") }

        // Good duration (30-60s is optimal)
        if duration >= 25 && duration <= 60 { score += 10 }
        else if duration > 60 { score -= 5 }

        // Filler word penalty
        let fillerCount = fillerWords.filter { text.contains($0) }.count
        score -= min(Double(fillerCount) * 2, 10)

        // Social angle detection
        let socialPhrases = ["you", "we", "everyone", "people", "nobody", "somebody"]
        if socialPhrases.filter({ text.contains($0) }).count >= 2 {
            score += 8
            reasons.append("social angle")
        }

        // Viral potential
        let viralPhrases = ["viral", "trending", "share", "subscribe", "comment", "like if", "tag someone"]
        if viralPhrases.contains(where: { text.contains($0) }) {
            score += 5
            reasons.append("viral potential")
        }

        score = max(1, min(100, score))

        // Generate title from first few meaningful words
        let titleWords = words.prefix(8).map(\.word).joined(separator: " ")
        let title = generateTitle(from: titleWords, fullText: text)

        // Generate thumbnail
        let thumbnailData = generateThumbnailData(from: videoURL, at: segment.startTime + (duration * 0.1))

        let scoreReason = reasons.isEmpty ? "highlight moment" : reasons.joined(separator: " · ")

        return Clip(
            id: UUID(),
            title: title,
            startTime: segment.startTime,
            endTime: segment.endTime,
            score: score,
            scoreReason: scoreReason,
            words: segment.words,
            isLiked: false,
            starRating: 0,
            captionStyleName: "Karaoke",
            aspectRatio: "9:16",
            notes: "",
            thumbnailData: thumbnailData
        )
    }

    // Derive a clean, readable title from the clip's actual words
    func generateTitle(fromWords words: [Word]) -> String {
        let rawWords = words
            .filter { !$0.word.hasPrefix("<|") && !$0.word.hasSuffix("|>") }
            .map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !rawWords.isEmpty else { return "Untitled Clip" }

        // Build full text and split into sentences
        let fullText = rawWords.joined(separator: " ")
        let sentences = fullText.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Find the first sentence with 5–18 content words
        let contentFillers = Set(["um", "uh", "like", "you know", "so", "well", "right", "okay", "gonna", "gotta", "wanna", "kinda", "sorta"])
        for sentence in sentences {
            let parts = sentence.split(separator: " ").map(String.init)
            let contentWords = parts.filter { w in
                let lower = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
                return !contentFillers.contains(lower) && lower.count > 1
            }
            if contentWords.count >= 4 && contentWords.count <= 20 {
                var title = parts.prefix(12).joined(separator: " ")
                title = title.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
                if title.last == "," { title = String(title.dropLast()) }
                return capitalize(title)
            }
        }

        // Fallback: first 8 non-filler words
        let clean = rawWords.filter { w in
            let lower = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !contentFillers.contains(lower) && lower.count > 1
        }.prefix(8).joined(separator: " ")
        return clean.isEmpty ? "Clip" : capitalize(clean)
    }

    private func capitalize(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func generateTitle(from opening: String, fullText: String) -> String {
        // Legacy — not used for new clips; kept for safety
        return capitalize(opening.split(separator: " ").prefix(7).joined(separator: " "))
    }

    private func generateThumbnailData(from url: URL, at time: TimeInterval) -> String? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let t = CMTime(seconds: time, preferredTimescale: 600)
        guard let cgImage = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiff),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return nil }
        return pngData.base64EncodedString()
    }

    func detectFillerWords(in words: [Word]) -> [String] {
        var found: [String] = []
        for word in words {
            let lower = word.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if fillerWords.contains(lower) {
                found.append(word.word)
            }
        }
        return Array(Set(found))
    }
}
