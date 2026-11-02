import SwiftUI
import AppKit
import AVFoundation

/// Clean up the full video: cut fillers, false starts and long pauses, then save a tighter copy.
struct CleanupSheet: View {
    let recordID: UUID
    @ObservedObject private var store = AutoReelsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var options = LongformCleanup.Options()
    @State private var words: [Word]?
    @State private var duration: Double = 0
    @State private var plan: LongformCleanup.Plan?
    @State private var progress: Double?
    @State private var saved: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }
    private var source: String? { record.flatMap { ReelGenerator.sourceVideoPath(for: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: "diamond.fill").font(.system(size: 5)).foregroundColor(Theme.sand)
                Text("THE FULL VIDEO, TIGHTER").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean up").font(Theme.display(28)).foregroundColor(Theme.cream)
                Text(record?.title ?? "").font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }

            if let saved {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Saved the cleaned video", systemImage: "checkmark.seal.fill").foregroundColor(Theme.good)
                        .font(.system(size: 14, weight: .semibold))
                    Text(saved.path).font(.system(size: 11)).foregroundColor(Theme.muted).textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                        Button { NSWorkspace.shared.activateFileViewerSelecting([saved]) } label: { Label("Show in Finder", systemImage: "folder") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    toggle($options.fillers, "Filler words", "um, uh, er, hmm")
                    toggle($options.falseStarts, "Stutters & false starts", "“I was going— I was going to say…” keeps the second try")
                    toggle($options.pauses, "Long pauses", "Pauses over \(String(format: "%.1f", options.maxPause))s become \(String(format: "%.2f", options.keepPause))s")
                    if options.pauses {
                        HStack(spacing: 10) {
                            Text("Shorten pauses over").font(.system(size: 11)).foregroundColor(Theme.muted)
                            Slider(value: $options.maxPause, in: 0.5...2.5, step: 0.1).frame(width: 200).tint(Theme.sand)
                            Text(String(format: "%.1fs", options.maxPause)).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.text)
                        }
                        .padding(.leading, 46)
                    }
                }

                summary

                if let e = error { Text(e).font(.system(size: 11)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                if let p = progress {
                    ProgressView(value: p).tint(Theme.action)
                    Text("Saving the cleaned video… \(Int(p * 100))%").font(.system(size: 11)).foregroundColor(Theme.muted)
                }
                HStack {
                    Text("Cuts fall between words, never inside them. A list of every cut is saved alongside.")
                        .font(.system(size: 10)).foregroundColor(Theme.faint)
                    Spacer()
                    Button("Cancel") { task?.cancel(); dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Button { save() } label: { Label("Save cleaned video…", systemImage: "scissors") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(progress != nil || (plan?.cutCount ?? 0) == 0)
                }
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
        .task { await load() }
        .onChange(of: options) { _, _ in replan() }
    }

    @ViewBuilder private var summary: some View {
        if words == nil {
            HStack(spacing: 8) { ProgressView().scaleEffect(0.6); Text("Reading the transcript…").font(.system(size: 12)).foregroundColor(Theme.muted) }
        } else if let p = plan {
            HStack(spacing: 22) {
                stat(fmt(p.removedSeconds), "shorter")
                stat("\(p.duration > 0 ? Int((p.removedSeconds / p.duration * 100).rounded()) : 0)%", "of the video")
                stat("\(p.fillers)", "fillers")
                stat("\(p.falseStarts)", "false starts")
                stat("\(p.pauses)", "pauses")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
            if options.fillers && p.fillers == 0 {
                Text("No ums or uhs in the transcript. The speech model often leaves them out, so pauses and false starts do most of the work.")
                    .font(.system(size: 10)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggle(_ on: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream)
                Text(detail).font(.system(size: 11)).foregroundColor(Theme.muted)
            }
        }
        .toggleStyle(.switch).tint(Theme.sand)
        .disabled(progress != nil)
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(Theme.display(20)).foregroundColor(Theme.cream).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundColor(Theme.muted)
        }
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(s.rounded()); return i >= 60 ? "\(i / 60)m \(i % 60)s" : "\(i)s"
    }

    private func load() async {
        guard let src = source else { error = "Can't find this video's source file."; words = []; return }
        do {
            words = try await TranscriptCache.transcript(for: src) { _ in }
            duration = (try? await AVURLAsset(url: URL(fileURLWithPath: src)).load(.duration).seconds) ?? (words?.last?.endTime ?? 0)
            replan()
        } catch { self.error = error.localizedDescription; words = [] }
    }

    private func replan() {
        guard let w = words, !w.isEmpty else { return }
        plan = LongformCleanup.plan(words: w, duration: duration, options: options)
    }

    private func save() {
        guard let src = source, let p = plan, let rec = record else { return }
        let panel = NSSavePanel()
        panel.title = "Save the cleaned video"
        panel.nameFieldStringValue = "\(rec.title) (cleaned).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = UserDefaults.standard.string(forKey: "ar_lastOutputDir").map { URL(fileURLWithPath: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil; progress = 0
        task = Task {
            do {
                try await LongformCleanup.export(source: URL(fileURLWithPath: src), plan: p, to: url) { v in
                    Task { @MainActor in progress = v }
                }
                try? LongformCleanup.cutList(p).write(to: url.deletingPathExtension().appendingPathExtension("cuts.txt"),
                                                     atomically: true, encoding: .utf8)
                saved = url
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            progress = nil
        }
    }
}
