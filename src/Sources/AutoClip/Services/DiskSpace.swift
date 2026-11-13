import Foundation
import SwiftUI

/// Free space on this Mac's disk, so big jobs can say up front when there isn't room
/// instead of failing partway with an unclear error.
enum DiskSpace {
    /// Free bytes on the disk holding `url` (macOS counts space it can clear, like caches)
    static func free(at url: URL = FileManager.default.temporaryDirectory) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? .max)
    }

    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    struct Full: LocalizedError {
        let free: Int64, needed: Int64, what: String
        var errorDescription: String? {
            "This Mac is almost out of space: \(DiskSpace.text(free)) free, and \(what) needs about \(DiskSpace.text(needed)). " +
            "Free some space (the Storage page under More tools shows what AutoClip keeps), then try again."
        }
    }

    /// Throws a plain explanation when there isn't room for `needed` bytes (plus a little to spare).
    static func check(_ needed: Int64, for what: String, at url: URL = FileManager.default.temporaryDirectory) throws {
        let f = free(at: url)
        guard f >= needed + 500_000_000 else {
            AppLog.write("Not enough space for \(what): \(text(f)) free, \(text(needed)) needed")
            throw Full(free: f, needed: needed, what: what)
        }
    }

    /// Below this, Home shows a warning
    static let lowMark: Int64 = 5_000_000_000
}

/// A line on Home when the disk is nearly full.
struct LowDiskBanner: View {
    @State private var free: Int64 = .max

    var body: some View {
        // A VStack is always there, even when empty, so the check below always runs
        VStack(spacing: 0) {
            if free < DiskSpace.lowMark {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark").foregroundColor(Theme.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Mac is almost full: \(DiskSpace.text(free)) free").font(.ui(size: 13.5, weight: .semibold)).foregroundColor(Theme.cream)
                        Text("Exports, downloads and transcribing can fail without room. Storage shows what AutoClip keeps and what can go.")
                            .font(.ui(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Storage") { HomeNav.shared.open(.storage) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.warn.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.warn.opacity(0.35), lineWidth: 1))
                .padding(.horizontal, 32)
            }
        }
        .task {
            // Checked when Home shows and every few minutes after
            while !Task.isCancelled {
                free = await Task.detached(priority: .utility) { DiskSpace.free() }.value
                try? await Task.sleep(nanoseconds: 180_000_000_000)
            }
        }
    }
}
