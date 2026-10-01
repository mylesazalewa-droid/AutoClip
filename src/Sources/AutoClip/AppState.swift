import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedProject: Project?
    @Published var selectedClip: Clip?
    @Published var showOnboarding: Bool
    @Published var isAnalyzing = false
    @Published var overlayVisible = false   // false = running in background, overlay hidden
    @Published var analyzeProgress: Double = 0
    @Published var analyzeStatus = ""
    @Published var showYouTubeSheet = false
    @Published var errorMessage: String?
    @Published var showError = false

    private let whisper = WhisperService.shared
    private let library = LibraryService.shared
    private let ai = AIService.shared

    private init() {
        showOnboarding = !WhisperService.shared.modelExists
    }

    func triggerImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.allowsMultipleSelection = false
        panel.message = "Select a video to analyze"
        panel.prompt = "Import"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.importVideo(url)
        }
    }

    func importVideo(_ url: URL) {
        isAnalyzing = true
        overlayVisible = true
        analyzeProgress = 0
        analyzeStatus = "Preparing..."

        library.importVideoFile(url, progress: { p, msg in
            DispatchQueue.main.async {
                self.analyzeProgress = p * 0.1
                self.analyzeStatus = msg
            }
        }) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    self.isAnalyzing = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            case .success(let project):
                self.analyzeVideo(project: project)
            }
        }
    }

    private func analyzeVideo(project: Project) {
        Task {
            do {
                await MainActor.run {
                    self.analyzeProgress = 0.10
                    self.analyzeStatus = "Checking video file..."
                }

                let videoPath = project.videoPath
                guard FileManager.default.fileExists(atPath: videoPath) else {
                    throw NSError(domain: "AutoClip", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Video file not found at: \(videoPath)\n\nThe original file may have been moved or deleted."
                    ])
                }

                await MainActor.run {
                    self.analyzeProgress = 0.15
                    self.analyzeStatus = "Loading AI model..."
                }

                if !whisper.isModelLoaded {
                    try await whisper.loadModel()
                }

                await MainActor.run {
                    self.analyzeProgress = 0.25
                    self.analyzeStatus = "Transcribing audio..."
                }

                let audioURL = URL(fileURLWithPath: videoPath)
                let words = try await whisper.transcribe(audioURL: audioURL) { p in
                    DispatchQueue.main.async {
                        self.analyzeProgress = 0.25 + p * 0.45
                        self.analyzeStatus = "Transcribing: \(Int(p * 100))%"
                    }
                }

                guard !words.isEmpty else {
                    throw NSError(domain: "AutoClip", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "No speech detected in the video. Make sure the video has clear audio and try again."
                    ])
                }

                await MainActor.run {
                    self.analyzeProgress = 0.7
                    self.analyzeStatus = "Analyzing clips..."
                }

                let videoURL = URL(fileURLWithPath: project.videoPath)
                let clips = await ai.generateClips(from: words, videoDuration: project.duration, videoURL: videoURL) { p, msg in
                    DispatchQueue.main.async {
                        self.analyzeProgress = 0.7 + p * 0.25
                        self.analyzeStatus = msg
                    }
                }

                await MainActor.run {
                    var updated = project
                    updated.clips = clips
                    updated.clipCount = clips.count
                    self.library.updateProject(updated)
                    self.selectedProject = updated
                    self.isAnalyzing = false
                    self.overlayVisible = false
                    self.analyzeProgress = 1.0
                    self.analyzeStatus = "Done"
                }

            } catch {
                await MainActor.run {
                    self.isAnalyzing = false
                    self.overlayVisible = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    func reanalyzeProject(_ project: Project) {
        isAnalyzing = true
        overlayVisible = true
        analyzeProgress = 0
        analyzeStatus = "Preparing..."
        selectedProject = project
        analyzeVideo(project: project)
    }
}
