import Foundation
import UserNotifications

/// Watches a YouTube channel (or playlist) and/or a folder. When a new video appears it is
/// downloaded, turned into reels with the user's usual Auto Reels settings and, if asked, made
/// into a content kit, so everything is waiting next time they open AutoClip.
/// Only videos that appear after watching starts are picked up (plus the latest one, if asked).
@MainActor
final class AutoImport: ObservableObject {
    static let shared = AutoImport()

    struct Settings: Codable, Equatable {
        var enabled = false
        var channel = ""
        var folder = ""
        var makeKit = true
        /// Where content kits go (empty = Documents/AutoClip/Content Kits)
        var kitFolder = ""
        var everyMinutes = 30
    }

    struct Event: Codable, Identifiable {
        var id = UUID()
        var date: Double
        var title: String
        var detail: String
        var ok: Bool
    }

    @Published var settings: Settings { didSet { if settings != oldValue { saveSettings() } } }
    @Published private(set) var log: [Event] = []
    @Published private(set) var status: String?
    @Published private(set) var lastCheck: Date?
    /// Video ids / file paths already handled
    private var seen: Set<String>
    private var timer: Timer?
    private var running = false

    private init() {
        let d = UserDefaults.standard
        settings = (d.data(forKey: "autoimport_settings")).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        seen = Set(d.stringArray(forKey: "autoimport_seen") ?? [])
        log = (d.data(forKey: "autoimport_log")).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "autoimport_settings") }
        schedule()
    }

    private func saveState() {
        UserDefaults.standard.set(Array(seen), forKey: "autoimport_seen")
        if let d = try? JSONEncoder().encode(Array(log.suffix(50))) { UserDefaults.standard.set(d, forKey: "autoimport_log") }
    }

    private func note(_ title: String, _ detail: String, ok: Bool) {
        log.append(Event(date: Date().timeIntervalSince1970, title: title, detail: detail, ok: ok))
        saveState()
    }

    var kitFolder: URL {
        if !settings.kitFolder.isEmpty { return URL(fileURLWithPath: settings.kitFolder) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Content Kits")
    }

    /// Called once at launch.
    func start() {
        schedule()
        if settings.enabled { Task { await check() } }
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard settings.enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(max(5, settings.everyMinutes)) * 60, repeats: true) { _ in
            Task { @MainActor in await AutoImport.shared.check() }
        }
    }

    // MARK: Finding new videos

    private static let videoTypes: Set<String> = ["mp4", "mov", "m4v", "mkv"]

    /// The newest uploads on the channel: (id, title), newest first.
    nonisolated static func latest(channel: String, count: Int = 5) async throws -> [(id: String, title: String)] {
        guard let ytdlp = YTDLP.executablePath() else { throw YTDLP.Failure(message: "yt-dlp not found. Install with: brew install yt-dlp") }
        var url = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        // A channel's home page lists shelves, not uploads
        if (url.contains("/@") || url.contains("/channel/") || url.contains("/c/")) && !url.contains("/videos")
            && !url.contains("/streams") && !url.contains("playlist") {
            url = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/videos"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = ["--flat-playlist", "--playlist-end", "\(count)", "--print", "%(id)s\t%(title)s", "--no-warnings", url]
        p.environment = YTDLP.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw YTDLP.Failure(message: "Couldn't read the channel: \(e.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
        }
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    private func newFiles() -> [URL] {
        guard !settings.folder.isEmpty else { return [] }
        let dir = URL(fileURLWithPath: settings.folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { f in
            guard Self.videoTypes.contains(f.pathExtension.lowercased()), !seen.contains(f.path) else { return false }
            // Still being copied in: wait until it hasn't changed for two minutes
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return Date().timeIntervalSince(m) > 120
        }
    }

    /// Marks everything there now as already handled, so only new videos are picked up.
    func markCurrentAsSeen() async {
        status = "Looking at what's there now…"
        if !settings.channel.isEmpty, let items = try? await Self.latest(channel: settings.channel, count: 15) {
            seen.formUnion(items.map(\.id))
        }
        if !settings.folder.isEmpty {
            let dir = URL(fileURLWithPath: settings.folder)
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where Self.videoTypes.contains(f.pathExtension.lowercased()) { seen.insert(f.path) }
        }
        saveState()
        status = nil
    }

    /// Forget the newest channel video so the next check makes reels from it.
    func doLatestNow() async {
        guard !settings.channel.isEmpty else { return }
        status = "Checking the channel…"
        if let first = try? await Self.latest(channel: settings.channel, count: 1).first { seen.remove(first.id); saveState() }
        status = nil
        await check()
    }

    // MARK: Running

    func check() async {
        guard settings.enabled, !running else { return }
        running = true
        defer { running = false; status = nil; lastCheck = Date() }
        if !settings.channel.isEmpty {
            status = "Checking the channel…"
            do {
                let items = try await Self.latest(channel: settings.channel)
                // Oldest new one first
                for item in items.reversed() where !seen.contains(item.id) {
                    seen.insert(item.id); saveState()
                    await process(title: item.title) {
                        try await YTDLP.download("https://www.youtube.com/watch?v=\(item.id)") { p, msg in
                            Task { @MainActor in AutoImport.shared.status = "“\(item.title)”: \(msg)" }
                            _ = p
                        }
                    }
                }
            } catch {
                note("Channel check failed", error.localizedDescription, ok: false)
            }
        }
        for f in newFiles() {
            seen.insert(f.path); saveState()
            await process(title: YTDLP.title(fromFile: f)) { f }
        }
    }

    private func process(title: String, fetch: () async throws -> URL) async {
        do {
            status = "Getting “\(title)”…"
            let url = try await fetch()
            status = "Making reels from “\(title)”…"
            let started = Date().timeIntervalSince1970
            let d = UserDefaults.standard
            let format = VideoExportService.ExportFormat(rawValue: d.string(forKey: "ar_format") ?? "") ?? .vertical9x16
            let provider = LLMClipService.AIProvider(rawValue: d.string(forKey: "ar_provider") ?? "") ?? .anthropic
            let key = await LLMClipService.shared.loadAPIKey(for: provider) ?? ""
            let useAI = (d.object(forKey: "ar_useAI") as? Bool ?? false) && !key.isEmpty
            let captions = d.object(forKey: "ar_captions") as? Bool ?? true
            let target = d.object(forKey: "ar_targetDur") as? Double ?? 90
            var params = AutoReelJobParams(videoURL: url, formatRaw: format.rawValue, captions: captions,
                                           captionStyleIndex: d.integer(forKey: "ar_captionIdx"), targetDuration: target,
                                           useAI: useAI, providerRaw: provider.rawValue,
                                           desiredReelCount: d.integer(forKey: "ar_reelCount"), storylineModeRaw: nil,
                                           topic: "", crossDissolve: d.bool(forKey: "ar_dissolve"),
                                           emojiOverlays: d.bool(forKey: "ar_emoji"),
                                           outputDir: URL(fileURLWithPath: d.string(forKey: "ar_lastOutputDir") ?? NSHomeDirectory()),
                                           singleClip: d.bool(forKey: "ar_singleClip"))
            params.sourceTitle = title
            let p = params
            let jobID = UUID()
            let task = Task.detached(priority: .utility) {
                await ReelPipeline.run(jobID: jobID, videoURL: p.videoURL, format: format, captions: p.captions,
                                       styleIdx: p.captionStyleIndex, targetDur: p.targetDuration, useAI: p.useAI,
                                       provider: provider, apiKey: key, desiredReelCount: p.desiredReelCount,
                                       topic: "", crossDissolve: p.crossDissolve, emojiOverlays: p.emojiOverlays,
                                       outputDir: p.outputDir, retryParams: p)
            }
            AutoReelsStore.shared.registerTask(task, for: jobID)
            await task.value
            guard let rec = AutoReelsStore.shared.reels.first(where: { $0.dateCreated >= started && $0.genParams?.sourceTitle == title }) else {
                let err = AutoReelsStore.shared.activeJobs.first { $0.id == jobID }?.error
                note(title, err ?? "Couldn't make reels.", ok: false)
                notify("Auto-import couldn't finish", "\(title): \(err ?? "no reels were made")")
                return
            }
            var detail = "\(rec.drafts?.count ?? 0) reels ready"
            if settings.makeKit, !(rec.drafts ?? []).isEmpty {
                status = "Building the content kit for “\(title)”…"
                try? FileManager.default.createDirectory(at: kitFolder, withIntermediateDirectories: true)
                do {
                    let r = try await ContentKit.build(record: rec, in: kitFolder, options: ContentKit.Options()) { msg in
                        AutoImport.shared.status = "“\(title)”: \(msg)"
                    }
                    if !r.seo.isEmpty, var latest = AutoReelsStore.shared.reels.first(where: { $0.id == rec.id }) {
                        latest.drafts = latest.drafts?.map { d in var d = d; if let s = r.seo[d.id], d.seo == nil { d.seo = s }; return d }
                        AutoReelsStore.shared.update(latest)
                    }
                    detail += ", content kit in \(r.folder.lastPathComponent)"
                } catch { detail += ", but the content kit failed: \(error.localizedDescription)" }
            }
            note(title, detail, ok: true)
            notify("New reels ready", "\(title): \(detail)")
        } catch {
            note(title, error.localizedDescription, ok: false)
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title; n.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }
}
