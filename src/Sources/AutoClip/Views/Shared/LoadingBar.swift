import SwiftUI

/// AutoClip's progress bar, used wherever something is loading.
/// Fills to the real amount when it's known: from `fraction`, or a percentage in the status text
/// ("Transcribing… 42%"). Otherwise a highlight slides along the bar to show it's still working.
struct LoadingBar: View {
    var status: String? = nil
    var fraction: Double? = nil
    var width: CGFloat? = 140
    var height: CGFloat = 5

    var body: some View {
        let f = fraction ?? Self.percent(in: status)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.1))
                if let f {
                    Capsule().fill(Theme.sand)
                        .frame(width: max(height, g.size.width * CGFloat(min(1, max(0, f)))))
                        .animation(.easeOut(duration: 0.3), value: f)
                } else {
                    Sweep(height: height)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(status ?? "Loading")
        .accessibilityValue(f.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }

    /// The last "NN%" in a status line, as 0…1
    static func percent(in s: String?) -> Double? {
        guard let s, let r = s.range(of: #"(\d{1,3})(\.\d+)?\s?%"#, options: [.regularExpression, .backwards]) else { return nil }
        let n = Double(s[r].filter { $0.isNumber || $0 == "." }) ?? 0
        return min(1, n / 100)
    }

    /// A highlight that slides back and forth
    private struct Sweep: View {
        var height: CGFloat
        @State private var go = false
        var body: some View {
            GeometryReader { g in
                let w = max(24, g.size.width * 0.35)
                Capsule().fill(Theme.sand)
                    .frame(width: w, height: height)
                    .offset(x: go ? g.size.width - w : 0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: go)
                    .onAppear { go = true }
            }
        }
    }
}
