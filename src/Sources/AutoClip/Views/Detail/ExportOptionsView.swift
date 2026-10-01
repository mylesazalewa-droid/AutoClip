import SwiftUI
import AppKit

struct ExportOptionsView: View {
    @Binding var clip: Clip
    let project: Project
    @Environment(\.dismiss) var dismiss

    @State private var format: VideoExportService.ExportFormat = .original
    @State private var burnCaptions = false
    @State private var selectedStyleName: String = "Karaoke"
    @State private var captionBgEnabled = true
    @State private var captionBgOpacity: Double = 0.55
    @State private var captionBgColor: NSColor = .black

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportStatus = ""
    @State private var exportDone = false
    @State private var exportError: String?

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    var selectedStyle: CaptionStyle {
        CaptionStyle.named(selectedStyleName)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Export Clip")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // FORMAT
                    section(title: "FORMAT") {
                        VStack(spacing: 8) {
                            ForEach(VideoExportService.ExportFormat.allCases, id: \.self) { fmt in
                                formatRow(fmt)
                            }
                        }
                    }

                    // CAPTIONS
                    section(title: "CAPTIONS") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $burnCaptions) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Burn Captions Into Video")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white)
                                    Text("Captions are permanently embedded in the exported file")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.white.opacity(0.4))
                                }
                            }
                            .toggleStyle(SwitchToggleStyle(tint: gold))

                            if burnCaptions {
                                VStack(alignment: .leading, spacing: 10) {
                                    // Style picker
                                    Text("Caption Style")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color.white.opacity(0.4))

                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                                        ForEach(CaptionStyle.all) { style in
                                            styleChip(style)
                                        }
                                    }

                                    // Background toggle
                                    Toggle(isOn: $captionBgEnabled) {
                                        Text("Caption Background")
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.white.opacity(0.7))
                                    }
                                    .toggleStyle(CheckboxToggleStyle())

                                    if captionBgEnabled {
                                        HStack(spacing: 12) {
                                            Text("Opacity")
                                                .font(.system(size: 12))
                                                .foregroundColor(Color.white.opacity(0.5))
                                                .frame(width: 52, alignment: .leading)
                                            Slider(value: $captionBgOpacity, in: 0...1)
                                                .accentColor(gold)
                                            Text("\(Int(captionBgOpacity * 100))%")
                                                .font(.system(size: 11))
                                                .foregroundColor(Color.white.opacity(0.4))
                                                .frame(width: 30)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    // CLIP INFO
                    section(title: "CLIP INFO") {
                        HStack(spacing: 16) {
                            infoItem(label: "Duration", value: clip.formattedDuration)
                            infoItem(label: "Score", value: "\(Int(clip.score))/100")
                            infoItem(label: "Words", value: "\(clip.words.filter { !$0.word.hasPrefix("<|") }.count)")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider().background(Color.white.opacity(0.08))

            // Export button / progress
            VStack(spacing: 10) {
                if isExporting {
                    VStack(spacing: 6) {
                        ProgressView(value: exportProgress)
                            .accentColor(gold)
                        Text(exportStatus)
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                } else if exportDone {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.4))
                        Text("Exported successfully!")
                            .font(.system(size: 13))
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.4))
                    }
                } else {
                    if let err = exportError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
                            .multilineTextAlignment(.center)
                    }

                    Button(action: startExport) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.to.line.compact")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Export \(format.rawValue)")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(gold)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420, height: 580)
        .background(Color(red: 0.09, green: 0.10, blue: 0.15))
        .onAppear {
            selectedStyleName = clip.captionStyleName
        }
    }

    // MARK: - Subviews

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.3))
                .tracking(1)
            content()
        }
    }

    private func formatRow(_ fmt: VideoExportService.ExportFormat) -> some View {
        let selected = format == fmt
        return Button(action: { format = fmt }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? gold.opacity(0.15) : Color.white.opacity(0.05))
                        .frame(width: 36, height: 36)
                    Image(systemName: fmt.icon)
                        .font(.system(size: 16))
                        .foregroundColor(selected ? gold : Color.white.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(fmt.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(selected ? .white : Color.white.opacity(0.7))
                    Text(fmt.description)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.35))
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(gold)
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? gold.opacity(0.07) : Color.white.opacity(0.04))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? gold.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func styleChip(_ style: CaptionStyle) -> some View {
        let selected = selectedStyleName == style.name
        return Button(action: { selectedStyleName = style.name }) {
            Text(style.name)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .black : Color.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(selected ? gold : Color.white.opacity(0.08))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func infoItem(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }

    // MARK: - Export

    private func startExport() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.nameFieldStringValue = clip.title.replacingOccurrences(of: "/", with: "-") + ".mp4"
        savePanel.message = "Export clip"
        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }

        isExporting = true
        exportProgress = 0
        exportError = nil
        exportStatus = "Preparing…"

        let options = VideoExportService.ExportOptions(
            format: format,
            burnCaptions: burnCaptions,
            captionStyle: selectedStyle,
            captionBgEnabled: captionBgEnabled,
            captionBgOpacity: captionBgOpacity,
            captionBgColor: captionBgColor
        )

        Task {
            do {
                if format == .vertical9x16 {
                    await MainActor.run { exportStatus = "Detecting faces…" }
                }
                if burnCaptions {
                    await MainActor.run { exportStatus = "Rendering captions…" }
                }

                try await VideoExportService.shared.exportClip(
                    clip, from: project, options: options, outputURL: outputURL
                ) { p in
                    DispatchQueue.main.async {
                        self.exportProgress = p
                        self.exportStatus = p < 0.95 ? "Encoding: \(Int(p * 100))%" : "Finalizing…"
                    }
                }

                let record = ExportRecord(
                    clipId: clip.id, projectId: project.id,
                    clipTitle: clip.title, exportDate: Date(),
                    format: "\(format.rawValue)\(burnCaptions ? " + Captions" : "")"
                )
                LibraryService.shared.addExportRecord(record)

                await MainActor.run {
                    isExporting = false
                    exportDone = true
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}
