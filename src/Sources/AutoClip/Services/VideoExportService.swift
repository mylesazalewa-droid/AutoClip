import Foundation
import AVFoundation
import AppKit
import Vision
import SwiftUI

// Deterministic RNG for reproducible per-reel variation shuffles
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 6364136223846793005 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

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
        var topicKeywords: [String] = []
        var crossDissolve: Bool = false
        var emojiOverlays: Bool = false
        /// When set, overrides captionStyle / captionBg* with the user's custom look
        var captionLook: CaptionLook? = nil
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
                applyFaceTrack(faceSamples, to: layerInstruction, base: .zero, end: clipDuration,
                               videoSize: videoSize, renderSize: renderSize, preferredTransform: preferredTransform)
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
                                                 bgEnabled: options.captionBgEnabled, bgOpacity: options.captionBgOpacity, bgColor: options.captionBgColor,
                                                 look: options.captionLook)
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
            // A 9:16 crop of 1080p is only 608x1080 — export at a full 1080x1920 instead
            let w = videoSize.width > videoSize.height ? round(videoSize.height * 9 / 16) : videoSize.width
            if w < 1080 { return CGSize(width: 1080, height: 1920) }
            return videoSize.width > videoSize.height ? CGSize(width: w, height: videoSize.height) : videoSize
        case .square1x1:
            let side = min(videoSize.width, videoSize.height)
            let out = max(side, 1080)
            return CGSize(width: out, height: out)
        case .horizontal16x9:
            if videoSize.height > videoSize.width {
                return CGSize(width: videoSize.width, height: round(videoSize.width * 9 / 16))
            }
            return videoSize
        }
    }

    private func cropTransform(centerX: Double, videoSize: CGSize, renderSize: CGSize, preferredTransform: CGAffineTransform) -> CGAffineTransform {
        // Largest window with the output's aspect ratio that fits in the source,
        // then scale it to fill renderSize (renderSize may be larger than the crop).
        let aspect = renderSize.width / renderSize.height
        let cropH = min(videoSize.height, videoSize.width / aspect)
        let cropW = cropH * aspect
        let scale = renderSize.width / cropW
        let clampedX = max(cropW / 2, min(videoSize.width - cropW / 2, centerX))
        let originX = clampedX - cropW / 2
        let originY = (videoSize.height - cropH) / 2
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -originX, y: -originY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Glide the crop between face samples with transform ramps (instead of jumping every sample).
    /// All times are integer CMTimes clamped to `end`, so ramps are contiguous and never overlap
    /// or overrun the instruction's time range (which AVFoundation rejects).
    private func applyFaceTrack(_ samples: [(time: Double, centerX: Double)],
                                to li: AVMutableVideoCompositionLayerInstruction,
                                base: CMTime, end: CMTime, videoSize: CGSize, renderSize: CGSize,
                                preferredTransform: CGAffineTransform) {
        func at(_ sec: Double) -> CMTime {
            CMTimeMinimum(CMTimeAdd(base, CMTime(value: Int64((sec * 600).rounded()), timescale: 600)), end)
        }
        for i in samples.indices {
            let tA = at(samples[i].time)
            guard CMTimeCompare(tA, end) < 0 else { break }
            let a = cropTransform(centerX: samples[i].centerX, videoSize: videoSize,
                                  renderSize: renderSize, preferredTransform: preferredTransform)
            if i + 1 < samples.count {
                let tB = at(samples[i + 1].time)
                if CMTimeCompare(tB, tA) > 0 {
                    let b = cropTransform(centerX: samples[i + 1].centerX, videoSize: videoSize,
                                          renderSize: renderSize, preferredTransform: preferredTransform)
                    li.setTransformRamp(fromStart: a, toEnd: b, timeRange: CMTimeRange(start: tA, end: tB))
                    continue
                }
            }
            li.setTransform(a, at: tA)
        }
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

        var raw: [(time: Double, centerX: Double?)] = []
        var t = startSec
        while t <= endSec {
            let cm = CMTime(seconds: t, preferredTimescale: 600)
            var cx: Double? = nil
            if let img = try? generator.copyCGImage(at: cm, actualTime: nil) {
                cx = await detectFaceCenterX(in: img, sourceWidth: videoSize.width)
            }
            raw.append((time: t - startSec, centerX: cx))
            t += interval
        }

        // Missed detections hold the last known position instead of snapping to center
        guard let firstHit = raw.first(where: { $0.centerX != nil })?.centerX else {
            return raw.map { (time: $0.time, centerX: Double(videoSize.width / 2)) }
        }
        var last = firstHit
        let filled = raw.map { r -> (time: Double, centerX: Double) in
            if let cx = r.centerX { last = cx }
            return (time: r.time, centerX: last)
        }
        return smoothSamples(filled, frameWidth: Double(videoSize.width))
    }

    private func detectFaceCenterX(in image: CGImage, sourceWidth: CGFloat) async -> Double? {
        await withCheckedContinuation { cont in
            let request = VNDetectFaceRectanglesRequest { req, _ in
                // Follow the largest (closest) face, not whichever Vision lists first
                guard let obs = req.results as? [VNFaceObservation],
                      let face = obs.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                             < $1.boundingBox.width * $1.boundingBox.height }) else {
                    cont.resume(returning: nil)
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

    private func smoothSamples(_ samples: [(time: Double, centerX: Double)], frameWidth: Double) -> [(time: Double, centerX: Double)] {
        guard samples.count > 2 else { return samples }

        // Pass 1: median (window 5 ≈ 2.5s) removes one-off misdetections without lagging
        var pass1 = samples
        for i in samples.indices {
            let win = samples[max(0, i - 2)...min(samples.count - 1, i + 2)].map(\.centerX).sorted()
            pass1[i] = (time: samples[i].time, centerX: win[win.count / 2])
        }

        // Pass 2: dead zone — hold the frame steady unless the speaker moves > 6% of frame width
        let threshold = frameWidth * 0.06
        var held = pass1
        var committed = pass1[0].centerX
        for i in pass1.indices {
            if abs(pass1[i].centerX - committed) > threshold { committed = pass1[i].centerX }
            held[i] = (time: pass1[i].time, centerX: committed)
        }

        // Pass 3: ease into each new position over ~1.5s; ramps interpolate between samples
        var out = held
        let alpha = 0.3
        for i in 1..<held.count {
            out[i] = (time: held[i].time,
                      centerX: out[i - 1].centerX * (1 - alpha) + held[i].centerX * alpha)
        }
        return out
    }

    // MARK: - Caption Layer

    // Emoji overlays: hook words trigger a contextual emoji floating above the caption
    private static let emojiMap: [(words: [String], emoji: String)] = [
        (["god","jesus","christ","lord","pray","prayer","faith","spirit","holy","blessed","blessing","church","bible","gospel","worship","savior","salvation"], "🙏"),
        (["fire","power","strength","bold","force","energy","fuel","burn","ignite","passion"], "🔥"),
        (["love","heart","care","compassion","kindness","mercy","grace","forgive"], "❤️"),
        (["money","success","rich","wealth","million","business","profit","income","earn"], "💰"),
        (["truth","light","wisdom","knowledge","secret","answer","key","understand","revelation"], "💡"),
        (["win","victory","champion","greatest","amazing","incredible","powerful","unstoppable"], "🏆"),
        (["change","transform","new","different","shift","revolution","breakthrough","move"], "⚡️"),
        (["celebrate","happy","joy","grateful","thankful","excited","accomplish"], "🎉"),
    ]

    private func buildCaptionLayer(clip: Clip, style: CaptionStyle, renderSize: CGSize,
                                   bgEnabled: Bool, bgOpacity: Double, bgColor: NSColor,
                                   keywords: Set<String> = [], emojiOverlays: Bool = false,
                                   look: CaptionLook? = nil) -> CALayer {
        if let look {
            return buildLookCaptionLayer(clip: clip, look: look, renderSize: renderSize, emojiOverlays: emojiOverlays)
        }
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)

        let fontScale: CGFloat = renderSize.width < 700 ? 0.08 : 0.055
        let fontSize = max(28, renderSize.width * fontScale)
        let keyFontSize = fontSize * 1.08  // keywords pop slightly larger
        let areaW = renderSize.width * 0.88
        let areaX = (renderSize.width - areaW) / 2
        let rowH = fontSize * 1.7
        let centerY = renderSize.height * 0.82

        let font = NSFont(name: style.fontName, size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let textColor = nsColor(for: style)
        let karaokeBase = NSColor(red: 1, green: 0.92, blue: 0, alpha: 1)     // standard gold
        let karaokeKey  = NSColor(red: 1, green: 1,    blue: 0.55, alpha: 1)  // brighter gold for keywords

        let words = clip.words.filter { !$0.word.hasPrefix("<|") && !$0.word.hasSuffix("|>") }
        let clipDur = clip.duration

        // Build per-word emoji lookup once
        var wordEmoji: [String: String] = [:]
        if emojiOverlays {
            for entry in Self.emojiMap {
                for w in entry.words { wordEmoji[w] = entry.emoji }
            }
        }

        for word in words {
            let ws = word.startTime - clip.startTime
            let we = word.endTime - clip.startTime
            guard ws >= 0, ws < clipDur else { continue }

            let clean = word.word.trimmingCharacters(in: .whitespaces)
            let lower = clean.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let isKeyword = keywords.contains(lower) || keywords.contains(clean.lowercased())

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
            tl.string = clean
            tl.font = font.fontName as CFString
            tl.fontSize = isKeyword ? keyFontSize : fontSize
            if style.isKaraoke {
                tl.foregroundColor = isKeyword ? karaokeKey.cgColor : karaokeBase.cgColor
            } else {
                tl.foregroundColor = textColor.cgColor
            }
            tl.alignmentMode = .center
            tl.truncationMode = .none
            tl.contentsScale = 1.0
            tl.isWrapped = false
            tl.shadowColor = NSColor.black.cgColor
            tl.shadowOpacity = isKeyword ? 1.0 : 0.9
            tl.shadowRadius = isKeyword ? 6 : 4
            tl.shadowOffset = CGSize(width: 0, height: -1)
            // CATextLayer draws from the top of its frame, so size it to one line and center it in the row
            let lineH = (isKeyword ? keyFontSize : fontSize) * 1.25
            tl.frame = CGRect(x: areaX, y: centerY - lineH / 2, width: areaW, height: lineH)
            tl.opacity = 0
            tl.add(wordAnim(start: ws, end: we, total: clipDur), forKey: "opacity")
            // Off-screen layers are never drawn by the export renderer — without this the
            // caption pill shows but the words are blank.
            tl.setNeedsDisplay(); tl.displayIfNeeded()
            container.addSublayer(tl)

            // Emoji overlay — pop up above the text at the keyword's spoken moment
            if emojiOverlays, let emoji = wordEmoji[lower] {
                let emojiSize = fontSize * 1.6
                let el = CATextLayer()
                el.string = emoji
                el.font = NSFont.systemFont(ofSize: emojiSize).fontName as CFString
                el.fontSize = emojiSize
                el.alignmentMode = .center
                el.contentsScale = 1.0
                el.isWrapped = false
                el.frame = CGRect(x: renderSize.width / 2 - areaW / 4,
                                  y: centerY + rowH * 0.6,
                                  width: areaW / 2, height: emojiSize * 1.5)
                el.opacity = 0
                el.add(wordAnim(start: ws, end: min(we + 0.3, clipDur), total: clipDur), forKey: "opacity")
                el.setNeedsDisplay(); el.displayIfNeeded()
                container.addSublayer(el)
            }
        }

        return container
    }

    /// Edits-style captions: phrases of N words, the spoken word highlighted, optional outline
    /// and a pill background sized to the text. One layer per word (the full phrase with that
    /// word highlighted), each visible from its word's start until the next word starts.
    private func buildLookCaptionLayer(clip: Clip, look: CaptionLook, renderSize: CGSize,
                                       emojiOverlays: Bool) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)

        let fontSize = look.fontSize(forRenderWidth: renderSize.width)
        let maxW = renderSize.width * 0.86
        let centerY = renderSize.height * CGFloat(look.position)
        let clipDur = clip.duration

        var wordEmoji: [String: String] = [:]
        if emojiOverlays {
            for entry in Self.emojiMap { for w in entry.words { wordEmoji[w] = entry.emoji } }
        }

        // Clip-relative timing; drop Whisper control tokens and words outside the clip
        let words: [(text: String, start: Double, end: Double)] = clip.words.compactMap { w in
            let t = w.word.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("<|"), !t.hasSuffix("|>") else { return nil }
            let ws = w.startTime - clip.startTime, we = min(w.endTime - clip.startTime, clipDur)
            guard ws >= 0, ws < clipDur else { return nil }
            return (t, ws, max(we, ws + 0.05))
        }
        let phrases = CaptionLook.phrases(words, maxWords: look.wordsPerCaption,
                                          text: { $0.text }, start: { $0.start }, end: { $0.end })

        for phrase in phrases {
            let texts = phrase.map(\.text)
            let phraseStart = phrase.first!.start
            let phraseEnd = min(phrase.last!.end, clipDur)

            // Measure with the widest variant so the pill doesn't jump between words
            let measured = look.measure(look.attributedPhrase(texts, active: nil, fontSize: fontSize), maxWidth: maxW)
            let textH = measured.height + fontSize * 0.1
            let textRect = CGRect(x: (renderSize.width - maxW) / 2, y: centerY - textH / 2, width: maxW, height: textH)

            if look.bgEnabled {
                let padX = fontSize * 0.35, padY = fontSize * 0.18
                let bg = CALayer()
                bg.backgroundColor = look.bgColor.nsColor.withAlphaComponent(CGFloat(look.bgOpacity)).cgColor
                bg.cornerRadius = fontSize * 0.25
                bg.frame = CGRect(x: (renderSize.width - measured.width) / 2 - padX, y: textRect.minY - padY,
                                  width: measured.width + padX * 2, height: textH + padY * 2)
                bg.opacity = 0
                bg.add(wordAnim(start: phraseStart, end: phraseEnd, total: clipDur), forKey: "opacity")
                container.addSublayer(bg)
            }

            for (j, w) in phrase.enumerated() {
                let start = j == 0 ? phraseStart : w.start
                let end = j + 1 < phrase.count ? phrase[j + 1].start : phraseEnd
                guard end > start else { continue }

                let tl = CATextLayer()
                tl.string = look.attributedPhrase(texts, active: j, fontSize: fontSize)
                tl.isWrapped = true
                tl.alignmentMode = .center
                tl.truncationMode = .none
                tl.contentsScale = 1.0
                tl.shadowColor = NSColor.black.cgColor
                tl.shadowOpacity = look.bgEnabled ? 0 : 0.8
                tl.shadowRadius = 4
                tl.shadowOffset = CGSize(width: 0, height: -1)
                tl.frame = textRect
                tl.opacity = 0
                tl.add(wordAnim(start: start, end: end, total: clipDur), forKey: "opacity")
                // Off-screen layers are never drawn by the export renderer unless forced
                tl.setNeedsDisplay(); tl.displayIfNeeded()
                container.addSublayer(tl)

                let lower = w.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if emojiOverlays, let emoji = wordEmoji[lower] {
                    let emojiSize = fontSize * 1.4
                    let el = CATextLayer()
                    el.string = emoji
                    el.fontSize = emojiSize
                    el.alignmentMode = .center
                    el.contentsScale = 1.0
                    el.frame = CGRect(x: renderSize.width / 2 - emojiSize, y: textRect.minY - emojiSize * 1.6,
                                      width: emojiSize * 2, height: emojiSize * 1.4)
                    el.opacity = 0
                    el.add(wordAnim(start: w.start, end: min(w.end + 0.3, clipDur), total: clipDur), forKey: "opacity")
                    el.setNeedsDisplay(); el.displayIfNeeded()
                    container.addSublayer(el)
                }
            }
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

        // Skip trailing filler only if what's left still ends a sentence —
        // never trade a complete ending ("…you know.") for a mid-sentence one
        let lastReal: Word = {
            guard let candidate = inRange.last(where: {
                !fillerWords.contains($0.word.lowercased().trimmingCharacters(in: .punctuationCharacters))
            }) else { return inRange.last! }
            let endsSentence = candidate.word.last.map { ".!?\"”".contains($0) } ?? false
            return endsSentence ? candidate : inRange.last!
        }()

        // Keep the segment's own edge padding when no words were dropped at that edge
        var c = clip
        if firstReal.id != inRange.first!.id { c.startTime = max(0, firstReal.startTime - 0.05) }
        if lastReal.id != inRange.last!.id { c.endTime = lastReal.endTime + 0.2 }
        return c
    }

    /// Returns (hook, chronologicalRest) where hook is the best opening moment.
    /// Hook = highest score clip that is ≤ min(targetDuration*0.45, 45) seconds.
    /// Rest = best-scoring clips that fit within targetDuration — count is auto-determined.
    func selectHookAndClips(
        from clips: [Clip],
        targetDuration: Double,
        variation: Int = 0,
        previouslyUsedIDs: Set<UUID> = []
    ) -> (hook: Clip?, rest: [Clip]) {
        let hookMaxDuration = min(targetDuration * 0.45, 45.0)
        guard !clips.isEmpty else { return (nil, []) }

        // For variation > 0, shuffle clips within score tiers so each reel picks different moments.
        // Clips within 15 points of each other are considered equally strong and get shuffled.
        var rng = SeededRNG(seed: UInt64(variation))
        let tierSize: Double = 15.0
        let byScore: [Clip]
        if variation > 0 {
            let maxScore = clips.map { $0.score }.max() ?? 100
            var tiers: [[Clip]] = []
            var tier: [Clip] = []
            var tierCeiling = maxScore
            for clip in clips.sorted(by: { $0.score > $1.score }) {
                if clip.score < tierCeiling - tierSize {
                    if !tier.isEmpty { tiers.append(tier.shuffled(using: &rng)); tier = [] }
                    tierCeiling = clip.score
                }
                tier.append(clip)
            }
            if !tier.isEmpty { tiers.append(tier.shuffled(using: &rng)) }
            byScore = tiers.flatMap { $0 }
        } else {
            byScore = clips.sorted { $0.score > $1.score }
        }

        // Partition: fresh clips first (not used in any prior reel), then reused ones as fallback.
        // This ensures reel N picks different moments from reel N-1 without sacrificing quality.
        let fresh = byScore.filter { !previouslyUsedIDs.contains($0.id) }
        let fallback = byScore.filter { previouslyUsedIDs.contains($0.id) }
        let ordered = fresh + fallback

        // Best hook: prefer fresh, highest score clip under hookMaxDuration; fall back to overall best
        let hookCandidate = ordered.first { $0.duration <= hookMaxDuration } ?? ordered.first!
        let hook = trimToWordBoundary(hookCandidate)
        var usedDuration = hook.duration
        var usedIDs: Set<UUID> = [hookCandidate.id]

        // Quality floor: only add clips that score at least 50% of the hook's score.
        // This stops the reel from padding with weak/unrelated moments just to hit the target.
        // The reel will be shorter than requested if not enough quality clips exist — that's correct.
        let qualityFloor = hookCandidate.score * 0.50

        var selected: [Clip] = []
        for clip in ordered {
            guard !usedIDs.contains(clip.id) else { continue }
            guard clip.score >= qualityFloor else { continue }          // skip weak clips
            let trimmed = trimToWordBoundary(clip)
            if usedDuration + trimmed.duration > targetDuration * 1.15 { continue }  // don't exceed target
            selected.append(trimmed)
            usedDuration += trimmed.duration
            usedIDs.insert(clip.id)
        }

        let chronological = selected.sorted { $0.startTime < $1.startTime }
        return (hook, chronological)
    }

    func selectTopClips(from clips: [Clip], targetDuration: Double, variation: Int = 0) -> [Clip] {
        let (hook, rest) = selectHookAndClips(from: clips, targetDuration: targetDuration, variation: variation)
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
    /// `sourceVideoPath` is stamped onto every returned clip so multi-source reels work.
    func autoSegmentsFromWords(_ allWords: [Word], sourceVideoPath: String = "") -> [Clip] {
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
            // Soft boundary: the speaker fully stopped (not just a breath) — only if we already have ≥5s
            let currentDur = (current.last?.endTime ?? 0) - (current.first?.startTime ?? 0)
            let softBoundary = nextGap > 2.5 && currentDur >= 5.0 && !endsWithComma

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
        var longSplit: [[Word]] = []
        for seg in merged {
            let dur = (seg.last?.endTime ?? 0) - (seg.first?.startTime ?? 0)
            guard dur > 50 else { longSplit.append(seg); continue }
            let targetTime = (seg.first?.startTime ?? 0) + dur / 2
            let splitIdx = seg.indices.min(by: { a, b in
                let aEndsPunct = seg[a].word.last.map { ".!?".contains($0) } ?? false
                let bEndsPunct = seg[b].word.last.map { ".!?".contains($0) } ?? false
                if aEndsPunct && !bEndsPunct { return true }
                if !aEndsPunct && bEndsPunct { return false }
                return abs(seg[a].endTime - targetTime) < abs(seg[b].endTime - targetTime)
            }) ?? seg.count / 2
            if splitIdx > 0 && splitIdx < seg.count - 1 {
                longSplit.append(Array(seg[...splitIdx]))
                longSplit.append(Array(seg[(splitIdx + 1)...]))
            } else {
                longSplit.append(seg)
            }
        }

        // ── Take deduplication (runs on full segments, before pause-split) ───────────
        // If the same content appears twice with a reset pause between the segments
        // (speaker stopped, restarted), keep only the better delivery and drop the rest.
        // Running this BEFORE pause-split ensures all sub-clips of a bad take are removed,
        // not just the last fragment.
        let protoClips: [Clip] = longSplit.compactMap { words in
            guard let first = words.first, let last = words.last else { return nil }
            return Clip(id: UUID(), title: first.word,
                        startTime: first.startTime, endTime: last.endTime + 0.15,
                        score: 0, scoreReason: "", words: words,
                        isLiked: false, starRating: 0,
                        captionStyleName: "Karaoke", aspectRatio: "9:16", notes: "")
        }
        let deduped     = deduplicateTakes(protoClips)
        let dedupedIDs  = Set(deduped.map { $0.id })
        let survivingGroups = zip(longSplit, protoClips)
            .filter { dedupedIDs.contains($1.id) }
            .map    { $0.0 }

        // Segments stay whole sentences. (A previous pass re-split them at every 0.4s pause,
        // but speakers breathe mid-sentence constantly — that was producing clips that started
        // and ended mid-thought.)
        let finalSegs = survivingGroups

        // Word index lookup so we can check what comes right before a segment
        var prevWordEnd: [UUID: (word: String, gap: Double)] = [:]
        for (i, w) in sorted.enumerated() where i > 0 {
            prevWordEnd[w.id] = (sorted[i - 1].word, w.startTime - sorted[i - 1].endTime)
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
            // Require clean sentence-ending punctuation for short/sparse clips.
            // Non-clean-ending fragments must be longer (>8s, 10+ words) to avoid mid-sentence cuts.
            // Every candidate must be a complete thought: begin where a sentence begins and
            // finish on sentence-ending punctuation (or right before the speaker stops talking).
            let endsClean = (last.word.last.map { ".!?\"”".contains($0) } ?? false)
            let nextGap = sorted.first(where: { $0.startTime > last.startTime }).map { $0.startTime - last.endTime } ?? 99
            guard endsClean || nextGap > 2.5 else { return nil }
            if let prev = prevWordEnd[first.id] {
                let prevEndsSentence = prev.word.trimmingCharacters(in: .whitespaces).last.map { ".!?\"”".contains($0) } ?? false
                guard prevEndsSentence || prev.gap > 2.5 else { return nil }
            }
            guard dur >= 6.0, words.count >= 10 else { return nil }

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
            // Strong bonus for complete sentences — penalise mid-statement fragments
            let cleanEndBonus = endsClean ? 18.0 : -8.0
            // Openers like "And…"/"But…"/"So…" sound like the middle of a thought
            let opener = first.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let openerPenalty: Double = ["and", "but", "so", "because", "or", "then", "which", "that"].contains(opener) ? 10.0 : 0.0
            // Penalise filler-heavy and hesitant delivery
            let fillerPenalty = fillerRatio * 25.0
            let pausePenalty  = Double(internalPauses) * 4.0

            let score = min(100, max(0, lenScore + hookCount * 10 + emphasisBonus + posScore + cleanEndBonus - fillerPenalty - pausePenalty - openerPenalty))

            let title = words.prefix(8).map { $0.word }.joined(separator: " ")
            // Pad edges so the last syllable isn't clipped, without catching neighbouring words
            let prevGap = prevWordEnd[first.id]?.gap ?? 1
            let headPad = min(0.15, max(0.02, prevGap - 0.05))
            let tailPad = min(0.35, max(0.1, nextGap - 0.05))
            var clip = Clip(id: UUID(), title: title, startTime: max(0, first.startTime - headPad),
                            endTime: last.endTime + tailPad, score: score, scoreReason: "Auto-segmented from transcript",
                            words: words, isLiked: false, starRating: 0,
                            captionStyleName: "Karaoke", aspectRatio: "9:16", notes: "", thumbnailData: nil)
            clip.sourceVideoPath = sourceVideoPath
            return clip
        }
    }

    // MARK: - Take deduplication

    /// Detects retakes: consecutive clips separated by a 1.5–15 s reset pause that cover
    /// substantially the same words. From each group keeps only the best-quality take.
    ///
    /// Threshold logic:
    ///  • Very tight gap (1.5–5 s)  → speaker clearly restarted; require ≥15 % word overlap
    ///    OR treat as retake if the previous clip was very short (< 6 significant words).
    ///  • Medium gap (5–15 s)       → require ≥28 % word overlap.
    func deduplicateTakes(_ clips: [Clip]) -> [Clip] {
        guard clips.count > 1 else { return clips }

        var result: [Clip] = []
        var i = 0

        while i < clips.count {
            var group = [clips[i]]

            while i + 1 < clips.count {
                let prev = group.last!
                let next = clips[i + 1]
                let gap  = next.startTime - prev.endTime

                guard gap >= 1.5 && gap <= 15.0 else { break }

                let prevBag = Set(prev.words
                    .map { $0.word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                    .filter { $0.count > 3 })
                let nextBag = Set(next.words
                    .map { $0.word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                    .filter { $0.count > 3 })

                // A very short previous clip (<6 significant words) is almost always
                // a partial/failed attempt — count it as a retake regardless of overlap.
                let prevIsPartial = prevBag.count < 6

                let threshold: Double = gap <= 5.0 ? 0.15 : 0.28
                let similarity: Double
                if prevBag.isEmpty || nextBag.isEmpty {
                    similarity = prevIsPartial ? 1.0 : 0.0
                } else {
                    let shared = Double(prevBag.intersection(nextBag).count)
                    let total  = Double(prevBag.union(nextBag).count)
                    similarity = shared / total
                }

                guard prevIsPartial || similarity >= threshold else { break }

                group.append(next)
                i += 1
            }

            if group.count > 1 {
                let best = group.max { takeQuality($0) < takeQuality($1) } ?? group.last!
                result.append(best)
            } else {
                result.append(group[0])
            }
            i += 1
        }
        return result
    }

    /// Quality score used only for take comparison (not the reel scoring system).
    private func takeQuality(_ clip: Clip) -> Double {
        let words = clip.words
        guard !words.isEmpty else { return 0 }

        let fillerCount = words.filter {
            fillerWords.contains($0.word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }.count

        var shortPauses = 0
        for j in 1..<words.count {
            if words[j].startTime - words[j - 1].endTime > 0.25 { shortPauses += 1 }
        }

        let endsClean  = words.last?.word.last.map { ".!?".contains($0) } ?? false
        let completion = endsClean ? 8.0 : 0.0

        // More words = more complete; penalise hesitations heavily
        return Double(words.count) + completion
             - Double(fillerCount) * 3.0
             - Double(shortPauses) * 2.0
    }

    func createHighlightReel(
        clips: [Clip],
        sourceVideoURL: URL,
        outputURL: URL,
        options: ExportOptions = ExportOptions(),
        progress: @escaping (Double, String) -> Void
    ) async throws {
        // Cache loaded assets so multi-source reels don't reload the same file repeatedly
        var assetCache: [String: AVURLAsset] = [:]
        func sourceAsset(for clip: Clip) -> AVURLAsset {
            let path = clip.sourceVideoPath.isEmpty ? sourceVideoURL.path : clip.sourceVideoPath
            if let cached = assetCache[path] { return cached }
            let a = AVURLAsset(url: URL(fileURLWithPath: path))
            assetCache[path] = a
            return a
        }

        // Determine render dimensions from the first clip's source
        let primaryAsset = sourceAsset(for: clips[0])
        guard let primaryVideoTrack = try await primaryAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.exportFailed("No video track in source file")
        }
        let primaryNaturalSize  = try await primaryVideoTrack.load(.naturalSize)
        let primaryTransform    = try await primaryVideoTrack.load(.preferredTransform)
        let primaryVideoSize    = visualSize(naturalSize: primaryNaturalSize, transform: primaryTransform)
        let renderSize          = computeRenderSize(format: options.format, videoSize: primaryVideoSize)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportFailed("Could not create composition video track")
        }
        compVideo.preferredTransform = primaryTransform
        var compAudio: AVMutableCompositionTrack? = nil  // created lazily only when a source has audio

        // ── Pass 1: stitch clips + remap words to reel timeline ──────────────
        var insertTime      = CMTime.zero
        var reelOffset      = 0.0
        var remappedWords   = [Word]()
        var insertedClips   = [Clip]()     // only clips that actually made it into the composition
        var clipInsertTimes = [CMTime]()   // exact timeline position of each inserted clip

        for (i, clip) in clips.enumerated() {
            await MainActor.run { progress(Double(i) / Double(clips.count) * 0.25, "Stitching clip \(i + 1) of \(clips.count)...") }

            let clipAsset = sourceAsset(for: clip)
            guard let srcVideo = try? await clipAsset.loadTracks(withMediaType: .video).first else { continue }
            let srcAudio = try? await clipAsset.loadTracks(withMediaType: .audio).first

            // Clamp clip to asset duration — prevents "Operation Stopped" when endTime
            // overshoots the source file (common for the last clip or floating-point drift)
            let assetDurSecs = CMTimeGetSeconds((try? await clipAsset.load(.duration)) ?? .positiveInfinity)
            let clampedStart = min(max(0, clip.startTime), assetDurSecs - 0.1)
            let clampedEnd   = min(clip.endTime, assetDurSecs)
            let dur = clampedEnd - clampedStart
            guard dur > 0.1 else { continue }

            let start = CMTime(seconds: clampedStart, preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: CMTime(seconds: dur, preferredTimescale: 600))

            do {
                try compVideo.insertTimeRange(range, of: srcVideo, at: insertTime)
            } catch {
                continue  // skip clips whose range can't be inserted (malformed asset)
            }
            clipInsertTimes.append(insertTime)  // record exact CMTime before advancing
            if let srcAudio {
                if compAudio == nil {
                    compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try? compAudio?.insertTimeRange(range, of: srcAudio, at: insertTime)
            }

            // Remap word times from source → reel timeline, filtering filler words from captions
            for w in clip.words {
                let relS = w.startTime - clip.startTime
                let relE = w.endTime   - clip.startTime
                guard relS >= 0, relS < dur else { continue }
                let clean = w.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                guard !fillerWords.contains(clean) else { continue }
                var rw = w; rw.startTime = reelOffset + relS; rw.endTime = reelOffset + relE
                remappedWords.append(rw)
            }

            // Store the CLAMPED clip so Pass 2 uses the same duration that was actually inserted
            var insertedClip = clip
            insertedClip.startTime = clampedStart
            insertedClip.endTime   = clampedEnd
            insertedClips.append(insertedClip)
            insertTime  = CMTime(seconds: CMTimeGetSeconds(insertTime) + dur, preferredTimescale: 600)
            reelOffset += dur
        }

        guard !insertedClips.isEmpty else {
            throw ExportError.exportFailed("No clips could be inserted — check that the video file is not corrupted and the clip timestamps are within the video duration.")
        }

        let reelDuration = reelOffset
        let needsEncode  = options.format != .original || (options.burnCaptions && !remappedWords.isEmpty)

        // ── Pass 2: per-segment face tracking + build video composition ───────
        var videoComposition: AVMutableVideoComposition? = nil

        if needsEncode {
            let nomFPS = try await primaryVideoTrack.load(.nominalFrameRate)
            let fps    = nomFPS > 0 ? Int32(nomFPS.rounded()) : 30
            let vc     = AVMutableVideoComposition()
            vc.frameDuration = CMTime(value: 1, timescale: fps)
            vc.renderSize    = renderSize

            let needsFace = options.format == .vertical9x16 || options.format == .square1x1

            var instructions = [AVMutableVideoCompositionInstruction]()

            for (i, clip) in insertedClips.enumerated() {
                let segStart = clipInsertTimes[i]  // use exact CMTime from Pass 1 — no floating-point drift
                await MainActor.run { progress(0.25 + Double(i) / Double(insertedClips.count) * 0.35, "Analyzing clip \(i + 1)...") }

                let clipAsset = sourceAsset(for: clip)
                // Get this clip's source dimensions for correct crop transform
                let clipNatSize  = (try? await clipAsset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? primaryNaturalSize
                let clipTransform = (try? await clipAsset.loadTracks(withMediaType: .video).first?.load(.preferredTransform)) ?? primaryTransform
                let clipVideoSize = visualSize(naturalSize: clipNatSize, transform: clipTransform)

                let segDur   = CMTime(seconds: clip.endTime - clip.startTime, preferredTimescale: 600)
                let segRange = CMTimeRange(start: segStart, duration: segDur)
                let instr    = AVMutableVideoCompositionInstruction()
                instr.timeRange = segRange

                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)

                if needsFace && clipVideoSize.width > clipVideoSize.height {
                    let srcRange = CMTimeRange(start: CMTime(seconds: clip.startTime, preferredTimescale: 600), duration: segDur)
                    let faces    = await detectFaces(in: clipAsset, clipRange: srcRange, videoSize: clipVideoSize)

                    if faces.isEmpty {
                        let t = cropTransform(centerX: clipVideoSize.width / 2, videoSize: clipVideoSize, renderSize: renderSize, preferredTransform: clipTransform)
                        li.setTransform(t, at: segStart)
                    } else {
                        applyFaceTrack(faces, to: li, base: segStart, end: segRange.end,
                                       videoSize: clipVideoSize, renderSize: renderSize, preferredTransform: clipTransform)
                    }
                } else {
                    let t = cropTransform(centerX: clipVideoSize.width / 2, videoSize: clipVideoSize, renderSize: renderSize, preferredTransform: clipTransform)
                    li.setTransform(t, at: segStart)
                }

                // Cross-dissolve: fade out at end of each clip, fade in at start
                if options.crossDissolve {
                    let dissolveDurSecs = 0.18
                    let dissolveTime = CMTime(seconds: dissolveDurSecs, preferredTimescale: 600)
                    let segSecs = CMTimeGetSeconds(segDur)
                    if i > 0, segSecs > dissolveTime.seconds * 2 {
                        li.setOpacityRamp(fromStartOpacity: 0.0, toEndOpacity: 1.0,
                                          timeRange: CMTimeRange(start: segStart, duration: dissolveTime))
                    }
                    if i < insertedClips.count - 1, segSecs > dissolveTime.seconds * 2 {
                        let fadeStart = CMTime(seconds: CMTimeGetSeconds(segStart) + segSecs - dissolveDurSecs, preferredTimescale: 600)
                        li.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0,
                                          timeRange: CMTimeRange(start: fadeStart, duration: dissolveTime))
                    }
                }

                instr.layerInstructions = [li]
                instructions.append(instr)
            }

            // Extend the last instruction to cover exactly the composition end.
            // Floating-point accumulation across many clips can leave a tiny gap between
            // the final instruction's end and the composition's true duration, which
            // causes AVFoundation to return "Operation Stopped" (-11803).
            // Use the composition's actual duration (not reelOffset) as the canonical end.
            let compActualDur = try await composition.load(.duration)
            let compEnd = compActualDur > .zero ? compActualDur : CMTime(seconds: reelOffset, preferredTimescale: 600)
            if instructions.isEmpty {
                // Fallback: single passthrough instruction covering the whole composition
                let passthrough = AVMutableVideoCompositionInstruction()
                passthrough.timeRange = CMTimeRange(start: .zero, duration: compEnd)
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
                passthrough.layerInstructions = [li]
                instructions.append(passthrough)
            } else {
                let lastStart = instructions[instructions.count - 1].timeRange.start
                if compEnd > lastStart {
                    instructions[instructions.count - 1].timeRange =
                        CMTimeRange(start: lastStart, duration: compEnd - lastStart)
                }
            }

            vc.instructions = instructions

            if options.burnCaptions && !remappedWords.isEmpty {
                let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: renderSize); parent.isGeometryFlipped = true
                let vl = CALayer(); vl.frame = CGRect(origin: .zero, size: renderSize); parent.addSublayer(vl)
                var reelClip = clips[0]
                reelClip.startTime = 0; reelClip.endTime = reelDuration; reelClip.words = remappedWords
                let keywordSet = Set(options.topicKeywords.map { $0.lowercased() })
                let captionLayer = buildCaptionLayer(clip: reelClip, style: options.captionStyle, renderSize: renderSize,
                                                     bgEnabled: options.captionBgEnabled, bgOpacity: options.captionBgOpacity,
                                                     bgColor: options.captionBgColor,
                                                     keywords: keywordSet, emojiOverlays: options.emojiOverlays,
                                                     look: options.captionLook)
                parent.addSublayer(captionLayer)
                vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: vl, in: parent)
            }

            videoComposition = vc
        }

        // ── Pass 3: export ────────────────────────────────────────────────────
        await MainActor.run { progress(0.65, "Exporting reel...") }

        // Load the true composition duration so we can set an explicit timeRange on the session.
        // This prevents AVFoundation from guessing the duration (which can cause -11803).
        let compDurationForExport = (try? await composition.load(.duration)) ?? CMTime(seconds: reelOffset, preferredTimescale: 600)

        // AVAssetExportSession requires output URL to not already exist
        try? FileManager.default.removeItem(at: outputURL)

        // When a videoComposition is in use, frames are being re-composited — AVFoundation
        // cannot do a passthrough export.  AVAssetExportPresetHighestQuality is a passthrough
        // preset and fails (-11803 "Operation Stopped") in that case.  Use a resolution-
        // specific preset instead, which always triggers a full re-encode.
        let preset: String
        if videoComposition != nil {
            // Size presets are bounding boxes that only scale DOWN, and they compare against
            // landscape dimensions — 1920x1080 would shrink a 1080x1920 reel to 608x1080.
            // The 4K box fits every render size we produce, so output == renderSize.
            preset = AVAssetExportPreset3840x2160
        } else {
            preset = bestExportPreset(for: composition, sourceAsset: primaryAsset)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.exportFailed("Could not create export session")
        }
        session.outputURL   = outputURL
        session.outputFileType = .mp4
        session.timeRange   = CMTimeRange(start: .zero, duration: compDurationForExport)
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
