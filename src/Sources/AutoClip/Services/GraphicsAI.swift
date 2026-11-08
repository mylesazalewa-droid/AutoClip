import Foundation
import AppKit

/// AI pictures for social graphics. Google's image model (Nano Banana) paints the background
/// only, with no words in it; the text, stickers and drawings stay as separate layers on top,
/// so everything remains editable. Uses the church's own Google key (or OpenAI's as a fallback).
enum GraphicsAI {
    enum Scene: String, CaseIterable, Identifiable {
        case auto, nature, sky, texture, abstract, collage, people, season
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Match the message"
            case .nature: return "Nature"
            case .sky: return "Sky and light"
            case .texture: return "Paper and texture"
            case .abstract: return "Abstract shapes"
            case .collage: return "Retro collage"
            case .people: return "People (no faces)"
            case .season: return "This season"
            }
        }
        var prompt: String {
            switch self {
            case .auto: return "a scene or object that captures the message's main image or metaphor"
            case .nature: return "a natural landscape, forest, water or mountains"
            case .sky: return "a dramatic sky, clouds and light"
            case .texture: return "a close-up texture such as worn paper, plaster, fabric or painted wood"
            case .abstract: return "bold abstract shapes and organic forms"
            case .collage: return "a retro cut-paper collage with torn paper, halftone dots and a cut-out photographic object"
            case .people: return "people seen from behind or in silhouette, faces not visible"
            case .season:
                let m = Calendar.current.component(.month, from: Date())
                switch m {
                case 12: return "Christmas: evergreen branches, warm lights, winter"
                case 1, 2: return "winter, a fresh start, quiet snow"
                case 3, 4: return "spring and Easter: morning light, new growth, an empty hillside"
                case 5, 6, 7, 8: return "summer: sun, fields, water"
                default: return "autumn: warm leaves, golden light"
                }
            }
        }
    }

    private static func mood(_ s: SermonCarousel.Style) -> String {
        switch s {
        case .bold: return "dramatic, high-contrast, dark and moody photography"
        case .poster: return "retro screen-printed poster look, flat bold shapes, visible paper grain"
        case .editorial: return "calm editorial photography, soft natural light, muted warm tones"
        case .photo: return "cinematic photography, shallow depth of field"
        case .color: return "flat graphic illustration in a limited palette"
        case .minimal: return "minimal, airy, lots of clean empty space, soft light"
        case .gradient: return "abstract glowing light and soft gradients"
        case .split: return "crisp documentary photography"
        case .film: return "35mm film photography, visible grain, warm vintage tones"
        }
    }

    /// The words sent to the image model. Shown to the user, who can change them.
    static func prompt(for s: SermonCarousel.Slide, in c: SermonCarousel, scene: Scene) -> String {
        let room = s.kind == .cover || c.style == .photo ? "the lower half" : "the centre"
        return """
        A background image for a church's Instagram post. The post says: "\(s.headline)".
        Show \(scene.prompt). Visual style: \(mood(c.style)). Lean on the colour #\(c.accentHex) where it fits.
        Keep \(room) calm and uncluttered so large text can sit on top.
        Absolutely no text, letters, words, numbers, logos, signatures or watermarks anywhere in the image.
        """
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Makes an image and saves it with AutoClip's graphics. Returns its path.
    static func generate(prompt: String, ratio: String) async throws -> String {
        let google = await LLMClipService.shared.loadAPIKey(for: .google) ?? ""
        let openai = await LLMClipService.shared.loadAPIKey(for: .openai) ?? ""
        let data: Data
        if !google.isEmpty {
            data = try await googleImage(prompt: prompt, ratio: ratio, key: google)
        } else if !openai.isEmpty {
            data = try await openAIImage(prompt: prompt, ratio: ratio, key: openai)
        } else {
            throw Failure(message: "AI pictures need a Google (Gemini) key, or an OpenAI key. Add one in AutoClip → Settings → AI.")
        }
        return try save(data)
    }

    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Graphics Art")
    }

    static func save(_ data: Data) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = data.starts(with: [0x89, 0x50]) ? "png" : "jpg"
        let url = folder.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url.path
    }

    /// Copies a photo the user chose, so it stays if the original moves.
    static func importPhoto(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return nil }
        return try? save(data)
    }

    // MARK: Google

    private static func googleImage(prompt: String, ratio: String, key: String) async throws -> Data {
        // Current Interactions API first (Nano Banana 2.1), then the older generateContent call
        do {
            return try await interactions(prompt: prompt, ratio: ratio, key: key, model: "gemini-nano-banana-2.1")
        } catch let first {
            do {
                return try await generateContent(prompt: prompt, ratio: ratio, key: key, model: "gemini-3.1-flash-image")
            } catch {
                do { return try await generateContent(prompt: prompt, ratio: ratio, key: key, model: "gemini-2.5-flash-image") }
                catch { throw first }
            }
        }
    }

    private static func interactions(prompt: String, ratio: String, key: String, model: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": model,
            "input": [["type": "text", "text": prompt]],
            "response_format": ["type": "image", "mime_type": "image/png", "aspect_ratio": ratio, "image_size": "2K"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func generateContent(prompt: String, ratio: String, key: String, model: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["responseModalities": ["IMAGE"], "imageConfig": ["aspectRatio": ratio]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    // MARK: OpenAI

    private static func openAIImage(prompt: String, ratio: String, key: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        let size = ratio == "1:1" ? "1024x1024" : "1024x1536"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-image-1", "prompt": prompt, "size": size, "n": 1])
        return try await send(req)
    }

    // MARK: Reading the answer

    private static func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else {
            let msg = (json as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw Failure(message: "The image service said no (\(code))\(msg.map { ": " + $0 } ?? ".")")
        }
        guard let json, let b64 = findImage(json), let img = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              NSImage(data: img) != nil else {
            throw Failure(message: "The image service didn't send back a picture. Try a different description.")
        }
        return img
    }

    /// The image wherever it sits in the reply: Google's `inlineData.data`, the Interactions
    /// API's image `data`, or OpenAI's `b64_json`. Picks the longest base64 string under those keys.
    static func findImage(_ any: Any) -> String? {
        var best: String?
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                for (k, val) in d {
                    if ["data", "b64_json", "bytes"].contains(k), let s = val as? String, s.count > 2000 {
                        if s.count > (best?.count ?? 0) { best = s }
                    } else {
                        walk(val)
                    }
                }
            } else if let a = v as? [Any] {
                a.forEach(walk)
            }
        }
        walk(any)
        return best
    }

    // MARK: Rewriting one slide

    enum Rewrite: String, CaseIterable, Identifiable {
        case shorter, punchier, warmer, again
        var id: String { rawValue }
        var label: String {
            switch self {
            case .shorter: return "Shorter"
            case .punchier: return "Punchier"
            case .warmer: return "Warmer"
            case .again: return "Try again"
            }
        }
        var ask: String {
            switch self {
            case .shorter: return "Make it noticeably shorter while keeping the meaning."
            case .punchier: return "Make it punchier and more scroll-stopping, without hype or clickbait."
            case .warmer: return "Make it warmer and more personal, like a pastor talking to one person."
            case .again: return "Write a fresh alternative that says the same thing a different way."
            }
        }
    }

    /// Rewrites one slide's words with a small AI request. Not for quotes or Scripture, whose words aren't ours to change.
    static func rewrite(_ s: SermonCarousel.Slide, how: Rewrite, title: String) async throws -> SermonCarousel.Slide {
        let prompt = """
        You edit one slide of an Instagram post made from a church message called "\(title)".
        Slide type: \(s.kind.label). Headline: "\(s.headline)". Supporting text: "\(s.body)".
        \(how.ask) Keep the headline under 12 words and the supporting text under 28 words (leave it empty if it was empty). No emojis.
        Respond with ONLY JSON: {"headline":"...","emphasis":"1 to 3 words copied exactly from the new headline","body":"..."}
        """
        let reply = try await LLMClipService.shared.complete(prompt, light: true)
        guard let obj = SermonCarousel.jsonObject(reply), let h = obj["headline"] as? String, !h.isEmpty else {
            throw Failure(message: "AI didn't return a rewrite. Try again.")
        }
        var out = s
        out.headline = h.trimmingCharacters(in: .whitespacesAndNewlines)
        out.emphasis = (obj["emphasis"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.body.isEmpty || !(obj["body"] as? String ?? "").isEmpty { out.body = (obj["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return out
    }
}
