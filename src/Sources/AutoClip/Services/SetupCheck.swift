import Foundation
import AVFoundation
import AppKit

/// Settings → General → "Check setup": goes through everything AutoClip needs on this Mac and
/// says, for each part, whether it works and what to do when it doesn't. Spends no AI credits.
@MainActor
final class SetupCheck: ObservableObject {
    static let shared = SetupCheck()

    enum State { case waiting, checking, good, warning, problem }

    struct Item: Identifiable {
        let id: String
        let title: String
        var state: State = .waiting
        var detail = ""
        /// What to do about it, when something's wrong
        var fix: Fix?
    }

    enum Fix: Equatable {
        case downloadModel
        case openAISettings
        case copy(String)
        case openURL(String)
        case getYouTubeTools
    }

    @Published var items: [Item] = []
    @Published var running = false
    @Published var lastRun: Date?

    var summary: String {
        if running { return "Checking…" }
        guard lastRun != nil else { return "Not checked yet" }
        let bad = items.filter { $0.state == .problem }.count
        let warn = items.filter { $0.state == .warning }.count
        if bad > 0 { return "\(bad) thing\(bad == 1 ? "" : "s") to fix" }
        if warn > 0 { return "Working. \(warn) optional thing\(warn == 1 ? "" : "s") to look at" }
        return "Everything is installed and working"
    }

    private static let steps: [(String, String)] = [
        ("app", "AutoClip"),
        ("folder", "AutoClip folder"),
        ("space", "Free space"),
        ("model", "Speech model"),
        ("engine", "Speech engine"),
        ("listen", "Turning speech into text"),
        ("export", "Making videos"),
        ("youtube", "YouTube links"),
        ("ffmpeg", "ffmpeg (optional)"),
        ("music", "Background music"),
        ("ai", "AI writing")
    ]

    func run() {
        guard !running else { return }
        running = true
        items = Self.steps.map { Item(id: $0.0, title: $0.1) }
        Task {
            await check("app") { _ in
                (.good, "Version \(AppInfo.version), on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", nil)
            }
            await check("folder") { _ in Self.folderCheck() }
            await check("space") { _ in Self.spaceCheck() }
            await check("model") { _ in
                WhisperService.shared.modelExists
                    ? (.good, "Downloaded and complete", nil)
                    : (.problem, "Not downloaded yet, or the download didn't finish. AutoClip needs it to turn sermons into text.", .downloadModel)
            }
            await check("engine") { _ in await Self.engineCheck() }
            await check("listen") { [weak self] _ in
                guard self?.items.first(where: { $0.id == "engine" })?.state == .good else {
                    return (.problem, "Skipped until the speech engine starts.", nil)
                }
                return await Self.listenCheck()
            }
            await check("export") { _ in await Self.exportCheck() }
            await check("youtube") { _ in await Self.youtubeCheck() }
            await check("ffmpeg") { _ in await Task.detached {
                YTDLP.ffmpegPath() == nil
                    ? (.good, "Not installed, and not needed: AutoClip puts YouTube video and sound together itself.", nil)
                    : Self.toolCheck(path: YTDLP.ffmpegPath(), name: "ffmpeg", need: "") }.value }
            await check("music") { _ in Self.musicCheck() }
            await check("ai") { _ in await Self.aiCheck() }
            running = false
            lastRun = Date()
        }
    }

    private func check(_ id: String, _ work: @escaping (SetupCheck?) async -> (State, String, Fix?)) async {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .checking
        let (state, detail, fix) = await work(self)
        items[i].state = state
        items[i].detail = detail
        items[i].fix = fix
    }

    // MARK: - The checks

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    private static func folderCheck() -> (State, String, Fix?) {
        let dir = AppPaths.root
        let probe = dir.appendingPathComponent(".setup-check")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return (.good, AppPaths.root == AppPaths.support ? "AutoClip can save its files (in its own folder, which needs no permission)" : "AutoClip can save to Documents → AutoClip", nil)
        } catch {
            return (.problem, "AutoClip can't save to Documents → AutoClip. Open System Settings → Privacy & Security → Files and Folders and allow AutoClip to use Documents.",
                    .openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"))
        }
    }

    private static func spaceCheck() -> (State, String, Fix?) {
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gb = Double(free) / 1_000_000_000
        let text = String(format: "%.0f GB free", gb)
        if gb < 5 { return (.problem, "\(text). A sermon and its clips can take several GB. Free some space, or use Storage in the sidebar to clear old messages.", nil) }
        if gb < 20 { return (.warning, "\(text). Enough for now, but sermons add up. Storage in the sidebar shows what can go.", nil) }
        return (.good, text, nil)
    }

    private static func engineCheck() async -> (State, String, Fix?) {
        let w = WhisperService.shared
        guard w.modelExists else { return (.problem, "Skipped until the speech model is downloaded.", .downloadModel) }
        if w.isModelLoaded { return (.good, "Running", nil) }
        do {
            try await w.loadModel()
            return (.good, "Starts and is ready", nil)
        } catch {
            return (.problem, "Couldn't start: \(error.localizedDescription)", .downloadModel)
        }
    }

