import SwiftUI
import UniformTypeIdentifiers

/// AutoClip in the menu bar: what's being made, what's ready, and a place to drop a video.
struct MenuBarPanel: View {
    @ObservedObject private var store = AutoReelsStore.shared
    @ObservedObject private var auto = AutoImport.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menubar_on") private var menuBarOn = true
    @State private var dropping = false

    private var jobs: [AutoReelJob] { store.activeJobs.filter { !$0.isFinished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AutoClip").font(.ui(size: 13, weight: .semibold))
                Spacer()
                Text(auto.settings.enabled ? "Autopilot on" : "Autopilot off").font(.ui(size: 12)).foregroundColor(auto.settings.enabled ? Theme.good : .secondary)
            }
            if !jobs.isEmpty {
                ForEach(jobs) { j in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(j.title).font(.ui(size: 13, weight: .medium)).lineLimit(1)
                        ProgressView(value: j.progress).tint(Theme.sand)
                        Text(j.statusMsg).font(.ui(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            } else if let s = auto.status {
                Text(s).font(.ui(size: 12)).foregroundColor(.secondary).lineLimit(2)
            }
            let waiting = Array(auto.waiting.prefix(4))
            if !waiting.isEmpty {
                Divider()
                Text("READY TO REVIEW").font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(.secondary)
                ForEach(waiting, id: \.record.id) { item in
                    HStack {
                        Text(item.record.title).font(.ui(size: 13)).lineLimit(1)
                        Spacer()
                        Button("Review") { review(item.record.id) }.controlSize(.small)
                    }
                }
            }
            Divider()
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.ui(size: 18)).foregroundColor(dropping ? Theme.sand : .secondary)
                Text("Drop a sermon here to make clips").font(.ui(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundColor(dropping ? Theme.sand : Color.secondary.opacity(0.4)))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in IncomingVideos.handle([url]) } }
                    }
                }
                return true
            }
            HStack {
                Button("Open AutoClip") { openMain() }
                Spacer()
                Button("Hide this icon") { menuBarOn = false }.buttonStyle(.link).font(.ui(size: 12))
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) { w.makeKeyAndOrderFront(nil) } else { openWindow(id: "main") }
    }

    private func review(_ id: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        store.reviewOnOpen = id
        openWindow(id: "reel-window", value: id)
    }
}
