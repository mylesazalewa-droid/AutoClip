import Foundation
import AppKit
import AVFoundation

class LibraryService: ObservableObject {
    static let shared = LibraryService()

    @Published var projects: [Project] = []
    @Published var exportHistory: [ExportRecord] = []

    private let libraryURL: URL
    private let historyURL: URL

    private init() {
        let appDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/AutoClip")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        libraryURL = appDir.appendingPathComponent("library.json")
        historyURL = appDir.appendingPathComponent("history.json")
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: libraryURL),
           let loaded = try? JSONDecoder().decode([Project].self, from: data) {
            self.projects = loaded.map { proj in
                var p = proj
                p.clips = proj.clips.map { clip in
                    var c = clip
                    if looksGarbled(c.title) && !c.words.isEmpty {
                        c.title = AIService.shared.generateTitle(fromWords: c.words)
                    }
                    return c
                }
                return p
            }
            save() // persist fixed titles
        }
        if let data = try? Data(contentsOf: historyURL),
           let history = try? JSONDecoder().decode([ExportRecord].self, from: data) {
            self.exportHistory = history
        }
    }

    private func looksGarbled(_ title: String) -> Bool {
        let lower = title.lowercased()
        let garbledMarkers = ["gonna", "gotta", "wanna", "they're and", "that's and", "i'm and", "you're and", "it's and"]
        return garbledMarkers.contains(where: { lower.contains($0) })
    }

    func save() {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: libraryURL)
        }
        if let data = try? JSONEncoder().encode(exportHistory) {
            try? data.write(to: historyURL)
        }
    }

    func addProject(_ project: Project) {
        projects.insert(project, at: 0)
        save()
    }

    func updateProject(_ project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
            save()
        }
    }

    func deleteProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    func updateClip(_ clip: Clip, in project: Project) {
        guard let pi = projects.firstIndex(where: { $0.id == project.id }),
              let ci = projects[pi].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        projects[pi].clips[ci] = clip
        save()
    }

    func addExportRecord(_ record: ExportRecord) {
        exportHistory.insert(record, at: 0)
        save()
    }

    // MARK: - Video Import

    func importVideoFile(_ url: URL, progress: @escaping (Double, String) -> Void, completion: @escaping (Result<Project, Error>) -> Void) {
        let videosDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/AutoClip/Videos")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

        let destID = UUID()
        let destURL = videosDir.appendingPathComponent("\(destID.uuidString).mp4")

        progress(0.05, "Copying video...")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.copyItem(at: url, to: destURL)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let asset = AVURLAsset(url: destURL)
            let duration = asset.duration.seconds
            let title = url.deletingPathExtension().lastPathComponent

            DispatchQueue.main.async {
                progress(0.15, "Generating thumbnail...")
            }

            let thumbnail = self.generateThumbnail(from: destURL)
            let thumbnailData = thumbnail?.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }.map { $0.base64EncodedString() }

            var project = Project(
                id: destID,
                title: title,
                videoPath: destURL.path,
                duration: duration,
                dateCreated: Date().timeIntervalSinceReferenceDate,
                clipCount: 0,
                thumbnailData: thumbnailData,
                clips: []
            )

            DispatchQueue.main.async {
                self.projects.insert(project, at: 0)
                self.save()
                completion(.success(project))
            }
        }
    }

    private func generateThumbnail(from url: URL, at time: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600)) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)
        guard let cgImage = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
