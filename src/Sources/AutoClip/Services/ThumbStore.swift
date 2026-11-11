import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// Thumbnails made once and kept on disk, so pages open with their pictures straight away
/// instead of working every one out again on each launch. Only a few are made at a time, so a
/// page full of cards doesn't make them all wait on each other.
enum ThumbStore {
    private static var folder: URL { AppPaths.folder("Cache/Thumbnails") }
    private static let limiter = Limiter(3)

    /// The thumbnail for `path` under `key` (what it shows: a time, a size, a shape), from disk if
    /// it was made before for this exact file; otherwise `make` runs (a few at a time) and the
    /// result is kept.
    static func image(for path: String, key: String, make: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        let file = location(path, key)
        if let file, let hit = read(file) { return hit }
        await limiter.enter()
        defer { Task { await limiter.leave() } }
        if let file, let hit = read(file) { return hit }   // made while this one waited
        guard let img = await make() else { return nil }
        if let file { write(img, to: file) }
        return img
    }

    /// Changes when the video file changes (a re-download or an edit makes a new thumbnail).
    private static func location(_ path: String, _ key: String) -> URL? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let stamp = "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.size] as? Int ?? 0)"
        let digest = SHA256.hash(data: Data("\(path)|\(stamp)|\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(String(digest.prefix(32)) + ".jpg")
    }

    private static func read(_ file: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func write(_ img: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Lets `n` in at a time; the rest wait their turn.
    actor Limiter {
        private let n: Int
        private var running = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(_ n: Int) { self.n = n }
        func enter() async {
            if running < n { running += 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func leave() {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
    }
}
