import SwiftUI
import AVFoundation

/// How the screen moments look in a vertical clip: the whole stage (zoomed in as far as you like),
/// or the speaker on top with the screen below.
struct WideShotControls: View {
    @Binding var draft: ReelDraft
    let gold: Color
    /// Copies these settings to the other clips from the same message (nil when there are none)
    var applyToAll: (() -> Void)?
    @State private var picking = false
    @State private var found: CGRect?
    @State private var looking = false
    @State private var note: String?

    private var split: Bool { draft.wideStyle == "split" }

    /// Where the first screen moment is, for the still frame
    private var momentTime: (path: String, time: Double)? {
        for p in draft.pieces {
            if let s = p.sentences.first(where: { $0.wide == true || ($0.wide == nil && ScreenCues.mentionsScreen($0.keptWords.map(\.word).joined(separator: " "))) }) {
                return (p.sourceVideoPath, s.start)
            }
        }
        guard let p = draft.pieces.first, let s = p.sentences.first else { return nil }
        return (p.sourceVideoPath, s.start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Screen moments").font(.ui(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55))
                PillTabs(selection: Binding(get: { draft.wideStyle ?? "full" }, set: { draft.wideStyle = $0 == "full" ? nil : $0 }),
                         items: [("full", "Whole stage"), ("split", "Speaker + screen")], compact: true)
                Spacer(minLength: 0)
                if let applyToAll {
                    Button("Use on every clip") { applyToAll(); note = "Every clip from this message now uses these settings." }
                        .buttonStyle(.plain).font(.ui(size: 11.5)).foregroundColor(gold)
                        .help("Same camera, same screen: copy these screen settings to the other clips from this message")
                }
            }
            if split {
                Text("The speaker on top, the screen below, while they talk about it.")
                    .font(.ui(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
            } else {
                slider("Zoom", value: $draft.wideZoom, range: 1...2, left: "Whole picture", right: "Closer",
                       auto: "Auto fits the speaker and the screen together")
                slider("Position", value: $draft.wideX, range: 0...1, left: "Left", right: "Right",
                       auto: "Auto centres between the speaker and the screen")
            }
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle").font(.ui(size: 11)).foregroundColor(gold.opacity(0.8))
                Text(screenText).font(.ui(size: 11.5)).foregroundColor(Theme.ink.opacity(0.7))
                Button(draft.screenRect == nil ? "Mark the screen" : "Move it") { picking = true }
                    .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(momentTime == nil)
                if draft.screenRect != nil {
                    Button("Find it again") { draft.screenRect = nil; look() }
                        .buttonStyle(.plain).font(.ui(size: 11.5)).foregroundColor(gold)
                }
            }
            if let note { Text(note).font(.ui(size: 11)).foregroundColor(Theme.good) }
        }
        .padding(.leading, 20)
        .task { look() }
        .sheet(isPresented: $picking) {
            if let m = momentTime {
                ScreenPicker(path: m.path, time: m.time, start: draft.screenRect.map { r -> CGRect in CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) } ?? found) { r in
                    draft.screenRect = [r.minX, r.minY, r.width, r.height].map { (Double($0) * 1000).rounded() / 1000 }
                }
            }
        }
    }

    private var screenText: String {
        if draft.screenRect != nil { return "Screen marked by hand" }
        if looking { return "Looking for the screen…" }
        return found == nil ? "Couldn't spot the screen. Mark it so the shot frames it." : "Screen found automatically"
    }

    private func look() {
        guard draft.screenRect == nil, let m = momentTime else { return }
        looking = true
        Task {
            found = await ScreenFinder.find(in: m.path, around: m.time)
            looking = false
        }
    }

    private func slider(_ title: String, value: Binding<Double?>, range: ClosedRange<Double>, left: String, right: String, auto: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.ui(size: 11.5)).foregroundColor(Theme.ink.opacity(0.7)).frame(width: 54, alignment: .leading)
            Text(left).font(.ui(size: 10.5)).foregroundColor(Theme.ink.opacity(0.5))
            Slider(value: Binding(get: { value.wrappedValue ?? (range.lowerBound + range.upperBound) / 2 },
                                  set: { value.wrappedValue = ($0 * 100).rounded() / 100 }),
                   in: range)
                .controlSize(.mini).frame(maxWidth: 220)
                .opacity(value.wrappedValue == nil ? 0.5 : 1)
            Text(right).font(.ui(size: 10.5)).foregroundColor(Theme.ink.opacity(0.5))
            Button(value.wrappedValue == nil ? "Auto" : "Back to auto") { value.wrappedValue = nil }
                .buttonStyle(.plain).font(.ui(size: 11, weight: value.wrappedValue == nil ? .semibold : .regular))
                .foregroundColor(value.wrappedValue == nil ? Theme.ink.opacity(0.7) : gold)
                .disabled(value.wrappedValue == nil)
                .help(auto)
        }
    }
}

/// A still from the video with a box to drag over the stage screen.
struct ScreenPicker: View {
    let path: String
    let time: Double
    let start: CGRect?
    let onDone: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var rect = CGRect(x: 0.55, y: 0.15, width: 0.35, height: 0.35)
    @State private var dragFrom: CGRect?
    @State private var finding = false
    private let width: CGFloat = 640

    var body: some View {
        let height = image.map { width * CGFloat($0.height) / CGFloat($0.width) } ?? width * 9 / 16
        VStack(alignment: .leading, spacing: 14) {
            Text("Where's the screen?").font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
            Text("Drag the box over the stage screen. Drag the corner to resize it.")
                .font(.ui(size: 12.5)).foregroundColor(Theme.muted)
            ZStack(alignment: .topLeading) {
                if let image { Image(decorative: image, scale: 1).resizable().frame(width: width, height: height) }
                else { Rectangle().fill(Theme.ink.opacity(0.06)).overlay(ProgressView().controlSize(.small)) }
                let box = CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height)
                Rectangle().fill(Theme.sand.opacity(0.18))
                    .overlay(Rectangle().stroke(Theme.sand, lineWidth: 2))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .gesture(DragGesture().onChanged { g in
                        let o = dragFrom ?? rect; dragFrom = o
                        rect.origin.x = min(1 - o.width, max(0, o.minX + g.translation.width / width))
                        rect.origin.y = min(1 - o.height, max(0, o.minY + g.translation.height / height))
                    }.onEnded { _ in dragFrom = nil })
                    .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
                Circle().fill(Theme.sand).frame(width: 14, height: 14)
                    .offset(x: box.maxX - 7, y: box.maxY - 7)
                    .gesture(DragGesture().onChanged { g in
                        let o = dragFrom ?? rect; dragFrom = o
                        rect.size.width = min(1 - o.minX, max(0.05, o.width + g.translation.width / width))
                        rect.size.height = min(1 - o.minY, max(0.05, o.height + g.translation.height / height))
                    }.onEnded { _ in dragFrom = nil })
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button { find() } label: { Label(finding ? "Looking…" : "Find it for me", systemImage: "viewfinder") }
                    .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(image == nil || finding)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Use this") { onDone(rect); dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .background(Theme.bg)
        .appLook(live: false)
        .task {
            if let start { rect = start }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1280, height: 720)
            image = try? await gen.image(at: CMTime(seconds: time + 0.5, preferredTimescale: 600)).image
        }
    }

    private func find() {
        guard let image else { return }
        finding = true
        Task.detached {
            let r = ScreenFinder.find(in: image)
            await MainActor.run {
                finding = false
                if let r { withAnimation(.easeOut(duration: 0.25)) { rect = r } }
            }
        }
    }
}
