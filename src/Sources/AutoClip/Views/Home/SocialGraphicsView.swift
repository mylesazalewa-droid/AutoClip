import SwiftUI
import AppKit

/// Quote cards, an Instagram carousel and a thumbnail for the full sermon, written by AI from
/// the transcript and drawn over frames of the speaker. Every card's text can be edited.
struct SocialGraphicsView: View {
    let record: AutoReelRecord
    let gold: Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var cards: [SocialGraphics.Card] = []
    @State private var images: [UUID: NSImage] = [:]
    @State private var frames: [Double: CGImage] = [:]
    @State private var source = ""
    @State private var status: String?
    @State private var error: String?
    @State private var saved: URL?

    private var look: CaptionLook {
        record.drafts?.first?.look ?? CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0])
    }
    private var footer: String { record.title }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Social graphics").font(.ui(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                    Text("Quote cards and a thumbnail from this message")
                        .font(.ui(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                }
                Spacer()
                Button { dismiss(); openWindow(id: "carousel-window", value: record.id) } label: {
                    Label("Sermon carousel", systemImage: "rectangle.split.3x1")
                }
                if !cards.isEmpty {
                    Button("Rewrite with AI") { generate() }.disabled(status != nil)
                    Button("Export all…") { exportAll() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(status != nil)
                }
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider().background(Theme.ink.opacity(0.08))

            if cards.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    if let status {
                        ProgressView().controlSize(.small)
                        Text(status).font(.ui(size: 13)).foregroundColor(Theme.ink.opacity(0.6))
                    } else {
                        Image(systemName: "photo.on.rectangle.angled").font(.ui(size: 38)).foregroundColor(gold)
                        Text("AI reads the message and writes 5 quote cards and a thumbnail headline.")
                            .font(.ui(size: 13)).foregroundColor(Theme.ink.opacity(0.6))
                        Button("Create graphics") { generate() }.buttonStyle(PrimaryButtonStyle())
                    }
                    if let error {
                        Text(error).font(.ui(size: 12)).foregroundColor(Theme.danger)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    if let saved {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.good)
                            Text("Saved to \(saved.lastPathComponent)").font(.ui(size: 13)).foregroundColor(Theme.ink)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                                .buttonStyle(.link)
                            Spacer()
                        }.padding(.horizontal, 16).padding(.top, 12)
                    }
                    if let status {
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.5); Text(status).font(.ui(size: 12)).foregroundColor(Theme.ink.opacity(0.6)) }
                            .padding(.top, 8)
                    }
                    section("Thumbnail for the full video", kinds: [.thumbnail], min: 360)
                    section("Quote cards", kinds: [.quote], min: 220)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 680)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }

    @ViewBuilder private func section(_ title: String, kinds: [SocialGraphics.Kind], min: CGFloat) -> some View {
        let items = cards.indices.filter { kinds.contains(cards[$0].kind) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased()).font(.ui(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: min), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(items, id: \.self) { i in cardView(i) }
                }
            }
            .padding(16)
        }
    }

    private func cardView(_ i: Int) -> some View {
        let c = cards[i]
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Theme.ink.opacity(0.05)
                if let img = images[c.id] { Image(nsImage: img).resizable().scaledToFit() }
                else { ProgressView().controlSize(.small) }
            }
            .aspectRatio(c.size.width / c.size.height, contentMode: .fit)
            .cornerRadius(6)
            TextField("Text", text: Binding(get: { cards[i].text }, set: { cards[i].text = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(.ui(size: 12)).foregroundColor(Theme.ink)
                .lineLimit(1...5)
                .padding(6).background(Theme.ink.opacity(0.06)).cornerRadius(5)
                .onSubmit { redraw(cards[i]) }
            HStack {
                Button("Update") { redraw(cards[i]) }.buttonStyle(.link).font(.ui(size: 12))
                Spacer()
                Button { shiftFrame(i) } label: { Label("Other photo", systemImage: "photo") }
                    .buttonStyle(.link).font(.ui(size: 12))
                    .help("Use a different moment from the video as the background")
            }
        }
    }

    // MARK: Actions

    private func generate() {
        error = nil; saved = nil; status = "Starting…"
        Task {
            do {
                let r = try await CostTag.$video.withValue(record.title) {
                    try await ReelGenerator.graphics(for: record) { msg in Task { @MainActor in status = msg } }
                }
                source = r.source
                cards = SocialGraphics.cards(from: r.plan, sentences: r.sentences).filter { [.quote, .thumbnail].contains($0.kind) }
                images = [:]
                status = "Drawing graphics…"
                for c in cards { await draw(c) }
            } catch { self.error = error.localizedDescription }
            status = nil
        }
    }

    private func redraw(_ c: SocialGraphics.Card) {
        Task { await draw(c) }
    }

    /// Moves a card's background to a moment a few seconds later in the talk.
    private func shiftFrame(_ i: Int) {
        cards[i].time += 7
        redraw(cards[i])
    }

    private func draw(_ c: SocialGraphics.Card) async {
        let bg: CGImage?
        if let cached = frames[c.time] { bg = cached } else {
            bg = await SocialGraphics.frame(at: c.time, source: source)
            frames[c.time] = bg
        }
        let look = self.look, footer = self.footer
        let data = await Task.detached(priority: .userInitiated) {
            SocialGraphics.png(SocialGraphics.render(c, background: bg, look: look, footer: footer))
        }.value
        if let data, let img = NSImage(data: data) { images[c.id] = img }
    }

    private func exportAll() {
        guard let folder = ReelExportLocation.pick(title: "Choose where to save the graphics") else { return }
        let safe = record.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dir = folder.appendingPathComponent(String(safe.prefix(60)) + " – Graphics")
        status = "Saving…"
        Task {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let look = self.look, footer = self.footer
            for c in cards {
                var bg = frames[c.time]
                if bg == nil { bg = await SocialGraphics.frame(at: c.time, source: source) }
                let data = await Task.detached(priority: .userInitiated) {
                    SocialGraphics.png(SocialGraphics.render(c, background: bg, look: look, footer: footer))
                }.value
                try? data?.write(to: dir.appendingPathComponent(c.fileName))
            }
            saved = dir
            status = nil
        }
    }
}
