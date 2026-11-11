import SwiftUI
import AVFoundation
import AppKit

// The Reframe, Audio and Captions tabs of the reel editor.

/// Before and after, side by side, and who the reel should follow.
struct ReframeWorkspace<Advanced: View>: View {
    @Binding var draft: ReelDraft
    let people: (ReelDraft.Piece) async -> [ReframePerson]
    @ViewBuilder let advanced: (Int) -> Advanced

    @State private var pieceIndex = 0
    @State private var found: [UUID: [ReframePerson]] = [:]
    @State private var frame: CGImage?
    @State private var everyClip = true
    /// The moment shown (source seconds) and who's in it
    @State private var moment: Double = 0
    @State private var targets: [CGRect] = []

    private var index: Int { min(pieceIndex, max(0, draft.pieces.count - 1)) }
    private var piece: ReelDraft.Piece? { draft.pieces.indices.contains(index) ? draft.pieces[index] : nil }
    private var framing: ReelDraft.Framing? { piece?.framing }
    private var crew: [ReframePerson]? { piece.flatMap { found[$0.id] } }

    private var outputAspect: CGFloat? {
        switch VideoExportService.ExportFormat(rawValue: draft.formatRaw) ?? .vertical9x16 {
        case .vertical9x16: return 9.0 / 16.0
        case .portrait4x5: return 4.0 / 5.0
        case .square1x1: return 1
        default: return nil
        }
    }

    /// Where the crop sits in the frame on show: the chosen person, or the main person for "whoever's talking"
    private var centre: Double {
        let xs = targets.map { Double($0.midX) }
        if let f = framing, f.mode == "fixed" || f.mode == "split" { return f.x }
        if let f = framing, f.mode == "person" {
            if abs((f.t ?? moment) - moment) < 0.5 { return f.x }
            return xs.min { abs($0 - f.x) < abs($1 - f.x) } ?? f.x
        }
        if let main = targets.max(by: { $0.height < $1.height }) { return Double(main.midX) }
        return crew?.first?.x ?? 0.5
    }

