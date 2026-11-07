// Makes AutoClip license keys. Keep the private key OUT of the repo: anyone who has it can
// make keys that unlock AutoClip.
//
//   swift license-tool.swift keygen "<folder>"
//       Writes private-key.txt there and prints the public key for Services/License.swift.
//   swift license-tool.swift issue "<private-key.txt>" "<name>" <solo|church|lifetime> [days] [email]
//       Prints a license key. Leave out days (or use 0) for a key that never expires.
import Foundation
import CryptoKit

struct Info: Codable { var id: String; var name: String; var email: String?; var plan: String; var issued: Date; var expires: Date? }

let args = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

guard args.count >= 2 else { fail("Usage: keygen <folder> | issue <key> <name> <plan> [days] [email]") }
switch args[1] {
case "keygen":
    guard args.count >= 3 else { fail("Give a folder for the private key.") }
    let dir = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("private-key.txt")
    guard !FileManager.default.fileExists(atPath: file.path) else { fail("A private key already exists there. Not replacing it.") }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "issue":
    guard args.count >= 5 else { fail("Usage: issue <private-key.txt> <name> <solo|church|lifetime> [days] [email]") }
    let raw = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: raw), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("That isn't a private key file.") }
    guard ["solo", "church", "lifetime"].contains(args[4]) else { fail("Plan must be solo, church or lifetime.") }
    let days = args.count >= 6 ? Int(args[5]) ?? 0 : 0
    let info = Info(id: UUID().uuidString, name: args[3], email: args.count >= 7 ? args[6] : nil, plan: args[4],
                    issued: Date(), expires: days > 0 ? Date().addingTimeInterval(Double(days) * 86400) : nil)
    let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = .sortedKeys
    let body = try e.encode(info)
    let sig = try key.signature(for: body)
    print("AUTOCLIP-" + body.base64EncodedString() + "." + sig.base64EncodedString())
default:
    fail("Unknown command \(args[1]).")
}
