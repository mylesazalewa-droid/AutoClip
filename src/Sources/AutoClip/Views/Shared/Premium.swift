import SwiftUI
import TipKit
import AVFoundation
import CoreImage
import Vision

// The cinematic look shared by every page: a soft backdrop drawn from your own video, a glass
// sidebar, and wide heroes. Text sits on dark shading so it reads over any picture.

/// The video the page backdrop is drawn from.
@MainActor
final class Backdrop: ObservableObject {
    static let shared = Backdrop()
    @Published var path: String?
}

/// A frame from a video, kept so it isn't worked out twice.
enum VideoFrames {
    private static let cache = NSCache<NSString, CGImage>()

    static func frame(_ path: String, width: CGFloat) async -> CGImage? {
        let key = "\(path)|\(Int(width))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await ThumbStore.image(for: path, key: "best|\(Int(width))") {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: width, height: width)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let at = await bestMoment(path, asset: asset)
            return try? await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static let moments = NSCache<NSString, NSNumber>()

    /// The moment to show: of a few spread through the video, the one with the clearest face,
    /// so a page doesn't open on a slide or an empty stage.
    private static func bestMoment(_ path: String, asset: AVAsset) async -> Double {
        if let hit = moments.object(forKey: path as NSString) { return hit.doubleValue }
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds > 1 else { return 0 }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        var best = min(seconds * 0.3, 300), bestSize = 0.0
        for fraction in [0.12, 0.25, 0.38, 0.5, 0.65, 0.8] {
            let t = seconds * fraction
            guard let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let size: Double = await withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async {
                    let request = VNDetectFaceRectanglesRequest()
                    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    // Facing the camera beats turned away
                    var biggest = 0.0
                    for face in request.results ?? [] {
                        let yaw: Double = face.yaw?.doubleValue ?? 0
                        let weight: Double = abs(yaw) < 0.4 ? 1 : 0.5
                        biggest = max(biggest, Double(face.boundingBox.height) * weight)
                    }
                    c.resume(returning: biggest)
                }
            }
            if size > bestSize { bestSize = size; best = t }
        }
        moments.setObject(NSNumber(value: best), forKey: path as NSString)
        return best
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// A small, heavily blurred, slightly richer version for the backdrop.
    static func blurred(_ path: String) async -> CGImage? {
        guard let small = await frame(path, width: 160) else { return nil }
        let input = CIImage(cgImage: small).clampedToExtent()
        let output = input
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .cropped(to: CIImage(cgImage: small).extent)
        return context.createCGImage(output, from: output.extent)
    }
}

/// The page behind everything: the current video's colours, softly, on deep charcoal.
struct AmbientBackdrop: View {
    @ObservedObject private var backdrop = Backdrop.shared
    @State private var image: CGImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Theme.bg
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .opacity(scheme == .dark ? 0.62 : 0.22)
                        .transition(.opacity)
                        .id(image.hashValue)
                }
            }
            .overlay {
                LinearGradient(colors: [Theme.bg.opacity(0.35), Theme.bg.opacity(0.72), Theme.bg.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: backdrop.path) {
            guard let path = backdrop.path, let blurred = await VideoFrames.blurred(path) else { return }
            withAnimation(.easeInOut(duration: 0.8)) { image = blurred }
        }
    }
}

/// A sharp frame from a video, filling its space.
struct VideoFrameView: View {
    let path: String
    var width: CGFloat = 1920
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.ink.opacity(0.03)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .task(id: path) {
            image = nil
            image = await VideoFrames.frame(path, width: width)
        }
    }
}

private struct HeroBlur: View {
    let path: String
    @State private var image: CGImage?
    var body: some View {
        Color.black.opacity(0.4)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill().overlay(Color.black.opacity(0.35)) }
            }
            .clipped()
        .task(id: path) { image = await VideoFrames.blurred(path) }
    }
}

/// The big picture at the top of a page.
struct CinematicHero<Actions: View>: View {
    let path: String?
    let eyebrow: String
    let title: String
    var detail: String?
    var height: CGFloat = 430
    var icon = "sparkles"
    @ViewBuilder var actions: Actions

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let path {
                // The same picture, soft, behind everything
                HeroBlur(path: path)
                // Then sharp at its real shape on the right, melting into the blur
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VideoFrameView(path: path).frame(width: height * 16 / 9, height: height).clipped()
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.38)], startPoint: .leading, endPoint: .trailing))
                }
            } else {
                LinearGradient(colors: [Theme.navy.opacity(0.8), Theme.olive.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .trailing) {
                        Image(systemName: icon).font(.ui(size: 170, weight: .thin)).foregroundColor(Theme.ink.opacity(0.55)).padding(.trailing, 90)
                    }
            }
            // Shade so the words read over any picture
            LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .black.opacity(0.3), location: 0.45),
                                   .init(color: .clear, location: 0.7)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 14) {
                Text(eyebrow.uppercased()).font(.ui(size: 12, weight: .semibold)).tracking(2.2).foregroundColor(Theme.sand)
                Text(title).font(Theme.display(46, weight: .medium)).foregroundColor(Theme.ink)
                    .lineLimit(2).minimumScaleFactor(0.7).frame(maxWidth: 680, alignment: .leading)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                if let detail {
                    Text(detail).font(.ui(size: 14)).foregroundColor(Theme.ink.opacity(0.78)).lineLimit(2).frame(maxWidth: 620, alignment: .leading)
                }
                HStack(spacing: 10) { actions }.padding(.top, 6)
            }
            .padding(.vertical, 44).padding(.leading, 64).padding(.trailing, 44)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.ink.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .task(id: path) { if let path { Backdrop.shared.path = path } }
    }
}

