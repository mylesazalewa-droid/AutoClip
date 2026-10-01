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

    private let modelDir: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/AutoClip/WhisperModels")
    }()

    private init() {}

    var modelExists: Bool {
        let modelPath = modelDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small.en")
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    func loadModel(progress: ((Double, String) -> Void)? = nil) async throws {
        await MainActor.run {
            isLoading = true
            loadProgress = 0
            statusMessage = "Loading model..."
        }

        let config = WhisperKitConfig(
            model: "openai_whisper-small.en",
            modelFolder: modelDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small.en").path,
            verbose: false
        )

        let kit = try await WhisperKit(config)

        await MainActor.run {
            self.whisper = kit
            self.isModelLoaded = true
            self.isLoading = false
            self.loadProgress = 1.0
            self.statusMessage = "Model ready"
        }
    }

    func downloadModel(progress: @escaping (Double, String) -> Void) async throws {
        await MainActor.run {
            isLoading = true
            statusMessage = "Downloading model..."
        }

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        _ = try await WhisperKit.download(
            variant: "openai_whisper-small.en",
            downloadBase: modelDir.appendingPathComponent("models"),
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
