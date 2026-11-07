import SwiftUI

/// On Home: clips Autopilot made while you were away.
struct AutopilotCard: View {
    @ObservedObject private var auto = AutoImport.shared
    @ObservedObject private var reels = AutoReelsStore.shared

    var body: some View {
        let waiting = Array(auto.waiting.prefix(3))
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sunrise.fill").foregroundColor(Theme.sand)
                    Text(waiting.count == 1 ? "Your clips are ready" : "\(waiting.count) sermons are ready").font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
                }
                ForEach(waiting, id: \.record.id) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.record.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1)
                            HStack(spacing: 8) {
                                Text("\(item.record.drafts?.count ?? 0) clips · \(Date(timeIntervalSince1970: item.event.date).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundColor(Theme.muted)
                                if let n = item.event.flagged, n > 0 {
                                    Label("\(n) to double-check", systemImage: "exclamationmark.shield").font(.system(size: 11)).foregroundColor(Theme.warn)
                                }
                            }
                        }
                        Spacer()
                        Button("Start reviewing") {
                            reels.reviewOnOpen = item.record.id
                            reels.navigateToReelID = item.record.id
                            HomeNav.shared.open(.autoReels)
                        }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        Button { auto.dismissWaiting(item.record.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.faint).help("Hide this")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.sand.opacity(0.35)))
                }
            }
            .padding(.horizontal, 32)
        }
    }
}

/// A small shield on a reel's row when Context Guard has something to say.
struct GuardBadge: View {
    let draft: ReelDraft
    @State private var serious = 0
    @State private var minor = 0

