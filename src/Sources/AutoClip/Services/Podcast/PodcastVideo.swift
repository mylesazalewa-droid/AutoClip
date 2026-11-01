import AVFoundation
import AppKit
import QuartzCore

/// Builds the edited video: every camera angle on its own track, the shot plan switching
/// between them (and zooming into one camera to make extra shots), cropped for each size,
/// with a title card, end card and name labels on export.
enum PodcastVideo {
    static let formats = ["16:9", "9:16", "1:1", "4:5"]
    static let formatNames = ["16:9": "YouTube 16:9", "9:16": "Vertical 9:16", "1:1": "Square 1:1", "4:5": "Feed 4:5"]

    static func renderSize(_ f: String) -> CGSize {
        switch f {
        case "9:16": return CGSize(width: 1080, height: 1920)
        case "1:1": return CGSize(width: 1080, height: 1080)
        case "4:5": return CGSize(width: 1080, height: 1350)
        default: return CGSize(width: 1920, height: 1080)
        }
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static func t(_ s: Double) -> CMTime { CMTime(value: Int64((max(0, s) * 600).rounded()), timescale: 600) }

    // MARK: Framing

    /// The part of the source (in its upright pixels) a shot shows at the output's shape.
    static func crop(person: PodcastEpisode.Person?, angle: Int, zoom: Double, src: CGSize, out: CGSize,
                     group: [[Double]], fallback: PodcastEpisode.Person?) -> CGRect {
        let W = Double(src.width), H = Double(src.height)
        let aspect = Double(out.width / out.height)
        var baseH = min(H, W / aspect)
        var baseW = baseH * aspect
        func box(_ p: PodcastEpisode.Person) -> [Double]? {
            p.angle == angle ? [p.x, p.y, p.w, p.h] : p.otherAngles[angle]
        }
        func clampRect(_ cx: Double, _ originY: Double, _ w: Double, _ h: Double) -> CGRect {
            let x = max(0, min(W - w, cx - w / 2)), y = max(0, min(H - h, originY))
            return CGRect(x: x, y: y, width: w, height: h)
        }
        func closeUp(_ b: [Double], zoom: Double) -> CGRect {
            let ratio = aspect >= 1.5 ? 0.30 : aspect >= 0.95 ? 0.24 : aspect >= 0.75 ? 0.22 : 0.19
            var h = b[3] * H / ratio / max(1, zoom)
            h = max(H * 0.5, min(baseH, h))
            var w = h * aspect
            if w > W { w = W; h = W / aspect }
            let fcx = (b[0] + b[2] / 2) * W, fcy = (b[1] + b[3] / 2) * H
            return clampRect(fcx, fcy - 0.40 * h, w, h)
        }
        if let p = person, let b = box(p) { return closeUp(b, zoom: zoom) }
        // Wide: everyone in this angle, if they fit the shape; otherwise whoever is talking
        if !group.isEmpty {
            let lo = group.map { $0[0] }.min()! * W, hi = group.map { $0[0] + $0[2] }.max()! * W
            if hi - lo <= baseW * 0.92 || aspect >= Double(src.width / src.height) - 0.01 {
                let z = max(1, zoom)
                baseW /= z; baseH /= z
                return clampRect((lo + hi) / 2, (H - baseH) / 2 * (z > 1 ? 0.6 : 1), baseW, baseH)
            }
            if let f = fallback, let b = box(f) {
                let fcx = (b[0] + b[2] / 2) * W
                return clampRect(fcx, (H - baseH) / 2, baseW, baseH)
            }
        }
        let z = max(1, zoom)
        baseW /= z; baseH /= z
        return clampRect(W / 2, (H - baseH) / 2, baseW, baseH)
    }

    // MARK: Building

    struct Built {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition?
        var renderSize: CGSize
        var duration: Double
    }

    /// `program` = the finished sound (with intro lead-in); without it the original sound is used
    /// and there is no lead-in (for previews).
    static func build(_ e: PodcastEpisode, format: String, program: (url: URL, lead: Double, total: Double)?,
                      previewHeight: CGFloat? = nil, overlays: Bool = false) async throws -> Built {
        let comp = AVMutableComposition()
        let lead = program?.lead ?? 0
        let kept = e.keptRanges
        let edited = e.editedDuration
        let total = program?.total ?? edited

        // Video tracks, one per angle
        struct AngleTrack { var track: AVMutableCompositionTrack; var size: CGSize; var transform: CGAffineTransform }
        var angles: [AngleTrack?] = []
        if !e.isAudioOnly {
            for a in e.angles {
                let asset = AVURLAsset(url: URL(fileURLWithPath: a.path))
                guard let src = try await asset.loadTracks(withMediaType: .video).first,
                      let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    angles.append(nil); continue
                }
                let nat = try await src.load(.naturalSize), pt = try await src.load(.preferredTransform)
                let vis = nat.applying(pt)
                let dur = CMTimeGetSeconds(try await asset.load(.duration))
                var out = lead
                for r in kept {
                    let s = max(0, r.lowerBound - a.offset), en = min(dur, r.upperBound - a.offset)
                    if en > s + 0.01 {
                        let at = out + (s - (r.lowerBound - a.offset))
                        try? ct.insertTimeRange(CMTimeRange(start: t(s), end: t(en)), of: src, at: t(at))
                    }
                    out += r.upperBound - r.lowerBound
                }
                angles.append(AngleTrack(track: ct, size: CGSize(width: abs(vis.width), height: abs(vis.height)), transform: pt))
            }
        }

        // Sound
        if let program {
            let pa = AVURLAsset(url: program.url)
            if let src = try await pa.loadTracks(withMediaType: .audio).first,
               let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try at.insertTimeRange(CMTimeRange(start: .zero, duration: try await pa.load(.duration)), of: src, at: .zero)
            }
        } else if let a = e.angles.first {
            let asset = AVURLAsset(url: URL(fileURLWithPath: a.path))
            if let src = try await asset.loadTracks(withMediaType: .audio).first,
               let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var out = 0.0
                for r in kept {
                    try? at.insertTimeRange(CMTimeRange(start: t(r.lowerBound), end: t(r.upperBound)), of: src, at: t(out))
                    out += r.upperBound - r.lowerBound
                }
            }
        }

        let live = angles.compactMap { $0 }
        guard !live.isEmpty else { return Built(composition: comp, videoComposition: nil, renderSize: .zero, duration: total) }

        var size = renderSize(format)
        if let h = previewHeight, size.height > h {
            let s = h / size.height
            size = CGSize(width: (size.width * s / 2).rounded() * 2, height: (size.height * s / 2).rounded() * 2)
        }

        // Shot plan → opacity and framing changes per angle
        var opacity: [Int: [Double: Float]] = [:]
        var framing: [Int: [Double: CGAffineTransform]] = [:]
        for (k, a) in angles.enumerated() where a != nil { opacity[k] = [0: 0]; framing[k] = [:] }
        let shots = e.shots.isEmpty ? [PodcastEpisode.Shot(start: 0, end: e.duration, angle: 0, person: nil)] : e.shots
        for shot in shots {
            let s = lead + e.editedTime(shot.start), en = lead + e.editedTime(shot.end)
            let k = (angles[safe: shot.angle] ?? nil) != nil ? shot.angle : (angles.firstIndex { $0 != nil } ?? 0)
            guard en > s, let a = angles[k] else { continue }
            let group = e.people.compactMap { p -> [Double]? in p.angle == k ? [p.x, p.y, p.w, p.h] : p.otherAngles[k] }
            let rect = crop(person: e.person(shot.person), angle: k, zoom: shot.zoom, src: a.size, out: size,
                            group: group, fallback: e.person(e.speaker(at: (shot.start + shot.end) / 2)))
            let scale = size.width / rect.width
            let tf = a.transform
                .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            for (j, b) in angles.enumerated() where b != nil { opacity[j]![s] = j == k ? 1 : 0 }
            framing[k]![s] = tf
        }
        if lead + edited < total { for k in opacity.keys { opacity[k]![lead + edited] = 0 } }

        let ins = AVMutableVideoCompositionInstruction()
        // Must cover the composition exactly, or playback shows nothing
        ins.timeRange = CMTimeRange(start: .zero, duration: program == nil ? comp.duration : t(total))
        ins.backgroundColor = NSColor.black.cgColor
        ins.layerInstructions = angles.enumerated().compactMap { k, a in
            guard let a else { return nil }
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: a.track)
            for (time, v) in opacity[k]!.sorted(by: { $0.key < $1.key }) where time < total { li.setOpacity(v, at: t(time)) }
            let frames = framing[k]!.sorted { $0.key < $1.key }
            if frames.first.map({ $0.key > 0 }) ?? true {
                li.setTransform(frames.first?.value ?? a.transform, at: .zero)
            }
            for (time, tf) in frames where time < total { li.setTransform(tf, at: t(time)) }
            return li
        }
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [ins]
        if overlays { vc.animationTool = overlayTool(e, size: size, lead: lead, edited: edited, total: total) }
        return Built(composition: comp, videoComposition: vc, renderSize: size, duration: total)
    }

    // MARK: Title card, end card and name labels

    private static func overlayTool(_ e: PodcastEpisode, size: CGSize, lead: Double, edited: Double, total: Double) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer(), video = CALayer(), overlay = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        video.frame = parent.frame
        overlay.frame = parent.frame
        parent.isGeometryFlipped = true
        parent.addSublayer(video)
        parent.addSublayer(overlay)
        let s = e.settings
        let unit = min(size.width, size.height) / 1080

        func fade(_ layer: CALayer, from a: Double, to b: Double, edge: Double = 0.4) {
            layer.opacity = 0
            let anim = CAKeyframeAnimation(keyPath: "opacity")
            let len = max(0.1, b - a)
            anim.values = [0, 1, 1, 0]
            anim.keyTimes = [0, NSNumber(value: min(0.45, edge / len)), NSNumber(value: max(0.55, 1 - edge / len)), 1]
            anim.beginTime = AVCoreAnimationBeginTimeAtZero + max(0.001, a)
            anim.duration = len
            anim.isRemovedOnCompletion = false
            anim.fillMode = .both
            layer.add(anim, forKey: "fade")
        }
        func text(_ str: String, size fs: CGFloat, weight: NSFont.Weight, color: NSColor = .white, width: CGFloat, align: CATextLayerAlignmentMode = .center) -> CATextLayer {
            let l = CATextLayer()
            l.string = NSAttributedString(string: str, attributes: [.font: NSFont.systemFont(ofSize: fs, weight: weight), .foregroundColor: color])
            l.isWrapped = true
            l.alignmentMode = align
            l.contentsScale = 1
            let h = (str as NSString).boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: NSFont.systemFont(ofSize: fs, weight: weight)]).height
            l.frame = CGRect(x: 0, y: 0, width: width, height: ceil(h) + 4)
            // Draw now: the export renders layers offscreen and won't draw text on its own
            l.setNeedsDisplay(); l.displayIfNeeded()
            return l
        }
        let cover = s.coverPath.flatMap { NSImage(contentsOfFile: $0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil)

        /// Cover art (if any) above the title, centred
        func card(from a: Double, to b: Double, subtitle: String?) {
            let card = CALayer()
            card.frame = parent.frame
            card.backgroundColor = NSColor(white: 0, alpha: lead > 0 || b > lead + edited ? 1 : 0.6).cgColor
            var y = size.height * 0.5
            var items: [CALayer] = []
            if let cover {
                let side = min(size.width, size.height) * 0.42
                let img = CALayer()
                img.contents = cover
                img.contentsGravity = .resizeAspectFill
                img.masksToBounds = true
                img.cornerRadius = 18 * unit
                img.frame = CGRect(x: 0, y: 0, width: side, height: side)
                items.append(img)
            }
            let title = text(e.title, size: 64 * unit, weight: .bold, width: size.width * 0.84)
            items.append(title)
            if let subtitle { items.append(text(subtitle, size: 34 * unit, weight: .medium, color: NSColor(white: 1, alpha: 0.7), width: size.width * 0.84)) }
            let gap = 28 * unit
            let totalH = items.map(\.frame.height).reduce(0, +) + gap * CGFloat(items.count - 1)
            y = (size.height - totalH) / 2
            for it in items {
                it.frame.origin = CGPoint(x: (size.width - it.frame.width) / 2, y: y)
                y += it.frame.height + gap
                card.addSublayer(it)
            }
            fade(card, from: a, to: b, edge: 0.6)
            overlay.addSublayer(card)
        }
        if s.titleCard {
            if lead > 0.5 { card(from: 0, to: lead + 0.3, subtitle: nil) }
            else { card(from: 0, to: 3.5, subtitle: nil) }
            if total > lead + edited + 1 { card(from: lead + edited, to: total, subtitle: "Thanks for listening") }
        }

        // Name labels the first time each person is on screen talking
        if s.showNames {
            for p in e.people where !p.name.isEmpty && p.name.range(of: #"^Person \d+$"#, options: .regularExpression) == nil {
                guard let first = e.shots.first(where: { $0.person == p.id && e.editedTime($0.end) - e.editedTime($0.start) > 2 })
                        ?? e.shots.first(where: { $0.person == p.id }) else { continue }
                let start = lead + e.editedTime(first.start) + 0.6
                let box = CALayer()
                let label = text(p.name, size: 40 * unit, weight: .bold, color: .black, width: size.width * 0.7, align: .left)
                let w = min(size.width * 0.8, (p.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 40 * unit, weight: .bold)]).width + 48 * unit)
                let bar = CALayer()
                bar.backgroundColor = NSColor(srgbRed: 1, green: 0.75, blue: 0, alpha: 1).cgColor
                bar.frame = CGRect(x: 0, y: 0, width: 10 * unit, height: label.frame.height + 24 * unit)
                box.backgroundColor = NSColor(white: 1, alpha: 0.94).cgColor
                box.frame = CGRect(x: 60 * unit, y: size.height - (size.height > size.width ? 520 : 200) * unit,
                                   width: w + 10 * unit, height: label.frame.height + 24 * unit)
                label.frame.origin = CGPoint(x: 34 * unit, y: 12 * unit)
                box.addSublayer(bar)
                box.addSublayer(label)
                fade(box, from: start, to: start + 4.5)
                overlay.addSublayer(box)
            }
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }

    // MARK: Export

    static func export(_ e: PodcastEpisode, format: String, program: (url: URL, lead: Double, total: Double),
                       to out: URL, progress: @escaping (Double) -> Void) async throws {
        let built = try await build(e, format: format, program: program, overlays: true)
        guard let vc = built.videoComposition else { throw Failure(message: "This episode has no video.") }
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure(message: "Couldn't start the video export.")
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = vc
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: .zero, duration: t(built.duration))
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in progress(Double(session.progress)) }
        RunLoop.main.add(timer, forMode: .common)
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: { session.cancelExport() }
        timer.invalidate()
        if let err = session.error { throw Failure(message: "Video export failed: \(err.localizedDescription)") }
        if session.status == .cancelled { throw CancellationError() }
    }

    /// A still of one person's face, for naming them.
    static func faceThumbnail(_ e: PodcastEpisode, _ p: PodcastEpisode.Person) async -> NSImage? {
        guard let a = e.angles[safe: p.angle] else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: a.path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        let turn = e.turns.first { $0.person == p.id && $0.end - $0.start > 3 }
        let time = turn.map { ($0.start + $0.end) / 2 - a.offset } ?? min(a.duration, 20)
        guard let (img, _) = try? await gen.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)) else { return nil }
        let W = Double(img.width), H = Double(img.height)
        let side = max(p.w * W, p.h * H) * 1.8
        let cx = (p.x + p.w / 2) * W, cy = (p.y + p.h / 2) * H
        let r = CGRect(x: max(0, min(W - side, cx - side / 2)), y: max(0, min(H - side, cy - side / 2)), width: min(side, W), height: min(side, H))
        guard let c = img.cropping(to: r) else { return nil }
        return NSImage(cgImage: c, size: NSSize(width: 96, height: 96))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
