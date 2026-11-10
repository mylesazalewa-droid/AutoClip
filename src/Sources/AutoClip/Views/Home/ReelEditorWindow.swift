import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Which reel an editor window is for.
struct EditorTarget: Codable, Hashable {
    var record: UUID
    var draft: UUID
}

extension AutoReelsStore {
    /// Saves an edited reel into its project. Only real changes mark an exported reel as stale.
    func saveDraft(_ draft: ReelDraft, in recordID: UUID) {
        guard var rec = reels.first(where: { $0.id == recordID }), var ds = rec.drafts,
              let i = ds.firstIndex(where: { $0.id == draft.id }) else { return }
        var d = draft
        var a = d, b = ds[i]
        a.exportedPath = nil; a.editedSinceExport = false; a.guardReview = nil
        b.exportedPath = nil; b.editedSinceExport = false; b.guardReview = nil
        if a != b, d.exportedPath != nil, d.exportedPath == ds[i].exportedPath { d.editedSinceExport = true }
        ds[i] = d
        rec.drafts = ds
        rec.duration = ds.first?.duration ?? rec.duration
        update(rec)
    }
}

/// Asks the reel list to export a reel, from an editor in another window.
@MainActor
final class ExportRequests: ObservableObject {
    static let shared = ExportRequests()
    @Published var pending: EditorTarget?
}

/// The editor in its own window, so it can be as big as the screen.
struct ReelEditorHost: View {
    let target: EditorTarget
    @ObservedObject private var store = AutoReelsStore.shared

    var body: some View {
        Group {
            if let rec = store.reels.first(where: { $0.id == target.record }),
               let d = rec.drafts?.first(where: { $0.id == target.draft }) {
                ReelEditorView(draft: d, gold: Theme.sand, recordID: rec.id,
                               onSave: { store.saveDraft($0, in: rec.id) },
                               onExport: { d in
                                   store.saveDraft(d, in: rec.id)
                                   ExportRequests.shared.pending = target
                               })
                    .navigationTitle(d.title)
            } else {
                Text("This clip was deleted.").foregroundColor(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .appLook(live: false)
        .tint(Theme.action)
        .background(WindowAccessor { $0.setFrameAutosaveName("AutoClipEditor") })
    }
}

/// Hands over the NSWindow a SwiftUI view lives in.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Takes over a window's close button (and ⌘W), to ask before throwing edits away.
final class CloseGuard: NSObject {
    var allow: () -> Bool = { true }
    weak var window: NSWindow?

    func attach(to w: NSWindow) {
        window = w
        guard let b = w.standardWindowButton(.closeButton) else { return }
        b.target = self
        b.action = #selector(tryClose(_:))
    }

    @objc func tryClose(_ sender: Any?) {
        if allow() { window?.close() }
    }
}

// MARK: - Timeline

/// The reel as a strip: each clip a block, sentences marked, punch-ins and slow pushes,
/// the hook and verse cards above, and the playhead. Click or drag to move through it.
struct EditTimeline: View {
    let draft: ReelDraft
    let timeline: [ReelDraft.TimedSentence]
    let zooms: [ReelMotion.Zoom]
    let overlays: [ReelOverlays.Placed]
    let total: Double
    let time: Double
    var seek: (Double) -> Void

    private var pieceSpans: [(index: Int, start: Double, end: Double)] {
        var out: [(Int, Double, Double)] = []
        for (i, p) in draft.pieces.enumerated() {
            let ids = Set(p.sentences.map(\.id))
            let ts = timeline.filter { ids.contains($0.id) }
            if let a = ts.map(\.start).min(), let b = ts.map(\.end).max() { out.append((i, a, b)) }
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x: (Double) -> CGFloat = { CGFloat($0 / max(total, 0.1)) * w }
            ZStack(alignment: .topLeading) {
                // Hook and verse cards
                ForEach(Array(overlays.filter { !$0.still }.enumerated()), id: \.offset) { _, o in
                    RoundedRectangle(cornerRadius: 2).fill(o.pop ? Theme.sand.opacity(0.9) : Theme.navyLight.opacity(0.9))
                        .frame(width: max(3, x(o.end) - x(o.start)), height: 5).offset(x: x(o.start), y: 0)
                }
                // Clips
                ForEach(pieceSpans, id: \.index) { s in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(s.index % 2 == 0 ? Theme.ink.opacity(0.16) : Theme.ink.opacity(0.1))
                        Text("\(s.index + 1)").font(.ui(size: 11, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).padding(.leading, 4)
                    }
                    .frame(width: max(2, x(s.end) - x(s.start) - 1), height: 22).offset(x: x(s.start), y: 9)
                }
                // Sentence edges
                ForEach(timeline, id: \.id) { t in
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1, height: 22).offset(x: x(t.start), y: 9)
                }
                // Movement
                ForEach(Array(zooms.enumerated()), id: \.offset) { _, z in
                    RoundedRectangle(cornerRadius: 2).fill(z.punch ? Theme.terracottaLight : Theme.terracottaLight.opacity(0.35))
                        .frame(width: max(3, x(z.end) - x(z.start)), height: 4).offset(x: x(z.start), y: 34)
                }
                // Playhead
                Rectangle().fill(Theme.cream).frame(width: 2, height: 36).offset(x: min(w - 2, x(time)), y: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                seek(max(0, min(total, Double(v.location.x / max(w, 1)) * total)))
            })
        }
        .frame(height: 40)
        .help("Moments, sentences, the hook (sand), verse cards (blue) and movement (orange). Click to jump.")
    }
}

// MARK: - Reordering clips by dragging

struct PieceDrop: DropDelegate {
    let target: UUID
    @Binding var draft: ReelDraft
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target,
              let a = draft.pieces.firstIndex(where: { $0.id == from }),
              let b = draft.pieces.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            draft.pieces.move(fromOffsets: IndexSet(integer: a), toOffset: b > a ? b + 1 : b)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
