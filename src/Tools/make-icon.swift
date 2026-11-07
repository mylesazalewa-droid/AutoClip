// Draws the AutoClip icon: a spoken waveform flowing into a tall clip frame.
//   swift make-icon.swift <output.png> [size]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let S = CGFloat(args.count > 2 ? Double(args[2])! : 1024)
let k = S / 1024

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)

// The tile, on Apple's icon grid (824 of 1024), with a soft shadow
let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 34 * k, color: c(0x000000, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(c(0x18191B)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [c(0x2A2622), c(0x161719)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// A warm glow behind the frame
let glow = CGGradient(colorsSpace: space, colors: [c(0xB4532F, 0.38), c(0xB4532F, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 640 * k, y: 512 * k), startRadius: 0,
                       endCenter: CGPoint(x: 640 * k, y: 512 * k), endRadius: 360 * k, options: [])
ctx.restoreGState()
// Hairline edge
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * k, dy: 1.5 * k), cornerWidth: 184 * k, cornerHeight: 184 * k, transform: nil))
ctx.setStrokeColor(c(0xFFFFFF, 0.08)); ctx.setLineWidth(3 * k); ctx.strokePath()

// The clip: a tall 9:16 frame
let frame = CGRect(x: 520 * k, y: 262 * k, width: 282 * k, height: 500 * k)
let framePath = CGPath(roundedRect: frame, cornerWidth: 46 * k, cornerHeight: 46 * k, transform: nil)
ctx.saveGState()
ctx.addPath(framePath); ctx.clip()
let fill = CGGradient(colorsSpace: space, colors: [c(0xDE7C58), c(0xB4532F)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fill, start: CGPoint(x: frame.minX, y: frame.maxY), end: CGPoint(x: frame.maxX, y: frame.minY), options: [])
ctx.restoreGState()

// The voice: waveform bars that build toward the clip, and the moment captured inside it
let barW: CGFloat = 32 * k, gap: CGFloat = 22 * k
let outside: [CGFloat] = [64, 118, 86, 170, 132, 228]
var x: CGFloat = frame.minX - 36 * k - CGFloat(outside.count) * barW - CGFloat(outside.count - 1) * gap
for (i, h) in outside.enumerated() {
    let hh = h * k
    let r = CGRect(x: x, y: 512 * k - hh / 2, width: barW, height: hh)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(c(0xD9C3A0, 0.3 + 0.7 * CGFloat(i + 1) / CGFloat(outside.count))); ctx.fillPath()
    x += barW + gap
}
let inside: [CGFloat] = [250, 340, 210]
let span = CGFloat(inside.count) * barW + CGFloat(inside.count - 1) * gap
var ix = frame.midX - span / 2
for h in inside {
    let hh = h * k
    let r = CGRect(x: ix, y: 512 * k - hh / 2, width: barW, height: hh)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(c(0xF6EBDA)); ctx.fillPath()
    ix += barW + gap
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
