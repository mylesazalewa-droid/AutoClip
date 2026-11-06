import SwiftUI
import AppKit

/// What AutoClip is keeping on this Mac, what uses it, and what can safely go.
struct StorageTab: View {
    @ObservedObject private var reels = AutoReelsStore.shared
    @ObservedObject private var activity = TabActivity.shared
    @Environment(\.pageVisible) private var visible
    @State private var report: StorageReport?
    @State private var scanning = false
    @State private var open: Set<String> = []
    @State private var pending: [StorageItem] = []
    @State private var note: String?
    @State private var problem: String?

    private let lowSpace: Int64 = 10_000_000_000

    private func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    var body: some View {
        ScrollView {
            PageHeader(eyebrow: "Manage", title: "Storage", subtitle: "What AutoClip keeps on this Mac, and what you can clear.") {
                if scanning { ProgressView().controlSize(.small) }
                else { Button { Task { await scan() } } label: { Label("Check again", systemImage: "arrow.clockwise") }.buttonStyle(SecondaryButtonStyle(compact: true)) }
            }
            VStack(alignment: .leading, spacing: 22) {
                if let report {
                    disk(report)
                    clearCard(report)
                    if let note { Text(note).font(.system(size: 12)).foregroundColor(Theme.good).fixedSize(horizontal: false, vertical: true) }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
                    ForEach(report.groups) { groupCard($0) }
                } else {
                    Text("Adding up your files…").font(.system(size: 13)).foregroundColor(Theme.muted)
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 28).padding(.top, 8)
        }
        .task { await scan() }
        .onPageShown { Task { await scan() } }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trash(pending) }
            Button("Cancel", role: .cancel) { pending = [] }
        } message: {
            Text(dialogMessage)
        }
    }

    private var dialogTitle: String {
        pending.count == 1 ? "Move “\(pending[0].name)” to the Trash?" : "Move \(pending.count) items to the Trash?"
    }

    private var dialogMessage: String {
        let total = size(pending.reduce(0) { $0 + $1.bytes })
        let users = Set(pending.flatMap(\.usedBy)).sorted()
        if users.isEmpty { return "\(total). Nothing in AutoClip uses \(pending.count == 1 ? "it" : "these"). You can put \(pending.count == 1 ? "it" : "them") back from the Trash, and the space comes back once the Trash is emptied." }
        return "\(total). \(users.joined(separator: ", ")) still \(users.count == 1 ? "uses" : "use") this, and those parts won't be able to open the file. You can put it back from the Trash, and the space comes back once the Trash is emptied."
    }

    private func disk(_ r: StorageReport) -> some View {
        let capacity = max(r.capacity, 1)
        let other = max(0, capacity - r.free - r.total)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                figure(size(r.free), "free on this Mac", r.free < lowSpace ? Theme.warn : .white)
                figure(size(r.total), "used by AutoClip", .white)
                Spacer()
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.sand).frame(width: geo.size.width * CGFloat(Double(min(r.total, capacity)) / Double(capacity)))
                    Rectangle().fill(Color.white.opacity(0.28)).frame(width: geo.size.width * CGFloat(Double(other) / Double(capacity)))
                    Rectangle().fill(Color.white.opacity(0.07))
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                key(Theme.sand, "AutoClip"); key(Color.white.opacity(0.28), "Everything else"); key(Color.white.opacity(0.07), "Free")
            }
            if r.free < lowSpace {
                Label("Space is low. Video exports need room to work and may fail.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundColor(Theme.warn)
            }
        }
    }

    private func figure(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(30, weight: .medium)).foregroundColor(color).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundColor(Theme.muted)
        }
    }

    private func key(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 10)).foregroundColor(Theme.muted)
        }
    }

    private func clearCard(_ r: StorageReport) -> some View {
        let unused = r.unused
        let busy = activity.anythingRunning
        return AssessCard(title: "Safe to clear", subtitle: "Files nothing in AutoClip mentions any more. They go to the Trash, so you can get them back.") {
            if unused.isEmpty {
                Text("Nothing unused right now. Everything here belongs to a project, report or review. Open a group below to choose for yourself.")
                    .font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 14) {
                    Text("\(size(unused.reduce(0) { $0 + $1.bytes })) in \(unused.count) \(unused.count == 1 ? "item" : "items")")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream)
                    Spacer()
                    Button { pending = unused } label: { Label("Move all to Trash", systemImage: "trash") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                }
                ForEach(unused.prefix(5)) { i in
                    HStack {
                        Text(i.name).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(size(i.bytes)).font(.system(size: 11)).foregroundColor(Theme.faint).monospacedDigit()
                    }
                }
                if unused.count > 5 { Text("and \(unused.count - 5) more").font(.system(size: 11)).foregroundColor(Theme.faint) }
            }
            if busy {
                Label("AutoClip is working on something, so clearing waits until it finishes.", systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundColor(Theme.warn)
            }
            Button("Open the Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")) }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.sand)
        }
    }

    private func groupCard(_ g: StorageGroup) -> some View {
        let isOpen = open.contains(g.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if isOpen { open.remove(g.id) } else { open.insert(g.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: g.icon).font(.system(size: 14)).foregroundColor(Theme.sand).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream)
                        Text(g.detail).font(.system(size: 11)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 12)
                    Text(size(g.bytes)).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).monospacedDigit()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundColor(Theme.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Rectangle().fill(Theme.line).frame(height: 1)
                ForEach(g.items) { itemRow($0, canClear: g.canClear) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private func itemRow(_ i: StorageItem, canClear: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.name).font(.system(size: 12)).foregroundColor(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(usage(i, canClear: canClear)).font(.system(size: 10)).foregroundColor(i.usedBy.isEmpty && canClear ? Theme.good : Theme.faint)
            }
            Spacer(minLength: 8)
            Text(size(i.bytes)).font(.system(size: 12)).foregroundColor(Theme.muted).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "folder").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundColor(Theme.muted).help("Show in Finder")
            if canClear {
                Button { pending = [i] } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(Theme.muted).help("Move to the Trash").disabled(activity.anythingRunning)
            }
        }
    }

    private func usage(_ i: StorageItem, canClear: Bool) -> String {
        let when = i.modified.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        if !canClear && i.usedBy.isEmpty { return "Kept by AutoClip" + when }
        if i.usedBy.isEmpty { return (i.isPartial ? "Unfinished download" : "Not used") + when }
        return "Used by \(i.usedBy.joined(separator: ", "))" + when
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        report = await StorageScan.run(reelFiles: reels.reels.flatMap { [$0.path] + $0.paths })
        scanning = false
    }

    private func trash(_ items: [StorageItem]) {
        pending = []
        note = nil; problem = nil
        // Work may have started while the question was up
        guard !TabActivity.shared.anythingRunning else {
            problem = "AutoClip started working on something, so nothing was moved. Try again when it finishes."
            return
        }
        var freed: Int64 = 0, failed: [String] = []
        for i in items {
            do {
                try FileManager.default.trashItem(at: i.url, resultingItemURL: nil)
                freed += i.bytes
            } catch { failed.append(i.name) }
        }
        if freed > 0 { note = "Moved \(size(freed)) to the Trash. Empty the Trash to get the space back." }
        if !failed.isEmpty { problem = "Couldn't move: \(failed.joined(separator: ", "))." }
        Task { await scan() }
    }
}
