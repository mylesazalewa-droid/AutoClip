import Foundation
import CryptoKit
import AppKit

/// A simple version of AutoClip for whoever's serving this week. The person who runs media saves
/// the church's style once, and from then on volunteers just add the sermon, pick clips and export.
/// The PIN stops accidental changes. It isn't real security.
@MainActor
final class VolunteerMode: ObservableObject {
    static let shared = VolunteerMode()

    /// Everything that makes a church's clips look like theirs
    struct ChurchStyle: Codable, Equatable {
        var name = "Our church style"
        var savedAt = Date()
        var look: CaptionLook?
        var audio: AudioSettings?
        var formatRaw: String?
        var captions: Bool?
        var captionIdx: Int?
        var targetDuration: Double?
        var reelCount: Int?
        var singleClip: Bool?
        var useAI: Bool?
        var dissolve: Bool?
        var emoji: Bool?

        var summary: String {
            let size = ReelEditorView.sizes.first { $0.0.rawValue == formatRaw }?.1 ?? "9:16"
            let count = (reelCount ?? 0) > 0 ? "\(reelCount!) clips" : "Automatic number of clips"
            return "\(size) · about \(Int(targetDuration ?? 90)) seconds · \(count) · captions \(captions ?? true ? "on" : "off")"
        }
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var style: ChurchStyle?
    private var pinHash: String?

    private static let enabledKey = "volunteer_on", styleKey = "volunteer_style", pinKey = "volunteer_pin"

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Self.enabledKey)
        pinHash = d.string(forKey: Self.pinKey)
        style = d.data(forKey: Self.styleKey).flatMap { try? JSONDecoder().decode(ChurchStyle.self, from: $0) }
    }

    var hasPIN: Bool { pinHash != nil }

    private static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data(("autoclip-volunteer:" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func checkPIN(_ pin: String) -> Bool { pinHash == nil || pinHash == Self.hash(pin) }

    func setPIN(_ pin: String?) {
        let clean = pin?.trimmingCharacters(in: .whitespaces) ?? ""
        pinHash = clean.isEmpty ? nil : Self.hash(clean)
        UserDefaults.standard.set(pinHash, forKey: Self.pinKey)
    }

    /// Takes the settings as they are now as the church's style.
    func saveCurrentStyle(name: String) {
        let d = UserDefaults.standard
        var s = ChurchStyle()
        s.name = name.isEmpty ? "Our church style" : name
        s.look = CaptionLook.load()
        s.audio = AudioSettings.load()
        s.formatRaw = d.string(forKey: "ar_format")
        s.captions = d.object(forKey: "ar_captions") as? Bool
        s.captionIdx = d.integer(forKey: "ar_captionIdx")
        s.targetDuration = d.object(forKey: "ar_targetDur") as? Double
        s.reelCount = d.integer(forKey: "ar_reelCount")
        s.singleClip = d.bool(forKey: "ar_singleClip")
        s.useAI = d.object(forKey: "ar_useAI") as? Bool
        s.dissolve = d.bool(forKey: "ar_dissolve")
        s.emoji = d.bool(forKey: "ar_emoji")
        store(s)
    }

    private func store(_ s: ChurchStyle) {
        style = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.styleKey) }
    }

    /// Puts the style in place so new reels and the editor use it.
    func applyStyle() {
        guard let s = style else { return }
        let d = UserDefaults.standard
        s.look?.save()
        s.audio?.save()
        if let v = s.formatRaw { d.set(v, forKey: "ar_format") }
        if let v = s.captions { d.set(v, forKey: "ar_captions") }
        if let v = s.captionIdx { d.set(v, forKey: "ar_captionIdx") }
        if let v = s.targetDuration { d.set(v, forKey: "ar_targetDur") }
        if let v = s.reelCount { d.set(v, forKey: "ar_reelCount") }
        if let v = s.singleClip { d.set(v, forKey: "ar_singleClip") }
        if let v = s.useAI { d.set(v, forKey: "ar_useAI") }
        if let v = s.dissolve { d.set(v, forKey: "ar_dissolve") }
        if let v = s.emoji { d.set(v, forKey: "ar_emoji") }
    }

    func turnOn() {
        applyStyle()
        enabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
    }

    /// False when the PIN is wrong.
    @discardableResult
    func turnOff(pin: String) -> Bool {
        guard checkPIN(pin) else { return false }
        enabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        return true
    }

    // MARK: Sharing a style with another Mac

    func exportStyle(to url: URL) throws {
        guard let style else { return }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(style).write(to: url, options: .atomic)
    }

    func importStyle(from url: URL) throws {
        let s = try JSONDecoder().decode(ChurchStyle.self, from: Data(contentsOf: url))
        store(s)
    }
}