/// A section title over rows of cards.
struct SectionTitle: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
            if let count { Text("\(count)").font(.ui(size: 13, weight: .medium)).foregroundColor(Theme.muted) }
        }
    }
}

/// The app's navigation, down the left side.
struct AppSidebar: View {
    @Binding var active: HomeTab
    @ObservedObject private var activity = TabActivity.shared
    @ObservedObject private var reels = AutoReelsStore.shared
    @ObservedObject private var podcasts = PodcastStore.shared
    @ObservedObject private var shorts = ShortDoctorModel.shared
    @ObservedObject private var volunteer = VolunteerMode.shared
    @Namespace private var highlight

    /// True while this page has work running, so it's clear it carried on when you left.
    private func working(_ tab: HomeTab) -> Bool {
        switch tab {
        case .autoReels: if reels.activeJobs.contains(where: { !$0.isFinished }) { return true }
        case .podcast: if !podcasts.status.isEmpty { return true }
        case .improve: if shorts.status != nil { return true }
        default: break
        }
        return activity.isWorking(tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { active = .projects } label: {
                HStack(spacing: 10) {
                    LogoMark(size: 30)
                    Text("AUTOCLIP").font(Theme.display(16, weight: .medium)).tracking(2.6).foregroundColor(Theme.cream)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.bottom, 24)

            row("Home", "house", .projects, also: .autoClips)
            if volunteer.enabled {
                row("Results", "chart.line.uptrend.xyaxis", .results)
            } else {
                row("Messages", "rectangle.stack", .messages)
                group("Create")
                row("Clips", "play.rectangle.on.rectangle", .autoReels)
                row("Social Graphics", "rectangle.split.3x1", .social)
                row("Improve a Clip", "wand.and.stars", .improve)
                row("Podcast", "mic", .podcast)
                group("Review")
                row("Rehearse", "text.book.closed", .rehearse)
                row("Assess", "waveform.badge.magnifyingglass", .assess)
                row("Worship", "music.note", .worship)
                row("Results", "chart.line.uptrend.xyaxis", .results)
                row("Approvals", "checkmark.seal", .approvals)
                group("Find")
                row("Search", "magnifyingglass", .search)
                group("Manage")
                row("Brand kit", "paintpalette", .brand)
                row("Storage", "internaldrive", .storage)
                if DataMove.isOwnerMac { row("Licences", "key", .licenses) }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                UpdateChip()
                if !volunteer.enabled {
                    AutoImportChip()
                    AIUsageChip()
                    ContentKindMenu()
                }
                VolunteerChip()
                if !volunteer.enabled { PlanChip() }
                Button { CommandBar.shared.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "command").font(.ui(size: 11.5))
                        Text("K to do anything").font(.ui(size: 12))
                    }
                    .foregroundColor(Theme.faint).padding(.horizontal, 12).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the command bar (⌘K)")
                .popoverTip(CommandBarTip(), arrowEdge: .leading)
            }
            .padding(.horizontal, 6)
        }
        .padding(.top, 44).padding(.bottom, 20).padding(.horizontal, 12)
        .frame(width: 228)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
        .overlay(Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1), alignment: .trailing)
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased()).font(.ui(size: 11.5, weight: .semibold)).tracking(1.6).foregroundColor(Theme.faint)
            .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 4)
    }

    private func row(_ title: String, _ icon: String, _ tab: HomeTab, also: HomeTab? = nil) -> some View {
        SidebarLink(title: title, icon: icon, isActive: active == tab || active == also, working: working(tab), highlight: highlight) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { active = tab }
        }
    }
}

private struct SidebarLink: View {
    let title: String
    let icon: String
    let isActive: Bool
    var working = false
    var highlight: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.ui(size: 13, weight: isActive ? .semibold : .regular)).frame(width: 20)
                    .foregroundColor(isActive ? Theme.sand : Theme.muted)
                Text(title).font(.ui(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : hover ? Theme.text : Theme.ink.opacity(0.72))
                Spacer()
                if working {
                    Circle().fill(Theme.sand).frame(width: 7, height: 7).help("Working")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.13))
                        .matchedGeometryEffect(id: "active", in: highlight)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(hover ? 0.06 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
