import SwiftUI

/// "Made for" chip in the header: what kind of videos the user makes, and what AutoClip has
/// learned from their reels so far.
struct ContentKindMenu: View {
    @AppStorage("content_kind") private var raw = ContentKind.sermon.rawValue
    @ObservedObject private var taste = TasteStore.shared
    @State private var showLearned = false
    @State private var hover = false

    private var kind: ContentKind { ContentKind(rawValue: raw) ?? .sermon }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Section("I make…") {
                    ForEach(ContentKind.allCases) { k in
                        Button { raw = k.rawValue } label: {
                            Label(k.label, systemImage: k == kind ? "checkmark" : k.icon)
                        }
                    }
                }
                Divider()
                Button("What AutoClip has learned…") { showLearned = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: kind.icon).font(.system(size: 12))
                    Text(kind.label).font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(hover ? Theme.cream : Theme.sand)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink.opacity(hover ? 0.08 : 0.04)))
            .overlay(Capsule().stroke(Theme.sand.opacity(0.3), lineWidth: 1))
            .onHover { hover = $0 }
            .help("What kind of videos you make — it changes how clips, captions and notes are written")
        }
        .popover(isPresented: $showLearned, arrowEdge: .bottom) { LearnedView(kind: kind) }
    }
}

/// What the reel picker has learned from exports, "Not for me" and edits.
struct LearnedView: View {
    let kind: ContentKind
    @ObservedObject private var taste = TasteStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "diamond.fill").font(.system(size: 5)).foregroundColor(Theme.sand)
                Text("LEARNING FROM YOU").font(.system(size: 11.5, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
            }
            Text("What AutoClip has learned").font(Theme.display(20)).foregroundColor(Theme.cream)
            let t = taste.taste
            let kept = t.kept.filter { $0.kind == kind.rawValue }
            let rejected = t.rejected.filter { $0.kind == kind.rawValue }
            if kept.isEmpty && rejected.isEmpty && t.addedAfter + t.addedBefore + t.removed == 0 {
                Text("Nothing yet. Every clip you export, every clip you mark Not for me, and every sentence you add or cut teaches AutoClip what to pick next time.")
                    .font(.system(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 16) {
                    stat("\(kept.count)", "kept")
                    stat("\(rejected.count)", "not for me")
                    stat("\(t.addedAfter + t.addedBefore)", "sentences added")
                    stat("\(t.removed)", "sentences cut")
                }
                let lessons = taste.lessons(for: kind)
                if !lessons.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lessons, id: \.self) { l in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "sparkle").font(.system(size: 11)).foregroundColor(Theme.sand).padding(.top, 3)
                                Text(l).font(.system(size: 13)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Text("New clips for \(kind.label.lowercased()) use this automatically.")
                    .font(.system(size: 12)).foregroundColor(Theme.faint)
                Button("Start over") { taste.reset() }.buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.surface)
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(Theme.display(22)).foregroundColor(Theme.cream)
            Text(label).font(.system(size: 11.5)).foregroundColor(Theme.muted)
        }
    }
}
