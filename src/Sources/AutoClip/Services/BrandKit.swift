import Foundation
import AppKit
import CoreImage

/// The church's look, set once: name, handle, logo, colours and headline type. New carousels,
/// posts and clips start from it, so everything looks like the church without picking it each week.
struct BrandKit: Codable, Equatable {
    enum LogoColour: String, Codable, CaseIterable, Identifiable {
        case auto, original, white, black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Fit the background"
            case .original: return "As it is"
            case .white: return "White"
            case .black: return "Black"
            }
        }
    }

    var name = ""
    var handle = ""
    var website = ""
    /// e.g. "Sundays at 9 and 11am", used in invite posts
    var serviceTimes = ""
    var primaryHex = "E8643C"
    var secondaryHex: String?
    var font: SermonCarousel.TypeChoice = .auto
    var logoPath: String?
    var logoColour: LogoColour = .auto
    var logoOnGraphics = true
    var logoOnClips = false
    /// Clip captions use the brand colour for the spoken word and key words
    var captionColours = true

    static let key = "brand_kit"
    static let changed = Notification.Name("BrandKit.changed")

    /// The saved kit, or nil when the church hasn't set one up.
    static func load() -> BrandKit? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(BrandKit.self, from: $0) }
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
        if !handle.isEmpty { UserDefaults.standard.set(handle, forKey: "carousel_handle") }
        BrandLogo.forget()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        BrandLogo.forget()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    var hasLogo: Bool { logoPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    /// What goes in the corner of each graphic: the handle, or the name when there's no handle
    var signature: String { handle.isEmpty ? name : handle }
    var colours: [String] { [primaryHex] + (secondaryHex.map { [$0] } ?? []) }

    /// Copies a logo into AutoClip's folder so it survives the original moving.
    static func importLogo(_ url: URL) -> String? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AutoClip/Brand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        return dest.path
    }
}

// MARK: Putting it to use

extension SermonCarousel {
    /// Takes the brand's colour, type and handle. Words and pictures stay as they are.
    mutating func applyBrand(_ b: BrandKit, posts alsoPosts: Bool = true) {
        accentHex = b.primaryHex
        if b.font != .auto { font = b.font }
        if !b.signature.isEmpty { handle = b.signature }
        guard alsoPosts, var p = posts else { return }
        for i in p.indices {
            // Alternate the two brand colours across the week
            p[i].accentHex = i % 2 == 1 ? b.secondaryHex : nil
            if b.font != .auto { p[i].font = b.font }
        }
        posts = p
    }

    /// Swatches to offer: the brand's colours first.
    static var swatches: [String] {
        let brand = BrandKit.load()?.colours ?? []
        return brand + accents.filter { !brand.contains($0) }
    }
}

extension CaptionLook {
    /// The spoken word and key words in the brand's colours.
    mutating func applyBrand(_ b: BrandKit) {
        highlightColor = RGBA(NSColor(hexString: b.primaryHex))
        emphasisColor = RGBA(NSColor(hexString: b.secondaryHex ?? b.primaryHex))
    }
}

// MARK: The logo, ready to draw

/// The logo as an image, recoloured to sit on a dark or light ground. Cached.
enum BrandLogo {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    static func forget() { lock.lock(); cache = [:]; lock.unlock() }

    static func image(onDark dark: Bool, kit: BrandKit? = BrandKit.load()) -> CGImage? {
        guard let kit, kit.hasLogo, let path = kit.logoPath else { return nil }
        let k = "\(path)|\(kit.logoColour.rawValue)|\(dark)"
        lock.lock(); if let c = cache[k] { lock.unlock(); return c }; lock.unlock()
        guard let src = NSImage(contentsOfFile: path) else { return nil }
        var r = CGRect(origin: .zero, size: src.size)
        guard let cg = src.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
        let out = recolour(trimmed(cg) ?? cg, kit.logoColour, onDark: dark) ?? cg
        lock.lock(); cache[k] = out; lock.unlock()
        return out
    }

    static func hasTransparency(_ img: CGImage) -> Bool {
        switch img.alphaInfo { case .none, .noneSkipLast, .noneSkipFirst: return false; default: break }
        // Check the corners: a logo on a white box isn't really transparent
        guard let px = pixels(img, size: 24) else { return true }
        let corners = [0, 23, 24 * 23, 24 * 24 - 1]
        return corners.contains { px[$0 * 4 + 3] < 200 }
    }

    /// Average brightness of the logo's visible pixels (0 dark – 1 light).
    static func brightness(_ img: CGImage) -> CGFloat {
        guard let px = pixels(img, size: 24) else { return 0.5 }
        var sum: CGFloat = 0, n: CGFloat = 0
        for i in 0..<(24 * 24) where px[i * 4 + 3] > 40 {
            let a = CGFloat(px[i * 4 + 3]) / 255
            // Unpremultiply
            let r = CGFloat(px[i * 4]) / 255 / a, g = CGFloat(px[i * 4 + 1]) / 255 / a, b = CGFloat(px[i * 4 + 2]) / 255 / a
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b; n += 1
        }
        return n > 0 ? sum / n : 0.5
    }

    private static func recolour(_ img: CGImage, _ mode: BrandKit.LogoColour, onDark: Bool) -> CGImage? {
        guard hasTransparency(img) else { return img }
        let target: NSColor?
        switch mode {
        case .original: target = nil
        case .white: target = .white
        case .black: target = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        case .auto:
            let b = brightness(img)
            if onDark && b < 0.35 { target = .white }
            else if !onDark && b > 0.75 { target = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1) }
            else { target = nil }
        }
        guard let target else { return img }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clip(to: rect, mask: img)
        ctx.setFillColor(target.cgColor)
        ctx.fill(rect)
        return ctx.makeImage()
    }

    /// Cuts away empty transparent edges so the logo sits where it's placed.
    private static func trimmed(_ img: CGImage) -> CGImage? {
        guard hasTransparency(img) else { return img }
        let w = img.width, h = img.height
        guard w * h < 40_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return img }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 10 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return img }
        // Memory rows run top to bottom, the same as cropping's origin
        return img.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    private static func pixels(_ img: CGImage, size s: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: s * s * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: s, height: s))
            return true
        }
        return ok ? buf : nil
    }
}
