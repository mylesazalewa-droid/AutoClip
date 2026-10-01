import Foundation
import AVFoundation
import AppKit
import Vision
import SwiftUI

class VideoExportService {
    static let shared = VideoExportService()
    private init() {}

    enum ExportFormat: String, CaseIterable {
        case original = "Original"
        case vertical9x16 = "9:16 Vertical"
        case square1x1 = "1:1 Square"
        case horizontal16x9 = "16:9 Horizontal"

        var icon: String {
            switch self {
            case .original: return "film"
            case .vertical9x16: return "iphone"
            case .square1x1: return "square"
            case .horizontal16x9: return "rectangle"
            }
        }
        var description: String {
            switch self {
            case .original: return "Keep source dimensions"
            case .vertical9x16: return "Portrait with face tracking"
            case .square1x1: return "Perfect square"
            case .horizontal16x9: return "Widescreen landscape"
            }
        }
    }

    struct ExportOptions {
        var format: ExportFormat = .original
        var burnCaptions: Bool = false
        var captionStyle: CaptionStyle = CaptionStyle.all[0]
        var captionBgEnabled: Bool = true
        var captionBgOpacity: Double = 0.55
        var captionBgColor: NSColor = .black
    }

    enum ExportError: LocalizedError {
        case missingVideoFile
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingVideoFile: return "Video file not found"
            case .exportFailed(let m): return m
            }
        }
    }

    // MARK: - Main Export

    func exportClip(_ clip: Clip, from project: Project, options: ExportOptions, outputURL: URL, progress: @escaping (Double) -> Void) async throws {
        let videoURL = URL(fileURLWithPath: project.videoPath)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw ExportError.missingVideoFile
        }

        let asset = AVURLAsset(url: videoURL)
        let clipStart = CMTime(seconds: clip.startTime, preferredTimescale: 600)
        let clipDuration = CMTime(seconds: clip.endTime - clip.startTime, preferredTimescale: 600)
        let clipTimeRange = CMTimeRange(start: clipStart, duration: clipDuration)

        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.exportFailed("No video track found")
        }
        let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        let videoSize = visualSize(naturalSize: naturalSize, transform: preferredTransform)

        // Build trimmed composition
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportFailed("Failed to create track")
        }
        try compVideo.insertTimeRange(clipTimeRange, of: sourceVideoTrack, at: .zero)

        if let src = sourceAudioTrack,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(clipTimeRange, of: src, at: .zero)
        }

        let renderSize = computeRenderSize(format: options.format, videoSize: videoSize)

        // Decide whether we actually need to re-encode
        // Passthrough (no re-encode) is possible when: same dimensions AND no captions to burn
        let needsReencode = options.format != .original || (options.burnCaptions && !clip.words.isEmpty)

        // Detect face positions only when we're cropping to a different aspect ratio
        var faceSamples: [(time: Double, centerX: Double)] = []
        let needsFaceTracking = options.format == .vertical9x16 || options.format == .square1x1
        if needsFaceTracking && videoSize.width > videoSize.height {
            faceSamples = await detectFaces(in: asset, clipRange: clipTimeRange, videoSize: videoSize)
        }

        // Preserve preferred transform on the composition track so orientation is correct in passthrough
        compVideo.preferredTransform = preferredTransform

        // Build video composition only when we must re-encode
        var builtVideoComposition: AVMutableVideoComposition? = nil
        if needsReencode {
            let videoComposition = AVMutableVideoComposition()
            // Match the source frame rate to avoid unnecessary frame interpolation
            let nominalFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)
            let fps = nominalFrameRate > 0 ? Int32(nominalFrameRate.rounded()) : 30
            videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
            videoComposition.renderSize = renderSize

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: clipDuration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)

            if faceSamples.isEmpty {
                let t = cropTransform(centerX: videoSize.width / 2, videoSize: videoSize, renderSize: renderSize, preferredTransform: preferredTransform)
                layerInstruction.setTransform(t, at: .zero)
            } else {
                // Use setTransform at each sample point; smoothSamples already applies
                // moving-average + exponential smoothing so 0.5s step changes are imperceptible,
                // and this avoids AVFoundation throwing on floating-point boundary mismatches
                // that setTransformRamp strictly validates.
                for s in faceSamples {
                    let t = cropTransform(centerX: s.centerX, videoSize: videoSize, renderSize: renderSize, preferredTransform: preferredTransform)
                    layerInstruction.setTransform(t, at: CMTime(seconds: s.time, preferredTimescale: 600))
                }
            }

            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]

            // Caption burn via CoreAnimation
            if options.burnCaptions && !clip.words.isEmpty {
                let parentLayer = CALayer()
                parentLayer.frame = CGRect(origin: .zero, size: renderSize)
                parentLayer.isGeometryFlipped = true

                let videoLayer = CALayer()
                videoLayer.frame = CGRect(origin: .zero, size: renderSize)
                parentLayer.addSublayer(videoLayer)

                let captions = buildCaptionLayer(clip: clip, style: options.captionStyle, renderSize: renderSize,
                                                 bgEnabled: options.captionBgEnabled, bgOpacity: options.captionBgOpacity, bgColor: options.captionBgColor)
                parentLayer.addSublayer(captions)

                videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
            }

            builtVideoComposition = videoComposition
        }

        if !needsReencode {
            // Lossless path: ffmpeg -c copy guarantees zero re-encoding, no quality loss
            try await ffmpegCopyTrim(input: videoURL, output: outputURL,
                                     start: clip.startTime, duration: clip.endTime - clip.startTime,
                                     progress: progress)
            return
        }

        // Re-encode path (format change or captions)
        try? FileManager.default.removeItem(at: outputURL)
        // Pass the original source asset so HEVC/iPhone videos get the correct fallback preset
        let preset = bestExportPreset(for: composition, sourceAsset: asset)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.exportFailed("Failed to create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        if let vc = builtVideoComposition { session.videoComposition = vc }
        session.timeRange = CMTimeRange(start: .zero, duration: clipDuration)

        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            progress(Double(session.progress))
        }
        await session.export()
        timer.invalidate()

        if session.status == .cancelled {
            throw ExportError.exportFailed("Export failed: video format not supported. Try 'Original' format or captions off.")
        }
        if let err = session.error { throw ExportError.exportFailed(err.localizedDescription) }
        progress(1.0)
    }

    // MARK: - Export preset selection

    /// Pick the best compatible export preset.
    /// IMPORTANT: must check the SOURCE asset (the original file), not the AVMutableComposition —
    /// a composition always reports HighestQuality as compatible regardless of the source codec,
    /// so checking the composition never triggers the HEVC fallback.
    private func bestExportPreset(for composition: AVAsset, sourceAsset: AVAsset? = nil) -> String {
        let checkAsset = sourceAsset ?? composition
        let compatible = AVAssetExportSession.exportPresets(compatibleWith: checkAsset)
        let preferred = AVAssetExportPresetHighestQuality
        guard compatible.contains(preferred) else {
            return AVAssetExportPreset1920x1080
        }
        return preferred
    }

    // MARK: - Geometry

    private func visualSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let s = naturalSize.applying(transform)
        return CGSize(width: abs(s.width), height: abs(s.height))
    }

    private func computeRenderSize(format: ExportFormat, videoSize: CGSize) -> CGSize {
        switch format {
        case .original:
            return videoSize
        case .vertical9x16:
            if videoSize.width > videoSize.height {
                return CGSize(width: round(videoSize.height * 9 / 16), height: videoSize.height)
            }
            return videoSize
        case .square1x1:
            let side = min(videoSize.width, videoSize.height)
            return CGSize(width: side, height: side)
        case .horizontal16x9:
            if videoSize.height > videoSize.width {
                return CGSize(width: videoSize.width, height: round(videoSize.width * 9 / 16))
            }
            return videoSize
        }
    }

    private func cropTransform(centerX: Double, videoSize: CGSize, renderSize: CGSize, preferredTransform: CGAffineTransform) -> CGAffineTransform {
        let clampedX = max(renderSize.width / 2, min(videoSize.width - renderSize.width / 2, centerX))
        let originX = clampedX - renderSize.width / 2
        let originY = (videoSize.height - renderSize.height) / 2
        return preferredTransform.concatenating(CGAffineTransform(translationX: -originX, y: -originY))
    }

    // MARK: - Face Detection

    private func detectFaces(in asset: AVAsset, clipRange: CMTimeRange, videoSize: CGSize) async -> [(time: Double, centerX: Double)] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        let startSec = CMTimeGetSeconds(clipRange.start)
        let endSec = startSec + CMTimeGetSeconds(clipRange.duration)
        let interval = 0.5

        var results: [(time: Double, centerX: Double)] = []
        var t = startSec
        while t <= endSec {
            let cm = CMTime(seconds: t, preferredTimescale: 600)
            let relTime = t - startSec
            if let img = try? generator.copyCGImage(at: cm, actualTime: nil) {
                let cx = await detectFaceCenterX(in: img, sourceWidth: videoSize.width)
                results.append((time: relTime, centerX: cx))
            } else {
                results.append((time: relTime, centerX: videoSize.width / 2))
            }
            t += interval
        }

        return smoothSamples(results)
    }

    private func detectFaceCenterX(in image: CGImage, sourceWidth: CGFloat) async -> Double {
        await withCheckedContinuation { cont in
            let request = VNDetectFaceRectanglesRequest { req, _ in
                guard let obs = req.results as? [VNFaceObservation], let face = obs.first else {
                    cont.resume(returning: Double(sourceWidth / 2))
                    return
                }
                // boundingBox is normalized with origin at bottom-left; midX gives horizontal center
                let cx = Double(face.boundingBox.midX) * Double(sourceWidth)
                cont.resume(returning: cx)
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    private func smoothSamples(_ samples: [(time: Double, centerX: Double)]) -> [(time: Double, centerX: Double)] {
        guard samples.count > 2 else { return samples }

        // Pass 1: wide moving average (window = 15, ~7.5s at 0.5s interval) to kill jitter
        var pass1 = samples
        let w = 15
        for i in 0..<samples.count {
            let lo = max(0, i - w / 2)
            let hi = min(samples.count - 1, i + w / 2)
            let avg = samples[lo...hi].map { $0.centerX }.reduce(0, +) / Double(hi - lo + 1)
            pass1[i] = (time: samples[i].time, centerX: avg)
        }

        // Pass 2: dead-zone — only commit a new center if it moved > 22% of range
        // (wider zone = camera stays put longer before panning)
        guard let minX = pass1.map(\.centerX).min(),
              let maxX = pass1.map(\.centerX).max() else { return pass1 }
        let range = max(maxX - minX, 1)
        let threshold = range * 0.22

        var out = pass1
        var committed = pass1[0].centerX
        for i in 0..<pass1.count {
            if abs(pass1[i].centerX - committed) > threshold {
                committed = pass1[i].centerX
            }
            out[i] = (time: pass1[i].time, centerX: committed)
        }

        // Pass 3: slow exponential smooth — camera barely moves between frames
        var expOut = out
        let alpha = 0.04  // very low = very smooth, cinematic pan
        for i in 1..<out.count {
            expOut[i] = (time: out[i].time,
                         centerX: expOut[i-1].centerX * (1 - alpha) + out[i].centerX * alpha)
        }
        return expOut
    }

    // MARK: - Caption Layer

    private func buildCaptionLayer(clip: Clip, style: CaptionStyle, renderSize: CGSize, bgEnabled: Bool, bgOpacity: Double, bgColor: NSColor) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)

        let fontScale: CGFloat = renderSize.width < 700 ? 0.08 : 0.055
        let fontSize = max(28, renderSize.width * fontScale)
        let areaW = renderSize.width * 0.88
        let areaX = (renderSize.width - areaW) / 2
        let rowH = fontSize * 1.7
        let centerY = renderSize.height * 0.82 // bottom area

        let font = NSFont(name: style.fontName, size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let textColor = nsColor(for: style)
        let strokeColor = nsColor(for: style, stroke: true)

        let words = clip.words.filter { !$0.word.hasPrefix("<|") && !$0.word.hasSuffix("|>") }
        let clipDur = clip.duration

        for word in words {
            let ws = word.startTime - clip.startTime
            let we = word.endTime - clip.startTime
            guard ws >= 0, ws < clipDur else { continue }

            // Background pill
            if bgEnabled {
                let bg = CALayer()
                bg.backgroundColor = bgColor.withAlphaComponent(bgOpacity).cgColor
                bg.cornerRadius = 6
                bg.frame = CGRect(x: areaX - 10, y: centerY - rowH / 2 - 4,
                                  width: areaW + 20, height: rowH + 8)
                bg.opacity = 0
                bg.add(wordAnim(start: ws, end: we, total: clipDur), forKey: "opacity")
                container.addSublayer(bg)
            }

            // Word text layer
            let tl = CATextLayer()
            tl.string = word.word.trimmingCharacters(in: .whitespaces)
            // Use font name string — safest for AVVideoCompositionCoreAnimationTool
            tl.font = font.fontName as CFString
            tl.fontSize = fontSize
            tl.foregroundColor = style.isKaraoke
                ? NSColor(red: 1, green: 0.92, blue: 0, alpha: 1).cgColor
                : textColor.cgColor
            tl.alignmentMode = .center
            tl.truncationMode = .none
            tl.contentsScale = 1.0   // video rendering is 1x — 2x shifts text out of frame
            tl.isWrapped = false
            tl.shadowColor = NSColor.black.cgColor
            tl.shadowOpacity = 0.9
            tl.shadowRadius = 4
            tl.shadowOffset = CGSize(width: 0, height: -1)
            tl.frame = CGRect(x: areaX, y: centerY - rowH / 2, width: areaW, height: rowH)
            tl.opacity = 0
            tl.add(wordAnim(start: ws, end: we, total: clipDur), forKey: "opacity")
            container.addSublayer(tl)
        }

        return container
    }

    private func wordAnim(start: Double, end: Double, total: Double) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        let safeEnd = min(end, total)
        let pre = max(0, start - 0.001) / total
        let s = start / total
        let e = safeEnd / total
        let post = min(1.0, (safeEnd + 0.001) / total)

        anim.keyTimes = [NSNumber(value: 0.0), NSNumber(value: pre), NSNumber(value: s),
                         NSNumber(value: e), NSNumber(value: post), NSNumber(value: 1.0)]
        anim.values   = [NSNumber(value: 0.0), NSNumber(value: 0.0), NSNumber(value: 1.0),
                         NSNumber(value: 1.0), NSNumber(value: 0.0), NSNumber(value: 0.0)]
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        anim.calculationMode = .linear
        return anim
    }

    private func nsColor(for style: CaptionStyle, stroke: Bool = false) -> NSColor {
        let c = stroke ? style.strokeColor : style.textColor
        // Map SwiftUI Color to NSColor via known values
        switch style.name {
        case "Karaoke":   return stroke ? .black : .white
        case "Dark":      return stroke ? .black : .white
        case "Clean":     return stroke ? .clear : .white
        case "Neon":      return stroke ? NSColor(red: 0, green: 0.5, blue: 0.4, alpha: 1) : NSColor(red: 0, green: 1, blue: 0.8, alpha: 1)
        case "Pop":       return stroke ? .black : NSColor(red: 1, green: 1, blue: 0, alpha: 1)
        case "Minimal":   return stroke ? .clear : .white
        case "Fire":      return stroke ? .black : NSColor(red: 1, green: 0.4, blue: 0, alpha: 1)
        case "Beasty":    return stroke ? NSColor(red: 0.5, green: 0, blue: 0.5, alpha: 1) : .white
        case "Matrix":    return stroke ? .black : NSColor(red: 0, green: 1, blue: 0.3, alpha: 1)
        case "Bubblegum": return stroke ? .white : NSColor(red: 1, green: 0.4, blue: 0.7, alpha: 1)
        case "Shadow":    return stroke ? .clear : .white
        case "Chalk":     return stroke ? .clear : NSColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1)
        default:          return stroke ? .clear : .white
        }
    }

    // Legacy signature for backward compatibility
    func exportClip(_ clip: Clip, from project: Project, captionBg: Bool, captionBgOpacity: Double, captionBgColor: NSColor, outputURL: URL, progress: @escaping (Double) -> Void) async throws {
        let opts = ExportOptions(format: .original, burnCaptions: false)
        try await exportClip(clip, from: project, options: opts, outputURL: outputURL, progress: progress)
    }

    // Overload that takes a raw source video URL (used by Auto Reels individual-clip export)
    func exportClip(_ clip: Clip, from videoURL: URL, to outputURL: URL, options: ExportOptions) async throws {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw ExportError.missingVideoFile
        }
        // Build a throwaway Project to reuse the existing exportClip pipeline
        let tempProject = Project(id: UUID(), title: "", videoPath: videoURL.path,
                                  duration: 0, dateCreated: 0, clipCount: 0,
                                  thumbnailData: nil, clips: [])
        try? FileManager.default.removeItem(at: outputURL)
        try await exportClip(clip, from: tempProject, options: options, outputURL: outputURL) { _ in }
    }

    // MARK: - FFmpeg lossless trim

    private func ffmpegPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil) { return bundled }
        let siblings = [
            Bundle.main.bundlePath + "/../Resources/ffmpeg",
            Bundle.main.bundlePath + "/Contents/Resources/ffmpeg"
        ]
        for p in siblings where FileManager.default.fileExists(atPath: p) { return p }
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.fileExists(atPath: p) { return p }
        if let found = try? Process.string(launchPath: "/usr/bin/which", arguments: ["ffmpeg"]).trimmingCharacters(in: .whitespacesAndNewlines),
           !found.isEmpty { return found }
        return nil
    }

    private func ffmpegCopyTrim(input: URL, output: URL, start: Double, duration: Double, progress: @escaping (Double) -> Void) async throws {
        guard let ffmpeg = ffmpegPath() else {
            // Fallback to AVFoundation passthrough if ffmpeg not found
            try await avFoundationPassthrough(input: input, output: output, start: start, duration: duration, progress: progress)
            return
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y",
            "-ss", String(format: "%.6f", start),
            "-i", input.path,
            "-t", String(format: "%.6f", duration),
            "-c", "copy",           // copy all streams — zero re-encoding
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart",
            output.path
        ]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()

        // Simulate progress while ffmpeg runs (it finishes quickly for copy)
        progress(0.1)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                cont.resume()
            }
        }

        if process.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw ExportError.exportFailed("ffmpeg: \(errMsg)")
        }
        progress(1.0)
    }

    private func avFoundationPassthrough(input: URL, output: URL, start: Double, duration: Double, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.exportFailed("Failed to create export session")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in progress(Double(session.progress)) }
        await session.export()
        timer.invalidate()
        if let err = session.error { throw ExportError.exportFailed(err.localizedDescription) }
        progress(1.0)
    }

    // MARK: - Highlight Reel

    // Common filler words/sounds that indicate hesitation or restarts.
    // Used to trim leading/trailing mess and penalise filler-heavy segments.
    private let fillerWords: Set<String> = [
        "um", "uh", "uhh", "hmm", "hm", "er", "ah", "ahh",
        "like", "okay", "ok", "so", "right", "you know", "i mean",
        "basically", "literally", "actually", "anyway"
    ]

    /// Trim a clip's start/end to spoken word boundaries, skipping leading/trailing filler sounds.
    func trimToWordBoundary(_ clip: Clip) -> Clip {
        guard !clip.words.isEmpty else { return clip }
        let inRange = clip.words.filter {
            $0.startTime >= clip.startTime - 0.3 && $0.endTime <= clip.endTime + 0.3
        }
        guard !inRange.isEmpty else { return clip }

        // Skip leading filler words so the clip starts on a real word
        let firstReal = inRange.first {
            let w = $0.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !fillerWords.contains(w)
        } ?? inRange.first!

        // Skip trailing filler words so the clip ends cleanly
        let lastReal = inRange.last {
            let w = $0.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !fillerWords.contains(w)
        } ?? inRange.last!

        var c = clip
        c.startTime = max(0, firstReal.startTime - 0.05)
        c.endTime = lastReal.endTime + 0.15
        return c
    }

    /// Returns (hook, chronologicalRest) where hook is the best opening moment.
    /// Hook = highest score clip that is ≤ hookMaxDuration seconds.
    /// Rest = best-scoring clips that fit within targetDuration — count is auto-determined.
    func selectHookAndClips(
        from clips: [Clip],
        targetDuration: Double,
        hookMaxDuration: Double = 20
    ) -> (hook: Clip?, rest: [Clip]) {
        guard !clips.isEmpty else { return (nil, []) }

        let byScore = clips.sorted { $0.score > $1.score }

        // Best hook: highest score clip under hookMaxDuration; fall back to overall best
        let hookCandidate = byScore.first { $0.duration <= hookMaxDuration } ?? byScore.first!
        let hook = trimToWordBoundary(hookCandidate)
        var usedDuration = hook.duration
        var usedIDs: Set<UUID> = [hookCandidate.id]

        // Auto-ceiling: allow up to all available clips (duration budget is the real limiter)
        let autoCeiling = clips.count

        var selected: [Clip] = []
        for clip in byScore {
            guard !usedIDs.contains(clip.id) else { continue }
            let trimmed = trimToWordBoundary(clip)
            if usedDuration + trimmed.duration > targetDuration { continue }
            selected.append(trimmed)
            usedDuration += trimmed.duration
            usedIDs.insert(clip.id)
            if usedIDs.count >= autoCeiling { break }
        }

        let chronological = selected.sorted { $0.startTime < $1.startTime }
        return (hook, chronological)
    }

    func selectTopClips(from clips: [Clip], targetDuration: Double) -> [Clip] {
        let (hook, rest) = selectHookAndClips(from: clips, targetDuration: targetDuration)
        guard let hook else { return [] }
        return [hook] + rest
    }

    // MARK: - HEVC Auto-conversion

    /// If the source video is HEVC/H.265 (e.g. iPhone), convert it to H.264 via ffmpeg
    /// before processing. Returns the original URL if already H.264 or if ffmpeg is unavailable.
    func convertHEVCIfNeeded(_ url: URL, status: @escaping (String) -> Void) async -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return url }
        let descs = (try? await track.load(.formatDescriptions)) ?? []
        let isHEVC = descs.compactMap { $0 as? CMFormatDescription }.contains {
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC
        }
        guard isHEVC, let ffmpeg = ffmpegPath() else { return url }

        status("Converting iPhone video to H.264 (one-time step)…")
        let tempDir = FileManager.default.temporaryDirectory
        let outURL = tempDir.appendingPathComponent("autoclip_h264_\(UUID().uuidString).mp4")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-i", url.path,
            "-c:v", "libx264", "-crf", "18", "-preset", "fast",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            outURL.path
        ]
        process.standardError = Pipe()
        try? process.run()
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                process.waitUntilExit()
                cont.resume(returning: process.terminationStatus == 0 ? outURL : url)
            }
        }
    }

    // MARK: - Raw transcript segmentation (Opus-style)

    /// Build reel candidates directly from the full transcript, ignoring existing clip boundaries.
    func autoSegmentsFromWords(_ allWords: [Word]) -> [Clip] {
        let sorted = allWords.sorted { $0.startTime < $1.startTime }
        guard !sorted.isEmpty else { return [] }

        let totalDuration = (sorted.last?.endTime ?? 1)

        // Split at genuine sentence boundaries only:
        //   • punctuation (.!?) + any pause > 0.15s → clean sentence end
        //   • very long pause > 1.5s alone (speaker took a breath mid-thought, still split)
        // This prevents mid-sentence cuts.
        var segments: [[Word]] = []
        var current: [Word] = []

        for i in 0..<sorted.count {
            let w = sorted[i]
            current.append(w)
            let nextGap = i < sorted.count - 1 ? sorted[i + 1].startTime - w.endTime : 99.0
            let endsWithSentence = w.word.last.map { ".!?".contains($0) } ?? false
            let endsWithComma    = w.word.last == ","

            // Hard boundary: sentence-ending punctuation + small pause
            let hardBoundary = endsWithSentence && nextGap > 0.15
            // Soft boundary: long silence (speaker stopped) — only if we already have ≥5s
            let currentDur = (current.last?.endTime ?? 0) - (current.first?.startTime ?? 0)
            let softBoundary = nextGap > 1.5 && currentDur >= 5.0 && !endsWithComma

            if hardBoundary || softBoundary {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }

        // Merge consecutive short segments until each is at least 8s.
        // This ensures every clip has enough substance to make sense on its own.
        var merged: [[Word]] = []
        var i = 0
        while i < segments.count {
            var seg = segments[i]
            while true {
                let dur = (seg.last?.endTime ?? 0) - (seg.first?.startTime ?? 0)
                if dur < 8.0 && i < segments.count - 1 {
                    i += 1; seg += segments[i]
                } else { break }
            }
            merged.append(seg)
            i += 1
        }

        // Split over-long segments (> 50s) at the nearest sentence boundary to the midpoint.
        var finalSegs: [[Word]] = []
        for seg in merged {
            let dur = (seg.last?.endTime ?? 0) - (seg.first?.startTime ?? 0)
            guard dur > 50 else { finalSegs.append(seg); continue }
            // Find sentence-boundary word closest to midpoint
            let targetTime = (seg.first?.startTime ?? 0) + dur / 2
            let splitIdx = seg.indices.min(by: { a, b in
                let aEndsPunct = seg[a].word.last.map { ".!?".contains($0) } ?? false
                let bEndsPunct = seg[b].word.last.map { ".!?".contains($0) } ?? false
                if aEndsPunct && !bEndsPunct { return true }
                if !aEndsPunct && bEndsPunct { return false }
                return abs(seg[a].endTime - targetTime) < abs(seg[b].endTime - targetTime)
            }) ?? seg.count / 2
            if splitIdx > 0 && splitIdx < seg.count - 1 {
                finalSegs.append(Array(seg[...splitIdx]))
                finalSegs.append(Array(seg[(splitIdx + 1)...]))
            } else {
                finalSegs.append(seg)
            }
        }

        // Engaging hook words — phrases/words that signal a strong standalone moment
        let hookWords = Set(["actually","honestly","here's","the truth","never","always","everyone",
                              "nobody","secret","wrong","mistake","warning","stop","wait","listen",
                              "important","key","point","remember","god","jesus","bible","pray","faith",
                              "love","life","believe","hope","church","spirit","blessing","power",
                              "if you","you need","you have","you can","i want","let me","think about",
                              "imagine","consider","what if","the reason","the problem","the answer"])

        // Score and convert to Clips
        return finalSegs.compactMap { words -> Clip? in
            guard let first = words.first, let last = words.last else { return nil }
            let dur = last.endTime - first.startTime
            // Must have enough words and time to form a complete thought
            guard dur >= 6, words.count >= 8 else { return nil }
            // Must end on a sentence boundary (complete thought)
            let endsClean = last.word.last.map { ".!?".contains($0) } ?? false
            guard endsClean else { return nil }

            // Measure filler density — skip segments where >20% of words are fillers
            let cleanWords = words.map { $0.word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let fillerCount = cleanWords.filter { fillerWords.contains($0) }.count
            let fillerRatio = Double(fillerCount) / Double(max(1, cleanWords.count))
            guard fillerRatio <= 0.20 else { return nil }

            // Count long internal pauses (>0.6s) — each one is a hesitation or stumble
            var internalPauses = 0
            for i in 1..<words.count {
                let gap = words[i].startTime - words[i - 1].endTime
                if gap > 0.6 { internalPauses += 1 }
            }

            let text = words.map { $0.word.lowercased() }.joined(separator: " ")
            // Count hook-word matches in the full text
            let hookCount = Double(hookWords.filter { text.contains($0) }.count)
            // Reward segments with exclamations/questions (more engaging delivery)
            let emphasisBonus = Double(words.filter { $0.word.last.map { "!?".contains($0) } ?? false }.count) * 4.0
            // Penalise very short or very long clips
            let lenScore: Double = dur < 10 ? dur * 1.5 : (dur <= 30 ? 20.0 : max(0, 20 - (dur - 30) * 0.5))
            // Small bonus for content early in the video (stronger hook potential)
            let posScore = (first.startTime / max(1, totalDuration)) < 0.25 ? 10.0 : 0.0
            // Penalise filler-heavy and hesitant delivery
            let fillerPenalty = fillerRatio * 25.0
            let pausePenalty  = Double(internalPauses) * 4.0

            let score = min(100, max(0, lenScore + hookCount * 10 + emphasisBonus + posScore - fillerPenalty - pausePenalty))

            let title = words.prefix(8).map { $0.word }.joined(separator: " ")
            return Clip(id: UUID(), title: title, startTime: max(0, first.startTime - 0.1),
                        endTime: last.endTime + 0.15, score: score, scoreReason: "Auto-segmented from transcript",
                        words: words, isLiked: false, starRating: 0,
                        captionStyleName: "Karaoke", aspectRatio: "9:16", notes: "", thumbnailData: nil)
        }
    }

    func createHighlightReel(
        clips: [Clip],
        sourceVideoURL: URL,
        outputURL: URL,
        options: ExportOptions = ExportOptions(),
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceVideoURL)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let srcVideo = videoTracks.first else {
            throw ExportError.exportFailed("No video track in source file")
        }

        let naturalSize  = try await srcVideo.load(.naturalSize)
        let prefTransform = try await srcVideo.load(.preferredTransform)
        let videoSize    = visualSize(naturalSize: naturalSize, transform: prefTransform)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportFailed("Could not create composition video track")
        }
        compVideo.preferredTransform = prefTransform

        let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let srcAudio  = audioTracks.first

        // ── Pass 1: stitch clips + remap words to reel timeline ──────────────
        var insertTime    = CMTime.zero
        var reelOffset    = 0.0
        var remappedWords = [Word]()

        for (i, clip) in clips.enumerated() {
            await MainActor.run { progress(Double(i) / Double(clips.count) * 0.25, "Stitching clip \(i + 1) of \(clips.count)...") }

            let dur   = clip.endTime - clip.startTime
            let start = CMTime(seconds: clip.startTime, preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: CMTime(seconds: dur, preferredTimescale: 600))

            try compVideo.insertTimeRange(range, of: srcVideo, at: insertTime)
            if let compAudio, let srcAudio { try? compAudio.insertTimeRange(range, of: srcAudio, at: insertTime) }

            // Remap word times from source → reel timeline, filtering filler words from captions
            for w in clip.words {
                let relS = w.startTime - clip.startTime
                let relE = w.endTime   - clip.startTime
                guard relS >= 0, relS < dur else { continue }
                // Don't display filler sounds in karaoke captions
                let clean = w.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard !fillerWords.contains(clean) else { continue }
                var rw = w; rw.startTime = reelOffset + relS; rw.endTime = reelOffset + relE
                remappedWords.append(rw)
            }

            insertTime  = CMTime(seconds: CMTimeGetSeconds(insertTime) + dur, preferredTimescale: 600)
            reelOffset += dur
        }

        let reelDuration = reelOffset
        let renderSize   = computeRenderSize(format: options.format, videoSize: videoSize)
        let needsEncode  = options.format != .original || (options.burnCaptions && !remappedWords.isEmpty)

        // ── Pass 2: per-segment face tracking + build video composition ───────
        var videoComposition: AVMutableVideoComposition? = nil

        if needsEncode {
            let nomFPS = try await srcVideo.load(.nominalFrameRate)
            let fps    = nomFPS > 0 ? Int32(nomFPS.rounded()) : 30
            let vc     = AVMutableVideoComposition()
            vc.frameDuration = CMTime(value: 1, timescale: fps)
            vc.renderSize    = renderSize

            let needsFace = options.format == .vertical9x16 || options.format == .square1x1

            var instructions  = [AVMutableVideoCompositionInstruction]()
            var segStart      = CMTime.zero

            for (i, clip) in clips.enumerated() {
                await MainActor.run { progress(0.25 + Double(i) / Double(clips.count) * 0.35, "Analyzing clip \(i + 1)...") }

                let segDur   = CMTime(seconds: clip.endTime - clip.startTime, preferredTimescale: 600)
                let segRange = CMTimeRange(start: segStart, duration: segDur)
                let instr    = AVMutableVideoCompositionInstruction()
                instr.timeRange = segRange

                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)

                if needsFace && videoSize.width > videoSize.height {
                    let srcRange = CMTimeRange(start: CMTime(seconds: clip.startTime, preferredTimescale: 600), duration: segDur)
                    let faces    = await detectFaces(in: asset, clipRange: srcRange, videoSize: videoSize)
                    let segBase  = CMTimeGetSeconds(segStart)

                    if faces.isEmpty {
                        // Fallback: center crop when face detection yields nothing
                        let t = cropTransform(centerX: videoSize.width / 2, videoSize: videoSize, renderSize: renderSize, preferredTransform: prefTransform)
                        li.setTransform(t, at: segStart)
                    } else {
                        for f in faces {
                            let tStart = CMTime(seconds: segBase + f.time, preferredTimescale: 600)
                            let tFrom  = cropTransform(centerX: f.centerX, videoSize: videoSize, renderSize: renderSize, preferredTransform: prefTransform)
                            li.setTransform(tFrom, at: tStart)
                        }
                    }
                } else {
                    let t = cropTransform(centerX: videoSize.width / 2, videoSize: videoSize, renderSize: renderSize, preferredTransform: prefTransform)
                    li.setTransform(t, at: segStart)
                }

                instr.layerInstructions = [li]
                instructions.append(instr)
                segStart = CMTime(seconds: CMTimeGetSeconds(segStart) + CMTimeGetSeconds(segDur), preferredTimescale: 600)
            }

            vc.instructions = instructions

            // Captions over full reel using remapped word timeline
            if options.burnCaptions && !remappedWords.isEmpty {
                let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: renderSize); parent.isGeometryFlipped = true
                let vl = CALayer(); vl.frame = CGRect(origin: .zero, size: renderSize); parent.addSublayer(vl)

                // Virtual clip: startTime=0, words already in reel time
                var reelClip = clips[0]
                reelClip.startTime = 0; reelClip.endTime = reelDuration; reelClip.words = remappedWords
                let captionLayer = buildCaptionLayer(clip: reelClip, style: options.captionStyle, renderSize: renderSize,
                                                     bgEnabled: options.captionBgEnabled, bgOpacity: options.captionBgOpacity, bgColor: options.captionBgColor)
                parent.addSublayer(captionLayer)
                vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: vl, in: parent)
            }

            videoComposition = vc
        }

        // ── Pass 3: export ────────────────────────────────────────────────────
        await MainActor.run { progress(0.65, "Exporting reel...") }

        // AVAssetExportSession requires output URL to not already exist
        try? FileManager.default.removeItem(at: outputURL)

        // Pass the original source asset — compositions always report HighestQuality as compatible
        // so checking the composition alone never triggers the HEVC/iPhone fallback preset.
        let preset = bestExportPreset(for: composition, sourceAsset: asset)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.exportFailed("Could not create export session")
        }
        session.outputURL  = outputURL
        session.outputFileType = .mp4
        if let vc = videoComposition { session.videoComposition = vc }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            let p = 0.65 + Double(session.progress) * 0.35
            DispatchQueue.main.async { progress(p, "Exporting reel...") }
        }
        RunLoop.main.add(timer, forMode: .common)
        await session.export()
        timer.invalidate()

        if session.status == .cancelled {
            throw ExportError.exportFailed("Export failed: video format not supported. Try 'Original' format or ensure the video is H.264 (MP4).")
        }
        if let err = session.error { throw ExportError.exportFailed(err.localizedDescription) }
        await MainActor.run { progress(1.0, "Done!") }
    }
}

private extension Process {
    static func string(launchPath: String, arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