    /// Turns 8 seconds of the built-in sample sermon into text.
    private static func listenCheck() async -> (State, String, Fix?) {
        guard let src = Bundle.main.url(forResource: "sample-sermon", withExtension: "mp4") else {
            return (.warning, "The sample video isn't in this copy of AutoClip, so this couldn't be tried.", nil)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("autoclip-check-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        let asset = AVURLAsset(url: src)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return (.problem, "Couldn't read the sample's sound.", nil)
        }
        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), duration: CMTime(seconds: 8, preferredTimescale: 600))
        await session.export()
        guard session.status == .completed else {
            return (.problem, "Couldn't read the sample's sound: \(session.error?.localizedDescription ?? "unknown")", nil)
        }
        do {
            let words = try await WhisperService.shared.transcribe(audioURL: out)
            guard !words.isEmpty else { return (.problem, "The speech engine ran but heard no words in the sample.", .downloadModel) }
            let heard = words.prefix(8).map(\.word).joined(separator: " ")
            return (.good, "Heard: “\(heard)…”", nil)
        } catch {
            return (.problem, "Couldn't turn the sample into text: \(error.localizedDescription)", nil)
        }
    }

    /// Crops one second of the sample into a vertical video, the same way clips are made.
    private static func exportCheck() async -> (State, String, Fix?) {
        guard let src = Bundle.main.url(forResource: "sample-sermon", withExtension: "mp4") else {
            return (.warning, "The sample video isn't in this copy of AutoClip, so this couldn't be tried.", nil)
        }
        let asset = AVURLAsset(url: src)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else {
            return (.problem, "Couldn't open the sample video.", nil)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("autoclip-check-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let render = CGSize(width: 540, height: 960)
        let scale = render.height / size.height
        let vc = AVMutableVideoComposition()
        vc.renderSize = render
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        li.setTransform(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: (render.width - size.width * scale) / 2, y: 0)), at: .zero)
        ins.layerInstructions = [li]
        vc.instructions = [ins]
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else {
            return (.problem, "This Mac can't start a video export.", nil)
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.timeRange = ins.timeRange
        session.videoComposition = vc
        await session.export()
        guard session.status == .completed else {
            return (.problem, "A test clip couldn't be made: \(session.error?.localizedDescription ?? "unknown"). Restart the Mac and check again.", nil)
        }
        return (.good, "A test vertical clip was made and removed", nil)
    }

    nonisolated private static func toolCheck(path: String?, name: String, need: String) -> (State, String, Fix?) {
        guard let path else {
            return (.warning, "\(name) isn't installed. \(need) To add it, install Homebrew (brew.sh), then run this in Terminal:", .copy("brew install \(name)"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [name == "ffmpeg" ? "-version" : "--version"]
        p.environment = YTDLP.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch {
            return (.problem, "\(name) is at \(path) but won't run: \(error.localizedDescription)", .copy("brew reinstall \(name)"))
        }
        p.waitUntilExit()
        let first = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").first.map(String.init) ?? ""
        guard p.terminationStatus == 0 else {
            return (.problem, "\(name) is installed but doesn't run properly.", .copy("brew reinstall \(name)"))
        }
        let version = name == "ffmpeg" ? (first.split(separator: " ").dropFirst(2).first.map(String.init) ?? "") : first
        return (.good, "Installed\(version.isEmpty ? "" : " (\(version))")", nil)
    }

    private static func youtubeCheck() async -> (State, String, Fix?) {
        guard YouTubeTools.installed else {
            return (.warning, "AutoClip gets its own YouTube downloader the first time you paste a link (about 80 MB). You can get it now.", .getYouTubeTools)
        }
        let (yt, deno) = await Task.detached { (YouTubeTools.version(of: YouTubeTools.ytdlp), YouTubeTools.version(of: YouTubeTools.deno)) }.value
        guard let yt, let deno else {
            return (.problem, "AutoClip's YouTube downloader is there but won't start. Get it again.", .getYouTubeTools)
        }
        return (.good, "Ready (downloader \(yt), helper \(deno)). It updates itself.", nil)
    }

    private static func musicCheck() -> (State, String, Fix?) {
        guard let a = AudioSettings.load(), let path = a.musicPath else { return (.good, "No song chosen", nil) }
        let name = a.musicName ?? "the song"
        guard let url = AudioSettings.readableMusic(path) else {
            return (.problem, "AutoClip can't open “\(name)”, so clips would export without it. Choose the song again in a clip's Audio tab.", nil)
        }
        if url.path != path {
            var b = a; b.musicPath = url.path; b.save()
            return (.good, "“\(name)” is ready. A copy now lives in Documents → AutoClip → Music.", nil)
        }
        return (.good, "“\(name)” is ready", nil)
    }

    /// Only whether a key is saved. It's never read out, and nothing is sent.
    private static func aiCheck() async -> (State, String, Fix?) {
        let provider = LLMClipService.chosenProvider
        let key = (await LLMClipService.shared.loadAPIKey(for: provider)) ?? ""
        if key == LLMClipService.includedAIKey {
            return (.good, "AutoClip AI is included. Titles, captions and graphics can be written.", nil)
        }
        if !key.isEmpty, provider == .anthropic {
            // Listing models is free, so this proves the key works without spending credits
            if let problem = await LLMClipService.shared.checkAnthropicKey(key) {
                return (.problem, "The Claude key didn't work: \(problem)", .openAISettings)
            }
            return (.good, "The Claude key works. Titles, captions and graphics can be written. (Checked for free.)", nil)
        }
        if !key.isEmpty { return (.good, "A \(provider.rawValue) key is saved. Titles, captions and graphics can be written.", nil) }
        return (.warning, "No AI key saved. Clips are still made on this Mac; writing titles, captions and graphics needs a key.", .openAISettings)
    }
}
