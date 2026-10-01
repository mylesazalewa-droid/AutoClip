import Foundation
import Security

actor LLMClipService {
    static let shared = LLMClipService()

    private let keychainService = "com.autoclip.anthropic-key"

    // MARK: - Keychain

    func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func loadAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecReturnData:  kCFBooleanTrue!,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Transcript formatting

    // Groups words into sentences and emits "[SS.s] sentence." lines
    private func formatTranscript(_ words: [Word]) -> String {
        var lines: [String] = []
        var buf = ""
        var lineStart: Double = 0

        for w in words {
            if buf.isEmpty { lineStart = w.startTime }
            buf += w.word + " "
            if w.word.last.map({ ".!?".contains($0) }) ?? false {
                lines.append("[\(String(format: "%.1f", lineStart))s] \(buf.trimmingCharacters(in: .whitespaces))")
                buf = ""
            }
        }
        if !buf.isEmpty {
            lines.append("[\(String(format: "%.1f", lineStart))s] \(buf.trimmingCharacters(in: .whitespaces))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Result type

    struct ClipSuggestion {
        let start: Double
        let end: Double
        let hook: String
        let reason: String
    }

    // MARK: - API call

    func selectClips(from words: [Word], apiKey: String,
                     targetDuration: Double) async throws -> [ClipSuggestion] {
        let transcript = formatTranscript(words)
        let totalSec = words.last?.endTime ?? 0
        let totalMin = max(1, Int(totalSec) / 60)
        // Aim for roughly 1 clip per 4–5 minutes of source; cap at 20
        let targetCount = max(3, min(20, totalMin / 4))

        let prompt = """
You are a viral short-form content editor specialising in sermons, podcasts, and long-form video.

Analyze the transcript below and choose the \(targetCount) best moments for social media clips.

RULES:
• Every clip must start AND end at a complete sentence boundary — never cut mid-sentence
• Each clip should be self-contained (makes sense with no surrounding context)
• Duration per clip: 15–60 seconds; aim for 20–45 s each
• Total combined duration must not exceed \(Int(targetDuration)) seconds
• Rank by virality: emotional resonance, quotable insight, surprising revelation, strong hook, clear call-to-action
• Skip repetitive content or sections that reference visual aids the viewer cannot see

Transcript (format: [SS.s] sentence):
\(transcript)

Respond with ONLY valid JSON — no markdown fences, no explanation, nothing else:
[{"start":12.5,"end":47.0,"hook":"Opening line of the clip","reason":"Why this moment works"}]
"""

        var body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]

        // If the transcript is very long (> ~100k chars) trim to first 120k
        // to stay within safe token limits while covering most content
        if prompt.count > 120_000 {
            let truncated = String(prompt.prefix(120_000)) + "\n...[transcript truncated]"
            body["messages"] = [["role": "user", "content": truncated]]
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json",    forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,                forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",          forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "LLM", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            // Surface a human-readable error (e.g. invalid key, quota exceeded)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let detail = err["message"] as? String {
                throw NSError(domain: "LLM", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: detail])
            }
            throw NSError(domain: "LLM", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(msg.prefix(300))])
        }

        // Decode Anthropic envelope
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else {
            throw NSError(domain: "LLM", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected API response shape"])
        }

        // Extract the JSON array from the text
        guard let start = text.firstIndex(of: "["),
              let end   = text.lastIndex(of: "]") else {
            throw NSError(domain: "LLM", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AI returned no parseable JSON.\n\nResponse: \(text.prefix(300))"])
        }
        let jsonSlice = String(text[start...end])

        guard let arr = try JSONSerialization.jsonObject(with: Data(jsonSlice.utf8)) as? [[String: Any]] else {
            throw NSError(domain: "LLM", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not parse AI clip array"])
        }

        return arr.compactMap { d -> ClipSuggestion? in
            guard let s = d["start"] as? Double,
                  let e = d["end"]   as? Double,
                  e > s else { return nil }
            return ClipSuggestion(
                start:  s,
                end:    e,
                hook:   d["hook"]   as? String ?? "",
                reason: d["reason"] as? String ?? ""
            )
        }
    }

    // MARK: - Convert suggestions → Clip objects

    func clipsFromSuggestions(_ suggestions: [ClipSuggestion],
                              allWords: [Word]) -> [Clip] {
        suggestions.enumerated().compactMap { idx, sug -> Clip? in
            let inRange = allWords.filter {
                $0.startTime >= sug.start - 0.5 && $0.endTime <= sug.end + 0.5
            }
            guard !inRange.isEmpty else { return nil }
            // Score: first suggestion gets highest score (hook), rest descend
            let score = max(10, 100 - Double(idx) * 6)
            let title = inRange.prefix(8).map { $0.word }.joined(separator: " ")
            return Clip(
                id: UUID(), title: title,
                startTime: max(0, (inRange.first?.startTime ?? sug.start) - 0.1),
                endTime:   (inRange.last?.endTime ?? sug.end) + 0.15,
                score: score, scoreReason: sug.reason,
                words: inRange, isLiked: false, starRating: 0,
                captionStyleName: "Karaoke", aspectRatio: "9:16",
                notes: sug.hook, thumbnailData: nil
            )
        }
    }
}
