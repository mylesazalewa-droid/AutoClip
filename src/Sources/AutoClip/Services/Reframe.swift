import Foundation
import AVFoundation
import AppKit
import Vision

/// A person found in a clip, for the "who should this follow?" question.
struct ReframePerson: Identifiable {
    let id = UUID()
    /// Where they sit across the frame, 0…1
    let x: Double
    /// When they were at `x` (source seconds)
    let time: Double
    let face: NSImage
}

/// Finds who's on screen so the reel can ask which of them to follow.
enum Reframe {
    static func frame(path: String, at time: Double, maxWidth: CGFloat = 1280) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        return try? await gen.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    private struct Face { let x: Double; let height: Double; let frame: Int; let box: CGRect; let time: Double }

    /// People on screen together during this stretch, left to right. Someone walking across the
    /// frame is one person, so a second person only counts when two faces share the frame.
    /// Far-off faces (an audience) are left out.
    static func people(in path: String, from start: Double, to end: Double) async -> [ReframePerson] {
        let count = 10
        var images: [CGImage] = []
        var faces: [Face] = []
        for k in 0..<count {
            let t = start + (end - start) * (Double(k) + 0.5) / Double(count)
            guard let img = await frame(path: path, at: t) else { continue }
            for o in await detect(img) where o.confidence > 0.6 && o.boundingBox.height >= 0.06 {
                faces.append(Face(x: o.boundingBox.midX, height: o.boundingBox.height, frame: images.count, box: o.boundingBox, time: t))
            }
            images.append(img)
        }
        guard let biggest = faces.map(\.height).max() else { return [] }
        let main = faces.filter { $0.height >= biggest * 0.45 }.sorted { $0.x < $1.x }

        // Group by position, splitting at gaps
        var groups: [[Face]] = []
        for f in main {
            if let last = groups.last?.last, f.x - last.x < 0.1 { groups[groups.count - 1].append(f) } else { groups.append([f]) }
        }
        let framesWithFaces = Set(main.map(\.frame)).count
        groups = groups.filter { Double(Set($0.map(\.frame)).count) >= Double(framesWithFaces) * 0.3 }
        let together = Dictionary(grouping: main, by: \.frame).values.filter { $0.count >= 2 }.count
        if groups.count > 1, Double(together) < Double(framesWithFaces) * 0.3 { groups = [main] }

        return groups.prefix(5).compactMap { group in
            guard let best = group.max(by: { $0.height < $1.height }), images.indices.contains(best.frame),
                  let face = crop(images[best.frame], around: best.box) else { return nil }
            return ReframePerson(x: best.x, time: best.time, face: face)
        }
    }

    /// Everyone in one frame, as boxes with 0…1 coordinates (origin at the bottom left).
    static func targets(in image: CGImage) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let faces = VNDetectFaceRectanglesRequest()
                let humans = VNDetectHumanRectanglesRequest()
                humans.upperBodyOnly = false
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([faces, humans])
                let bodies = (humans.results ?? []).map(\.boundingBox).filter { $0.height > 0.2 }
                // A face inside a body is the same person
                let lone = (faces.results ?? []).map(\.boundingBox).filter { f in f.height >= 0.04 && !bodies.contains { $0.contains(CGPoint(x: f.midX, y: f.midY)) } }
                continuation.resume(returning: bodies + lone)
            }
        }
    }

    /// Vision blocks while it works, so it runs off the shared task threads.
    private static func detect(_ image: CGImage) async -> [VNFaceObservation] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                continuation.resume(returning: request.results ?? [])
            }
        }
    }

    private static func crop(_ image: CGImage, around box: CGRect) -> NSImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let side = max(box.width * w, box.height * h) * 1.7
        let rect = CGRect(x: box.midX * w - side / 2, y: (1 - box.midY) * h - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let c = image.cropping(to: rect) else { return nil }
        return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
    }
}

/// Thumbnails and sound levels across a whole reel, for the audio view.
enum ReelMedia {
    static func thumbnails(_ asset: AVAsset, duration: Double, count: Int) async -> [CGImage] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [CGImage] = []
        for k in 0..<count {
            guard !Task.isCancelled else { break }
            let t = duration * (Double(k) + 0.5) / Double(count)
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { out.append(img) }
        }
        return out
    }

    /// One loudness value per bar, 0…1.
    static func levels(_ asset: AVAsset, duration: Double, bars: Int) async -> [Float] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8000
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { return [] }
        reader.add(out)
        guard reader.startReading() else { return [] }
        let perBar = max(1, Int(duration * Double(rate)) / max(1, bars))
        var levels: [Float] = []
        var sum: Float = 0
        var n = 0
        while let buffer = out.copyNextSampleBuffer() {
            guard !Task.isCancelled else { reader.cancelReading(); return [] }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for i in 0..<(length / 4) {
                    sum += samples[i] * samples[i]
                    n += 1
                    if n == perBar { levels.append((sum / Float(perBar)).squareRoot()); sum = 0; n = 0 }
                }
            }
        }
        let peak = max(levels.max() ?? 1, 0.0001)
        return levels.map { ($0 / peak).squareRoot() }
    }
}
