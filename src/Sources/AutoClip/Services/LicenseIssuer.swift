import Foundation
import CryptoKit

/// The owner's side of licences: makes keys and keeps a list of who has which, so a lost key can be
/// copied again instead of made again. It only does anything on the Mac that holds the private key
/// (Documents/AutoClip License Keys/private-key.txt), which never ships with the app.
struct IssuedLicense: Codable, Identifiable, Equatable {
    var id: String          // the id inside the key
    var name: String
    var email: String?
    var plan: String
    var issued: Date
    var expires: Date?
    var key: String
    var note = ""

    var planValue: Plan { Plan(rawValue: plan) ?? .solo }
    var expired: Bool { expires.map { $0 < Date() } ?? false }
    /// How long it was given for, so a renewal gives the same again
    var lengthDays: Int? { expires.map { max(1, Int(($0.timeIntervalSince(issued) / 86400).rounded())) } }
}

@MainActor
final class LicenseIssuer: ObservableObject {
    static let shared = LicenseIssuer()
    @Published private(set) var issued: [IssuedLicense] = []

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/AutoClip License Keys")
    }
    private static var privateKeyFile: URL { folder.appendingPathComponent("private-key.txt") }
    private static var listFile: URL { folder.appendingPathComponent("issued-keys.json") }

    /// True on the owner's Mac only.
    static var isOwnerMac: Bool { FileManager.default.fileExists(atPath: privateKeyFile.path) }

    private init() { load() }

    private func signingKey() -> Curve25519.Signing.PrivateKey? {
        guard let raw = try? String(contentsOf: Self.privateKeyFile, encoding: .utf8),
              let d = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: d)
    }

    /// The private key is there and makes keys this version of AutoClip accepts.
    var keyWorks: Bool {
        guard let k = signingKey() else { return false }
        return License.publicKeyMatches(k.publicKey.rawRepresentation)
    }

    // MARK: List

    func load() {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.listFile), let list = try? d.decode([IssuedLicense].self, from: data) {
            issued = list
        }
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(issued) else { return }
        try? data.write(to: Self.listFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.listFile.path)
    }

    // MARK: Making keys

    enum IssueError: LocalizedError {
        case noKey, needsName
        var errorDescription: String? {
            switch self {
            case .noKey: return "The private key in Documents › AutoClip License Keys is missing or unreadable."
            case .needsName: return "Give the church or person a name."
            }
        }
    }

    /// Makes a key. `days` nil means it never ends. `from` is when its time starts (a renewal starts at the old end date).
    @discardableResult
    func issue(name: String, email: String?, plan: Plan, days: Int?, from start: Date = Date(), note: String = "") throws -> IssuedLicense {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw IssueError.needsName }
        guard let key = signingKey() else { throw IssueError.noKey }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = LicenseInfo(id: UUID().uuidString, name: name, email: (email?.isEmpty ?? true) ? nil : email, plan: plan.rawValue,
                               issued: Date(), expires: days.map { start.addingTimeInterval(Double($0) * 86400) })
        // Encoded exactly as license-tool.swift does it
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = .sortedKeys
        let body = try e.encode(info)
        let sig = try key.signature(for: body)
        let text = "AUTOCLIP-" + body.base64EncodedString() + "." + sig.base64EncodedString()
        let item = IssuedLicense(id: info.id, name: info.name, email: info.email, plan: info.plan, issued: info.issued,
                                 expires: info.expires, key: text, note: note)
        issued.insert(item, at: 0)
        save()
        return item
    }

    /// A new key for the same church, with the same length, starting when the old one ends (or today if it has ended).
    @discardableResult
    func renew(_ old: IssuedLicense) throws -> IssuedLicense {
        let start = max(Date(), old.expires ?? Date())
        return try issue(name: old.name, email: old.email, plan: old.planValue, days: old.lengthDays ?? 365, from: start,
                         note: old.note)
    }

    /// Adds a key given out before this list existed. Returns false if it isn't a valid AutoClip key.
    func addExisting(_ raw: String, note: String = "") -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = License.decode(text) else { return false }
        if issued.contains(where: { $0.id == info.id }) { return true }
        let full = text.hasPrefix("AUTOCLIP-") ? text : "AUTOCLIP-" + text
        issued.append(IssuedLicense(id: info.id, name: info.name, email: info.email, plan: info.plan, issued: info.issued,
                                    expires: info.expires, key: full, note: note))
        issued.sort { $0.issued > $1.issued }
        save()
        return true
    }

    func update(_ item: IssuedLicense) {
        guard let i = issued.firstIndex(where: { $0.id == item.id }) else { return }
        issued[i] = item
        save()
    }

    /// Takes it off the list. The key itself keeps working until its end date.
    func remove(_ item: IssuedLicense) {
        issued.removeAll { $0.id == item.id }
        save()
    }
}
