import SwiftUI
import TipKit

/// How much of a vertical video each app covers with its own buttons and text. These are close
/// approximations: the apps change them and they differ by phone.
enum PhoneView: String, CaseIterable, Identifiable {
    case off, shorts, reels, tiktok
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .shorts: return "YouTube Shorts"
        case .reels: return "Instagram Reels"
        case .tiktok: return "TikTok"
        }
    }
    /// Fractions of the height and width that the app covers
    var top: CGFloat { self == .tiktok ? 0.09 : 0.07 }
    var bottom: CGFloat {
        switch self {
        case .off: return 0
        case .shorts: return 0.17
        case .reels: return 0.2
        case .tiktok: return 0.2
        }
    }
    var right: CGFloat { self == .off ? 0 : self == .reels ? 0.13 : 0.15 }

    var next: PhoneView {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    /// Where captions can safely sit in this app (0 = top, 1 = bottom)
    var safeCaptionPosition: Double { Double(1 - bottom) - 0.08 }

    /// True when captions at this position run under the app's own text.
    func captionsCovered(_ look: CaptionLook) -> Bool {
        guard self != .off else { return false }
        return look.position + 0.035 * look.sizeScale > Double(1 - bottom)
    }
}

/// The app's buttons and text drawn over a vertical preview. Plain shapes, not the real apps'
/// branding: the point is to show what gets covered.
struct PhoneChrome: View {
    let view: PhoneView
    var showZones = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let unit = max(9, w * 0.058)
            ZStack(alignment: .topLeading) {
                if showZones {
                    Rectangle().fill(Color.red.opacity(0.13)).frame(width: w, height: h * view.bottom).offset(y: h * (1 - view.bottom))
                    Rectangle().fill(Color.red.opacity(0.13)).frame(width: w * view.right, height: h * (1 - view.bottom)).offset(x: w * (1 - view.right))
                    Rectangle().fill(Color.red.opacity(0.09)).frame(width: w * (1 - view.right), height: h * view.top)
                }
                // Along the top
                HStack(spacing: unit * 0.8) {
                    if view == .tiktok {
                        Text("Following").opacity(0.6)
                        Text("For You").fontWeight(.bold)
                    } else {
                        Text(view == .reels ? "Clips" : "Shorts").fontWeight(.bold)
                    }
                    Spacer()
                    Image(systemName: "magnifyingglass")
                }
                .font(.system(size: unit)).foregroundColor(.white)
                .padding(.horizontal, unit).frame(width: w, height: h * view.top, alignment: .center)
                .shadow(radius: 2)

                // Down the right side
                VStack(spacing: unit * 1.15) {
                    ForEach(["heart.fill", "bubble.right.fill", "arrowshape.turn.up.right.fill", "bookmark.fill"], id: \.self) { icon in
                        VStack(spacing: 2) {
                            Image(systemName: icon).font(.system(size: unit * 1.45))
                            Text("1.2K").font(.system(size: unit * 0.6))
                        }
                    }
                    Image(systemName: "ellipsis").font(.system(size: unit * 1.2))
                }
                .foregroundColor(.white).shadow(radius: 2)
                .frame(width: w * view.right)
                .position(x: w * (1 - view.right / 2), y: h * (1 - view.bottom) - unit * 6.5)

                // Along the bottom
                VStack(alignment: .leading, spacing: unit * 0.35) {
                    HStack(spacing: unit * 0.4) {
                        Circle().fill(Color.white.opacity(0.85)).frame(width: unit * 1.5, height: unit * 1.5)
                        Text("@yourchurch").font(.system(size: unit * 0.9, weight: .bold))
                        Text("Follow").font(.system(size: unit * 0.7, weight: .semibold))
                            .padding(.horizontal, unit * 0.45).padding(.vertical, unit * 0.15)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.8)))
                    }
                    Text("Your description shows here, and it can cover two lines of the picture…")
                        .font(.system(size: unit * 0.8)).lineLimit(2)
                    HStack(spacing: unit * 0.3) {
                        Image(systemName: "music.note")
                        Text("Original audio")
                    }
                    .font(.system(size: unit * 0.7))
                }
                .foregroundColor(.white).shadow(radius: 2)
                .padding(.horizontal, unit * 0.7)
                .frame(width: w, height: h * view.bottom, alignment: .topLeading)
                .offset(y: h * (1 - view.bottom) + unit * 0.2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Picks which app to preview in.
struct PhoneViewMenu: View {
    @Binding var view: PhoneView
    var body: some View {
        Menu {
            ForEach(PhoneView.allCases) { v in
                Button { view = v } label: { if v == view { Label(v.label, systemImage: "checkmark") } else { Text(v.label) } }
            }
        } label: {
            Label(view == .off ? "Phone view" : view.label, systemImage: "iphone")
                .font(.system(size: 11)).foregroundColor(view == .off ? Color.white.opacity(0.6) : Theme.sand)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .onChange(of: view) { v in if v != .off { PhoneViewTip().invalidate(reason: .actionPerformed) } }
        .help("See the clip with an app's buttons and text on top, to check nothing important is covered (P)")
    }
}

extension View {
    /// A phone-shaped edge around the preview when a phone view is on.
    @ViewBuilder func phoneBezel(_ view: PhoneView) -> some View {
        if view == .off { self } else {
            self.padding(5)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.07)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
        }
    }
}
