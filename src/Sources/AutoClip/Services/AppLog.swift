import Foundation
import AppKit
import os

/// A short diary of what AutoClip was doing, kept on this Mac only. It goes into a problem report
/// (which the person reads before sending), so a crash, a freeze or a close for lack of memory
/// comes with what was running at the time. Nothing here is sent anywhere by itself.
enum AppLog {
    private static let queue = DispatchQueue(label: "autoclip.log", qos: .utility)
    private static let maxBytes = 2_000_000

    static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AutoClip/Logs/autoclip.log")
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
        return f
    }()

    /// Adds one line. Safe from any thread.
    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: file) else { return }
            defer { try? h.close() }
            let end = (try? h.seekToEnd()) ?? 0
            try? h.write(contentsOf: Data(line.utf8))
            // Keep the newest half once it grows past the limit
            if end > UInt64(maxBytes), let d = try? Data(contentsOf: file) {
                let tail = d.suffix(maxBytes / 2)
                let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
                try? Data(tail[start...]).write(to: file)
            }
        }
    }

    /// The last lines, for a problem report.
    static func tail(_ lines: Int = 200) -> String {
        queue.sync {
            guard let s = try? String(contentsOf: file, encoding: .utf8) else { return "" }
            return s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
    }

    /// Memory AutoClip is using now, in MB.
    static func memoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    // MARK: Watching for trouble

    private static var pressure: DispatchSourceMemoryPressure?
    private static var watchdog: Thread?
    private static let quitting = OSAllocatedUnfairLock(initialState: false)

    /// Called once at launch: notes the start, low memory, and the window freezing.
    static func start() {
        let v = Bundle.main.infoDictionary
        write("Started AutoClip \(v?["CFBundleShortVersionString"] ?? "?") (\(v?["CFBundleVersion"] ?? "?")) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB, \(cpu())")

        let p = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        p.setEventHandler {
            let level = p.data.contains(.critical) ? "very low" : "low"
            write("This Mac is \(level) on memory. AutoClip is using \(memoryMB()) MB.")
        }
        p.resume()
        pressure = p

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            quitting.withLock { $0 = true }
            write("Quit normally")
            queue.sync {}
        }

        // A background check that the window is still answering. A freeze over 8 seconds is noted once.
        let t = Thread {
            let lastAnswer = OSAllocatedUnfairLock(initialState: Date())
            var reported = false
            var sampled = false
            while true {
                // In every run loop mode, so a dialog waiting for an answer isn't taken for a freeze
                RunLoop.main.perform(inModes: [.common, .modalPanel, .eventTracking]) { lastAnswer.withLock { $0 = Date() } }
                Thread.sleep(forTimeInterval: 2)
                if quitting.withLock({ $0 }) { return }
                let silent = Date().timeIntervalSince(lastAnswer.withLock { $0 })
                if silent > 4, !reported, !sampled {
                    // While it's still stuck: note where the time is going, for a problem report
                    sampled = true
                    captureFreeze()
                }
                if silent < 3 { sampled = false }
                if silent > 8, !reported {
                    reported = true
                    write("The window stopped responding for \(Int(silent)) s (using \(memoryMB()) MB)")
                } else if silent < 3, reported {
                    reported = false
                    write("The window is responding again")
                }
            }
        }
        t.name = "AutoClip watchdog"
        t.qualityOfService = .utility
        t.start()
        watchdog = t
    }

    // MARK: Freezes

    static var freezeDir: URL { file.deletingLastPathComponent().appendingPathComponent("Freezes", isDirectory: true) }

    /// Records three seconds of what AutoClip is doing (macOS's own `sample` tool), keeping the last five.
    private static func captureFreeze() {
        let fm = FileManager.default
        try? fm.createDirectory(at: freezeDir, withIntermediateDirectories: true)
        let name = "freeze \(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-mayDie", "-file", freezeDir.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let old = ((try? fm.contentsOfDirectory(at: freezeDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
        for f in old.dropFirst(5) { try? fm.removeItem(at: f) }
    }

    /// The newest freeze: AutoClip's own busiest steps on the main thread, most time first.
    static func lastFreeze() -> String? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: freezeDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let f = files.first, let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        // Only the main thread's part (up to the next thread)
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("Main Thread") || $0.contains("com.apple.main-thread") }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.range(of: #"^\s*\d+ Thread_"#, options: .regularExpression) != nil } ?? lines.endIndex
        let main = lines[start..<end]
        var steps: [(Int, String)] = []
        var seen = Set<String>()
        for l in main where l.contains("(in AutoClip)") || l.contains("(in WhisperKit)") {
            let t = l.trimmingCharacters(in: CharacterSet(charactersIn: " +!:|"))
            let parts = t.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[0]) else { continue }
            let what = String(parts[1]).replacingOccurrences(of: #"\s+\[0x[0-9a-f]+\]"#, with: "", options: .regularExpression)
            if seen.insert(what).inserted { steps.append((n, what)) }
        }
        guard !steps.isEmpty else { return nil }
        return "\(f.lastPathComponent)\n" + steps.sorted { $0.0 > $1.0 }.prefix(25).map { "\($0.0)  \($0.1)" }.joined(separator: "\n")
    }

    private static func cpu() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
