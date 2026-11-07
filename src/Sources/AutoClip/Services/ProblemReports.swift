import Foundation
import AppKit

/// Notices when AutoClip closed unexpectedly last time and offers a report. Nothing is sent
/// unless the person reads it and chooses to email or save it.
@MainActor
final class ProblemReports: ObservableObject {
    static let shared = ProblemReports()

    @Published var showSheet = false
    @Published private(set) var crashedLastTime = false
    private var previousStart: Date?

    private var marker: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AutoClip/running")
    }

    /// Called once at launch.
    func start() {
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path) {
            previousStart = (try? fm.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
            crashedLastTime = true
            showSheet = true
        }
        try? fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: marker)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [marker] _ in
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func dismiss() { showSheet = false; crashedLastTime = false }

    /// The report, exactly as it would be sent.
    func report(note: String) -> String {
        var lines = [
            "AutoClip \(AppInfo.version) (\(AppInfo.build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(Self.model()) · \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB memory",
            "Date: \(Date().formatted())",
        ]
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines += ["", "What happened:", note] }
        if let crash = latestCrashLog() {
            lines += ["", "Crash log: \(crash.lastPathComponent)", String((try? String(contentsOf: crash, encoding: .utf8))?.prefix(60_000) ?? "")]
        } else if crashedLastTime {
            lines += ["", "AutoClip closed unexpectedly, but macOS didn't save a crash log."]
        }
        return lines.joined(separator: "\n")
    }

    private func latestCrashLog() -> URL? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports")
        let since = previousStart ?? Date().addingTimeInterval(-7 * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("AutoClip") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { f -> (URL, Date)? in
                guard let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d >= since else { return nil }
                return (f, d)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private static func model() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    func save(_ text: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "AutoClip report \(Date().formatted(.iso8601.year().month().day())).txt"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? text.write(to: u, atomically: true, encoding: .utf8)
        dismiss()
    }

    var canEmail: Bool { !AppInfo.supportEmail.isEmpty }

    func email(_ text: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AutoClip report.txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        guard let s = NSSharingService(named: .composeEmail) else { return }
        s.recipients = [AppInfo.supportEmail]
        s.subject = "AutoClip \(AppInfo.version) problem report"
        s.perform(withItems: ["Report attached.", file])
        dismiss()
    }
}
