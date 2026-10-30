import Foundation
import Security

actor LLMClipService {
    static let shared = LLMClipService()

    private var cachedGeminiModel: String? = nil

    private func fetchBestGeminiModel(apiKey: String) async -> String {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return "gemini-2.0-flash"
        }
        let names: [String] = models.compactMap { m -> String? in
            guard let name = m["name"] as? String else { return nil }
            let methods = m["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }
        let preferred = ["gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.5-flash-preview-04-17",
                         "gemini-2.0-flash-exp", "gemini-1.5-flash"]
        for p in preferred { if names.contains(p) { return p } }
        if let flash = names.first(where: { $0.contains("flash") && !$0.contains("lite") }) { return flash }
        if let any = names.first(where: { $0.contains("flash") }) { return any }
        return names.first ?? "gemini-2.0-flash"
    }

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
            case .google:    return "Gemini (auto-select)"
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
        // Cap segments sent to AI — long videos can have 200+ segments, blowing the token budget.
        // Sample evenly so the AI still sees the full arc of the video.
        let maxSegments = 80
        let sampledSegments: [Clip]
        if segments.count > maxSegments {
            let step = Double(segments.count) / Double(maxSegments)
            sampledSegments = (0..<maxSegments).map { segments[Int(Double($0) * step)] }
        } else {
            sampledSegments = segments
        }
        let list = formatSegments(sampledSegments)
        let prompt = buildSegmentPrompt(segmentList: list, targetCount: targetCount,
                                        targetDuration: targetDuration, topic: topic,
                                        numberOfReels: numberOfReels, variation: variation)

        // LLM output is non-deterministic — one unparseable reply shouldn't fail the whole reel,
        // so retry once before surfacing the error.
        var sampled: [Clip] = []
        for attempt in 1...2 {
            let text: String
            switch provider {
            case .anthropic: text = try await callAnthropic(prompt: prompt, apiKey: apiKey)
            case .openai:    text = try await callOpenAI(prompt: prompt, apiKey: apiKey)
            case .google:    text = try await callGoogle(prompt: prompt, apiKey: apiKey)
            }
            // Parse against sampledSegments so indices align, then map back to originals
            do {
                sampled = try parseSegmentJSON(from: text, segments: sampledSegments)
                break
            } catch {
                if attempt == 2 { throw error }
            }
        }
        // Re-map: find each sampled clip in the original list by id
        return sampled.compactMap { s in segments.first { $0.id == s.id } ?? s }
    }

    // MARK: - Story mode — AI reads the whole transcript and composes one coherent short

    struct StoryPlan {
        var title: String
        var ranges: [ClosedRange<Int>]   // sentence index ranges, in playback order
    }

    /// Sends the full numbered transcript and asks the model to build ONE self-contained
    /// short (hook → context → point → payoff) from runs of consecutive sentences.
    /// `avoid` holds sentence indices already used by other reels from the same video.
    func composeStory(sentences: [(start: Double, end: Double, text: String)],
                      targetDuration: Double, topic: String?, avoid: Set<Int>,
                      reelNumber: Int, provider: AIProvider, apiKey: String) async throws -> StoryPlan {
        let lines = sentences.enumerated().map { i, s -> String in
            let m = Int(s.start) / 60, sec = Int(s.start) % 60
            let used = avoid.contains(i) ? " (USED)" : ""
            return "[\(i)] \(m):\(String(format: "%02d", sec)) \(Int((s.end - s.start).rounded()))s\(used): \(s.text)"
        }.joined(separator: "\n")
        let topicLine = (topic?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? "\nTHEME: build the story around \"\(topic!)\".\n" : ""
        let target = Int(targetDuration)

        let prompt = """
You are an expert short-form video editor (Reels, TikTok, Shorts). Below is the full transcript of a talk, one numbered sentence per line with its timestamp and length.
\(topicLine)
Build ONE coherent short of about \(target) seconds (acceptable: \(Int(Double(target) * 0.85))–\(Int(Double(target) * 1.15))s) by choosing runs of CONSECUTIVE sentences. It must make complete sense to someone who never saw the talk.

Structure:
1. HOOK (first 3–8s): the most curiosity-grabbing or bold line. It may come from anywhere in the talk.
2. CONTEXT: just enough setup for the main idea to land.
3. CORE: one main idea or story — stay on a single thread, no topic jumps.
4. PAYOFF: end on a strong, conclusive line (a punchline, takeaway or challenge) — never mid-thought.

Rules:
- Each run starts where a thought starts — never with a line that depends on what came before ("And so that's why…", "This is…", "He said…" without who).
- Keep runs in their original order after the hook. Prefer fewer, longer runs (2–5) over many tiny jumps.
- Skip greetings, announcements, housekeeping, "turn to page…", jokes that need context, and anything referring to visuals the viewer can't see.
- Never use sentences marked (USED) — they belong to other reels. This is reel #\(reelNumber); pick a different idea from the other reels.
- Count the seconds: the sum of the chosen sentences' lengths must be within the range above.

Transcript:
\(lines)

Respond with ONLY valid JSON, no markdown:
{"title":"short catchy title (max 8 words)","segments":[{"from":12,"to":15},{"from":40,"to":47}]}
"""
        var lastError: Error = llmError("AI returned no story")
        for _ in 1...2 {
            let text: String
            switch provider {
            case .anthropic: text = try await callAnthropic(prompt: prompt, apiKey: apiKey)
            case .openai:    text = try await callOpenAI(prompt: prompt, apiKey: apiKey)
            case .google:    text = try await callGoogle(prompt: prompt, apiKey: apiKey)
            }
            do { return try parseStory(text, sentenceCount: sentences.count, avoid: avoid) }
            catch { lastError = error }
        }
        throw lastError
    }

    // MARK: - 🔥 Fire Short — a teaser cut built to make people click through

    struct FirePlan {
        var ranges: [ClosedRange<Int>]
        var title: String          // SEO title
        var description: String    // SEO description
        var hashtags: [String]
        var hookText: String       // on-screen text for the first seconds
    }

    func composeFireShort(sentences: [(start: Double, end: Double, text: String)],
                          targetDuration: Double, topic: String?,
                          provider: AIProvider, apiKey: String) async throws -> FirePlan {
        let lines = sentences.enumerated().map { i, s -> String in
            let m = Int(s.start) / 60, sec = Int(s.start) % 60
            return "[\(i)] \(m):\(String(format: "%02d", sec)) \(Int((s.end - s.start).rounded()))s: \(s.text)"
        }.joined(separator: "\n")
        let topicLine = (topic?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? "\nTHEME / KEYWORDS to target: \"\(topic!)\"\n" : ""
        let target = Int(targetDuration)
        let prompt = """
You are a world-class short-form editor and YouTube/TikTok SEO strategist. Below is the full transcript of a talk, one numbered sentence per line with timestamp and length.
\(topicLine)
Create the "FIRE SHORT": a \(target)-second (acceptable \(Int(Double(target) * 0.8))–\(Int(Double(target) * 1.15))s) teaser cutdown whose only job is to make viewers desperate to watch the full message.

Build a HOOK ROLLERCOASTER from runs of consecutive sentences (the runs may come from anywhere and in any order):
1. HOOK (0–3s): the single most arresting line — a bold claim, a shocking statement or a burning question.
2. TENSION: raise the stakes or show the problem/pain.
3. MINI-PAYOFF: a quick satisfying insight… then immediately
4. RE-HOOK: a "but"/twist/new question that pulls them deeper.
5. PEAK: the most emotional or powerful moment in the whole talk.
6. CLIFFHANGER: end on an open loop — a setup or question whose answer is NOT given, so they must go watch the full message. Never end on a full resolution.

Rules:
- Every run must make sense on its own; never start on a line that depends on missing context.
- Prefer 4–7 short punchy runs; cut slow setup, greetings, announcements and anything visual-dependent.
- Count seconds: sum of chosen sentences must fit the range above.

SEO:
- "title": searchable, curiosity-driven, max 60 characters, includes the main keyword.
- "description": 2–3 sentences, keyword-rich, teases the answer without giving it, ends with a call to watch the full message.
- "hashtags": 6–10 relevant hashtags (with #), mix of broad and niche.
- "hookText": 3–6 words of on-screen text for the opening seconds.

Transcript:
\(lines)

Respond with ONLY valid JSON, no markdown:
{"title":"...","description":"...","hashtags":["#..."],"hookText":"...","segments":[{"from":12,"to":13},{"from":88,"to":90}]}
"""
        var lastError: Error = llmError("AI returned no Fire Short")
        for _ in 1...2 {
            let text: String
            switch provider {
            case .anthropic: text = try await callAnthropic(prompt: prompt, apiKey: apiKey)
            case .openai:    text = try await callOpenAI(prompt: prompt, apiKey: apiKey)
            case .google:    text = try await callGoogle(prompt: prompt, apiKey: apiKey)
            }
            do {
                let story = try parseStory(text, sentenceCount: sentences.count, avoid: [])
                guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
                      let obj = try? JSONSerialization.jsonObject(with: Data(String(text[start...end]).utf8)) as? [String: Any]
                else { throw llmError("Fire Short wasn't valid JSON") }
                return FirePlan(ranges: story.ranges, title: story.title,
                                description: obj["description"] as? String ?? "",
                                hashtags: obj["hashtags"] as? [String] ?? [],
                                hookText: obj["hookText"] as? String ?? "")
            } catch { lastError = error }
        }
        throw lastError
    }

    private func parseStory(_ text: String, sentenceCount: Int, avoid: Set<Int>) throws -> StoryPlan {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(String(text[start...end]).utf8)) as? [String: Any],
              let segs = obj["segments"] as? [[String: Any]] else {
            throw llmError("AI story wasn't valid JSON.\n\nResponse: \(text.prefix(400))")
        }
        var ranges: [ClosedRange<Int>] = []
        var taken = Set<Int>()
        for seg in segs {
            guard var a = seg["from"] as? Int, var b = seg["to"] as? Int else { continue }
            if a > b { swap(&a, &b) }
            a = max(0, a); b = min(sentenceCount - 1, b)
            guard a <= b else { continue }
            let r = a...b
            // Drop overlaps with earlier picks or other reels
            guard r.allSatisfy({ !taken.contains($0) && !avoid.contains($0) }) else { continue }
            ranges.append(r); taken.formUnion(r)
        }
        guard !ranges.isEmpty else { throw llmError("AI story had no usable segments.") }
        return StoryPlan(title: (obj["title"] as? String) ?? "", ranges: ranges)
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
        let model: String
        if let cached = cachedGeminiModel {
            model = cached
        } else {
            let resolved = await fetchBestGeminiModel(apiKey: apiKey)
            cachedGeminiModel = resolved
            model = resolved
        }
        // Force JSON output so Gemini can't answer in prose or markdown
        var genConfig: [String: Any] = [
            "temperature": 0.2,
            "maxOutputTokens": 8192,
            "responseMimeType": "application/json"
        ]
        // 2.5 models "think" by default and those tokens eat the output budget — cap it.
        // (Older models reject thinkingConfig, so only send it to 2.5+.)
        if model.contains("2.5") || model.contains("-3") {
            genConfig["thinkingConfig"] = ["thinkingBudget": 512]
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": genConfig
        ]
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw llmError("Gemini returned non-JSON response")
        }
        // Surface prompt-block reason clearly
        if let blocked = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            throw llmError("Gemini blocked the request: \(blocked). Try a different topic or disable AI mode.")
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw llmError("Gemini returned no candidates.\n\(raw.prefix(200))")
        }
        let finishReason = first["finishReason"] as? String ?? "STOP"
        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            // No content at all — now surface finish reason
            if finishReason != "STOP" {
                throw llmError("Gemini stopped early (\(finishReason)). Try shortening the video or disabling AI mode.")
            }
            throw llmError("Gemini response missing text content")
        }
        // The answer can be split across several parts; skip any thought-summary parts
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        if text.isEmpty {
            throw llmError("Gemini response missing text content (\(finishReason))")
        }
        // MAX_TOKENS: response was cut mid-JSON — try partial parse, only error if nothing useful
        if finishReason == "MAX_TOKENS", !text.contains("[") {
            throw llmError("Gemini hit output limit (MAX_TOKENS). Try disabling AI mode or using a shorter video.")
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

    /// Pulls the segment array out of an LLM reply. Handles a bare array, an object wrapping
    /// the array (e.g. {"clips":[...]}), a single object, and arrays truncated mid-item.
    private func extractSegmentArray(from text: String) -> [[String: Any]]? {
        func parse<S: StringProtocol>(_ s: S) -> Any? {
            try? JSONSerialization.jsonObject(with: Data(String(s).utf8))
        }
        func segments(in obj: Any?) -> [[String: Any]]? {
            if let arr = obj as? [[String: Any]] { return arr }
            if let dict = obj as? [String: Any] {
                if dict["index"] != nil { return [dict] }
                for value in dict.values {
                    if let arr = value as? [[String: Any]] { return arr }
                }
            }
            return nil
        }
        if let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
           let end = text.lastIndex(where: { $0 == "]" || $0 == "}" }),
           start < end,
           let arr = segments(in: parse(text[start...end])) {
            return arr
        }
        // Truncated reply: keep every complete {...} item and close the array
        if let start = text.firstIndex(of: "["),
           let lastObj = text.lastIndex(of: "}"),
           start < lastObj,
           let arr = parse(text[start...lastObj] + "]") as? [[String: Any]] {
            return arr
        }
        return nil
    }

    private func parseSegmentJSON(from text: String, segments: [Clip]) throws -> [Clip] {
        guard let arr = extractSegmentArray(from: text) else {
            let preview = text.isEmpty ? "(empty)" : String(text.prefix(500))
            throw llmError("AI returned no parseable JSON.\n\nResponse: \(preview)")
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
