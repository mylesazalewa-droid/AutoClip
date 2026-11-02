import SwiftUI

/// The look of the app: deep charcoal surfaces, sand (beige) for highlights and headings,
/// terracotta for the main action, olive for success and navy for feature panels — the
/// "woven fabric" palette — with serif display type for titles.
enum Theme {
    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }

    // Surfaces, darkest to lightest
    static let bg = hex(0x141517)
    static let surface = hex(0x1B1D20)
    static let raised = hex(0x23262A)
    static let raised2 = hex(0x2D3035)
    static let line = Color.white.opacity(0.07)

    // The fabric colours
    static let navy = hex(0x1E2A4A)
    static let navyLight = hex(0x5B74B0)
    static let olive = hex(0x4B5135)
    static let oliveLight = hex(0xA3AE6E)
    static let sand = hex(0xD9C3A0)
    static let sandDeep = hex(0xB89B72)
    static let terracotta = hex(0xB4532F)
    static let terracottaLight = hex(0xDE7C58)
    static let charcoal = hex(0x2E3033)

    // Text
    static let cream = hex(0xF1E9DC)
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)

    // Meaning
    static let accent = sand
    static let action = terracotta
    static let good = oliveLight
    static let warn = hex(0xE3A15F)
    static let danger = terracottaLight

    /// Serif display type for titles, like a label on a bolt of cloth.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Small spaced capitals for section labels.
    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold) }
}

/// The main action: a terracotta pill with cream text.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, compact: compact)
    }
    private struct PrimaryBody: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundColor(Theme.cream)
                .padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 6 : 9)
                .background(Capsule().fill(Theme.terracotta.opacity(configuration.isPressed ? 0.8 : hover ? 1 : 0.92)))
                .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.18 : 0.08), lineWidth: 1))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// A quieter action: an outlined sand pill.
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, compact: compact)
    }
    private struct SecondaryBody: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundColor(Theme.sand)
                .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 6 : 9)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.1 : hover ? 0.07 : 0.03)))
                .overlay(Capsule().stroke(Theme.sand.opacity(hover ? 0.6 : 0.35), lineWidth: 1))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// A title in the house style: small diamond, thin rule, serif capitals.
struct DisplayTitle: View {
    let text: String
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "diamond").font(.system(size: 7)).foregroundColor(Theme.sand.opacity(0.8))
            Text(text.uppercased()).font(Theme.display(size)).tracking(size * 0.12).foregroundColor(Theme.cream)
        }
    }
}
