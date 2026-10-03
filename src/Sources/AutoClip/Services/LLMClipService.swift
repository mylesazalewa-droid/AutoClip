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
            case .google:    return "gemini-2.0-flash"
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

    // MARK: - Segment-based prompt builder
    // Segments come from the local model (clean sentence-boundary cuts).
    // The LLM's only job is to rank and select them — it never touches timestamps.

    private func formatSegments(_ segments: [Clip]) -> String {
        segments.enumerated().map { i, clip in
            let dur = String(format: "%.0fs", clip.endTime - clip.startTime)
            let preview = clip.words.prefix(20).map { $0.word }.joined(separator: " ")
            return "#\(i): [\(dur)] \(preview)"
        }.joined(separator: "\n")
    }

    private func buildSegmentPrompt(segmentList: String, targetCount: Int, targetDuration: Double,
                                     topic: String?, numberOfReels: Int = 1, variation: Int = 0) -> String {
        let topicLine: String
        if let t = topic, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            topicLine = "\nTOPIC / THEME: \"\(t)\" — strongly prefer segments that speak to this theme.\n"
        } else {
            topicLine = ""
        }

        let multiReelLine = numberOfReels > 1 ? """

MULTI-REEL MODE (\(numberOfReels) reels): Select at least \(targetCount) segments spread across the ENTIRE video.
• Cover different CHAPTERS of the content — beginning, middle, end
• No two selected segments should make the same main point
• Prioritise BREADTH over picking the same top 2–3 moments
""" : ""

        let variationLine = variation > 0 ? """

VARIATION #\(variation): You have already made a selection. This time choose a DIFFERENT mix.
• Skip the obvious top clips you'd normally pick first
• Find compelling moments you may have overlooked
• Try segments from parts of the video not covered before
""" : ""

        return """
You are a world-class viral short-form content editor specializing in social media clips.
\(topicLine)\(multiReelLine)\(variationLine)
STEP 1 — Understand the content: Read all segments to identify the speaker's main argument, emotional arc, and key chapters before selecting anything.

STEP 2 — Score each candidate on the Virality Framework (100 points total):
• HOOK (25 pts): First 3–5 words immediately grab attention, pose a question, or make a bold claim
• FLOW (25 pts): Idea is self-contained — starts with a hook, ends with a payoff, no missing context
• VALUE (25 pts): Offers actionable advice, surprising insight, or emotional peak (inspiration, humor, contrast)
• RELEVANCE (25 pts): Topic aligns with what drives engagement on TikTok, Instagram Reels, YouTube Shorts

STEP 3 — Select the \(targetCount) highest-scoring segments.

RULES:
• Segments are already cut cleanly — do NOT suggest custom timestamps
• Target combined duration: ~\(Int(targetDuration)) seconds
• Maximize DIVERSITY — different ideas, different emotional tones, no repeated message
• Skip any segment referencing visual aids the viewer cannot see
• Prefer segments where the first 3 words could stand alone as a caption hook

Segments (format: #index: [duration] first-words…):
\(segmentList)

Respond with ONLY valid JSON — no markdown fences, no explanation:
[{"index":3,"hook":"First compelling words","reason":"Why this moment is viral","viralityScore":84}]
"""
    }

    // MARK: - API call — segments in, selected Clips out

    func selectSegments(from segments: [Clip], provider: AIProvider, apiKey: String,
                        targetDuration: Double, topic: String? = nil,
                        numberOfReels: Int = 1, variation: Int = 0) async throws -> [Clip] {
        let avgDur = segments.isEmpty ? 15.0
            : segments.reduce(0.0) { $0 + ($1.endTime - $1.startTime) } / Double(segments.count)
        // For multi-reel, request more clips so each reel gets a diverse set
        let baseCount = Int((targetDuration / max(5.0, avgDur)).rounded(.up)) + 2
        let targetCount = max(3, min(40, numberOfReels > 1 ? baseCount + numberOfReels * 2 : baseCount))
        let list = formatSegments(segments)
        let prompt = buildSegmentPrompt(segmentList: list, targetCount: targetCount,
                                        targetDuration: targetDuration, topic: topic,
                                        numberOfReels: numberOfReels, variation: variation)

        let text: String
        switch provider {
        case .anthropic: text = try await callAnthropic(prompt: prompt, apiKey: apiKey)
        case .openai:    text = try await callOpenAI(prompt: prompt, apiKey: apiKey)
        case .google:    text = try await callGoogle(prompt: prompt, apiKey: apiKey)
        }

        return try parseSegmentJSON(from: text, segments: segments)
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
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)"
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
            var rawMsg = String(data: data, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                rawMsg = (json["error"] as? [String: Any])?["message"] as? String
                    ?? (json["error"] as? String)
                    ?? rawMsg
            }
            // Friendly messages for common Anthropic key issues
            if rawMsg.contains("not scoped to a workspace") || rawMsg.contains("anthropic-workspace-id") {
                throw llmError(
                    "Your Anthropic API key needs to be workspace-scoped.\n\n" +
                    "Fix: Go to console.anthropic.com → Settings → API Keys → " +
                    "create a new key inside a Workspace (not a personal key). " +
                    "Paste the new key in AutoClip."
                )
            }
            if rawMsg.contains("invalid x-api-key") || rawMsg.contains("invalid_api_key") || http.statusCode == 401 {
                throw llmError("Invalid API key. Check that you copied the full key correctly.")
            }
            throw llmError(rawMsg.isEmpty ? "HTTP \(http.statusCode)" : String(rawMsg.prefix(300)))
        }
    }

    private func llmError(_ msg: String) -> NSError {
        NSError(domain: "LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func parseSegmentJSON(from text: String, segments: [Clip]) throws -> [Clip] {
        guard let start = text.firstIndex(of: "["),
              let end   = text.lastIndex(of: "]") else {
            throw llmError("AI returned no parseable JSON.\n\nResponse: \(text.prefix(300))")
        }
        guard let arr = try? JSONSerialization.jsonObject(
            with: Data(String(text[start...end]).utf8)) as? [[String: Any]] else {
            throw llmError("Could not parse AI segment array")
        }
        var seen = Set<Int>()
        var result: [Clip] = []
        for (rank, d) in arr.enumerated() {
            guard let idx = d["index"] as? Int,
                  idx >= 0, idx < segments.count,
                  !seen.contains(idx) else { continue }
            seen.insert(idx)
            var clip = segments[idx]
            // Prefer the AI's explicit virality score if provided, otherwise rank-based
            let llmScore: Double? = (d["viralityScore"] as? Double) ?? (d["viralityScore"] as? Int).map { Double($0) }
            clip.score       = llmScore ?? max(10, 100 - Double(rank) * 6)
            clip.scoreReason = d["reason"] as? String ?? clip.scoreReason
            clip.notes       = d["hook"]   as? String ?? clip.notes
            result.append(clip)
        }
        guard !result.isEmpty else {
            throw llmError("AI returned no valid segment indices.")
        }
        return result
    }
}
