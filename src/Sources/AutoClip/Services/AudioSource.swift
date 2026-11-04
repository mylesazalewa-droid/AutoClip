import Foundation
import AVFoundation
import AppKit
import CryptoKit
import SwiftUI

/// Lets audio-only files go through everything a video does. The reel pipeline, face tracking
/// and export all work on video, so an audio file first gets a companion video: its artwork (or
/// a mic) and title over a moving waveform, with the original audio. The art stays in the middle
/// of the frame, so it survives a vertical crop. Made once per file, then reused.
enum AudioSource {
    static let types: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "flac", "ogg", "opus", "wma"]

    private static let size = CGSize(width: 1920, height: 1080)
    private static let fps: Int32 = 15
    private static let barCount = 25

    static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/AutoClip/Audio")
    }

    static func isAudioFile(_ url: URL) -> Bool { types.contains(url.pathExtension.lowercased()) }

    /// True for audio files, and for movie files that only hold sound.
    static func needsVideo(_ url: URL) async -> Bool {
        if isAudioFile(url) { return true }
        let asset = AVURLAsset(url: url)
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return video.isEmpty && !audio.isEmpty
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "AutoClip", code: 70, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The companion video for this audio file, making it if needed.
    static func video(for audio: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let values = try? audio.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(audio.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = dir.appendingPathComponent(hash)
        let title = audio.deletingPathExtension().lastPathComponent
        let output = folder.appendingPathComponent("\(title).mp4")
        // Written straight to its final name; the marker says it finished
        let finished = folder.appendingPathComponent(".finished")
        if FileManager.default.fileExists(atPath: finished.path), FileManager.default.fileExists(atPath: output.path) { return output }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let readable = try await readableAudio(audio, in: folder)
        let levels = try await readLevels(readable)
        progress(0.1)
        let background = try await drawBackground(asset: AVURLAsset(url: audio), title: title)
        try? FileManager.default.removeItem(at: output)
        do {
            try await write(audio: readable, levels: levels, background: background, to: output) { progress(0.1 + $0 * 0.9) }
            FileManager.default.createFile(atPath: finished.path, contents: nil)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        if readable != audio { try? FileManager.default.removeItem(at: readable) }
        return output
    }

    /// Ogg, Opus and WMA can't be read by the system, so ffmpeg converts those first.
    private static func readableAudio(_ url: URL, in folder: URL) async throws -> URL {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)) ?? []
        if !tracks.isEmpty { return url }
        guard let ffmpeg = YTDLP.ffmpegPath() else {
            throw fail("AutoClip can't read this audio format. Save it as MP3, M4A or WAV and try again.")
        }
        let out = folder.appendingPathComponent("converted.m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", url.path, "-vn", "-c:a", "aac", "-b:a", "192k", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        guard p.terminationStatus == 0 else { throw fail("Couldn't read this audio file.") }
        return out
    }

    /// How loud the audio is for each video frame, 0…1.
    private static func readLevels(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw fail("This file has no sound in it.")
        }
        let rate = 8000
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? fail("Couldn't read this audio file.") }

        let perFrame = rate / Int(fps)
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        while let buffer = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for i in 0..<(length / 4) {
                    sum += samples[i] * samples[i]
                    count += 1
                    if count == perFrame {
                        levels.append((sum / Float(perFrame)).squareRoot())
                        sum = 0; count = 0
                    }
                }
            }
        }
        if let e = reader.error { throw e }
        guard !levels.isEmpty else { throw fail("This file has no sound in it.") }
        // A loud moment fills the bars, whatever the recording level
        let peak = max(levels.sorted()[Int(Double(levels.count - 1) * 0.98)], 0.0001)
        return levels.map { min(1, ($0 / peak).squareRoot()) }
    }

    private static func context(_ data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext? {
        CGContext(data: data, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func color(_ c: Color) -> CGColor { NSColor(c).usingColorSpace(.deviceRGB)?.cgColor ?? .white }

    /// Everything that doesn't move. Laid out in the middle column so a 9:16 crop keeps it all.
    private static func drawBackground(asset: AVAsset, title: String) async throws -> CGImage {
        var art: NSImage?
        if let items = try? await asset.load(.commonMetadata),
           let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await item.load(.dataValue) { art = NSImage(data: data) }

        guard let ctx = context(nil, bytesPerRow: 0) else { throw fail("Couldn't draw the audio video.") }
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [color(Theme.olive), color(Theme.bg)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: size.width / 2, y: size.height * 0.62), startRadius: 0,
                               endCenter: CGPoint(x: size.width / 2, y: size.height * 0.62), endRadius: size.width * 0.5,
                               options: .drawsAfterEndLocation)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let side: CGFloat = 250
        let tile = NSRect(x: (size.width - side) / 2, y: size.height - 120 - side, width: side, height: side)
        NSBezierPath(roundedRect: tile, xRadius: 26, yRadius: 26).setClip()
        if let art {
            // Fill the square without squashing
            let scale = max(side / max(art.size.width, 1), side / max(art.size.height, 1))
            let w = art.size.width * scale, h = art.size.height * scale
            art.draw(in: NSRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h))
        } else {
            NSColor(Theme.charcoal).setFill()
            tile.fill()
            let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
                .applying(.init(paletteColors: [NSColor(Theme.sand)]))
            if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                mic.draw(in: NSRect(x: tile.midX - mic.size.width / 2, y: tile.midY - mic.size.height / 2,
                                    width: mic.size.width, height: mic.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: 30, weight: .medium)
        let serif = font.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 30) } ?? font
        NSAttributedString(string: YTDLP.title(fromFile: URL(fileURLWithPath: title + ".mp4")),
                           attributes: [.font: serif, .foregroundColor: NSColor(Theme.cream), .paragraphStyle: style])
            .draw(with: NSRect(x: (size.width - 520) / 2, y: tile.minY - 112, width: 520, height: 88),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage() else { throw fail("Couldn't draw the audio video.") }
        return image
    }

    /// Bars spread out from the middle: the centre is now, the edges are a moment ago.
    private static func drawBars(_ ctx: CGContext, levels: [Float], frame: Int, color: CGColor) {
        let barWidth: CGFloat = 10, gap: CGFloat = 10, maxHeight: CGFloat = 150
        let centreY = size.height - 610
        ctx.setFillColor(color)
        for i in 0..<barCount {
            let away = abs(i - barCount / 2)
            let at = frame - away * 2
            let level = at >= 0 && at < levels.count ? CGFloat(levels[at]) : 0
            let h = max(barWidth, level * maxHeight)
            let x = size.width / 2 + CGFloat(i - barCount / 2) * (barWidth + gap) - barWidth / 2
            let rect = CGRect(x: x, y: centreY - h / 2, width: barWidth, height: h)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        }
        ctx.fillPath()
    }

    private final class Pump: @unchecked Sendable {
        let lock = NSLock()
        var failure: Error?
        func fail(_ e: Error) { lock.lock(); if failure == nil { failure = e }; lock.unlock() }
    }

    private static func write(audio: URL, levels: [Float], background: CGImage, to output: URL,
                              progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: audio)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw fail("This file has no sound in it.") }
        let reader = try AVAssetReader(asset: asset)
        let audioOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(audioOut)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        // Mostly still: a low bitrate keeps an hour of audio to a few hundred MB
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000, AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
        videoIn.expectsMediaDataInRealTime = false
        audioIn.expectsMediaDataInRealTime = false
        writer.add(videoIn); writer.add(audioIn)
        guard reader.startReading() else { throw reader.error ?? fail("Couldn't read this audio file.") }
        guard writer.startWriting() else { throw writer.error ?? fail("Couldn't write the audio video.") }
        writer.startSession(atSourceTime: .zero)

        let barColor = color(Theme.sand)
        let total = levels.count
        let pump = Pump()
        var frame = 0
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        audioIn.requestMediaDataWhenReady(on: DispatchQueue(label: "autoclip.audio.a")) {
                            while audioIn.isReadyForMoreMediaData {
                                guard writer.status == .writing, let sample = audioOut.copyNextSampleBuffer() else {
                                    audioIn.markAsFinished(); c.resume(); return
                                }
                                if !audioIn.append(sample) {
                                    pump.fail(writer.error ?? fail("Couldn't write the audio."))
                                    audioIn.markAsFinished(); c.resume(); return
                                }
                            }
                        }
                    }
                }
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "autoclip.audio.v")) {
                            while videoIn.isReadyForMoreMediaData {
                                guard writer.status == .writing, frame < total else {
                                    videoIn.markAsFinished(); c.resume(); return
                                }
                                var buffer: CVPixelBuffer?
                                guard let pool = adaptor.pixelBufferPool,
                                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                                    pump.fail(fail("Couldn't draw the audio video."))
                                    videoIn.markAsFinished(); c.resume(); return
                                }
                                CVPixelBufferLockBaseAddress(buffer, [])
                                if let ctx = context(CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer)) {
                                    ctx.draw(background, in: CGRect(origin: .zero, size: size))
                                    drawBars(ctx, levels: levels, frame: frame, color: barColor)
                                }
                                CVPixelBufferUnlockBaseAddress(buffer, [])
                                if !adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) {
                                    pump.fail(writer.error ?? fail("Couldn't write the audio video."))
                                    videoIn.markAsFinished(); c.resume(); return
                                }
                                frame += 1
                                if frame % 150 == 0 { progress(Double(frame) / Double(total)) }
                            }
                        }
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }
        try Task.checkCancellation()
        if let e = pump.failure { writer.cancelWriting(); throw e }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? fail("Couldn't read this audio file.") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? fail("Couldn't write the audio video.") }
        progress(1)
    }
}
