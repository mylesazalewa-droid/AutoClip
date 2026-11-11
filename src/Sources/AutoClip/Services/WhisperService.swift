import Foundation
import WhisperKit
import AVFoundation

class WhisperService: ObservableObject {
    static let shared = WhisperService()

    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var loadProgress: Double = 0
    @Published var statusMessage = ""

    private var whisper: WhisperKit?
    private var loadedVariant: String?

    private let modelDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/AutoClip/WhisperModels")
    }()

    private init() {}

    static let modelSizes: [(key: String, label: String, mb: Int)] = [
        ("tiny",   "Tiny — fastest, ~39 MB",      39),
        ("base",   "Base — fast, ~74 MB",          74),
        ("small",  "Small — balanced, ~244 MB",   244),
        ("medium", "Medium — accurate, ~769 MB",  769)
    ]

    var selectedVariant: String {
        let size = UserDefaults.standard.string(forKey: "whisper_model_size") ?? "small"
        return "openai_whisper-\(size).en"
    }

    /// Where the model's files are. Older versions saved one "models" folder too deep, so both places are checked.
    private func modelFolder(_ variant: String) -> URL? {
        let tail = "argmaxinc/whisperkit-coreml/\(variant)"
        let places = [
            modelDir.appendingPathComponent("models/\(tail)"),
            modelDir.appendingPathComponent("models/models/\(tail)"),
            modelDir.appendingPathComponent(tail)
        ]
        return places.first { Self.isComplete($0) }
    }

    /// A model folder is usable once its three parts are there (a stopped download can leave some out).
    private static func isComplete(_ url: URL) -> Bool {
        ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    var modelExists: Bool { modelFolder(selectedVariant) != nil }

    /// Where the speech engine keeps its small word list (the "tokenizer"). Older versions used
    /// ~/Documents/huggingface, so that is kept when it's already there. Otherwise it lives with
    /// the model, and its folder is made first: the engine's own download fails on a new Mac
    /// when the folder isn't there yet.
    private func tokenizerBase(for variant: String) throws -> URL {
        let repo = "models/" + variant.replacingOccurrences(of: "openai_", with: "openai/")
        let old = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/huggingface")
        if FileManager.default.fileExists(atPath: old.appendingPathComponent("\(repo)/tokenizer.json").path) { return old }
        let folder = modelDir.appendingPathComponent(repo)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A half-finished earlier try can leave pieces behind that block the next one
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".incomplete") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(f))
        }
        return modelDir
    }

    func loadModel(progress: ((Double, String) -> Void)? = nil) async throws {
        let variant = selectedVariant
        await MainActor.run {
            isLoading = true
            loadProgress = 0
            statusMessage = "Loading model..."
        }

        guard let folder = modelFolder(variant) else {
            await MainActor.run { isLoading = false; statusMessage = "" }
            throw NSError(domain: "WhisperService", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The speech model didn't finish downloading. Check the internet connection and press Download again."])
        }
        var config = WhisperKitConfig(
            model: variant,
            modelFolder: folder.path,
            tokenizerFolder: try tokenizerBase(for: variant),
            verbose: false
        )

        let kit: WhisperKit
        do { kit = try await WhisperKit(config) }
        catch {
            // One more try: a dropped connection while fetching the word list is the usual cause
            do {
                config.tokenizerFolder = try tokenizerBase(for: variant)
                kit = try await WhisperKit(config)
            } catch {
                await MainActor.run { isLoading = false; statusMessage = "" }
                throw NSError(domain: "WhisperService", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "The speech model couldn't finish setting up (\(error.localizedDescription)). Check the internet connection and try again."])
            }
        }

        await MainActor.run {
            self.whisper = kit
            self.loadedVariant = variant
            self.isModelLoaded = true
            self.isLoading = false
            self.loadProgress = 1.0
            self.statusMessage = "Model ready"
        }
    }

    func downloadModel(progress: @escaping (Double, String) -> Void) async throws {
        let variant = selectedVariant
        await MainActor.run {
            isLoading = true
            statusMessage = "Downloading model..."
        }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: modelDir,
            useBackgroundSession: false
        ) { prog in
            DispatchQueue.main.async {
                progress(prog.fractionCompleted, "Downloading: \(Int(prog.fractionCompleted * 100))%")
            }
        }

        await MainActor.run {
            self.isLoading = false
            self.statusMessage = "Download complete"
        }

        try await loadModel(progress: progress)
    }

    func invalidateIfVariantChanged() {
        if isModelLoaded, let loaded = loadedVariant, loaded != selectedVariant {
            whisper = nil
            isModelLoaded = false
            loadedVariant = nil
        }
    }

    func transcribe(audioURL: URL, progress: ((Double) -> Void)? = nil) async throws -> [Word] {
        guard let whisper else {
            throw NSError(domain: "WhisperService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            wordTimestamps: true
        )

        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)

        var words: [Word] = []
        for result in results {
            for segment in result.segments {
                guard let wordTimings = segment.words else { continue }
                for wt in wordTimings {
                    let text = wt.word.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty,
                          !text.hasPrefix("<|"),
                          !text.hasSuffix("|>") else { continue }
                    words.append(Word(
                        id: UUID(),
                        word: text,
                        startTime: Double(wt.start),
                        endTime: Double(wt.end),
                        confidence: Double(wt.probability)
                    ))
                }
            }
        }

        return words
    }
}
