import Foundation
import CryptoKit
import AppKit

/// Plans and the license that unlocks them. Keys are signed with a private key kept outside the
/// repo (see src/Tools/license-tool.swift), so only you can make them. Everything is checked on
/// this Mac, so it stops casual sharing, not a determined cracker.
enum Plan: String, Codable, CaseIterable {
    case trial, solo, church, lifetime
    var label: String {
        switch self {
        case .trial: return "Free trial"
        case .solo: return "Solo"
        case .church: return "Church"
        case .lifetime: return "Lifetime"
        }
    }
}

/// What some plans add.
enum PlanFeature {
    case volunteerMode, worship
    var label: String { self == .volunteerMode ? "Volunteer Mode" : "Worship review" }
    /// Who gets it. The trial includes everything so people can try it all.
    func included(in plan: Plan) -> Bool { plan == .trial || plan == .church || plan == .lifetime }
}

struct LicenseInfo: Codable, Equatable {
    var id: String
    var name: String
    var email: String?
    var plan: String
    var issued: Date
    var expires: Date?
    var planValue: Plan { Plan(rawValue: plan) ?? .solo }
    var expired: Bool { expires.map { $0 < Date() } ?? false }
}

@MainActor
final class License: ObservableObject {
    static let shared = License()
    /// Sermons the free trial can turn into reels
    static let trialSermons = 2
    private static let publicKey = "l26JCqT9QcIw5BHv+kVDaNoZbn4dJVcYlcavqJXfUVc="
    private static let keyKey = "license_key", usedKey = "trial_sermons"

    @Published private(set) var info: LicenseInfo?
    @Published private(set) var trialUsed: [String]

    private init() {
        let d = UserDefaults.standard
        info = d.string(forKey: Self.keyKey).flatMap(Self.decode)
        trialUsed = d.stringArray(forKey: Self.usedKey) ?? []
    }

    // MARK: Checking keys

    nonisolated static func decode(_ raw: String) -> LicenseInfo? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("AUTOCLIP-") { text.removeFirst("AUTOCLIP-".count) }
        let parts = text.split(separator: ".")
        guard parts.count == 2, let body = Data(base64Encoded: String(parts[0])), let sig = Data(base64Encoded: String(parts[1])),
              let pkData = Data(base64Encoded: publicKey),
              let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkData),
              pk.isValidSignature(sig, for: body) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(LicenseInfo.self, from: body)
    }

    /// Whether a private key's public half is the one this app checks keys with.
    nonisolated static func publicKeyMatches(_ raw: Data) -> Bool {
        raw.base64EncodedString() == publicKey
    }

    /// The license key as entered, while it's genuine and current (it's what AutoClip AI checks).
    nonisolated static var activeKey: String? {
        guard let raw = UserDefaults.standard.string(forKey: "license_key"), let info = decode(raw), !info.expired else { return nil }
        return raw
    }

    /// For exports, which don't run on the main actor: true until a valid key has ever been added.
    nonisolated static var watermarkExports: Bool {
        guard let raw = UserDefaults.standard.string(forKey: keyKey) else { return true }
        return decode(raw) == nil
    }

    // MARK: State

    /// The plan in force. An expired key keeps its exports clean but can't start new sermons.
    var plan: Plan { info.map { $0.expired ? .trial : $0.planValue } ?? .trial }
    var expired: Bool { info?.expired ?? false }
    var licensed: Bool { info != nil && !expired }
    var trialLeft: Int { max(0, Self.trialSermons - trialUsed.count) }

    func has(_ f: PlanFeature) -> Bool { f.included(in: plan) || (expired && f.included(in: info?.planValue ?? .trial)) }

    var status: String {
        if let info, info.expired { return "\(info.planValue.label) plan ended" }
        if let info { return "\(info.planValue.label) plan" }
        return trialLeft == 0 ? "Free trial used" : "Free trial · \(trialLeft) sermon\(trialLeft == 1 ? "" : "s") left"
    }

    static let trialMessage = "Your free trial has made clips from \(trialSermons) sermons. Activate AutoClip to make more. Your existing clips can still be edited and exported."

    /// True when this video may become reels. Each new video in the trial counts once.
    func allowSermon(_ path: String) -> Bool {
        if licensed || SampleSermon.isSample(path: path) || trialUsed.contains(path) { return true }
        guard trialUsed.count < Self.trialSermons, !expired else { return false }
        trialUsed.append(path)
        UserDefaults.standard.set(trialUsed, forKey: Self.usedKey)
        return true
    }

    // MARK: Changing it

    struct Problem: LocalizedError { let errorDescription: String? }

    func activate(_ text: String) throws {
        guard let found = Self.decode(text) else {
            throw Problem(errorDescription: "That key isn't valid. Copy the whole key, starting with AUTOCLIP-.")
        }
        if found.expired { throw Problem(errorDescription: "That key ended on \(found.expires!.formatted(date: .abbreviated, time: .omitted)).") }
        UserDefaults.standard.set(text.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.keyKey)
        info = found
    }

    func remove() {
        UserDefaults.standard.removeObject(forKey: Self.keyKey)
        info = nil
    }

    func openPurchasePage() {
        let s = AppInfo.purchaseURL.isEmpty ? AppInfo.websiteURL : AppInfo.purchaseURL
        if let u = URL(string: s), !s.isEmpty { NSWorkspace.shared.open(u) }
    }

    var canBuy: Bool { !(AppInfo.purchaseURL.isEmpty && AppInfo.websiteURL.isEmpty) }
}
