import SwiftUI
import AVFoundation

/// Separate, resizable window for one video's reels: the list (generate, edit, export) on
/// the left and a large preview of the selected reel, with captions, on the right.
struct ReelWindowView: View {
    let recordID: UUID
    @ObservedObject private var store = AutoReelsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var previewID: UUID?
    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }
    private var previewDraft: ReelDraft? {
        let ds = record?.drafts ?? []
        return ds.first { $0.id == previewID } ?? ds.first
    }

    var body: some View {
        Group {
            if record != nil {
                HSplitView {
                    ReelDraftsView(recordID: recordID, gold: gold,
                                   onDelete: { store.remove(id: recordID); dismiss() },
                                   previewingID: previewDraft?.id,
                                   onPreview: { previewID = $0 })
                        .frame(minWidth: 520, idealWidth: 600)
                    Group {
                        if let d = previewDraft {
                            DraftPreviewPane(draft: d, gold: gold).id(d.id)
                        } else {
                            Text("No reels yet").foregroundColor(Color.white.opacity(0.4))
                        }
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            } else {
                Text("This reel was deleted.").foregroundColor(Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
        .preferredColorScheme(.dark)
        .navigationTitle(record?.title ?? "Reels")
        .frame(minWidth: 940, minHeight: 600)
    }
}

/// Big playback of a draft reel: instant (un-rendered) preview with the caption look drawn on top.
struct DraftPreviewPane: View {
    let draft: ReelDraft
    let gold: Color

    @State private var player = AVPlayer()
    @State private var words: [Word] = []
    @State private var time: Double = 0
    @State private var total: Double = 1
    @State private var isPlaying = false
    @State private var observer: Any?
    @State private var sourceAspect: CGFloat = 16.0 / 9.0

    private var aspect: CGFloat {
        switch VideoExportService.ExportFormat(rawValue: draft.formatRaw) ?? .vertical9x16 {
        case .vertical9x16: return 9.0 / 16.0
        case .portrait4x5: return 4.0 / 5.0
        case .square1x1: return 1
        default: return sourceAspect
        }
    }
    private var look: CaptionLook { draft.look ?? CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0]) }

    var body: some View {
        VStack(spacing: 12) {
            Text(draft.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            ZStack {
                Color.black
                FillPlayerView(player: player)
                if draft.captions,
                   let img = look.overlayImage(words: words, time: time, size: CGSize(width: 720, height: 720 / aspect)) {
                    Image(nsImage: img).resizable().allowsHitTesting(false)
                }
                if !isPlaying {
                    Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundColor(.white.opacity(0.85))
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .cornerRadius(10)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            HStack(spacing: 10) {
                Button { toggle() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill").foregroundColor(gold) }
                    .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                Slider(value: Binding(get: { time }, set: { t in
                    time = t; player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }), in: 0...max(total, 0.1)).tint(gold)
                Text("\(fmt(time)) / \(fmt(total))").font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
            }
            .frame(maxWidth: 520)
        }
        .padding(20)
        .task { await load() }
        .onChange(of: draft) { _ in Task { await load() } }
        .onDisappear { if let o = observer { player.removeTimeObserver(o) }; player.pause() }
    }

    private func toggle() {
        if isPlaying { player.pause() } else {
            if time >= total - 0.1 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying.toggle()
    }

    private func load() async {
        guard let (item, ws) = await draft.previewItem() else { return }
        if let o = observer { player.removeTimeObserver(o); observer = nil }
        player.replaceCurrentItem(with: item)
        words = ws
        total = max(0.1, draft.duration)
        time = 0; isPlaying = false
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = size.applying(t)
            if abs(r.height) > 0 { sourceAspect = abs(r.width) / abs(r.height) }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { t in
            time = CMTimeGetSeconds(t)
            if time >= total - 0.05 { isPlaying = false }
        }
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(max(0, s).rounded()); return String(format: "%d:%02d", i / 60, i % 60)
    }
}
