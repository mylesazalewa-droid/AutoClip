import Foundation
import AppKit
import UserNotifications

/// One thing someone is asked to approve: a clip, the carousel, or a single post.
struct ReviewItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case clip, carousel, post }
    enum Decision: String, Codable { case pending, approved, changes }

    /// A stretch of a video to play, in order
    struct Span: Codable, Equatable {
        var file: Int      // index into the request's videos
        var start: Double
        var end: Double
    }

    var id = UUID()
    var kind: Kind
    /// The clip's draft id, the post's slide id, or the sermon's id for its carousel
    var refID: UUID
    var title: String
    var caption: String?
    /// Pictures in the review folder (carousel slides or the post)
    var images: [String] = []
    /// The finished clip (index into videos), when it has been exported since its last edit
    var finished: Int?
    /// Otherwise the moments of the sermon video it's made from, with no captions
    var spans: [Span] = []
    var decision: Decision = .pending
    var note = ""
    var by = ""
    var at: Date?
}

/// A link sent to a pastor or comms lead with the clips and graphics from one sermon.
struct ReviewRequest: Codable, Identifiable, Equatable {
    var id = UUID()
    var token: String
    var recordID: UUID
    var title: String
    var created = Date()
    var items: [ReviewItem]
    /// Video files the page may play (exported clips and sermon videos)
    var videos: [String] = []
    /// No longer shared
    var closed = false

    var counts: (approved: Int, changes: Int, waiting: Int) {
        (items.filter { $0.decision == .approved }.count, items.filter { $0.decision == .changes }.count,
         items.filter { $0.decision == .pending }.count)
    }
    var folder: URL { ReviewStore.root.appendingPathComponent(token) }
}

