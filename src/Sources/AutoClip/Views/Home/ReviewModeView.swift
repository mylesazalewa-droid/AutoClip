import SwiftUI

/// Swipe through new reels one at a time with the keyboard: → keeps, ← throws out, space plays,
/// Z undoes. Each reel starts playing as it comes up. Kept reels end up selected for export,
/// and every choice teaches the reel picker (like export and 👎 do).
struct ReviewModeView: View {
    let recordID: UUID
    @Binding var selected: Set<UUID>
    var onToss: (ReelDraft) -> Void
    var onExport: ([UUID]) -> Void

    @ObservedObject private var store = AutoReelsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [UUID] = []
    @State private var index = 0
    @State private var kept: [UUID] = []
    @State private var tossed: [(draft: ReelDraft, at: Int)] = []
    @State private var history: [(id: UUID, choice: Choice)] = []
    private enum Choice { case keep, toss, skip }
    private let gold = Theme.sand

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }
    private var current: ReelDraft? {
        guard index < queue.count else { return nil }
        return record?.drafts?.first { $0.id == queue[index] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick review").font(Theme.display(20)).foregroundColor(Theme.cream)
                    Text(index < queue.count ? "Reel \(index + 1) of \(queue.count)" : "All reviewed")
                        .font(.system(size: 11)).foregroundColor(Theme.muted)
                }
                Spacer()
                Text("\(kept.count) kept · \(tossed.count) tossed").font(.system(size: 12)).foregroundColor(gold).monospacedDigit()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).padding(.leading, 10)
            }
            .padding(16)
            ProgressView(value: Double(min(index, queue.count)), total: Double(max(queue.count, 1)))
                .tint(gold).padding(.horizontal, 16)

            if let d = current {
                DraftPreviewPane(draft: d, gold: gold, autoplay: true).id(d.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 14) {
                    keyButton("Toss", key: "←", color: Theme.danger, shortcut: .leftArrow) { decide(keep: false) }
                    keyButton("Undo", key: "Z", color: Theme.muted, shortcut: "z") { undo() }
                        .disabled(history.isEmpty).opacity(history.isEmpty ? 0.4 : 1)
                    keyButton("Skip", key: "↓", color: Theme.muted, shortcut: .downArrow) { history.append((d.id, .skip)); index += 1 }
                    keyButton("Keep", key: "→", color: Theme.good, shortcut: .rightArrow) { decide(keep: true) }
                }
                .padding(.bottom, 18)
            } else {
                finished.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 760)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            // Reels not exported yet first: those are the new ones
            let ds = record?.drafts ?? []
            queue = ds.filter { $0.exportedPath == nil }.map(\.id) + ds.filter { $0.exportedPath != nil }.map(\.id)
        }
    }

    private var finished: some View {
        VStack(spacing: 14) {
            if kept.isEmpty {
                Image(systemName: "checkmark.seal").font(.system(size: 34)).foregroundColor(gold)
            } else {
                CelebrationBurst(size: 40)
            }
            Text("You kept \(kept.count) of \(queue.count)").font(Theme.display(24)).foregroundColor(Theme.cream)
            Text("Kept reels are selected in the list. AutoClip will pick more like them next time.")
                .font(.system(size: 12)).foregroundColor(Theme.muted)
            HStack(spacing: 10) {
                if !history.isEmpty {
                    Button("Undo last") { undo() }.buttonStyle(SecondaryButtonStyle(compact: false)).keyboardShortcut("z", modifiers: [])
                }
                if !kept.isEmpty {
                    Button("Export \(kept.count) kept reel\(kept.count == 1 ? "" : "s")") {
                        let ids = kept; dismiss(); onExport(ids)
                    }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func keyButton(_ title: String, key: String, color: Color, shortcut: KeyEquivalent,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(key).font(.system(size: 13, weight: .bold, design: .monospaced))
                    .frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.6)))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: [])
    }

    private func decide(keep: Bool) {
        guard let d = current, let rec = record else { return }
        Delight.tick()
        history.append((d.id, keep ? .keep : .toss))
        if keep {
            kept.append(d.id)
            selected.insert(d.id)
            TasteStore.shared.liked(d, kind: rec.kind)
        } else {
            tossed.append((d, (rec.drafts ?? []).firstIndex { $0.id == d.id } ?? 0))
            onToss(d)
        }
        index += 1
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        if last.choice == .keep {
            kept.removeAll { $0 == last.id }
            selected.remove(last.id)
            if let d = record?.drafts?.first(where: { $0.id == last.id }) { TasteStore.shared.unliked(d) }
        } else if last.choice == .toss, let t = tossed.popLast(), var rec = record {
            var ds = rec.drafts ?? []
            ds.insert(t.draft, at: min(t.at, ds.count))
            rec.drafts = ds
            rec.reelTitles = ds.map(\.title)
            store.update(rec)
            TasteStore.shared.unrejected(t.draft)
        }
        index = max(0, index - 1)
    }
}