    var body: some View {
        // An HStack, because a Group with nothing in it never runs its task
        HStack(spacing: 0) {
            if serious > 0 {
                Label("\(serious) to double-check", systemImage: "exclamationmark.shield.fill")
                    .foregroundColor(Theme.warn)
                    .help("Context Guard: this clip might say something the speaker didn't mean. Open it to see why.")
            } else if minor > 0 {
                Image(systemName: "shield").foregroundColor(Color.white.opacity(0.35)).help("Context Guard has \(minor) small note\(minor == 1 ? "" : "s"). Open the reel to see.")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .task(id: ContextGuard.signature(draft)) {
            let d = draft
            let found = await Task.detached(priority: .utility) { ContextGuard.quick(d) }.value
            serious = found.filter(\.serious).count
            minor = found.count - serious
        }
    }
}

/// In the editor: what this reel might say that the speaker didn't mean.
struct ContextGuardCard: View {
    @Binding var draft: ReelDraft
    @Binding var translation: String
    let busy: Bool
    let error: String?
    let runDeep: () -> Void
    @State private var issues: [ContextGuard.Issue] = []
    @State private var open = true

    private var review: ReelDraft.GuardReview? {
        draft.guardReview.flatMap { $0.signature == ContextGuard.signature(draft) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: issues.contains(where: \.serious) ? "exclamationmark.shield.fill" : "checkmark.shield")
                    .foregroundColor(issues.contains(where: \.serious) ? Theme.warn : Theme.good)
                Text("CONTEXT GUARD").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundColor(Color.white.opacity(0.5))
                Text(headline).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 4)
                if !issues.isEmpty || review != nil {
                    Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down") }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5))
                }
            }
            if open {
                ForEach(issues) { issue in row(issue) }
                if let review { aiResult(review) }
            }
            HStack(spacing: 8) {
                Button { runDeep() } label: {
                    Label(review == nil ? "Check meaning and Scripture with AI" : "Check again", systemImage: "sparkles")
                }
                .controlSize(.small).disabled(busy || draft.includedSentenceCount == 0)
                Picker("Translation", selection: $translation) {
                    ForEach(ContextGuard.translations, id: \.self) { Text($0 == "Any" ? "Any translation" : $0).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .help("Which Bible translation quoted verses are compared with")
                if busy { ProgressView().scaleEffect(0.5).frame(width: 14, height: 14) }
                Spacer(minLength: 0)
            }
            if let error { Text(error).font(.system(size: 10)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            Text("A second pair of eyes, not a final word. You know what was meant.")
                .font(.system(size: 9)).foregroundColor(Color.white.opacity(0.35))
        }
        .padding(12)
        .background(Color.white.opacity(0.04)).cornerRadius(10)
        .task(id: ContextGuard.signature(draft)) {
            let d = draft
            issues = await Task.detached(priority: .userInitiated) { ContextGuard.quick(d) }.value
        }
    }

    private var headline: String {
        let serious = issues.filter(\.serious).count
        if serious > 0 { return "\(serious) thing\(serious == 1 ? "" : "s") to double-check" }
        if !issues.isEmpty { return "\(issues.count) small note\(issues.count == 1 ? "" : "s")" }
        return "Nothing stands out"
    }

    private func row(_ issue: ContextGuard.Issue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(issue.serious ? Theme.warn : Color.white.opacity(0.3)).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.system(size: 12, weight: .medium)).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                Text(issue.detail).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let fix = issue.fix, let label = issue.fixLabel {
                Button(label) { draft.applyFix(fix) }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private func aiResult(_ r: ReelDraft.GuardReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: r.verdict == "clear" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(r.verdict == "clear" ? Theme.good : Theme.warn)
                Text(r.summary ?? (r.verdict == "clear" ? "AI found this fair to the message." : "AI found something to look at."))
                    .font(.system(size: 12)).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((r.issues ?? []).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let q = item.quote { Text("“\(q)”").font(.system(size: 11, weight: .medium)).foregroundColor(.white).fixedSize(horizontal: false, vertical: true) }
                        if let w = item.why { Text(w).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 4)
                    if let i = clipIndex(item), item.fix == "add_after" || item.fix == "add_before" {
                        Button(item.fix == "add_after" ? "Add the next sentence" : "Add the sentence before") {
                            draft.applyFix(item.fix == "add_after" ? .addAfter(piece: i) : .addBefore(piece: i))
                        }.controlSize(.small)
                    }
                }
            }
            ForEach(Array((r.verses ?? []).enumerated()), id: \.offset) { _, v in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: verseIcon(v.status)).font(.system(size: 10)).foregroundColor(v.status == "different" ? Theme.warn : Color.white.opacity(0.5))
                    Text("\(v.reference ?? "A verse"): \(verseText(v.status))\(v.note.map { ". \($0)" } ?? "")")
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !(r.verses ?? []).isEmpty {
                Text("AI can misremember Bible wording. Check the verse itself before relying on this.")
                    .font(.system(size: 9)).foregroundColor(Color.white.opacity(0.35))
            }
        }
    }

    private func clipIndex(_ item: ReelDraft.GuardReview.Item) -> Int? {
        guard let c = item.clip, draft.pieces.indices.contains(c - 1) else { return nil }
        return c - 1
    }

    private func verseIcon(_ s: String?) -> String {
        switch s { case "matches": return "checkmark.circle"; case "different": return "exclamationmark.circle"; default: return "questionmark.circle" }
    }

    private func verseText(_ s: String?) -> String {
        switch s {
        case "matches": return "matches"
        case "paraphrase": return "paraphrased"
        case "different": return "looks different from that translation"
        default: return "not sure"
        }
    }
}

/// The editor's keys, one glance.
struct EditorKeysHelp: View {
    private let keys: [(String, String)] = [
        ("Space", "Play or pause"), ("J", "Play backward, or back 5 seconds"), ("K", "Stop"), ("L", "Play, press again to go faster"),
        ("← →", "Nudge 0.1 second (hold Shift for 1 second)"), ("↑ ↓", "Previous or next sentence"),
        ("I", "Start this clip here"), ("O", "End this clip here"), ("X or Delete", "Cut or restore this sentence"),
        ("F", "Focus mode"), ("P", "Next phone view"), ("⌘K", "Say what to change"), ("⌘Z", "Undo"), ("?", "This list")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard shortcuts").font(.system(size: 13, weight: .semibold)).foregroundColor(.white).padding(.bottom, 4)
            ForEach(keys, id: \.0) { k, v in
                HStack(spacing: 10) {
                    Text(k).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(Theme.sand)
                        .frame(width: 84, alignment: .leading)
                    Text(v).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.75))
                }
            }
        }
        .padding(16).frame(width: 340).background(Theme.surface)
    }
}