    private var canReframe: Bool {
        guard outputAspect != nil, let frame else { return false }
        return frame.width > frame.height
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if draft.pieces.count > 1 {
                    PillTabs(selection: $pieceIndex, items: draft.pieces.indices.map { ($0, "Clip \($0 + 1)") }, compact: true)
                }
                comparison
                question
                if piece != nil { advanced(index) }
            }
            .padding(20)
        }
        .background(
            RadialGradient(colors: [Theme.raised2.opacity(0.7), Theme.bg], center: .center, startRadius: 40, endRadius: 620)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .task(id: piece?.id) { await load() }
    }

    private func load() async {
        guard let p = piece, let first = p.sentences.first, let last = p.sentences.last else { return }
        let start = p.framing?.t ?? (first.start + last.end) / 2
        moment = min(max(start, first.start), last.end)
        await show(moment)
        if found[p.id] == nil {
            let list = await people(p)
            found[p.id] = list
        }
    }

    private func show(_ t: Double) async {
        guard let p = piece, let image = await Reframe.frame(path: p.sourceVideoPath, at: t, maxWidth: 1920) else { return }
        frame = image
        targets = await Reframe.targets(in: image)
    }

    /// Clicking someone follows them. Near a detected person it snaps to them; anywhere else it
    /// still works, for when detection missed them.
    private func choose(atX x: Double) {
        let near = targets.map { Double($0.midX) }.min { abs($0 - x) < abs($1 - x) }
        let picked = near.flatMap { abs($0 - x) < 0.08 ? $0 : nil } ?? x
        apply(ReelDraft.Framing(mode: "person", x: (picked * 1000).rounded() / 1000, t: moment))
    }

    // MARK: Before and after

    private var comparison: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(spacing: 10) {
                beforeImage.frame(maxWidth: 460)
                if let p = piece, let first = p.sentences.first, let last = p.sentences.last, last.end - first.start > 1 {
                    HStack(spacing: 8) {
                        Image(systemName: "clock").font(.ui(size: 11.5)).foregroundColor(Theme.muted)
                        Slider(value: $moment, in: first.start...last.end) { editing in
                            if !editing { Task { await show(moment) } }
                        }
                        .controlSize(.mini)
                        .help("Pick the moment to look at, then click the person to follow")
                    }
                    .frame(maxWidth: 460)
                }
                label("Before")
            }
            Image(systemName: "arrow.right").font(.ui(size: 14, weight: .medium)).foregroundColor(Theme.muted)
            VStack(spacing: 10) {
                afterImage
                label(framing?.mode == "split" ? "Split layout" : canReframe ? "Fill layout" : "Original shape")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.ui(size: 13, weight: .medium)).foregroundColor(Theme.cream)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink.opacity(0.1)))
    }

    @ViewBuilder private var beforeImage: some View {
        if let frame {
            let aspect = CGFloat(frame.width) / CGFloat(frame.height)
            Image(decorative: frame, scale: 1).resizable().aspectRatio(aspect, contentMode: .fit)
                .overlay {
                    if canReframe {
                        GeometryReader { geo in
                            ForEach(Array(targets.enumerated()), id: \.offset) { _, box in
                                RoundedRectangle(cornerRadius: 4).stroke(Theme.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .frame(width: box.width * geo.size.width, height: box.height * geo.size.height)
                                    .position(x: box.midX * geo.size.width, y: (1 - box.midY) * geo.size.height)
                                    .allowsHitTesting(false)
                            }
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { p in choose(atX: Double(p.x / geo.size.width)) }
                                .help("Click a person to follow them")
                        }
                    }
                }
                .overlay {
                    if canReframe, let out = outputAspect {
                        GeometryReader { geo in
                            ForEach(cropBoxes(aspect: aspect, output: out), id: \.self) { x in
                                let w = geo.size.height * (framing?.mode == "split" ? out * 2 : out)
                                let cx = min(max(CGFloat(x) * geo.size.width, w / 2), geo.size.width - w / 2)
                                Rectangle().fill(Theme.sand.opacity(0.12))
                                    .overlay(Rectangle().stroke(Theme.sand, lineWidth: 1.5))
                                    .frame(width: w, height: geo.size.height)
                                    .position(x: cx, y: geo.size.height / 2)
                                    .allowsHitTesting(false)
                                Label("AI", systemImage: "sparkles").font(.ui(size: 11, weight: .bold)).foregroundColor(Theme.onSand)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.sand))
                                    .position(x: cx, y: geo.size.height - 16)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(Theme.ink.opacity(0.05)).aspectRatio(16 / 9, contentMode: .fit)
                .overlay(LoadingBar())
        }
    }

    private func cropBoxes(aspect: CGFloat, output: CGFloat) -> [Double] {
        if let f = framing, f.mode == "split" { return [f.x, f.x2 ?? 0.75] }
        return [centre]
    }

    @ViewBuilder private var afterImage: some View {
        let height: CGFloat = 300
        if let frame, canReframe, let out = outputAspect {
            Group {
                if let f = framing, f.mode == "split" {
                    VStack(spacing: 0) {
                        crop(frame, x: f.x, aspect: out * 2).resizable()
                        crop(frame, x: f.x2 ?? 0.75, aspect: out * 2).resizable()
                    }
                } else {
                    crop(frame, x: centre, aspect: out).resizable()
                }
            }
            .frame(width: height * out, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        } else if let frame {
            let aspect = CGFloat(frame.width) / CGFloat(frame.height)
            Image(decorative: frame, scale: 1).resizable().aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: height).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func crop(_ image: CGImage, x: Double, aspect: CGFloat) -> Image {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var cw = h * aspect, ch = h
        if cw > w { cw = w; ch = w / aspect }
        let left = min(max(CGFloat(x) * w - cw / 2, 0), w - cw)
        let rect = CGRect(x: left, y: (h - ch) / 2, width: cw, height: ch)
        return Image(decorative: image.cropping(to: rect) ?? image, scale: 1)
    }

    // MARK: Who to follow

    @ViewBuilder private var question: some View {
        if !canReframe, frame != nil {
            Text("This clip keeps the video's shape, so there's nothing to reframe. Pick 9:16, 4:5 or 1:1 on the Edit tab to choose a framing.")
                .font(.ui(size: 13)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
        } else if let crew {
            VStack(spacing: 12) {
                Text(crew.count >= 2 ? "\(crew.count) people found. Who should this follow?" : framing?.mode == "person" ? "Following who you picked." : crew.count == 1 ? "One person found. The frame follows them." : "No one found clearly.")
                    .font(Theme.display(17)).foregroundColor(Theme.cream)
                Text("Wrong person or missed someone? Click them in the picture. Use the slider to find a clearer moment.")
                    .font(.ui(size: 12)).foregroundColor(Theme.muted)
                if crew.count < 2, framing != nil {
                    Button("Back to whoever's talking") { apply(nil) }.controlSize(.small)
                }
                if crew.count >= 2 {
                    HStack(spacing: 12) {
                        ForEach(Array(crew.enumerated()), id: \.element.id) { i, person in
                            ReframeTile(title: "Person \(i + 1)", selected: isFollowing(person)) {
                                Image(nsImage: person.face).resizable().scaledToFill()
                            } action: { moment = person.time; apply(ReelDraft.Framing(mode: "person", x: person.x, t: person.time)); Task { await show(person.time) } }
                        }
                        ReframeTile(title: "Whoever's talking", selected: framing == nil) {
                            Image(systemName: "waveform").font(.ui(size: 20)).foregroundColor(Theme.sand)
                        } action: { apply(nil) }
                        if outputAspect ?? 1 < 1 {
                            ReframeTile(title: "Both, stacked", selected: framing?.mode == "split") {
                                Image(systemName: "rectangle.split.1x2").font(.ui(size: 20)).foregroundColor(Theme.sand)
                            } action: { apply(ReelDraft.Framing(mode: "split", x: crew[0].x, x2: crew[crew.count - 1].x)) }
                        }
                    }
                    if draft.pieces.count > 1 {
                        Toggle("Use for every clip", isOn: $everyClip).toggleStyle(.checkbox)
                            .font(.ui(size: 12)).foregroundColor(Theme.muted)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                LoadingBar()
                Text("Looking for people…").font(.ui(size: 13)).foregroundColor(Theme.muted)
            }
        }
    }

    private func isFollowing(_ person: ReframePerson) -> Bool {
        framing?.mode == "person" && abs((framing?.x ?? -1) - person.x) < 0.001
    }

    private func apply(_ f: ReelDraft.Framing?) {
        draft.reframeAsked = true
        if everyClip { for i in draft.pieces.indices { draft.pieces[i].framing = f } } else { draft.pieces[index].framing = f }
    }
}

struct ReframeTile<Content: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder let content: Content
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack { Theme.ink.opacity(0.06); content }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Theme.cream : Theme.ink.opacity(0.12), lineWidth: selected ? 2 : 1))
                Text(title).font(.ui(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Theme.cream : Theme.muted).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(.plain)
    }
}

/// The whole reel as a filmstrip above a waveform. The part already played is bright. Click to jump.
struct ReelStrip: View {
    let asset: AVAsset?
    let token: Int
    let duration: Double
    let time: Double
    let seek: (Double) -> Void
    @State private var thumbs: [CGImage] = []
    @State private var levels: [Float] = []

    private var progress: CGFloat { CGFloat(min(1, max(0, time / max(duration, 0.1)))) }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { _, t in
                        Image(decorative: t, scale: 1).resizable().scaledToFill()
                            .frame(width: max(1, (geo.size.width - CGFloat(thumbs.count - 1) * 2) / CGFloat(max(1, thumbs.count))), height: 48)
                            .clipped()
                    }
                }
            }
            .frame(height: 48)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))

            GeometryReader { geo in
                Canvas { ctx, size in
                    guard !levels.isEmpty else { return }
                    let step = size.width / CGFloat(levels.count)
                    for (i, l) in levels.enumerated() {
                        let h = max(3, CGFloat(l) * (size.height - 10))
                        let x = CGFloat(i) * step
                        let rect = CGRect(x: x, y: (size.height - h) / 2, width: max(1.5, step * 0.55), height: h)
                        let played = x / size.width <= progress
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.ink.opacity(played ? 0.95 : 0.3)))
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white).frame(width: 2).offset(x: progress * geo.size.width)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    seek(Double(max(0, min(1, v.location.x / geo.size.width))) * duration)
                })
            }
            .frame(height: 52)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.06)))
        }
        .task(id: token) {
            guard let asset, duration > 0 else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let bars = 180, count = 12, length = duration
            let (t, l) = await Task.detached(priority: .utility) {
                let a = await ReelMedia.thumbnails(asset, duration: length, count: count)
                let b = await ReelMedia.levels(asset, duration: length, bars: bars)
                return (a, b)
            }.value
            guard !Task.isCancelled else { return }
            thumbs = t; levels = l
        }
    }
}

