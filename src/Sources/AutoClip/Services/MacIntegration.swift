import AppKit
import SwiftUI
import Combine
import UserNotifications
import AVFoundation
import TipKit

/// What macOS hands AutoClip directly: files opened from Finder or dropped on the Dock icon,
/// the right-click service, and taps on notifications.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider.shared
        // Use the icon in this copy of the app, not one macOS cached from an older version
        if let url = (Bundle.main.url(forResource: "AutoClipIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns")), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
        if UserDefaults.standard.bool(forKey: "tips_reset") {
            try? Tips.resetDatastore()
            UserDefaults.standard.set(false, forKey: "tips_reset")
        }
        try? Tips.configure([.displayFrequency(.immediate)])
        Task { @MainActor in
            DockStatus.shared.start()
            ReviewStore.shared.startIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Reopen.quitting = true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in IncomingVideos.handle(urls) }
    }

    // While AutoClip is in front, its own screens say it all
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["record"] as? String
        let page = response.notification.request.content.userInfo["page"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if page == "social" {
                HomeNav.shared.open(.social)
            } else if page == "approvals" {
                HomeNav.shared.open(.approvals)
            } else if let raw, let id = UUID(uuidString: raw) {
                if response.actionIdentifier == Notifier.reviewAction { AutoReelsStore.shared.reviewOnOpen = id }
                if let open = CommandBar.shared.openReel { open(id) }
            }
            completionHandler()
        }
    }
}

/// Right-click a video in Finder → Services (or Quick Actions) → Make Clips with AutoClip.
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    @objc func makeClips(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { error.pointee = "Choose a video or audio file." as NSString; return }
        Task { @MainActor in IncomingVideos.handle(urls) }
    }
}

/// Videos that arrive from outside the window.
@MainActor
enum IncomingVideos {
    static let types: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "m4a", "mp3", "wav", "aiff", "aif"]

    static func handle(_ urls: [URL]) {
        let files = urls.filter { types.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !VolunteerMode.shared.enabled { HomeNav.shared.open(.autoReels) }
        Task {
            for f in files { await AutoImport.shared.makeReelsNow(from: f) }
        }
    }
}

// MARK: - Notifications

@MainActor
enum Notifier {
    static let category = "reels-ready", reviewAction = "review"

    nonisolated static func registerCategories() {
        let review = UNNotificationAction(identifier: reviewAction, title: "Review", options: [.foreground])
        let cat = UNNotificationCategory(identifier: category, actions: [review], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    /// "Your clips are ready", with a picture from the first one. Only when AutoClip isn't in front.
    static func reelsReady(_ rec: AutoReelRecord, flagged: Int = 0) async {
        guard !NSApp.isActive else { return }
        let c = UNUserNotificationCenter.current()
        guard (try? await c.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let n = UNMutableNotificationContent()
        let count = rec.drafts?.count ?? 0
        n.title = "Your clips are ready"
        n.body = "\(count) clip\(count == 1 ? "" : "s") from “\(rec.title)”" + (flagged > 0 ? ", \(flagged) to double-check" : "")
        n.sound = .default
        n.categoryIdentifier = category
        n.userInfo = ["record": rec.id.uuidString]
        if let pic = await thumbnail(rec), let a = try? UNNotificationAttachment(identifier: "picture", url: pic) { n.attachments = [a] }
        try? await c.add(UNNotificationRequest(identifier: rec.id.uuidString, content: n, trigger: nil))
    }

    /// "Your Sunday is ready": the carousel and posts are made. Only when AutoClip isn't in front.
    static func graphicsReady(_ rec: AutoReelRecord, _ c: SermonCarousel) async {
        guard !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let n = UNMutableNotificationContent()
        n.title = "Your Sunday is ready"
        n.body = "“\(rec.title)”: clips, a \(c.slides.count)-slide carousel and \(c.postList.count) posts for the week, ready to review."
        n.sound = .default
        n.userInfo = ["record": rec.id.uuidString, "page": "social"]
        try? await center.add(UNNotificationRequest(identifier: "social-" + rec.id.uuidString, content: n, trigger: nil))
    }

    private static func thumbnail(_ rec: AutoReelRecord) async -> URL? {
        guard let piece = rec.drafts?.first?.pieces.first, let s = piece.sentences.first else { return nil }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: piece.sourceVideoPath)))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 640, height: 640)
        guard let cg = try? await g.image(at: CMTime(seconds: s.start + 1, preferredTimescale: 600)).image else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autoclip-\(rec.id.uuidString).jpg")
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

// MARK: - Dock

/// A progress bar on the Dock icon while reels are being made, and a count of clips waiting.
@MainActor
final class DockStatus {
    static let shared = DockStatus()
    private var bag = Set<AnyCancellable>()
    private var showing = false

