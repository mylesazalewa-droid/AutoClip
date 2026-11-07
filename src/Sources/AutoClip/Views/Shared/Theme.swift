import SwiftUI
import AppKit

/// The look of the app: deep charcoal surfaces, sand (beige) for highlights and headings,
/// terracotta for the main action, olive for success and navy for feature panels — the
/// "woven fabric" palette — with serif display type for titles.
enum Theme {
    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }
    private static func ns(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    /// One colour for dark windows and another for light ones, chosen as each view draws
    private static func pair(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// Text and lines: white on dark, warm near-black on light
    static let ink = pair(.white, ns(0x1F1C19))

    // Surfaces, darkest to lightest
    static let bg = pair(ns(0x141517), ns(0xF3F0EA))
    static let surface = pair(NSColor.white.withAlphaComponent(0.055), NSColor.white.withAlphaComponent(0.78))
    static let raised = pair(NSColor.white.withAlphaComponent(0.085), NSColor.white)
    static let raised2 = pair(NSColor.white.withAlphaComponent(0.13), NSColor.white)
    static let line = pair(NSColor.white.withAlphaComponent(0.09), NSColor.black.withAlphaComponent(0.11))

    // The fabric colours
    static let navy = hex(0x1E2A4A)
    static let navyLight = pair(ns(0x5B74B0), ns(0x3E5590))
    static let olive = hex(0x4B5135)
    static let oliveLight = pair(ns(0xA3AE6E), ns(0x5E6B2E))
    static let sand = pair(ns(0xD9C3A0), ns(0x8C6A3E))
    static let sandDeep = pair(ns(0xB89B72), ns(0x7A5A30))
    static let terracotta = hex(0xB4532F)
    static let terracottaLight = pair(ns(0xDE7C58), ns(0xB4532F))
    static let charcoal = hex(0x2E3033)

    // Text, with enough contrast to read comfortably
    static let cream = pair(ns(0xF1E9DC), ns(0x2B241D))
    static let text = ink.opacity(0.92)
    static let muted = pair(NSColor.white.withAlphaComponent(0.70), ns(0x1F1C19, 0.66))
    static let faint = pair(NSColor.white.withAlphaComponent(0.52), ns(0x1F1C19, 0.5))

    /// Text on sand: dark on the light sand of dark mode, light on the deeper sand of light mode
    static let onSand = pair(ns(0x141517), ns(0xFBF7F0))
    /// Text on terracotta, navy or other fixed colours: always light
    static let onColor = hex(0xF1E9DC)
    static let onColorMuted = hex(0xF1E9DC, 0.72)

    // Meaning
    static let accent = sand
    static let action = terracotta
    static let good = oliveLight
    static let warn = pair(ns(0xE3A15F), ns(0xA8611F))
    static let danger = terracottaLight

    /// Serif display type for titles, like a label on a bolt of cloth.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Small spaced capitals for section labels.
    static func label(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .semibold) }
}

/// Light, dark, or whatever the Mac is set to.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { self == .system ? "Match Mac" : self == .light ? "Light" : "Dark" }
    var scheme: ColorScheme? { self == .system ? nil : self == .light ? .light : .dark }
    static let key = "appearance"
    static var current: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }

    /// Menus, alerts and other system pieces follow too.
    static func applyToApp() {
        switch current {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Puts a window in the chosen appearance, and the house button style on every plain button.
struct AppLook: ViewModifier {
    @AppStorage(AppAppearance.key) private var raw = AppAppearance.dark.rawValue
    func body(content: Content) -> some View {
        content
            .preferredColorScheme((AppAppearance(rawValue: raw) ?? .dark).scheme)
            .buttonStyle(QuietButtonStyle())
            .onAppear { AppAppearance.applyToApp() }
            .onChange(of: raw) { _ in AppAppearance.applyToApp() }
    }
}

extension View {
    func appLook() -> some View { modifier(AppLook()) }
}

/// The everyday button: a soft rounded pill that matches the rest of the app,
/// instead of the stock grey one.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuietBody(configuration: configuration) }
    private struct QuietBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var size
        @State private var hover = false
        var body: some View {
            let small = size == .small || size == .mini
            configuration.label
                .font(.system(size: small ? 12 : 13, weight: .medium))
                .foregroundColor(Theme.text)
                .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 4 : 7)
                .background(RoundedRectangle(cornerRadius: small ? 7 : 9, style: .continuous)
                    .fill(Theme.ink.opacity(configuration.isPressed ? 0.16 : hover ? 0.11 : 0.07)))
                .overlay(RoundedRectangle(cornerRadius: small ? 7 : 9, style: .continuous).stroke(Theme.line, lineWidth: 1))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
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
                .foregroundColor(Theme.onColor)
                .padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 6 : 9)
                .background(Capsule().fill(Theme.terracotta.opacity(configuration.isPressed ? 0.8 : hover ? 1 : 0.92)))
                .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.18 : 0.08), lineWidth: 1)) // on terracotta, always light
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
                .background(Capsule().fill(Theme.ink.opacity(configuration.isPressed ? 0.1 : hover ? 0.07 : 0.03)))
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
            Image(systemName: "diamond").font(.system(size: 10)).foregroundColor(Theme.sand.opacity(0.8))
            Text(text.uppercased()).font(Theme.display(size)).tracking(size * 0.12).foregroundColor(Theme.cream)
        }
    }
}

/// The AutoClip mark: a spoken line captured in a tall clip.
struct LogoMark: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.87, green: 0.49, blue: 0.35), Theme.terracotta], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.62, height: size)
            HStack(spacing: size * 0.07) {
                ForEach([0.5, 0.78, 0.42], id: \.self) { h in
                    Capsule().fill(Theme.onColor).frame(width: size * 0.075, height: size * h)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("AutoClip")
    }
}
