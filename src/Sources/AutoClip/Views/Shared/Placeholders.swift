import SwiftUI
import AppKit

/// A soft light that sweeps across something that's still loading. Still when motion is reduced.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content.overlay {
            if !reduce {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Theme.ink.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }
                .clipped()
                .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 } }
            }
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Grey lines shaped like the rows that are on their way.
struct PlaceholderRows: View {
    var count = 4
    var label: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let label { Text(label).font(.system(size: 12)).foregroundColor(Theme.muted) }
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.07)).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.08)).frame(width: [220, 170, 250, 190][i % 4], height: 11)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.05)).frame(width: [320, 280, 360, 300][i % 4], height: 9)
                    }
                }
                .shimmer()
            }
        }
        .accessibilityLabel(label ?? "Loading")
    }
}

// MARK: - Getting a clip onto a phone

enum ShareOut {
    /// AirDrop the exported clip, usually to your own iPhone.
    static func airDrop(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path), let s = NSSharingService(named: .sendViaAirDrop) else { return }
        s.perform(withItems: [url])
    }

    static var canAirDrop: Bool { NSSharingService(named: .sendViaAirDrop) != nil }
}

extension View {
    /// Lets an exported clip be dragged straight into Finder, a browser upload, Messages or Slack.
    @ViewBuilder func draggableClip(_ path: String?) -> some View {
        if let path, FileManager.default.fileExists(atPath: path) {
            self.onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
                .help("Drag this clip into Finder, a browser upload, Messages or Slack")
        } else {
            self
        }
    }
}