    func start() {
        AutoReelsStore.shared.$activeJobs.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        AutoImport.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
        refresh()
    }

    private func refresh() {
        let tile = NSApp.dockTile
        let jobs = AutoReelsStore.shared.activeJobs.filter { !$0.isFinished }
        if jobs.isEmpty {
            if showing { tile.contentView = nil; showing = false }
        } else {
            let p = jobs.map(\.progress).reduce(0, +) / Double(jobs.count)
            let v = NSHostingView(rootView: DockTileView(progress: p))
            v.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = v
            showing = true
        }
        let waiting = AutoImport.shared.waiting.count
        tile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        tile.display()
    }
}

private struct DockTileView: View {
    let progress: Double
    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSApp.applicationIconImage).resizable()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.6))
                    Capsule().fill(Color(red: 0.85, green: 0.76, blue: 0.63)).frame(width: max(8, g.size.width * progress))
                }
            }
            .frame(height: 14).padding(.horizontal, 16).padding(.bottom, 14)
        }
    }
}

// MARK: - Small pleasures

enum Delight {
    static var soundsOn: Bool { UserDefaults.standard.object(forKey: "sounds_on") as? Bool ?? true }

    static func success() {
        if soundsOn { NSSound(named: "Glass")?.play() }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// A short burst of sand-coloured sparks around a checkmark. Still when motion is reduced.
struct CelebrationBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var start = Date()
    var size: CGFloat = 46

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = min(1, ctx.date.timeIntervalSince(start) / 0.9)
            Canvas { g, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                guard !reduce else { return }
                for i in 0..<12 {
                    let a = Double(i) / 12 * .pi * 2
                    let r = Double(size) * 0.25 + Double(size) * 0.45 * t
                    let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                    let d = 4 * (1 - t)
                    g.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                           with: .color(i % 2 == 0 ? Theme.sand.opacity(1 - t) : Theme.terracottaLight.opacity(1 - t)))
                }
            }
            .overlay(
                Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.5)).foregroundColor(Theme.good)
                    .scaleEffect(reduce ? 1 : (t < 0.3 ? 0.4 + 2.4 * t : 1.12 - 0.12 * min(1, (t - 0.3) / 0.3)))
            )
        }
        .frame(width: size * 2, height: size * 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Tips

struct CommandBarTip: Tip {
    var title: Text { Text("Do anything with ⌘K") }
    var message: Text? { Text("Jump to a page, open a clip or search your sermons. In the editor, say what to change.") }
    var image: Image? { Image(systemName: "command") }
}

struct QuickReviewTip: Tip {
    var title: Text { Text("Review clips with the arrow keys") }
    var message: Text? { Text("→ keeps a clip and ← tosses it. Kept clips are ready to export.") }
    var image: Image? { Image(systemName: "rectangle.stack") }
}

struct PhoneViewTip: Tip {
    var title: Text { Text("See it on a phone") }
    var message: Text? { Text("Check that the app's buttons don't cover your captions. Press P in the editor to switch apps.") }
    var image: Image? { Image(systemName: "iphone") }
}

struct MovementTip: Tip {
    var title: Text { Text("Movement brings a still shot to life") }
    var message: Text? { Text("Punch-ins land on the strongest lines. A slow push carries long stretches.") }
    var image: Image? { Image(systemName: "arrow.up.left.and.arrow.down.right") }
}
