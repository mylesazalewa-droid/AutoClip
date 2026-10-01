import Foundation
import Security

actor LLMClipService {
    static let shared = LLMClipService()

    // MARK: - Provider

    enum AIProvider: String, CaseIterable, Identifiable {
        case anthropic = "Claude (Anthropic)"
        case openai    = "GPT-4o (OpenAI)"
        case google    = "Gemini (Google)"

        var id: String { rawValue }

        var keychainService: String {
            switch self {
            case .anthropic: return "com.autoclip.key.anthropic"
            case .openai:    return "com.autoclip.key.openai"
            case .google:    return "com.autoclip.key.google"
            }
        }

        var modelLabel: String {
            switch self {
            case .anthropic: return "claude-haiku-4-5"
            case .openai:    return "gpt-4o-mini"
            case .google:    return "gemini-1.5-flash"
            }
        }

        var keyPlaceholder: String {
            switch self {
            case .anthropic: return "sk-ant-..."
            case .openai:    return "sk-..."
            case .google:    return "AIza..."
            }
        }
    }

    // MARK: - Keychain

    func saveAPIKey(_ key: String, for provider: AIProvider) {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: provider.keychainService as CFString
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func loadAPIKey(for provider: AIProvider) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: provider.keychainService as CFString,
            kSecReturnData:  kCFBooleanTrue!,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Transcript formatting

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

    // MARK: - Shared prompt builder

    private func buildPrompt(transcript: String, targetCount: Int, targetDuration: Double) -> String {
        """
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
    }

    // MARK: - API call

    func selectClips(from words: [Word], provider: AIProvider, apiKey: String,
                     targetDuration: Double) async throws -> [ClipSuggestion] {
        let transcript = formatTranscript(words)
        let totalMin = max(1, Int((words.last?.endTime ?? 0)) / 60)
        let targetCount = max(3, min(20, totalMin / 4))
        let prompt = buildPrompt(transcript: transcript, targetCount: targetCount, targetDuration: targetDuration)

        let text: String
        switch provider {
        case .anthropic: text = try await callAnthropic(prompt: prompt, apiKey: apiKey)
        case .openai:    text = try await callOpenAI(prompt: prompt, apiKey: apiKey)
        case .google:    text = try await callGoogle(prompt: prompt, apiKey: apiKey)
        }

        return try parseClipJSON(from: text)
    }

    // MARK: - Anthropic

    private func callAnthropic(prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else {
            throw llmError("Unexpected Anthropic response")
        }
        return text
    }

    // MARK: - OpenAI

    private func callOpenAI(prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            throw llmError("Unexpected OpenAI response")
        }
        return text
    }

    // MARK: - Google Gemini

    private func callGoogle(prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]]
        ]
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw llmError("Unexpected Gemini response")
        }
        return text
    }

    // MARK: - Helpers

    private func checkHTTP(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw llmError("No HTTP response") }
        guard http.statusCode == 200 else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = (json["error"] as? [String: Any])?["message"] as? String
                    ?? (json["error"] as? String)
                    ?? String(data: data, encoding: .utf8)?.prefix(300).description
                    ?? "HTTP \(http.statusCode)"
                throw llmError(msg)
            }
            throw llmError("HTTP \(http.statusCode)")
        }
    }

    private func llmError(_ msg: String) -> NSError {
        NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func parseClipJSON(from text: String) throws -> [ClipSuggestion] {
        guard let start = text.firstIndex(of: "["),
              let end   = text.lastIndex(of: "]") else {
            throw llmError("AI returned no parseable JSON.\n\nResponse: \(text.prefix(300))")
        }
        guard let arr = try? JSONSerialization.jsonObject(
            with: Data(String(text[start...end]).utf8)) as? [[String: Any]] else {
            throw llmError("Could not parse AI clip array")
        }
        return arr.compactMap { d -> ClipSuggestion? in
            guard let s = d["start"] as? Double, let e = d["end"] as? Double, e > s else { return nil }
            return ClipSuggestion(start: s, end: e,
                                  hook:   d["hook"]   as? String ?? "",
                                  reason: d["reason"] as? String ?? "")
        }
    }

    // MARK: - Convert suggestions → Clip objects

    func clipsFromSuggestions(_ suggestions: [ClipSuggestion], allWords: [Word]) -> [Clip] {
        suggestions.enumerated().compactMap { idx, sug -> Clip? in
            let inRange = allWords.filter {
                $0.startTime >= sug.start - 0.5 && $0.endTime <= sug.end + 0.5
            }
            guard !inRange.isEmpty else { return nil }
            let score = max(10, 100 - Double(idx) * 6)
            let title = inRange.prefix(8).map { $0.word }.joined(separator: " ")
            return Clip(id: UUID(), title: title,
                        startTime: max(0, (inRange.first?.startTime ?? sug.start) - 0.1),
                        endTime:   (inRange.last?.endTime ?? sug.end) + 0.15,
                        score: score, scoreReason: sug.reason,
                        words: inRange, isLiked: false, starRating: 0,
                        captionStyleName: "Karaoke", aspectRatio: "9:16",
                        notes: sug.hook, thumbnailData: nil)
        }
    }
}
