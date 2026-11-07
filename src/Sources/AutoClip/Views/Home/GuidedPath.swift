import SwiftUI

/// One clear path through the app: from a sermon to shorts you've posted and learned from.
struct GuidedPathCard: View {
    @ObservedObject private var reels = AutoReelsStore.shared
    @ObservedObject private var results = ShortResultsStore.shared

    private enum Step: Int, CaseIterable { case add, review, export, results }

    private var latest: AutoReelRecord? { reels.reels.first { !($0.drafts ?? []).isEmpty } }
    private var drafts: [ReelDraft] { latest?.drafts ?? [] }
    private var exported: [ReelDraft] { drafts.filter { $0.exportedPath != nil } }
    private var reviewed: Bool {
        guard let latest else { return false }
        return !exported.isEmpty || UserDefaults.standard.bool(forKey: AutoReelsStore.reviewedKey(latest.id))
    }
    private var hasResults: Bool {
        let paths = Set(exported.compactMap(\.exportedPath))
        let titles = Set(drafts.map(\.title))
        return results.shorts.contains { ($0.videoPath.map(paths.contains) ?? false) || titles.contains($0.title) }
    }

    private func isDone(_ s: Step) -> Bool {
        switch s {
        case .add: return latest != nil
        case .review: return reviewed
        case .export: return !exported.isEmpty
        case .results: return hasResults
        }
    }

    private var current: Step? { Step.allCases.first { !isDone($0) } }

    private func title(_ s: Step) -> String {
        switch s {
        case .add: return "Add your sermon"
        case .review: return "Pick your best clips"
        case .export: return "Polish and export"
        case .results: return "Post and add results"
        }
    }

    private func detail(_ s: Step) -> String {
        switch s {
        case .add: return latest?.title ?? "Drop in a video or paste a link. AutoClip finds the moments worth sharing."
        case .review: return drafts.isEmpty ? "Keep or toss each clip, one at a time." : "\(drafts.count) clips to look through, one at a time."
        case .export: return drafts.isEmpty ? "Trim it, check the captions and save it." : "\(exported.count) of \(drafts.count) exported so far."
        case .results: return "Tell AutoClip how they did, and it learns what works for your audience."
        }
    }

    private func action(_ s: Step) -> (String, () -> Void) {
        switch s {
        case .add:
            return ("Choose a sermon", { reels.requestNewReel = true; HomeNav.shared.open(.autoReels) })
        case .review:
            return ("Start reviewing", {
                guard let id = latest?.id else { return }
                reels.reviewOnOpen = id
                reels.navigateToReelID = id
                HomeNav.shared.open(.autoReels)
            })
        case .export:
            return ("Open the clips", {
                guard let id = latest?.id else { return }
                reels.navigateToReelID = id
                HomeNav.shared.open(.autoReels)
            })
        case .results:
            return ("Add results", { HomeNav.shared.open(.results) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(latest == nil ? "Start here" : current == nil ? "That one's done" : "Your next step")
                    .font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
                if let t = latest?.title {
                    Text(t).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
                }
                Spacer()
                if current == nil {
                    Button { action(.add).1() } label: { Label("Start the next sermon", systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Step.allCases, id: \.rawValue) { step(_: $0) }
            }
        }
        .padding(.horizontal, 32)
    }

    private func step(_ s: Step) -> some View {
        let done = isDone(s)
        let now = s == current
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(done ? Theme.good.opacity(0.25) : now ? Theme.sand : Color.white.opacity(0.08)).frame(width: 22, height: 22)
                    if done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.good) }
                    else { Text("\(s.rawValue + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(now ? Theme.bg : Theme.muted) }
                }
                Text(title(s)).font(.system(size: 13, weight: .semibold)).foregroundColor(now || done ? Theme.cream : Theme.muted)
            }
            Text(detail(s)).font(.system(size: 11)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if now {
                let a = action(s)
                Button(action: a.1) { Text(a.0) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(now ? Theme.sand.opacity(0.1) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(now ? Theme.sand.opacity(0.5) : Theme.line, lineWidth: 1))
    }
}
