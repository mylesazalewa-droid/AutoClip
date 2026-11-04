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
            case .anthropic: return "claude-haiku-5-5"
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
        var hook: String = ""            // on-screen text for the first seconds
        var keywords: [String] = []      // words the captions highlight
    }

    /// Sends the full numbered transcript and asks the model to build ONE self-contained
    /// short (hook → context → point → payoff) from runs of consecutive sentences.
    /// `avoid` holds sentence indices already used by other reels from the same video.
    func composeStory(sentences: [(start: Double, end: Double, text: String)],
                      targetDuration: Double, topic: String?, avoid: Set<Int>,
                      reelNumber: Int, otherTitles: [String] = [], single: Bool = false,
                      kind: ContentKind = .current,
                      provider: AIProvider, apiKey: String) async throws -> StoryPlan {
        let taste = await TasteStore.promptBlock(for: kind)
        let othersLine = otherTitles.isEmpty ? "" : """

Other reels from this talk ALREADY cover these ideas — pick a clearly DIFFERENT main idea, and write a title with different wording (don't reuse their key phrases):
\(otherTitles.map { "- " + $0 }.joined(separator: "\n"))
"""
        let lines = sentences.enumerated().map { i, s -> String in
            let m = Int(s.start) / 60, sec = Int(s.start) % 60
            let used = avoid.contains(i) ? " (USED)" : ""
            return "[\(i)] \(m):\(String(format: "%02d", sec)) \(Int((s.end - s.start).rounded()))s\(used): \(s.text)"
        }.joined(separator: "\n")
        let topicLine = (topic?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? "\nTHEME: build the story around \"\(topic!)\".\n" : ""
        let target = Int(targetDuration)

        let singlePrompt = """
You are an expert short-form video editor (Reels, TikTok, Shorts). Below is the full transcript of a talk, one numbered sentence per line with its timestamp and length.
\(kind.promptContext)
\(topicLine)\(taste)
Pick ONE single continuous passage (one run of CONSECUTIVE sentences, no jumps) of about \(target) seconds (acceptable: \(Int(Double(target) * 0.7))–\(Int(Double(target) * 1.2))s, or up to \(max(Int(Double(target) * 1.6), 90))s if that's what it takes to finish the thought) that works perfectly as a stand-alone short.

Rules:
- It must START on a line that grabs attention and makes sense with no context — never on a line that depends on what came before ("And so…", "That's why…", "He said…").
- It must END where the speaker finishes this thought, on a strong, conclusive line (a punchline, takeaway or challenge) — never mid-thought.
- The ending must be where the speaker lands THIS point: their own conclusion, application or punchline for the same thought. Never tack on a general uplifting line, blessing, prayer or encouragement that isn't about this point.
- \(kind.resolutionRule)
- Prefer a complete story, illustration or one powerful point.
- Skip greetings, announcements, housekeeping and anything referring to visuals the viewer can't see.
- Never use sentences marked (USED) — they belong to other reels. This is reel #\(reelNumber).\(othersLine)

Transcript:
\(lines)

Respond with ONLY valid JSON, no markdown:
{"title":"short catchy title (max 8 words)","hook":"3–7 word on-screen hook for the first 3 seconds that makes people stop scrolling (not the same as the title)","keywords":["3–6 single words from the chosen lines that carry the meaning, to highlight in captions"],"segments":[{"from":40,"to":52}]}
"""
        let prompt = single ? singlePrompt : """
You are an expert short-form video editor (Reels, TikTok, Shorts). Below is the full transcript of a talk, one numbered sentence per line with its timestamp and length.
\(kind.promptContext)
\(topicLine)\(taste)
Build ONE coherent short of about \(target) seconds (acceptable: \(Int(Double(target) * 0.85))–\(Int(Double(target) * 1.15))s) by choosing runs of CONSECUTIVE sentences. It must make complete sense to someone who never saw the talk. Finishing the thought matters more than the length: if a really strong point needs it, you may run up to \(max(Int(Double(target) * 1.6), 90))s rather than cut it off.

Structure:
1. HOOK (first 3–8s): the most curiosity-grabbing or bold line. It may come from anywhere in the talk.
2. CONTEXT: just enough setup for the main idea to land.
3. CORE: one main idea or story — stay on a single thread, no topic jumps.
4. CLOSER: end where the speaker finishes THIS thought — their own conclusion, application or punchline for the same point, usually the sentences right after the core. The last line must clearly complete what the hook and core set up, so a viewer feels the thought is finished. Never tack on a general uplifting line, blessing, prayer or encouragement from elsewhere in the talk that isn't about this exact point. \(kind.resolutionRule) A resolution from later in the talk is allowed ONLY when it plainly answers the same struggle (same idea and words).
Before answering, check the last run: is it about the same subject as the core? If not, drop it and end earlier.

Rules:
- Each run starts where a thought starts — never with a line that depends on what came before ("And so that's why…", "This is…", "He said…" without who).
- Keep runs in their original order after the hook. Prefer fewer, longer runs (2–5) over many tiny jumps.
- Skip greetings, announcements, housekeeping, "turn to page…", jokes that need context, and anything referring to visuals the viewer can't see.
- Never use sentences marked (USED) — they belong to other reels. This is reel #\(reelNumber); pick a different idea from the other reels.\(othersLine)
- Count the seconds: the sum of the chosen sentences' lengths should be within the range above (or up to \(max(Int(Double(target) * 1.6), 90))s only to finish a strong thought).

Transcript:
\(lines)

Respond with ONLY valid JSON, no markdown:
{"title":"short catchy title (max 8 words)","hook":"3–7 word on-screen hook for the first 3 seconds that makes people stop scrolling (not the same as the title)","keywords":["3–6 single words from the chosen lines that carry the meaning, to highlight in captions"],"segments":[{"from":12,"to":15},{"from":40,"to":47}]}
"""
        var lastError: Error = llmError("AI returned no story")
        for _ in 1...2 {
            let text: String
            switch provider {
            case .anthropic: text = try await callAnthropic(prompt: prompt, apiKey: apiKey)
            case .openai:    text = try await callOpenAI(prompt: prompt, apiKey: apiKey)
            case .google:    text = try await callGoogle(prompt: prompt, apiKey: apiKey)
            }
            do {
                var plan = try parseStory(text, sentenceCount: sentences.count, avoid: avoid)
                if single, let first = plan.ranges.first, let last = plan.ranges.last {
                    // One passage: if the model returned pieces, join them only when they're adjacent
                    plan.ranges = plan.ranges.count > 1 && last.upperBound - first.lowerBound <= plan.ranges.reduce(0) { $0 + $1.count } + 2
                        ? [first.lowerBound...last.upperBound] : [plan.ranges.max { $0.count < $1.count }!]
                }
                return plan
            }
            catch { lastError = error }
        }
        throw lastError
    }

    // MARK: - Chat: a short about what the user asks for

    private func numbered(_ sentences: [(start: Double, end: Double, text: String)]) -> String {
        sentences.enumerated().map { i, s -> String in
            let m = Int(s.start) / 60, sec = Int(s.start) % 60
            return "[\(i)] \(m):\(String(format: "%02d", sec)) \(Int((s.end - s.start).rounded()))s: \(s.text)"
        }.joined(separator: "\n")
    }

    private func ask(_ prompt: String, provider: AIProvider, apiKey: String) async throws -> String {
        switch provider {
        case .anthropic: return try await callAnthropic(prompt: prompt, apiKey: apiKey)
        case .openai:    return try await callOpenAI(prompt: prompt, apiKey: apiKey)
        case .google:    return try await callGoogle(prompt: prompt, apiKey: apiKey)
        }
    }

    /// Simple jobs (hooks, post copy, topic lists) run on this Mac when on-device AI is on and
    /// running, and on the cloud model otherwise.
    private func askLight(_ prompt: String, provider: AIProvider, apiKey: String) async throws -> String {
        if await LocalAI.ready() {
            do { return try await LocalAI.generate(prompt) }
            catch { if apiKey.isEmpty { throw error } }   // fall back to the cloud when there's a key
        }
        return try await ask(prompt, provider: provider, apiKey: apiKey)
    }

    /// Builds one short that fulfils `request` ("a short about forgiveness") using only what
    /// the talk says. Throws with the model's explanation if the talk doesn't cover it.
    func composeRequested(_ request: String, sentences: [(start: Double, end: Double, text: String)],
                          targetDuration: Double, kind: ContentKind = .current,
                          provider: AIProvider, apiKey: String) async throws -> StoryPlan {
        let target = Int(targetDuration)
        let taste = await TasteStore.promptBlock(for: kind)
        let prompt = """
You are an expert short-form video editor. Below is the full transcript of a talk, one numbered sentence per line with timestamp and length.
\(kind.promptContext)
\(taste)
The creator asks: "\(request)"

Build ONE coherent short of about \(target) seconds (acceptable \(Int(Double(target) * 0.8))–\(Int(Double(target) * 1.15))s) that does exactly what they asked, using ONLY what is said in this talk, from runs of CONSECUTIVE sentences.
- Open with a strong hook related to the request, then build to a clear, conclusive ending.
- The ending must be where the speaker lands THIS point: their own conclusion, application or punchline for the same thought. Never tack on a general uplifting line, blessing, prayer or encouragement that isn't about this point.
- \(kind.resolutionRule)
- Every run must make sense on its own; skip greetings, announcements and visual references.
- Keep runs in their original order after the hook. Prefer 2–6 runs.
- If the request asks for a different length (e.g. "30 seconds"), use that length instead.
- If the talk does not really cover what they asked, do NOT force it: respond {"error":"<one friendly sentence saying what the talk does cover that is closest>"}.

Transcript:
\(numbered(sentences))

Respond with ONLY valid JSON, no markdown:
{"title":"short catchy title (max 8 words)","hook":"3–7 word on-screen hook for the first 3 seconds that makes people stop scrolling (not the same as the title)","keywords":["3–6 single words from the chosen lines that carry the meaning, to highlight in captions"],"segments":[{"from":12,"to":15},{"from":40,"to":47}]}
"""
        var lastError: Error = llmError("AI returned nothing")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
               let obj = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any],
               let msg = obj["error"] as? String, obj["segments"] == nil {
                throw llmError(msg)   // talk doesn't cover it — surface the model's explanation
            }
            do { return try parseStory(text, sentenceCount: sentences.count, avoid: []) }
            catch { lastError = error }
        }
        throw lastError
    }

    /// The main topics / stories in the talk, phrased as short requests the user can click.
    func listTopics(sentences: [(start: Double, end: Double, text: String)],
                    provider: AIProvider, apiKey: String) async throws -> [String] {
        let prompt = """
Below is the transcript of a talk. List the 6–10 most compelling topics, stories or moments it covers that would each make a great short video. Phrase each as a short request of 3–8 words, e.g. "the story about his daughter", "why forgiveness frees you".

Transcript:
\(numbered(sentences))

Respond with ONLY valid JSON: {"topics":["...","..."]}
"""
        let text = try await askLight(prompt, provider: provider, apiKey: apiKey)
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any],
              let topics = obj["topics"] as? [String], !topics.isEmpty else {
            throw llmError("AI didn't return a topic list.")
        }
        return topics
    }

    // MARK: - Speaking coach

    /// Coaching report for a whole talk. `stats` is a short plain-text summary of the measured
    /// delivery (pace, pauses, fillers…) so the advice can reference real numbers.
    func coachReport(sentences: [(start: Double, end: Double, text: String)], stats: String,
                     provider: AIProvider, apiKey: String) async throws -> SpeakerReport.Coach {
        let lines = sentences.enumerated().map { i, s -> String in
            let m = Int(s.start) / 60, sec = Int(s.start) % 60
            return "[\(i)] \(m):\(String(format: "%02d", sec)) \(s.text)"
        }.joined(separator: "\n")
        let prompt = """
You are an experienced \(ContentKind.current == .sermon ? "preaching and public-speaking" : "public-speaking and on-camera") coach. Below is the transcript of a \(ContentKind.current.noun) (numbered sentences with timestamps) and measurements of the speaker's delivery. Give honest, warm, specific coaching that helps this speaker grow. Reference sentence numbers so the speaker can jump to the moment.

MEASURED DELIVERY:
\(stats)

Return:
- "score": overall 1–10 for clarity and impact.
- "summary": 2 sentences.
- "strengths": 3 items {title (max 6 words), detail (1–2 sentences, specific), sentence}.
- "improvements": 3 items {title, detail (what happened and why it matters), sentence, drill (one concrete practice exercise for this week)}. Use the measurements where relevant (e.g. pace, fillers, long runs without pausing).
- "bigIdea": the one main idea a listener would take away, as one sentence; "clarity": 1–10 how clearly it came through; "mentions": sentence numbers where the big idea is stated or restated.
- "sections": the sermon's structure in order, covering the whole talk: {kind: one of intro|point|story|scripture|application|close|other, title (max 6 words), from, to}.
- "best": the 3 strongest moments {sentence, quote (max 15 words, verbatim), why}.
- "weakest": the 3 weakest or most rambling moments {sentence, quote, why}.
- "jargon": up to 8 church/insider words or phrases a newcomer might not understand (empty if none).

Transcript:
\(lines)

Respond with ONLY valid JSON, no markdown:
{"score":7,"summary":"...","strengths":[{"title":"...","detail":"...","sentence":12}],"improvements":[{"title":"...","detail":"...","sentence":40,"drill":"..."}],"bigIdea":"...","clarity":7,"mentions":[3,50],"sections":[{"kind":"intro","title":"...","from":0,"to":20}],"best":[{"sentence":88,"quote":"...","why":"..."}],"weakest":[{"sentence":120,"quote":"...","why":"..."}],"jargon":["..."]}
"""
        func time(_ any: Any?) -> Double? {
            guard let i = (any as? Int) ?? (any as? Double).map({ Int($0) }), sentences.indices.contains(i) else { return nil }
            return sentences[i].start
        }
        var lastError: Error = llmError("The AI coach didn't return a report")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                  let o = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any] else {
                lastError = llmError("The AI coach's report wasn't valid JSON — try again"); continue
            }
            let notes = { (key: String) -> [SpeakerReport.Coach.Note] in
                (o[key] as? [[String: Any]] ?? []).compactMap { n in
                    guard let t = n["title"] as? String else { return nil }
                    return .init(title: t, detail: n["detail"] as? String ?? "", time: time(n["sentence"]), drill: n["drill"] as? String)
                }
            }
            let moments = { (key: String) -> [SpeakerReport.Coach.Moment] in
                (o[key] as? [[String: Any]] ?? []).compactMap { m in
                    guard let t = time(m["sentence"]) else { return nil }
                    return .init(time: t, quote: m["quote"] as? String ?? "", why: m["why"] as? String ?? "")
                }
            }
            let sections: [SpeakerReport.Coach.Section] = (o["sections"] as? [[String: Any]] ?? []).compactMap { sct in
                guard let from = sct["from"] as? Int, let to = sct["to"] as? Int,
                      sentences.indices.contains(from), sentences.indices.contains(max(from, to)) else { return nil }
                return .init(kind: (sct["kind"] as? String ?? "other").lowercased(), title: sct["title"] as? String ?? "",
                             start: sentences[from].start, end: sentences[max(from, to)].end)
            }
            let score = (o["score"] as? Int) ?? (o["score"] as? Double).map { Int($0) } ?? 0
            guard score > 0 || !sections.isEmpty else { lastError = llmError("The AI coach's report was empty — try again"); continue }
            return .init(score: max(1, min(10, score)), summary: o["summary"] as? String ?? "",
                         strengths: notes("strengths"), improvements: notes("improvements"),
                         bigIdea: o["bigIdea"] as? String ?? "",
                         bigIdeaClarity: (o["clarity"] as? Int) ?? 0,
                         bigIdeaMentions: (o["mentions"] as? [Any] ?? []).compactMap { time($0) },
                         sections: sections, best: moments("best"), weakest: moments("weakest"),
                         jargon: o["jargon"] as? [String] ?? [])
        }
        throw lastError
    }

    // MARK: - Worship coach

    func worshipCoach(facts: String, provider: AIProvider, apiKey: String) async throws -> WorshipCoach {
        let prompt = """
You are an experienced, encouraging worship pastor reviewing the worship part of a church service with the team, so they can improve week by week. These are measurements from a recording, what was said between songs, and the team's own notes. The measurements are rough and depend on the camera and sound feed. Don't judge anyone's heart or sincerity; talk about craft and how it comes across.

\(facts)

Return:
- "summary": 2 sentences.
- "wins": 3 items {title (max 6 words), detail (1–2 specific sentences)}.
- "improvements": 3 items {title, detail (what the recording showed and one practical change)}.
- "rehearsal": 3 to 5 short steps for this week's rehearsal.

Respond with ONLY valid JSON, no markdown:
{"summary":"...","wins":[{"title":"...","detail":"..."}],"improvements":[{"title":"...","detail":"..."}],"rehearsal":["..."]}
"""
        var lastError: Error = llmError("The AI coach didn't return a report")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                  let o = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any],
                  let summary = o["summary"] as? String else {
                lastError = llmError("The AI coach's report wasn't valid JSON — try again"); continue
            }
            let items = { (key: String) -> [WorshipCoach.Item] in
                (o[key] as? [[String: Any]] ?? []).compactMap { n in
                    guard let t = n["title"] as? String else { return nil }
                    return .init(title: t, detail: n["detail"] as? String ?? "")
                }
            }
            return WorshipCoach(summary: summary, wins: items("wins"), improvements: items("improvements"),
                                rehearsal: o["rehearsal"] as? [String] ?? [])
        }
        throw lastError
    }

    // MARK: - Sermon notes

    /// Small-group / website notes for a sermon. `verses` are the references found in the
    /// transcript, so the AI doesn't have to guess them from garbled speech.
    func sermonNotes(sentences: [(start: Double, end: Double, text: String)], title: String, verses: [String],
                     kind: ContentKind = .sermon,
                     provider: AIProvider, apiKey: String) async throws -> SpeakerReport.Notes {
        let sermon = kind == .sermon
        let lines = sentences.enumerated().map { i, s -> String in
            let m = Int(s.start) / 60, sec = Int(s.start) % 60
            return "[\(i)] \(m):\(String(format: "%02d", sec)) \(s.text)"
        }.joined(separator: "\n")
        let prompt = """
\(sermon ? "You write sermon notes for a church's small groups and website." : "You write companion notes for a \(kind.noun) — for a blog, newsletter or website.") Below is the transcript of a \(kind.noun) (numbered sentences with timestamps). The video is titled "\(title)".\(sermon ? " Scripture references detected in the audio: \(verses.isEmpty ? "none" : verses.joined(separator: "; "))." : "")

Write notes that someone who missed it could follow, in the speaker's own ideas and tone. Don't invent points the speaker didn't make. Fix obvious transcription errors\(sermon ? " in Bible references" : " in names").\(sermon ? "" : " Don't add a spiritual angle that isn't there; leave \"verses\" empty and \"prayer\" as \"\" unless the speaker quotes Scripture or prays.")

Return:
- "title": a clear title (use the video title if it fits).
- "bigIdea": the one main idea, one sentence.
- "summary": 3–4 sentences.
- "points": the main points in order (usually 3–5): {title (max 8 words), summary (2–3 sentences), sentence (where the point starts), verses (references used for this point)}.
- "verses": every Scripture passage referenced, in order.
- "quotes": 3–5 memorable lines, verbatim or lightly cleaned up, max 25 words each.
- "questions": 5 \(sermon ? "small-group discussion" : "reflection or discussion") questions, from easy/personal to deeper/application.
- "application": 2–3 concrete things to try this week.
- "prayer": a short closing prayer (2–3 sentences) based on the message.

Transcript:
\(lines)

Respond with ONLY valid JSON, no markdown:
{"title":"...","bigIdea":"...","summary":"...","points":[{"title":"...","summary":"...","sentence":12,"verses":["Romans 8:28"]}],"verses":["..."],"quotes":["..."],"questions":["..."],"application":["..."],"prayer":"..."}
"""
        var lastError: Error = llmError("The AI didn't return sermon notes")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                  let o = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any] else {
                lastError = llmError("The sermon notes weren't valid JSON — try again"); continue
            }
            let points: [SpeakerReport.Notes.Point] = (o["points"] as? [[String: Any]] ?? []).compactMap { p in
                guard let t = p["title"] as? String else { return nil }
                let i = (p["sentence"] as? Int) ?? (p["sentence"] as? Double).map { Int($0) }
                return .init(title: t, summary: p["summary"] as? String ?? "",
                             time: i.flatMap { sentences.indices.contains($0) ? sentences[$0].start : nil },
                             verses: p["verses"] as? [String] ?? [])
            }
            guard !points.isEmpty else { lastError = llmError("The sermon notes came back empty — try again"); continue }
            return .init(title: o["title"] as? String ?? title, bigIdea: o["bigIdea"] as? String ?? "",
                         summary: o["summary"] as? String ?? "", points: points,
                         verses: o["verses"] as? [String] ?? verses, quotes: o["quotes"] as? [String] ?? [],
                         questions: o["questions"] as? [String] ?? [], application: o["application"] as? [String] ?? [],
                         prayer: o["prayer"] as? String ?? "")
        }
        throw lastError
    }

    // MARK: - Podcast show notes

    /// Titles, description, chapters, keywords, quotes and a social post for a podcast episode.
    /// `paragraphs` carry source-clock times; chapter times come back on that clock.
    func podcastNotes(title: String, paragraphs: [(start: Double, speaker: String?, text: String)], people: [String],
                      provider: AIProvider, apiKey: String) async throws -> PodcastNotes {
        func stamp(_ t: Double) -> String { let i = Int(t); return String(format: "%d:%02d", i / 60, i % 60) }
        var body = paragraphs.map { "[\(stamp($0.start))]\($0.speaker.map { " \($0):" } ?? "") \($0.text)" }.joined(separator: "\n")
        if body.count > 240_000 { body = String(body.prefix(120_000)) + "\n[…]\n" + String(body.suffix(120_000)) }
        let named = people.filter { $0.range(of: #"^Person \d+$"#, options: .regularExpression) == nil }
        let prompt = """
You write show notes for a podcast. Below is the transcript of an episode titled "\(title)"\(named.isEmpty ? "" : " with \(named.joined(separator: ", "))"). Each paragraph starts with a [m:ss] timestamp.

Write in a warm, clear voice that matches the conversation. Don't invent anything that isn't said. Fix obvious transcription errors in names and Bible references.

Return:
- "titles": 3 episode title ideas (max 70 characters each), best first.
- "summary": 1–2 sentences.
- "description": a podcast description of 2–3 short paragraphs (what it's about, what listeners will take away); no timestamps, no hashtags.
- "chapters": 5–12 chapters covering the whole episode in order, the first at "0:00": {"at": "m:ss", "title": max 6 words}. Put each chapter where that topic actually starts.
- "keywords": 6–10 search keywords.
- "quotes": 3–5 memorable lines, verbatim or lightly cleaned up, max 25 words each.
- "guests": names of guests mentioned as being on the episode (empty if unclear).
- "socialPost": a short post (2–3 sentences) inviting people to listen.

Transcript:
\(body)

Respond with ONLY valid JSON, no markdown:
{"titles":["..."],"summary":"...","description":"...","chapters":[{"at":"0:00","title":"..."}],"keywords":["..."],"quotes":["..."],"guests":[],"socialPost":"..."}
"""
        func seconds(_ v: Any?) -> Double? {
            if let n = v as? Double { return n }
            if let n = v as? Int { return Double(n) }
            guard let s = v as? String else { return nil }
            let c = s.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            return c.isEmpty ? nil : c.reduce(0) { $0 * 60 + $1 }
        }
        var lastError: Error = llmError("The AI didn't return show notes")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                  let o = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any] else {
                lastError = llmError("The show notes weren't valid JSON — try again"); continue
            }
            var chapters: [PodcastNotes.Chapter] = (o["chapters"] as? [[String: Any]] ?? []).compactMap { c in
                guard let t = c["title"] as? String, let at = seconds(c["at"]) else { return nil }
                return .init(time: at, title: t)
            }.sorted { $0.time < $1.time }
            if let first = chapters.first, first.time > 1 { chapters.insert(.init(time: 0, title: "Introduction"), at: 0) }
            let description = o["description"] as? String ?? ""
            guard !description.isEmpty else { lastError = llmError("The show notes came back empty — try again"); continue }
            return PodcastNotes(titles: o["titles"] as? [String] ?? [title], summary: o["summary"] as? String ?? "",
                                description: description, chapters: chapters, keywords: o["keywords"] as? [String] ?? [],
                                quotes: o["quotes"] as? [String] ?? [], guests: o["guests"] as? [String] ?? [],
                                socialPost: o["socialPost"] as? String ?? "")
        }
        throw lastError
    }

    // MARK: - Series coherence

    struct SeriesPart {
        var title: String
        var date: Date
        var paragraphs: [(start: Double, text: String)]
        var bigIdea: String?
    }

    /// Reads every message in a series together and judges whether it holds together: one
    /// throughline, each week building on the last, callbacks, gaps, repeats and tensions.
    func seriesAnalysis(name: String, parts: [SeriesPart], provider: AIProvider, apiKey: String) async throws -> SeriesAnalysis {
        func stamp(_ t: Double) -> String { let i = Int(t); return String(format: "%d:%02d", i / 60, i % 60) }
        // Keep the prompt a sensible size: long series keep each talk's opening and closing in full
        let budget = max(12_000, 220_000 / max(1, parts.count))
        let df = DateFormatter(); df.dateStyle = .medium
        let body = parts.enumerated().map { i, p -> String in
            var text = p.paragraphs.map { "[\(stamp($0.start))] \($0.text)" }.joined(separator: "\n")
            if text.count > budget {
                text = String(text.prefix(budget / 2)) + "\n[… middle of the message left out for length …]\n" + String(text.suffix(budget / 2))
            }
            let idea = p.bigIdea.map { "\nBig idea noted earlier: \($0)" } ?? ""
            return "=== PART \(i + 1): \(p.title) (\(df.string(from: p.date)))\(idea) ===\n\(text)"
        }.joined(separator: "\n\n")
        let prompt = """
You are an experienced preaching coach. Below are the transcripts of a sermon series called "\(name)", \(parts.count) messages in the order they were preached. Each paragraph starts with a [m:ss] timestamp within that message.

Assess the series AS A SERIES: does it hold together and make sense across the weeks? Look for:
- a clear throughline (one idea the whole series develops) — or the lack of one;
- whether each message builds on the previous ones, or could stand alone in any order;
- explicit connections: recaps of earlier weeks, callbacks, repeated phrases or images, set-ups for next week;
- gaps: missing steps in the logic, questions raised but never answered, abrupt jumps in topic;
- overlaps: the same point taught again without adding anything;
- tensions: places where messages seem to contradict or pull in different directions.
Be honest and specific. Loosely related standalone messages should score low; a tightly built series high. Quote the preacher's actual words. Fix obvious transcription errors.

Return:
- "score": 1–10 for how coherent the series is.
- "verdict": one sentence.
- "summary": 3–4 sentences on how the series works as a whole.
- "throughline": the one idea that ties it together, in one sentence (say plainly if there isn't a clear one).
- "arc": 2–3 sentences on how it progresses from first to last.
- "parts": one entry per message, in order: {"bigIdea": one sentence, "role": how it serves the series (1 sentence), "fit": 1–10 how well it connects to the throughline and the other messages, "note": one sentence on what would tie it in better (or what it does well), "links": up to 3 moments where the preacher connects to another message — {"at": "m:ss" from this message, "quote": max 20 words, "to": the other part's number}}.
- "strengths": 2–4 {title (max 8 words), detail (1–2 sentences), parts: [part numbers]}.
- "gaps": 0–4, same shape.
- "overlaps": 0–3, same shape.
- "tensions": 0–3, same shape (empty if none).
- "suggestions": 3–5 concrete ways to make this series (or the next one) tie together better.
- "recap": one paragraph summarising the whole series for the church website.

\(body)

Respond with ONLY valid JSON, no markdown:
{"score":7,"verdict":"...","summary":"...","throughline":"...","arc":"...","parts":[{"bigIdea":"...","role":"...","fit":8,"note":"...","links":[{"at":"3:10","quote":"...","to":1}]}],"strengths":[{"title":"...","detail":"...","parts":[1,2]}],"gaps":[],"overlaps":[],"tensions":[],"suggestions":["..."],"recap":"..."}
"""
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? Double).map { Int($0) } ?? (v as? String).flatMap { Int($0) } }
        func seconds(_ v: Any?) -> Double? {
            if let n = v as? Double { return n }
            if let n = v as? Int { return Double(n) }
            guard let s = v as? String else { return nil }
            let comps = s.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard !comps.isEmpty else { return nil }
            return comps.reduce(0) { $0 * 60 + $1 }
        }
        func findings(_ v: Any?) -> [SeriesAnalysis.Finding] {
            (v as? [[String: Any]] ?? []).compactMap { f in
                guard let t = f["title"] as? String else { return nil }
                let ps = (f["parts"] as? [Any] ?? []).compactMap(int).filter { (1...parts.count).contains($0) }
                return .init(title: t, detail: f["detail"] as? String ?? "", parts: ps)
            }
        }
        var lastError: Error = llmError("The AI didn't return a series assessment")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                  let o = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any] else {
                lastError = llmError("The series assessment wasn't valid JSON — try again"); continue
            }
            var ps: [SeriesAnalysis.Part] = (o["parts"] as? [[String: Any]] ?? []).map { p in
                let links: [SeriesAnalysis.Link] = (p["links"] as? [[String: Any]] ?? []).compactMap { l in
                    guard let q = l["quote"] as? String else { return nil }
                    return .init(time: seconds(l["at"]), quote: q, to: int(l["to"]).flatMap { (1...parts.count).contains($0) ? $0 : nil })
                }
                return .init(bigIdea: p["bigIdea"] as? String ?? "", role: p["role"] as? String ?? "",
                             fit: min(10, max(1, int(p["fit"]) ?? 5)), note: p["note"] as? String ?? "", links: links)
            }
            guard !ps.isEmpty, let score = int(o["score"]) else { lastError = llmError("The series assessment came back empty — try again"); continue }
            while ps.count < parts.count { ps.append(.init(bigIdea: "", role: "", fit: 5, note: "", links: [])) }
            return SeriesAnalysis(videos: [], score: min(10, max(1, score)), verdict: o["verdict"] as? String ?? "",
                                  summary: o["summary"] as? String ?? "", throughline: o["throughline"] as? String ?? "",
                                  arc: o["arc"] as? String ?? "", parts: Array(ps.prefix(parts.count)),
                                  strengths: findings(o["strengths"]), gaps: findings(o["gaps"]),
                                  overlaps: findings(o["overlaps"]), tensions: findings(o["tensions"]),
                                  suggestions: o["suggestions"] as? [String] ?? [], recap: o["recap"] as? String ?? "")
        }
        throw lastError
    }

    // MARK: - Hopeful ending

    /// A short run from the talk (about 6–20s) that resolves `reelText` with hope — the
    /// "But God…" turn — to add at the end of a reel that finishes on a downer.
    func findHopefulEnding(sentences: [(start: Double, end: Double, text: String)], reelText: String,
                           inReel: Set<Int>, provider: AIProvider, apiKey: String) async throws -> ClosedRange<Int> {
        let lines = sentences.enumerated().map { i, s -> String in
            "[\(i)] \(Int((s.end - s.start).rounded()))s\(inReel.contains(i) ? " (IN REEL)" : ""): \(s.text)"
        }.joined(separator: "\n")
        let prompt = """
A short video was cut from a sermon. Here is what the short currently says:
\"\"\"
\(reelText.prefix(3000))
\"\"\"

It needs a hopeful resolution at the end so it doesn't finish on a downer — a "But God…" turn: grace, forgiveness, a promise of God, what Jesus has done, or a hopeful challenge that answers the struggle the short raises.

From the full transcript below, choose ONE run of 1–4 CONSECUTIVE sentences (about 6–20 seconds) that delivers that resolution in the speaker's own words. It must make sense right after the short's last line and end on a complete, encouraging thought. Don't pick sentences marked (IN REEL).

Transcript:
\(lines)

Respond with ONLY valid JSON: {"title":"","segments":[{"from":120,"to":122}]}
"""
        var lastError: Error = llmError("AI didn't find a hopeful ending")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            do {
                let plan = try parseStory(text, sentenceCount: sentences.count, avoid: inReel)
                if let r = plan.ranges.first { return r.count > 5 ? r.lowerBound...(r.lowerBound + 4) : r }
            } catch { lastError = error }
        }
        throw lastError
    }

    // MARK: - Hook text

    /// 3–7 words of on-screen text for the opening seconds of a reel.
    func writeHook(transcript: String, title: String, provider: AIProvider, apiKey: String) async throws -> String {
        let prompt = """
You write on-screen hook text for short vertical videos (Reels, TikTok, Shorts) from church messages.
Write ONE hook of 3–7 words shown in the first 3 seconds. It must create curiosity or tension and make people stop scrolling. It should fit what is actually said. No hashtags, no emojis, no quotation marks.

Reel title: \(title)
What is said in the reel:
\(transcript.prefix(4000))

Respond with ONLY valid JSON: {"hook":"..."}
"""
        let text = try await askLight(prompt, provider: provider, apiKey: apiKey)
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any],
              let hook = obj["hook"] as? String, !hook.isEmpty else { throw llmError("AI didn't return a hook") }
        return hook.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespacesAndNewlines))
    }

    // MARK: - Social graphics (quote cards, carousel, thumbnail)

    struct GraphicsPlan: Equatable {
        struct Quote: Equatable { var text: String; var sentence: Int }
        var quotes: [Quote]
        var carouselTitle: String
        var carouselSlides: [String]
        var thumbnailHeadline: String
        var thumbnailSentence: Int
    }

    func composeGraphics(sentences: [(start: Double, end: Double, text: String)], kind: ContentKind = .current,
                         provider: AIProvider, apiKey: String) async throws -> GraphicsPlan {
        let prompt = """
You are a social media designer\(kind == .sermon ? " for a church" : ""). Below is the transcript of a \(kind.noun), one numbered sentence per line.
\(kind.promptContext)

Write content for still graphics:
1. "quotes": the 5 most shareable, stand-alone quotes. Use the speaker's own words (you may trim filler or join two adjacent sentences, but never invent). Each max 25 words, must make sense with no context. "sentence" = the index of the line it comes from.
2. "carousel": an Instagram carousel that teaches the heart of the message. "title" = a scroll-stopping hook (max 8 words). "slides" = 4–6 key points, each max 22 words, in the speaker's voice, building to the main truth. Do not include a final call-to-action slide.
3. "thumbnail": for the full \(kind.noun) video. "headline" = 2–5 bold words that create curiosity (not the \(kind.noun) title). "sentence" = index of a line where the speaker is likely most animated/emotional (a strong moment), used for the photo.

Transcript:
\(numbered(sentences))

Respond with ONLY valid JSON, no markdown:
{"quotes":[{"text":"...","sentence":12}],"carousel":{"title":"...","slides":["..."]},"thumbnail":{"headline":"...","sentence":40}}
"""
        var lastError: Error = llmError("AI returned no graphics")
        for _ in 1...2 {
            let text = try await ask(prompt, provider: provider, apiKey: apiKey)
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any] else {
                lastError = llmError("AI graphics weren't valid JSON"); continue
            }
            let clamp = { (i: Int?) in max(0, min(sentences.count - 1, i ?? 0)) }
            let quotes = (obj["quotes"] as? [[String: Any]] ?? []).compactMap { q -> GraphicsPlan.Quote? in
                guard let t = q["text"] as? String, !t.isEmpty else { return nil }
                return .init(text: t, sentence: clamp(q["sentence"] as? Int))
            }
            let car = obj["carousel"] as? [String: Any] ?? [:]
            let thumb = obj["thumbnail"] as? [String: Any] ?? [:]
            guard !quotes.isEmpty else { lastError = llmError("AI found no quotes"); continue }
            return GraphicsPlan(quotes: quotes,
                                carouselTitle: car["title"] as? String ?? "",
                                carouselSlides: car["slides"] as? [String] ?? [],
                                thumbnailHeadline: thumb["headline"] as? String ?? "",
                                thumbnailSentence: clamp(thumb["sentence"] as? Int))
        }
        throw lastError
    }

    /// A caption and hashtags for each reel, ready to paste into Instagram, TikTok or YouTube.
    /// `reels` is (title, what's said). Returns one SEO per reel, in order.
    func postCopy(reels: [(title: String, text: String)], videoTitle: String, kind: ContentKind,
                  provider: AIProvider, apiKey: String) async throws -> [ReelDraft.SEO] {
        let list = reels.enumerated().map { i, r in "[\(i)] \"\(r.title)\": \(r.text.prefix(1200))" }.joined(separator: "\n\n")
        let prompt = """
You write social posts for short videos cut from a \(kind.noun) called "\(videoTitle)". \(kind.promptContext)

For each reel below, write:
- "title": a YouTube Shorts title, max 70 characters, curiosity-driven but honest.
- "caption": an Instagram/TikTok caption: a first line that stops the scroll, 1–3 short lines that add to (not repeat) the video, then a gentle call to action. Max 450 characters. No hashtags in the caption.
- "hashtags": 5–8 relevant hashtags (with #), mixing broad and specific.
Use the speaker's own ideas; don't invent claims.

Reels:
\(list)

Respond with ONLY valid JSON, no markdown:
{"posts":[{"reel":0,"title":"...","caption":"...","hashtags":["#..."]}]}
"""
        var lastError: Error = llmError("AI returned no posts")
        for _ in 1...2 {
            let text = try await askLight(prompt, provider: provider, apiKey: apiKey)
            guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any],
                  let posts = obj["posts"] as? [[String: Any]] else { lastError = llmError("AI posts weren't valid JSON"); continue }
            var out = reels.map { ReelDraft.SEO(title: $0.title, description: "", hashtags: [], hookText: "") }
            for p in posts {
                guard let i = (p["reel"] as? Int) ?? (p["reel"] as? Double).map({ Int($0) }), out.indices.contains(i) else { continue }
                out[i] = .init(title: p["title"] as? String ?? reels[i].title, description: p["caption"] as? String ?? "",
                               hashtags: Self.hashtags(p["hashtags"]), hookText: "")
            }
            guard out.contains(where: { !$0.description.isEmpty }) else { lastError = llmError("AI posts came back empty"); continue }
            return out
        }
        throw lastError
    }

    /// Hashtags from a reply: an array, or one string of several (smaller models do that).
    static func hashtags(_ v: Any?) -> [String] {
        let raw = (v as? [String]) ?? (v as? String).map { [$0] } ?? []
        return raw.flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "," }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "#" }
            .map { $0.hasPrefix("#") ? $0 : "#" + $0 }
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
6. CLIFFHANGER: end on an open loop — a setup or question whose answer is NOT given, so they must go watch the full message. Never end on a full resolution, but never on hopelessness either: the open loop should point toward hope (\"But God…\", \"here's what changed everything\").

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
        let keywords = (obj["keywords"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return StoryPlan(title: (obj["title"] as? String) ?? "", ranges: ranges, hook: (obj["hook"] as? String) ?? "",
                         keywords: Array(keywords.prefix(8)))
    }

    // MARK: - Anthropic

    private func callAnthropic(prompt: String, apiKey: String) async throws -> String {
        do {
            return try await callAnthropic(prompt: prompt, apiKey: apiKey, model: "claude-haiku-5-5")
        } catch {
            // Keys/accounts that can't use Haiku 5.5 yet fall back to Haiku 4.5
            let msg = error.localizedDescription.lowercased()
            guard msg.contains("model") || msg.contains("not_found") || msg.contains("not found") else { throw error }
            return try await callAnthropic(prompt: prompt, apiKey: apiKey, model: "claude-haiku-4-5")
        }
    }

    private func callAnthropic(prompt: String, apiKey: String, model: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "messages": [["role": "user", "content": prompt]]
        ]
        // Haiku 5.5 thinks by default; low effort keeps it fast and cheap for clip picking
        if model == "claude-haiku-5-5" { body["output_config"] = ["effort": "low"] }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkHTTP(resp, data: data)
        // Thinking blocks may come before the answer, so take the text blocks
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw llmError("Unexpected Anthropic response")
        }
        if let u = json["usage"] as? [String: Any] {
            CostMeter.record(provider: "Claude", model: model, input: u["input_tokens"] as? Int ?? 0,
                             output: u["output_tokens"] as? Int ?? 0)
        }
        let text = blocks.filter { $0["type"] as? String == "text" }
                         .compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            if json["stop_reason"] as? String == "refusal" { throw llmError("Claude declined this request.") }
            throw llmError("Unexpected Anthropic response")
        }
        return text
    }

    // MARK: - OpenAI

    private func callOpenAI(prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "max_tokens": 4096,
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
        if let u = json["usage"] as? [String: Any] {
            CostMeter.record(provider: "OpenAI", model: "gpt-4o-mini", input: u["prompt_tokens"] as? Int ?? 0,
                             output: u["completion_tokens"] as? Int ?? 0)
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
        if let u = json["usageMetadata"] as? [String: Any] {
            // Thinking tokens are billed as output
            CostMeter.record(provider: "Gemini", model: model, input: u["promptTokenCount"] as? Int ?? 0,
                             output: (u["candidatesTokenCount"] as? Int ?? 0) + (u["thoughtsTokenCount"] as? Int ?? 0))
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
