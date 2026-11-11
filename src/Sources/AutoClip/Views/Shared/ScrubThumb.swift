import SwiftUI
import AVFoundation
import AppKit

/// Moments to show when the pointer moves across a reel's thumbnail.
enum ScrubFrames {
    struct Moment: Equatable { var path: String; var time: Double; var word: String }

    static func moments(_ draft: ReelDraft, count: Int = 12) -> [Moment] {
        let clips = draft.renderClips
        let total = clips.reduce(0) { $0 + $1.duration }
        guard total > 0, count > 0 else { return [] }
        return (0..<count).compactMap { n in
            var at = total * (Double(n) + 0.5) / Double(count)
            for c in clips {
                if at <= c.duration {
                    let t = c.startTime + at
                    let word = c.words.last { $0.startTime <= t }?.word ?? c.words.first?.word ?? ""
                    return Moment(path: c.sourceVideoPath, time: t, word: word)
                }
                at -= c.duration
            }
            return nil
        }
    }
}

/// A thumbnail that plays through the reel as the pointer moves across it, without opening it.
struct ScrubThumb: View {
    var draft: ReelDraft?
    let path: String
    var faceAspect: CGFloat?

    @State private var position: CGFloat?
    @State private var frames: [Int: NSImage] = [:]
    @State private var moments: [ScrubFrames.Moment] = []
    @State private var loading = false

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        GeometryReader { geo in
            let index = position.map { min(max(moments.count - 1, 0), Int($0 / max(geo.size.width, 1) * CGFloat(moments.count))) }
            ZStack(alignment: .bottom) {
                if let d = draft, let t = ClipMomentThumb.openingTime(d), let aspect = faceAspect {
                    // Each clip shows its own opening moment, so clips are easy to tell apart
                    ClipMomentThumb(path: path, time: t, aspect: aspect)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    ReelThumbnailView(path: path, faceAspect: faceAspect)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                if let index, moments.indices.contains(index) {
                    if let img = frames[index] ?? nearest(index) {
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    }
                    Text(moments[index].word).font(.system(size: max(11, geo.size.width * 0.075), weight: .heavy))
                        .foregroundColor(.white).shadow(color: .black, radius: 3).lineLimit(1)
                        .padding(.bottom, geo.size.height * 0.2)
                    GeometryReader { g in
                        Rectangle().fill(Color.white.opacity(0.25)).frame(height: 3)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Theme.sand).frame(width: (position ?? 0) / max(geo.size.width, 1) * g.size.width, height: 3)
                            }
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(height: 3)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    position = max(0, min(p.x, geo.size.width))
                    load()
                case .ended:
                    position = nil
                }
            }
        }
    }

    /// While a frame is on its way, show the closest one that's ready.
    private func nearest(_ i: Int) -> NSImage? {
        frames.min { abs($0.key - i) < abs($1.key - i) }?.value
    }

    private func load() {
        guard let draft, !loading, moments.isEmpty else { return }
        loading = true
        let list = ScrubFrames.moments(draft)
        moments = list
        Task {
            var generators: [String: AVAssetImageGenerator] = [:]
            for (i, m) in list.enumerated() {
                let key = "\(m.path)|\(Int(m.time * 2))" as NSString
                if let hit = Self.cache.object(forKey: key) { frames[i] = hit; continue }
                guard FileManager.default.fileExists(atPath: m.path) else { continue }
                let gen: AVAssetImageGenerator = generators[m.path] ?? {
                    let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: m.path)))
                    g.appliesPreferredTrackTransform = true
                    g.maximumSize = CGSize(width: 480, height: 480)
                    let slack = CMTime(seconds: 0.5, preferredTimescale: 600)
                    g.requestedTimeToleranceBefore = slack
                    g.requestedTimeToleranceAfter = slack
                    return g
                }()
                generators[m.path] = gen
                if let cg = try? await gen.image(at: CMTime(seconds: m.time, preferredTimescale: 600)).image {
                    let img = NSImage(cgImage: cg, size: .zero)
                    Self.cache.setObject(img, forKey: key)
                    frames[i] = img
                }
            }
            loading = false
        }
    }
}


/// A picture of the moment a clip opens on, framed on the speaker.
struct ClipMomentThumb: View {
    let path: String
    let time: Double
    let aspect: CGFloat
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    /// When the clip's first kept word is said, a beat in so the speaker's mouth is open.
    static func openingTime(_ d: ReelDraft) -> Double? {
        for p in d.pieces {
            for s in p.sentences where s.included {
                if let w = s.keptWords.first { return w.startTime + 0.4 }
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.raised2)
            if let image {
                Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: "\(path)|\(Int(time * 10))|\(aspect)") {
            let key = "\(path)|\(Int(time * 10))|\(aspect)" as NSString
            if let hit = Self.cache.object(forKey: key) { image = hit; return }
            guard FileManager.default.fileExists(atPath: path),
                  let cg = await Reframe.frame(path: path, at: time, maxWidth: 720) else { return }
            let a = aspect
            let framed = await Task.detached(priority: .utility) { () -> CGImage in
                if abs(CGFloat(cg.width) / CGFloat(cg.height) - a) < 0.02 { return cg }
                return ReelThumbnailView.frame(cg, aspect: a) ?? ReelThumbnailView.crop(cg, aspect: a, centerX: 0.5, centerY: 0.5) ?? cg
            }.value
            let ns = NSImage(cgImage: framed, size: .zero)
            Self.cache.setObject(ns, forKey: key)
            image = ns
        }
    }
}