@MainActor
final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()
    @Published private(set) var requests: [ReviewRequest] = []
    /// Set while a review link is being made, by sermon
    @Published private(set) var preparing: [UUID: String] = [:]

    nonisolated static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AutoClip/Reviews")
    }
    private static var index: URL { root.appendingPathComponent("reviews.json") }

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Self.index), let r = try? dec.decode([ReviewRequest].self, from: d) { requests = r }
        ReviewServer.shared.publish(requests)
    }

    /// Starts the server when there's something shared. Called at launch.
    func startIfNeeded() {
        if requests.contains(where: { !$0.closed }) { ReviewServer.shared.start() }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(requests).write(to: Self.index, options: .atomic)
        ReviewServer.shared.publish(requests)
    }

    // MARK: Looking things up

    /// The latest answer about a clip, carousel or post.
    func latest(_ refID: UUID, kind: ReviewItem.Kind) -> ReviewItem? {
        for r in requests.sorted(by: { $0.created > $1.created }) {
            if let i = r.items.first(where: { $0.refID == refID && $0.kind == kind }) { return i }
        }
        return nil
    }

    func request(_ id: UUID) -> ReviewRequest? { requests.first { $0.id == id } }
    func link(_ r: ReviewRequest) -> URL? { ReviewServer.shared.url(for: r.token) }

    // MARK: Making a link

    struct Choice { var clips = true, carousel = true, posts = true }

    /// Gathers the clips and graphics into a new review link.
    func make(for rec: AutoReelRecord, choose: Choice) async -> ReviewRequest? {
        guard preparing[rec.id] == nil else { return nil }
        preparing[rec.id] = "Getting it ready…"
        defer { preparing[rec.id] = nil }
        var r = ReviewRequest(token: Self.newToken(), recordID: rec.id, title: rec.title, items: [])
        try? FileManager.default.createDirectory(at: r.folder, withIntermediateDirectories: true)
        func video(_ path: String) -> Int {
            if let i = r.videos.firstIndex(of: path) { return i }
            r.videos.append(path); return r.videos.count - 1
        }
        if choose.clips {
            for (n, d) in (rec.drafts ?? []).enumerated() {
                var item = ReviewItem(kind: .clip, refID: d.id, title: d.title.isEmpty ? "Clip \(n + 1)" : d.title)
                item.caption = d.seo.map { $0.title + ($0.description.isEmpty ? "" : "\n\n" + $0.description) }
                if let p = d.exportedPath, !d.editedSinceExport, FileManager.default.fileExists(atPath: p) {
                    item.finished = video(p)
                } else {
                    item.spans = d.renderRuns.compactMap { run in
                        let src = run.clip.sourceVideoPath
                        guard FileManager.default.fileExists(atPath: src) else { return nil }
                        return ReviewItem.Span(file: video(src), start: run.clip.startTime, end: run.clip.endTime)
                    }
                    if item.spans.isEmpty { continue }
                }
                r.items.append(item)
            }
        }
        if let c = CarouselStore.load(rec.id) {
            let photos = CarouselPhotoCache()
            if choose.carousel, !c.slides.isEmpty {
                preparing[rec.id] = "Drawing the carousel…"
                let dir = r.folder.appendingPathComponent("carousel")
                let urls = await CarouselExport.write(c, photos: photos, to: dir)
                var item = ReviewItem(kind: .carousel, refID: rec.id, title: c.title.isEmpty ? "Carousel" : c.title)
                item.caption = c.captionWithTags
                item.images = urls.map { "carousel/" + $0.lastPathComponent }
                if !item.images.isEmpty { r.items.append(item) }
            }
            if choose.posts, !c.postList.isEmpty {
                preparing[rec.id] = "Drawing the posts…"
                let dir = r.folder.appendingPathComponent("posts")
                let urls = await CarouselExport.writePosts(c, photos: photos, to: dir)
                for (i, s) in c.postList.enumerated() where i < urls.count {
                    var item = ReviewItem(kind: .post, refID: s.id, title: "Post \(i + 1): " + s.kind.label)
                    item.caption = s.caption
                    item.images = ["posts/" + urls[i].lastPathComponent]
                    r.items.append(item)
                }
            }
        }
        guard !r.items.isEmpty else {
            try? FileManager.default.removeItem(at: r.folder)
            return nil
        }
        requests.insert(r, at: 0)
        persist()
        ReviewServer.shared.start()
        return r
    }

    private static func newToken() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Answers

    /// An answer from the phone page.
    func record(token: String, item: UUID, decision: ReviewItem.Decision, note: String, by: String) {
        guard let r = requests.firstIndex(where: { $0.token == token && !$0.closed }),
              let i = requests[r].items.firstIndex(where: { $0.id == item }) else { return }
        requests[r].items[i].decision = decision
        requests[r].items[i].note = String(note.prefix(2000))
        requests[r].items[i].by = String(by.prefix(80))
        requests[r].items[i].at = Date()
        persist()
        let it = requests[r].items[i], title = requests[r].title
        Task { await Self.notify(it, title: title) }
    }

    /// Set from the Mac (e.g. to clear an answer).
    func set(_ requestID: UUID, item: UUID, decision: ReviewItem.Decision) {
        guard let r = requests.firstIndex(where: { $0.id == requestID }),
              let i = requests[r].items.firstIndex(where: { $0.id == item }) else { return }
        requests[r].items[i].decision = decision
        if decision == .pending { requests[r].items[i].note = ""; requests[r].items[i].by = ""; requests[r].items[i].at = nil }
        persist()
    }

    func close(_ id: UUID) {
        guard let r = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[r].closed = true
        persist()
        if !requests.contains(where: { !$0.closed }) { ReviewServer.shared.stop() }
    }

    func reopen(_ id: UUID) {
        guard let r = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[r].closed = false
        persist()
        ReviewServer.shared.start()
    }

    /// Removes the request and its pictures (to the Trash).
    func delete(_ id: UUID) {
        guard let r = requests.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.trashItem(at: requests[r].folder, resultingItemURL: nil)
        requests.remove(at: r)
        persist()
        if !requests.contains(where: { !$0.closed }) { ReviewServer.shared.stop() }
    }

    private static func notify(_ it: ReviewItem, title: String) async {
        guard !NSApp.isActive else { return }
        let c = UNUserNotificationCenter.current()
        guard (try? await c.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let n = UNMutableNotificationContent()
        let who = it.by.isEmpty ? "Your reviewer" : it.by
        n.title = it.decision == .approved ? "\(who) approved \(it.title)" : "\(who) asked for changes"
        n.body = it.decision == .approved ? "From “\(title)”" : "\(it.title): \(it.note.isEmpty ? "No note" : it.note)"
        n.sound = .default
        n.userInfo = ["page": "approvals"]
        try? await c.add(UNNotificationRequest(identifier: "review-" + it.id.uuidString + "-\(Date().timeIntervalSince1970)", content: n, trigger: nil))
    }
}