/// Caption styling beside the preview: Presets, Font and Effects.
struct CaptionPanel: View {
    @Binding var captions: Bool
    @Binding var look: CaptionLook
    let gold: Color
    private enum Tab: String { case presets = "Presets", font = "Font", effects = "Effects" }
    @State private var tab: Tab = .presets

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach([Tab.presets, .font, .effects], id: \.self) { t in
                    Button(t.rawValue) { tab = t }.buttonStyle(.plain)
                        .font(.ui(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundColor(tab == t ? Theme.cream : Theme.muted)
                }
                Spacer()
            }
            .padding(14)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case .presets: presets
                    case .font: CaptionEditorView(look: $look, gold: gold, part: .font)
                    case .effects: CaptionEditorView(look: $look, gold: gold, part: .effects)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private var presets: some View {
        Button { captions = false } label: {
            tile(selected: !captions) { Image(systemName: "nosign").font(.ui(size: 18)).foregroundColor(Theme.muted) }
        }.buttonStyle(.plain)
        name("No captions")
        ForEach(CaptionStyle.all) { style in
            let preset = CaptionLook(preset: style)
            Button { captions = true; look = preset } label: {
                tile(selected: captions && same(preset)) { CaptionPresetSample(look: preset) }
            }.buttonStyle(.plain)
            name(style.name)
        }
    }

    private func same(_ preset: CaptionLook) -> Bool {
        var a = look; a.keywords = []
        return a == preset
    }

    private func tile<C: View>(selected: Bool, @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Theme.cream : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
    }

    private func name(_ s: String) -> some View {
        Text(s).font(.ui(size: 11.5)).foregroundColor(Theme.muted).padding(.top, -6)
    }
}

/// A preset drawn with the exporter's own caption code, so the sample matches the reel.
private struct CaptionPresetSample: View {
    let look: CaptionLook
    @State private var image: NSImage?
    var body: some View {
        ZStack { if let image { Image(nsImage: image).resizable().scaledToFit().padding(.horizontal, 10) } else { Color.clear } }
            .task { image = draw() }
    }
    private func draw() -> NSImage {
        let size = CGSize(width: 600, height: 88)
        var l = look
        l.position = 0.5
        l.wordsPerCaption = 3
        l.motion = .highlight
        return NSImage(size: size, flipped: true) { _ in
            l.draw(["Choose", "a", "style"], active: 2, age: 1, in: size)
            return true
        }
    }
}
