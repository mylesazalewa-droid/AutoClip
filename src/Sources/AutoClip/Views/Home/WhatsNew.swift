import SwiftUI

/// After an update, Home says what changed (the release notes for this version), once.
@MainActor
final class WhatsNew: ObservableObject {
    static let shared = WhatsNew()
    private static let seenKey = "whats_new_seen"

    @Published private(set) var notes: String?

    /// At launch. A new install isn't an update, so it just remembers the version.
    func check() async {
        let d = UserDefaults.standard
        let now = AppInfo.version
        guard let seen = d.string(forKey: Self.seenKey) else { d.set(now, forKey: Self.seenKey); return }
        guard seen != now else { return }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.releasesRepo)/releases/tags/v\(now)")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["body"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notes = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dismiss() {
        UserDefaults.standard.set(AppInfo.version, forKey: Self.seenKey)
        notes = nil
    }
}

struct WhatsNewCard: View {
    @ObservedObject private var news = WhatsNew.shared

    var body: some View {
        if let notes = news.notes {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("What's new in AutoClip \(AppInfo.version)", systemImage: "sparkles")
                        .font(.ui(size: 15, weight: .semibold)).foregroundColor(Theme.cream)
                    Spacer()
                    Button("Got it") { withAnimation { news.dismiss() } }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
                Text(LocalizedStringKey(notes))
                    .font(.ui(size: 13)).foregroundColor(Theme.text).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sand.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.sand.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 32)
            .transition(.opacity)
        }
    }
}
