import SwiftUI
import AVFoundation

/// Separate, resizable window for one video's reels: the list (generate, edit, export) on
/// the left and a large preview of the selected reel, with captions, on the right.
struct ReelWindowView: View {
    let recordID: UUID
    @ObservedObject private var store = AutoReelsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var previewID: UUID?
    private let gold = Theme.sand

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
                            Text("No clips yet").foregroundColor(Theme.ink.opacity(0.55))
                        }
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            } else {
                Text("This clip was deleted.").foregroundColor(Theme.ink.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AmbientBackdrop())
        .appLook()
        .navigationTitle(record?.title ?? "Clips")
        .frame(minWidth: 940, minHeight: 600)
        .background(WindowAccessor { $0.setFrameAutosaveName("AutoClipReels") })
        .onAppear { UserDefaults.standard.set(recordID.uuidString, forKey: Reopen.key) }
        .onDisappear {
            // Closed by hand: don't reopen it. Open at quit: do.
            if !Reopen.quitting, UserDefaults.standard.string(forKey: Reopen.key) == recordID.uuidString {
                UserDefaults.standard.removeObject(forKey: Reopen.key)
            }
        }
    }
}

/// Big playback of a draft reel: instant (un-rendered) preview with the caption look drawn on top.
struct DraftPreviewPane: View {
    let draft: ReelDraft
    let gold: Color
    /// Start playing as soon as it's loaded (quick review)
    var autoplay = false

    @State private var player = AVPlayer()
    @State private var words: [Word] = []
    @State private var time: Double = 0
    @State private var total: Double = 1
    @State private var isPlaying = false
    @State private var observer: Any?
    @State private var sourceAspect: CGFloat = 16.0 / 9.0
    @State private var following = false
    @State private var overlayItems: [ReelOverlays.Placed] = []
    @State private var followTask: Task<Void, Never>?
    @State private var zooms: [ReelMotion.Zoom] = []
    @AppStorage("phone_view") private var phoneRaw = PhoneView.off.rawValue
    private var phone: PhoneView { PhoneView(rawValue: phoneRaw) ?? .off }
    private var isVertical: Bool { draft.formatRaw == VideoExportService.ExportFormat.vertical9x16.rawValue }

    private var aspect: CGFloat {
        switch VideoExportService.ExportFormat(rawValue: draft.formatRaw) ?? .vertical9x16 {
        case .vertical9x16: return 9.0 / 16.0
        case .portrait4x5: return 4.0 / 5.0
        case .square1x1: return 1
        default: return sourceAspect
        }
    }
    private var look: CaptionLook { draft.styledLook }

    var body: some View {
        VStack(spacing: 12) {
            Text(draft.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
            ZStack {
                Color.black
                FillPlayerView(player: player)
                    .scaleEffect(ReelMotion.scale(at: time, zooms))
                if let img = ReelOverlays.previewImage(overlayItems, time: time, size: CGSize(width: 720, height: 720 / aspect)) {
                    Image(nsImage: img).resizable().allowsHitTesting(false)
                }
                if draft.captions,
                   let img = look.overlayImage(words: words, time: time, size: CGSize(width: 720, height: 720 / aspect)) {
                    Image(nsImage: img).resizable().allowsHitTesting(false)
                }
                if phone != .off, isVertical { PhoneChrome(view: phone) }
                if !isPlaying {
                    Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundColor(.white.opacity(0.85))
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipped()
            .cornerRadius(phone == .off ? 10 : 18)
            .phoneBezel(isVertical ? phone : .off)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }

            HStack(spacing: 10) {
                Button { toggle() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill").foregroundColor(gold) }
                    .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])
                Slider(value: Binding(get: { time }, set: { t in
                    time = t; player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }), in: 0...max(total, 0.1)).tint(Theme.action)
                Text("\(fmt(time)) / \(fmt(total))").font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.ink.opacity(0.55))
            }
            .frame(maxWidth: 520)
            HStack(spacing: 10) {
                PhoneViewMenu(view: Binding(get: { phone }, set: { phoneRaw = $0.rawValue }))
                if phone != .off, isVertical, draft.captions, phone.captionsCovered(look) {
                    Text("Captions sit behind \(phone.label)'s text. Move them up in the editor.").font(.system(size: 11.5)).foregroundColor(Theme.warn)
                }
            }
            if following {
                Label("Finding the speaker…", systemImage: "person.crop.rectangle")
                    .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
            }
        }
        .padding(20)
        .environment(\.colorScheme, .dark)
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
        followSpeaker(item)
        words = ws
        overlayItems = ReelOverlays.layout(hook: draft.hook, verses: draft.showVerses ? VerseDetector.find(in: ws) : [],
                                           look: look, size: CGSize(width: 720, height: 720 / aspect),
                                           duration: max(0.1, draft.duration), hookStyle: draft.hookAnimation, tag: draft.seriesTag)
        total = max(0.1, draft.duration)
        zooms = ReelMotion.zooms(draft)
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
        if autoplay { player.play(); isPlaying = true }
    }

    /// Re-crops the preview to follow whoever is talking (same tracking as the export)
    private func followSpeaker(_ item: AVPlayerItem) {
        followTask?.cancel()
        following = true
        let d = draft
        followTask = Task {
            let vc = await Task.detached(priority: .userInitiated) { await d.followComposition(for: item) }.value
            guard !Task.isCancelled else { return }
            if player.currentItem === item, let vc { item.videoComposition = vc }
            following = false
        }
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(max(0, s).rounded()); return String(format: "%d:%02d", i / 60, i % 60)
    }
}
