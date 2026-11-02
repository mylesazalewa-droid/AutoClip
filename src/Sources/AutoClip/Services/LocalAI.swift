import Foundation

/// AI that runs on this Mac through Ollama (ollama.com): free and private, but smaller and
/// slower than the cloud models, so it only takes the simple jobs — hooks, post captions and
/// hashtags, topic lists. Picking the clips for a reel stays with the cloud model.
enum LocalAI {
    static let host = URL(string: "http://127.0.0.1:11434")!

    /// "Use this Mac for simple jobs"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "local_ai_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "local_ai_enabled") }
    }

    /// The Ollama model to use (empty = the best chat model installed)
    static var model: String {
        get { UserDefaults.standard.string(forKey: "local_ai_model") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "local_ai_model") }
    }

    /// Chat models installed in Ollama (embedding and vision-only models left out).
    static func installedModels() async -> [String]? {
        var req = URLRequest(url: host.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
            .filter { n in !["embed", "llava", "moondream", "bakllava", "minilm"].contains { n.contains($0) } }
    }

    /// The model to run, or nil when Ollama isn't running or has no chat model.
    static func resolvedModel() async -> String? {
        guard let models = await installedModels(), !models.isEmpty else { return nil }
        if !model.isEmpty, models.contains(model) { return model }
        let preferred = ["qwen3", "gemma3", "llama3.2", "llama3.1", "mistral", "phi"]
        for p in preferred { if let m = models.first(where: { $0.hasPrefix(p) }) { return m } }
        return models.first
    }

    /// True when simple jobs should go to this Mac.
    static func ready() async -> Bool {
        guard enabled else { return false }
        return await resolvedModel() != nil
    }

    /// Runs `prompt` and returns the reply (asked for as JSON).
    static func generate(_ prompt: String) async throws -> String {
        guard let model = await resolvedModel() else {
            throw NSError(domain: "LocalAI", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "On-device AI isn't running. Open Ollama (ollama.com) and install a model, e.g. “ollama pull llama3.2”."])
        }
        let body: [String: Any] = ["model": model, "prompt": prompt, "stream": false, "format": "json",
                                   "options": ["temperature": 0.4, "num_ctx": 8192]]
        var req = URLRequest(url: host.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 300
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String, !text.isEmpty else {
            throw NSError(domain: "LocalAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "On-device AI gave no answer."])
        }
        CostMeter.record(provider: "This Mac", model: model,
                         input: json["prompt_eval_count"] as? Int ?? 0, output: json["eval_count"] as? Int ?? 0)
        return text
    }
}
