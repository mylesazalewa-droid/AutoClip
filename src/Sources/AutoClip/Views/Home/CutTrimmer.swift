import SwiftUI
import AVFoundation

/// The sound around a cut, read once and kept.
enum CutWaveform {
    private static let cache = NSCache<NSString, NSArray>()
    private static let lock = NSLock()
    private static var transcripts: [String: [Word]] = [:]

    static func levels(path: String, from: Double, to: Double, bars: Int) async -> [Float] {
        let key = "\(path)|\(from)|\(to)|\(bars)" as NSString
        if let hit = cache.object(forKey: key) as? [Float] { return hit }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, to > from else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [Float] in
            guard let reader = try? AVAssetReader(asset: asset) else { return [] }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
            let rate = 8000.0
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            guard reader.startReading() else { return [] }
            let perBar = max(1, Int((to - from) * rate) / bars)
            var out: [Float] = []
            var sum: Float = 0, n = 0
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { continue }
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                    for i in 0..<(length / 4) {
                        sum += samples[i] * samples[i]; n += 1
                        if n == perBar { out.append((sum / Float(perBar)).squareRoot()); sum = 0; n = 0 }
                    }
                }
            }
            let peak = out.max() ?? 0
            if peak > 0 { out = out.map { $0 / peak } }
            cache.setObject(out as NSArray, forKey: key)
            return out
        }.value
    }

    /// Everything said in the video, so the words around a cut can be shown.
    static func words(path: String) async -> [Word] {
        lock.lock(); let hit = transcripts[path]; lock.unlock()
        if let hit { return hit }
        return await Task.detached(priority: .utility) { () -> [Word] in
            let loaded = TranscriptCache.load(for: path) ?? []
            lock.lock(); transcripts[path] = loaded; lock.unlock()
            return loaded
        }.value
    }
}

/// Drag the handle along the sound to choose exactly where a clip starts or ends.
struct CutTrimmer: View {
    let path: String
    /// Where the cut falls with no adjustment
    let base: Double
    let isStart: Bool
    let value: Double
    /// Words in this sentence, so cut ones can be marked
    let sentenceWords: [Word]
    let cutIDs: Set<UUID>
    let onCommit: (Double) -> Void

    @State private var drag: Double?
    @State private var levels: [Float] = []
    @State private var said: [Word] = []
    private let gold = Theme.sand
    static let limit = 5.0

    private var span: Double { max(3, abs(value) + 1) }
    private var lower: Double { max(0, base - span) }
    private var upper: Double { base + span }
    private var shown: Double { drag ?? value }
    private var cutTime: Double { base + shown }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in draw(context, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in drag = nudge(at: g.location.x, width: geo.size.width) }
                    .onEnded { g in
                        let final = nudge(at: g.location.x, width: geo.size.width)
                        drag = nil
                        onCommit(final)
                    })
                .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
        }
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(isStart ? "Drag to choose where this clip starts" : "Drag to choose where this clip ends")
        .task(id: "\(path)|\(lower)|\(upper)") {
            levels = await CutWaveform.levels(path: path, from: lower, to: upper, bars: 160)
            said = await CutWaveform.words(path: path)
        }
    }

    private func nudge(at x: CGFloat, width: CGFloat) -> Double {
        let t = lower + (upper - lower) * Double(min(width, max(0, x)) / max(width, 1))
        let raw = t - base
        return (min(Self.limit, max(-Self.limit, raw)) * 20).rounded() / 20
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let waveHeight = size.height - 16
        func x(_ t: Double) -> CGFloat { CGFloat((t - lower) / max(upper - lower, 0.01)) * size.width }
        let cutX = x(cutTime)

        // The part that plays is bright; what's left out is dim
        for (i, level) in levels.enumerated() {
            let bx = size.width * CGFloat(i) / CGFloat(max(levels.count, 1))
            let h = max(1, CGFloat(level) * waveHeight)
            let plays = isStart ? bx >= cutX : bx <= cutX
            let bar = CGRect(x: bx, y: (waveHeight - h) / 2, width: max(1, size.width / CGFloat(max(levels.count, 1)) - 1), height: h)
            context.fill(Path(bar), with: .color(plays ? gold.opacity(0.85) : Color.white.opacity(0.16)))
        }

        // What's said here
        let cutStarts = Set(sentenceWords.filter { cutIDs.contains($0.id) }.map { ($0.startTime * 100).rounded() })
        var lastEnd: CGFloat = -100
        for w in said where w.endTime > lower && w.startTime < upper {
            let wordX = x(w.startTime)
            let isCut = cutStarts.contains((w.startTime * 100).rounded())
            let plays = isStart ? w.startTime >= cutTime - 0.02 : w.endTime <= cutTime + 0.02
            let label = context.resolve(Text(w.word).font(.system(size: 9, weight: .medium))
                .foregroundColor(isCut ? Theme.danger : plays ? Color.white.opacity(0.85) : Color.white.opacity(0.35))
                .strikethrough(isCut))
            let width = label.measure(in: size).width
            guard wordX > lastEnd + 3 else { continue }
            context.draw(label, at: CGPoint(x: wordX, y: size.height - 8), anchor: .leading)
            lastEnd = wordX + width
        }

        // The handle
        let handle = CGRect(x: cutX - 1, y: 0, width: 2, height: size.height)
        context.fill(Path(handle), with: .color(.white))
        let grip = CGRect(x: cutX - 5, y: waveHeight / 2 - 9, width: 10, height: 18)
        context.fill(Path(roundedRect: grip, cornerRadius: 3), with: .color(.white))
    }
}
