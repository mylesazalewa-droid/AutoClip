import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// Finds the stage screen in a sermon video, so the wide shot can frame the speaker and the
/// screen together, and the split view can show the screen on its own.
enum ScreenFinder {
    private static var cache: [String: CGRect?] = [:]
    private static let lock = NSLock()

    /// The screen's place in the picture (0…1, from the top left), looked for around `time`.
    static func find(in path: String, around time: Double) async -> CGRect? {
        let key = "\(path)#\(Int(time))"
        if let hit = lock.withLock({ cache[key] }) { return hit }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 960, height: 540)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var found: [CGRect] = []
        for dt in [0.5, 2.0, 4.0] {
            guard let img = try? gen.copyCGImage(at: CMTime(seconds: time + dt, preferredTimescale: 600), actualTime: nil) else { continue }
            if let r = find(in: img) { found.append(r) }
        }
        // The one most of the frames agree on, so a person walking past doesn't move it
        func agree(_ r: CGRect) -> Int {
            found.filter { o in let i = r.intersection(o); return !i.isNull && i.width * i.height > 0.5 * min(r.width * r.height, o.width * o.height) }.count
        }
        let result = found.max { agree($0) < agree($1) }
        lock.withLock { cache[key] = result }
        return result
    }

    /// One frame: a dark screen set into a lit backdrop, then straight edges, then a lit projector screen.
    static func find(in img: CGImage) -> CGRect? {
        darkPanel(img) ?? rectangle(in: img) ?? brightPatch(in: img)
    }

    /// A dark panel set into a brighter backdrop: in each column, how far down the picture stays light.
    /// Columns where it turns dark much sooner than the backdrop around them, side by side, are the screen.
    private static func darkPanel(_ img: CGImage) -> CGRect? {
        let W = 96, H = 54
        var px = [UInt8](repeating: 0, count: W * H)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        func l(_ x: Int, _ y: Int) -> Double { Double(px[y * W + x]) / 255 }
        // How far down each column the backdrop is lit, starting from the first lit cell near the top
        var lit = [Int](repeating: 0, count: W)
        var top = [Int](repeating: 0, count: W)
        for x in 0..<W {
            var y = 0
            while y < H / 3 && l(x, y) < 0.45 { y += 1 }
            top[x] = y
            var d = y
            while d < H - 1 && !(l(x, d) < 0.22 && l(x, d + 1) < 0.22) { d += 1 }
            lit[x] = d
        }
        let sorted = lit.sorted()
        let backdrop = sorted[Int(Double(W) * 0.7)]
        guard backdrop > H / 4 else { return nil }   // no bright backdrop to stand out from
        // The widest run of columns that go dark well before the backdrop does (small gaps allowed for a person in front)
        var best = (0, -1), runStart = -1, gap = 0
        for x in 0...W {
            let dark = x < W && lit[x] < backdrop - H / 7 && top[x] < H / 3
            if dark { if runStart < 0 { runStart = x }; gap = 0 }
            else if runStart >= 0 {
                gap += 1
                if gap > 3 || x == W {
                    let end = x - gap
                    if end - runStart > best.1 - best.0 { best = (runStart, end) }
                    runStart = -1; gap = 0
                }
            }
        }
        guard best.1 > best.0 else { return nil }
        // A screen has a straight top edge: drop columns at either end that don't share it (a person beside it)
        let mid = Array(lit[best.0...best.1]).sorted()[(best.1 - best.0) / 2]
        var a = best.0, b = best.1
        while a < b && abs(lit[a] - mid) > 1 { a += 1 }
        while b > a && abs(lit[b] - mid) > 1 { b -= 1 }
        let w = Double(b - a + 1) / Double(W)
        guard w > 0.14, w < 0.75 else { return nil }
        best = (a, b)
        let y0 = Double(mid) / Double(H)
        // A 16:9 screen in a 16:9 picture is about as tall as it is wide (in 0…1 terms)
        let bottom = min(Double(backdrop) / Double(H) + 0.04, y0 + w * 1.05)
        let h = max(w * 0.55, bottom - y0)
        return CGRect(x: Double(best.0) / Double(W), y: y0, width: w, height: min(h, 1 - y0))
    }


    private static func rectangle(in img: CGImage) -> CGRect? {
        let req = VNDetectRectanglesRequest()
        req.minimumAspectRatio = 0.4
        req.maximumAspectRatio = 0.85
        req.minimumSize = 0.12
        req.maximumObservations = 8
        req.minimumConfidence = 0.6
        req.quadratureTolerance = 20
        try? VNImageRequestHandler(cgImage: img).perform([req])
        let lum = Luma(img)
        let picks = (req.results ?? []).compactMap { o -> (CGRect, Double)? in
            let b = o.boundingBox
            let r = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            guard r.width * r.height > 0.02, r.width < 0.95 else { return nil }
            // Shaped like a screen (about as tall as wide, in 0…1 terms) and standing out from the picture
            guard r.height / r.width > 0.45, r.height / r.width < 1.4 else { return nil }
            let inside = lum?.mean(in: r) ?? 0.5
            let contrast = abs(inside - (lum?.overall ?? 0.5))
            guard contrast > 0.12 else { return nil }
            return (r, Double(r.width * r.height) * contrast)
        }
        return picks.max { $0.1 < $1.1 }?.0
    }

    /// The largest block of bright cells on a coarse grid.
    private static func brightPatch(in img: CGImage) -> CGRect? {
        guard let lum = Luma(img) else { return nil }
        let cols = lum.w, rows = lum.h
        let sorted = lum.v.sorted()
        let cut = max(sorted[Int(Double(sorted.count) * 0.85)], lum.overall * 1.6)
        var seen = [Bool](repeating: false, count: lum.v.count)
        var best: (n: Int, box: (Int, Int, Int, Int))?
        for start in lum.v.indices where !seen[start] && lum.v[start] >= cut {
            var stack = [start], n = 0
            var x0 = cols, y0 = rows, x1 = 0, y1 = 0
            seen[start] = true
            while let i = stack.popLast() {
                n += 1
                let x = i % cols, y = i / cols
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < cols, ny < rows else { continue }
                    let j = ny * cols + nx
                    if !seen[j] && lum.v[j] >= cut { seen[j] = true; stack.append(j) }
                }
            }
            if n > (best?.n ?? 0) { best = (n, (x0, y0, x1, y1)) }
        }
        guard let b = best else { return nil }
        let w = Double(b.box.2 - b.box.0 + 1) / Double(cols), h = Double(b.box.3 - b.box.1 + 1) / Double(rows)
        let fill = Double(b.n) / Double((b.box.2 - b.box.0 + 1) * (b.box.3 - b.box.1 + 1))
        // Solid enough, big enough, and shaped like a screen (not a lit wall or a white shirt)
        guard w * h > 0.02, w < 0.9, fill > 0.55, (w * 16 / 9) / h > 0.9, (w * 16 / 9) / h < 3.2 else { return nil }
        return CGRect(x: Double(b.box.0) / Double(cols), y: Double(b.box.1) / Double(rows), width: w, height: h)
    }

    /// Brightness on a small grid.
    private struct Luma {
        let w = 64, h = 36
        var v: [Double]
        var overall: Double { v.reduce(0, +) / Double(v.count) }
        init?(_ img: CGImage) {
            var px = [UInt8](repeating: 0, count: 64 * 36)
            guard let ctx = CGContext(data: &px, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 64, height: 36))
            v = px.map { Double($0) / 255 }
        }
        func mean(in r: CGRect) -> Double {
            let x0 = max(0, Int(r.minX * 64)), x1 = min(63, Int(r.maxX * 64))
            let y0 = max(0, Int(r.minY * 36)), y1 = min(35, Int(r.maxY * 36))
            guard x1 >= x0, y1 >= y0 else { return 0 }
            var s = 0.0, n = 0
            for y in y0...y1 { for x in x0...x1 { s += v[y * 64 + x]; n += 1 } }
            return s / Double(n)
        }
    }
}
