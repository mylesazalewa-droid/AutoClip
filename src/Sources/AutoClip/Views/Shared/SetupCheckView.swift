import SwiftUI
import AppKit

/// The "Check setup" list in Settings → General.
struct SetupCheckView: View {
    @ObservedObject private var check = SetupCheck.shared
    @ObservedObject private var whisper = WhisperService.shared
    @State private var downloading = false
    @State private var downloadNote: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                summaryIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.summary).font(.ui(size: 13, weight: .medium))
                    Text("Makes sure the speech model, video making and download tools work on this Mac. Uses no AI credits.")
                        .font(.ui(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(check.lastRun == nil ? "Check setup" : "Check again") { check.run() }
                    .disabled(check.running || downloading)
            }
            if !check.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(check.items) { item in row(item) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.04)))
            }
        }
    }

    @ViewBuilder private var summaryIcon: some View {
        let bad = check.items.contains { $0.state == .problem }
        let warn = check.items.contains { $0.state == .warning }
        if check.running { ProgressView().controlSize(.small).frame(width: 20) }
        else if check.lastRun == nil { Image(systemName: "stethoscope").foregroundColor(.secondary).frame(width: 20) }
        else {
            Image(systemName: bad ? "xmark.octagon.fill" : warn ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundColor(bad ? Theme.danger : warn ? Theme.sand : Theme.good).frame(width: 20)
        }
    }

    private func row(_ item: SetupCheck.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch item.state {
                case .waiting: Image(systemName: "circle").foregroundColor(.secondary.opacity(0.5))
                case .checking: ProgressView().controlSize(.mini)
                case .good: Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.good)
                case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.sand)
                case .problem: Image(systemName: "xmark.circle.fill").foregroundColor(Theme.danger)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.ui(size: 12.5, weight: .medium))
                if !item.detail.isEmpty {
                    Text(item.detail).font(.ui(size: 11.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let fix = item.fix { fixView(fix) }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func fixView(_ fix: SetupCheck.Fix) -> some View {
        switch fix {
        case .downloadModel:
            HStack(spacing: 8) {
                Button(downloading ? "Downloading…" : "Download the speech model") { download() }
                    .controlSize(.small).disabled(downloading)
                if let downloadNote { Text(downloadNote).font(.ui(size: 11)).foregroundColor(.secondary) }
            }
        case .openAISettings:
            Text("Add one in the AI tab at the top of Settings.").font(.ui(size: 11.5)).foregroundColor(.secondary)
        case .copy(let command):
            HStack(spacing: 8) {
                Text(command).font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.08)))
                    .textSelection(.enabled)
                Button(copied == command ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = command
                }
                .controlSize(.small)
            }
        case .openURL(let url):
            Button("Open System Settings") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                .controlSize(.small)
        }
    }

    private func download() {
        downloading = true
        downloadNote = nil
        Task {
            do {
                try await WhisperService.shared.downloadModel { p, _ in
                    DispatchQueue.main.async { downloadNote = "\(Int(p * 100))%" }
                }
                downloading = false
                downloadNote = nil
                check.run()
            } catch {
                downloading = false
                downloadNote = error.localizedDescription
            }
        }
    }
}
