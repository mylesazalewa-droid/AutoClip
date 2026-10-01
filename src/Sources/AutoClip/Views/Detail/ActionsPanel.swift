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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text("\(Int(clip.score))")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundColor(clip.scoreColor)
                    Text("/ 100")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.4))
                }

                if !clip.scoreReason.isEmpty {
                    Text(clip.scoreReason)
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 16)

            // Actions section
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.3))

                // Export button
                Button(action: { showExportOptions = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.to.line.compact")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Export")
                            .font(.system(size: 15, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color(red: 1.0, green: 0.75, blue: 0.0))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showExportOptions) {
                    ExportOptionsView(clip: $clip, project: project)
                }

                if showExportSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.4))
                        Text("Exported successfully!")
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.4))
                    }
                }

                // Share
                Button(action: shareClip) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13))
                        Text("Share Clip")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Copy transcript
                Button(action: copyTranscript) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                        Text("Copy Transcript")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Rating
                VStack(alignment: .leading, spacing: 6) {
                    Text("RATING")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.3))

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
