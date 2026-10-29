import SwiftUI
import AppKit

/// Edits-style caption controls with a live preview. The preview draws with the same
/// `CaptionLook.attributedPhrase` the exporter uses, so it matches the rendered reel.
struct CaptionEditorView: View {
    @Binding var look: CaptionLook
    let gold: Color

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()
    private static let popular = ["Impact", "Arial Black", "Avenir Next", "Futura", "Helvetica Neue",
                                  "Montserrat", "Gill Sans", "Rockwell", "American Typewriter",
                                  "Marker Felt", "Chalkboard SE", "Bradley Hand", "Courier New"]
        .filter { NSFontManager.shared.availableMembers(ofFontFamily: $0) != nil }

    private let sampleWords = ["This", "is", "how", "your", "captions", "look"]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            preview
            VStack(alignment: .leading, spacing: 10) {
                fontRow
                sliderRow("Size", value: $look.sizeScale, range: 0.5...2.0, label: "\(Int(look.sizeScale * 100))%")
                sliderRow("Position", value: $look.position, range: 0.1...0.92,
                          label: look.position < 0.35 ? "Top" : look.position < 0.65 ? "Middle" : "Bottom")
                wordsRow
                colorRow
                outlineRow
                backgroundRow
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45)
            Image(nsImage: previewImage(step: step))
                .resizable()
                .frame(width: 135, height: 240)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    /// Draws one frame of the caption animation at 2× for a crisp 135×240 preview.
    private func previewImage(step: Int) -> NSImage {
        let size = CGSize(width: 270, height: 480)
        let n = max(1, look.wordsPerCaption)
        let phraseCount = Int((Double(sampleWords.count) / Double(n)).rounded(.up))
        let phraseIdx = (step / n) % phraseCount
        let phrase = Array(sampleWords[(phraseIdx * n)..<min(sampleWords.count, phraseIdx * n + n)])
        let active = step % n < phrase.count ? step % n : phrase.count - 1
        let look = self.look

        return NSImage(size: size, flipped: true) { rect in
            let bg = NSGradient(colors: [NSColor(white: 0.32, alpha: 1), NSColor(white: 0.12, alpha: 1)])
            bg?.draw(in: rect, angle: -90)
            // Silhouette so position reads in context
            NSColor(white: 0.45, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 105, y: 120, width: 60, height: 70)).fill()
            NSBezierPath(roundedRect: CGRect(x: 75, y: 195, width: 120, height: 200), xRadius: 30, yRadius: 30).fill()

            let fontSize = look.fontSize(forRenderWidth: size.width)
            let maxW = size.width * 0.86
            let str = look.attributedPhrase(phrase, active: active, fontSize: fontSize)
            let m = look.measure(look.attributedPhrase(phrase, active: nil, fontSize: fontSize), maxWidth: maxW)
            let centerY = size.height * CGFloat(look.position)
            if look.bgEnabled {
                let padX = fontSize * 0.35, padY = fontSize * 0.18
                look.bgColor.nsColor.withAlphaComponent(CGFloat(look.bgOpacity)).setFill()
                NSBezierPath(roundedRect: CGRect(x: (size.width - m.width) / 2 - padX, y: centerY - m.height / 2 - padY,
                                                 width: m.width + padX * 2, height: m.height + padY * 2),
                             xRadius: fontSize * 0.25, yRadius: fontSize * 0.25).fill()
            }
            str.draw(with: CGRect(x: (size.width - maxW) / 2, y: centerY - m.height / 2, width: maxW, height: m.height + 4),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
    }

    // MARK: Controls

    private var fontRow: some View {
        HStack {
            label("Font")
            Spacer()
            Menu {
                Section("Popular") {
                    ForEach(Self.popular, id: \.self) { fam in Button(fam) { selectFamily(fam) } }
                }
                Section("All fonts") {
                    ForEach(Self.families, id: \.self) { fam in Button(fam) { selectFamily(fam) } }
                }
            } label: {
                Text(NSFont(name: look.fontName, size: 12)?.displayName ?? look.fontName)
                    .font(.custom(look.fontName, size: 12))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Picks the heaviest face in the family — captions read best bold.
    private func selectFamily(_ family: String) {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let best = members
            .filter { ($0[3] as? UInt).map { $0 & NSFontTraitMask.italicFontMask.rawValue == 0 } ?? true }
            .max { ($0[2] as? Int ?? 0) < ($1[2] as? Int ?? 0) }
        if let ps = (best ?? members.first)?[0] as? String { look.fontName = ps }
    }

    private var wordsRow: some View {
        HStack {
            label("Words on screen")
            Spacer()
            Picker("", selection: $look.wordsPerCaption) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
        }
    }

    private var colorRow: some View {
        HStack(spacing: 8) {
            label("Text")
            ColorPicker("", selection: $look.textColor.color, supportsOpacity: false).labelsHidden()
            Spacer(minLength: 6)
            label("Highlight")
            ColorPicker("", selection: $look.highlightColor.color, supportsOpacity: false).labelsHidden()
            Spacer(minLength: 6)
            Toggle("AA", isOn: $look.uppercase).toggleStyle(.button).font(.system(size: 11, weight: .bold))
                .help("ALL CAPS")
        }
    }

    private var outlineRow: some View {
        HStack(spacing: 10) {
            label("Outline")
            ColorPicker("", selection: $look.strokeColor.color, supportsOpacity: false).labelsHidden()
            Slider(value: $look.strokeWidth, in: 0...10).tint(gold)
            Text(look.strokeWidth < 0.5 ? "Off" : "\(Int(look.strokeWidth))")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(gold).frame(width: 28)
        }
    }

    private var backgroundRow: some View {
        HStack(spacing: 10) {
            label("Box")
            Toggle("", isOn: $look.bgEnabled).toggleStyle(.switch).tint(gold).labelsHidden()
            if look.bgEnabled {
                ColorPicker("", selection: $look.bgColor.color, supportsOpacity: false).labelsHidden()
                Slider(value: $look.bgOpacity, in: 0.1...1).tint(gold)
            }
            Spacer(minLength: 0)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label text: String) -> some View {
        HStack(spacing: 10) {
            label(title)
            Slider(value: value, in: range).tint(gold)
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundColor(gold).frame(width: 48, alignment: .trailing)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
            .lineLimit(1).fixedSize()
    }
}
