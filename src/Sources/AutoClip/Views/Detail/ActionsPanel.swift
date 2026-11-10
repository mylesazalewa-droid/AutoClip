import SwiftUI
import AppKit

struct ActionsPanel: View {
    @Binding var clip: Clip
    let project: Project

    @State private var showExportOptions = false
    @State private var showExportSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title and score
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title)
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text("\(Int(clip.score))")
                        .font(.ui(size: 26, weight: .heavy))
                        .foregroundColor(clip.scoreColor)
                    Text("/ 100")
                        .font(.ui(size: 14))
                        .foregroundColor(Theme.ink.opacity(0.55))
                }

                if !clip.scoreReason.isEmpty {
                    Text(clip.scoreReason)
                        .font(.ui(size: 13))
                        .foregroundColor(Theme.ink.opacity(0.55))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider().background(Theme.ink.opacity(0.08)).padding(.horizontal, 16)

            // Actions section
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTIONS")
                    .font(.ui(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.ink.opacity(0.55))

                // Export button
                Button(action: { showExportOptions = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.to.line.compact")
                            .font(.ui(size: 14, weight: .semibold))
                        Text("Export")
                            .font(.ui(size: 15, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.ui(size: 12))
                    }
                    .foregroundColor(Theme.onSand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.sand)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showExportOptions) {
                    ExportOptionsView(clip: $clip, project: project)
                }

                if showExportSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.good)
                        Text("Exported successfully!")
                            .font(.ui(size: 13))
                            .foregroundColor(Theme.good)
                    }
                }

                // Share
                Button(action: shareClip) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.ui(size: 13))
                        Text("Share Clip")
                            .font(.ui(size: 13))
                    }
                    .foregroundColor(Theme.ink.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.ink.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Copy transcript
                Button(action: copyTranscript) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .font(.ui(size: 13))
                        Text("Copy Transcript")
                            .font(.ui(size: 13))
                    }
                    .foregroundColor(Theme.ink.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.ink.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Rating
                VStack(alignment: .leading, spacing: 6) {
                    Text("RATING")
                        .font(.ui(size: 11.5, weight: .semibold))
                        .foregroundColor(Theme.ink.opacity(0.55))

                    HStack(spacing: 6) {
                        StarRatingView(rating: clip.starRating, interactive: true) { star in
                            var updated = clip
                            updated.starRating = star
                            clip = updated
                            LibraryService.shared.updateClip(updated, in: project)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    func shareClip() {
        let videoURL = URL(fileURLWithPath: project.videoPath)
        let picker = NSSharingServicePicker(items: [videoURL])
        if let window = NSApp.keyWindow {
            picker.show(relativeTo: .zero, of: window.contentView!, preferredEdge: .minY)
        }
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip.transcriptText, forType: .string)
    }
}
