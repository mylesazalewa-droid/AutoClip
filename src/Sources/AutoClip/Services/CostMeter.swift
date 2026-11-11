import Foundation

/// Keeps a running tab of what AI calls cost, from the token counts each provider sends
/// back. Prices are list prices per million tokens, so totals are close estimates, not bills.
@MainActor
final class CostMeter: ObservableObject {
    static let shared = CostMeter()

    struct Entry: Codable, Identifiable {
        var id = UUID()
        var date: Double
        var provider: String
        var model: String
        var input: Int
        var output: Int
        var cost: Double
        /// The video the call was for (nil = not tied to one)
        var video: String?
    }

    /// Which video the AI calls in this task are for (see `CostTag`).
    nonisolated static var video: String? { CostTag.video }

    @Published private(set) var entries: [Entry] = []

    private static var file: URL {
        let d = AppPaths.root
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("ai-costs.json")
    }

    private init() {
        if let d = try? Data(contentsOf: Self.file), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.file, options: .atomic) }
    }

    /// US dollars per million tokens (input, output).
    nonisolated static func price(model: String, input: Int) -> (Double, Double) {
        let m = model.lowercased()
        if m.contains("haiku-5") { return input > 100_000 ? (0.50, 2.50) : (0.10, 0.50) }
        if m.contains("haiku-4") { return (1, 5) }
        if m.contains("gpt-4o-mini") { return (0.15, 0.60) }
        if m.contains("gpt-4o") { return (2.50, 10) }
        if m.contains("flash-lite") { return (0.10, 0.40) }
        if m.contains("2.0-flash") || m.contains("1.5-flash") { return (0.10, 0.40) }
        if m.contains("flash") { return (0.30, 2.50) }
        if m.contains("pro") { return (1.25, 10) }
        return (0, 0)    // on-device models are free
    }

    /// Called after every AI reply. Safe from any thread.
    nonisolated static func record(provider: String, model: String, input: Int, output: Int) {
        let (pi, po) = provider == "This Mac" ? (0, 0) : price(model: model, input: input)
        let e = Entry(date: Date().timeIntervalSince1970, provider: provider, model: model, input: input, output: output,
                      cost: Double(input) / 1_000_000 * pi + Double(output) / 1_000_000 * po, video: video)
        Task { @MainActor in
            let m = CostMeter.shared
            m.entries.append(e)
            if m.entries.count > 5000 { m.entries.removeFirst(m.entries.count - 5000) }
            m.save()
        }
    }

    func reset() { entries = []; save() }

    private var monthStart: Double {
        Calendar.current.dateInterval(of: .month, for: Date())?.start.timeIntervalSince1970 ?? 0
    }

    var thisMonth: Double { entries.filter { $0.date >= monthStart }.reduce(0) { $0 + $1.cost } }
    var allTime: Double { entries.reduce(0) { $0 + $1.cost } }
    var callsThisMonth: Int { entries.filter { $0.date >= monthStart }.count }

    /// Spend per video, most expensive first (this month).
    var byVideo: [(video: String, cost: Double, calls: Int)] {
        var d: [String: (Double, Int)] = [:]
        for e in entries where e.date >= monthStart {
            let k = e.video ?? "Other"
            d[k, default: (0, 0)].0 += e.cost
            d[k, default: (0, 0)].1 += 1
        }
        return d.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.cost > $1.cost }
    }

    func cost(for video: String) -> Double { entries.filter { $0.video == video }.reduce(0) { $0 + $1.cost } }

    static func dollars(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", v)
    }
}

/// Which video the AI calls in a task are for. Set it around a job:
/// `await CostTag.$video.withValue(title) { … }`
enum CostTag {
    @TaskLocal static var video: String?
}

/// Says up front what an AI action is likely to cost, from what recent requests cost.
@MainActor
enum AICost {
    /// "1 AI request (about 2¢)", or "free, on this Mac" when recent requests ran on-device.
    static func phrase(_ requests: Int = 1) -> String {
        let recent = CostMeter.shared.entries.suffix(40)
        let what = requests == 1 ? "1 AI request" : "\(requests) AI requests"
        guard !recent.isEmpty else { return what }
        let local = recent.filter { $0.provider == "This Mac" }.count
        if local * 2 > recent.count { return "\(what), free on this Mac" }
        let paid = recent.filter { $0.provider != "This Mac" && $0.cost > 0 }
        guard !paid.isEmpty else { return what }
        let each = paid.reduce(0) { $0 + $1.cost } / Double(paid.count) * Double(requests)
        return "\(what) (about \(cents(each)))"
    }

    static func cents(_ v: Double) -> String {
        if v < 0.005 { return "under 1¢" }
        if v < 1 { return "\(Int((v * 100).rounded()))¢" }
        return String(format: "$%.2f", v)
    }
}
