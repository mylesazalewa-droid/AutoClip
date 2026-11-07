import SwiftUI
import AVFoundation

struct ClipCard: View {
    let clip: Clip
    let project: Project
    let isSelected: Bool
    var onToggleLike: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack(alignment: .bottom) {
                thumbnailView
                    .frame(height: 220)
                    .clipped()

                // Gradient overlay at bottom
                LinearGradient(
                    gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.85)]),
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 120)

                // Caption preview overlay
                VStack {
                    Spacer()
                    captionOverlay
                        .padding(.bottom, 4)
                }

                // Time indicators
                HStack {
                    Text(clip.formattedStartTime)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                    Spacer()
                    HStack(spacing: 2) {
                        Circle()
                            .fill(Color(red: 1, green: 0.2, blue: 0.2))
                            .frame(width: 6, height: 6)
                        Text(clip.formattedDuration)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Theme.ink)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .top)

                // Close button on hover
                if isHovered && isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "xmark")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(Theme.ink)
                                .padding(5)
                                .background(Color.black.opacity(0.7))
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }

            // Waveform bars
            waveformBars
                .frame(height: 24)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

            // Transcript excerpt
            Text(clip.transcriptText)
                .font(.system(size: 12))
                .foregroundColor(Theme.ink.opacity(0.6))
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .frame(height: 32, alignment: .top)

            Divider()
                .background(Theme.ink.opacity(0.06))

            // Bottom: score + stars + heart
            HStack(spacing: 8) {
                ScoreBadge(score: clip.score, size: 36)

                StarRatingView(rating: clip.starRating, interactive: false)

                Spacer()

                Image(systemName: clip.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 13))
                    .foregroundColor(clip.isLiked ? Theme.danger : Theme.ink.opacity(0.35))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleLike()
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Title
            Text(clip.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.ink.opacity(0.8))
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .frame(height: 32)
        }
        .background(
            isSelected
                ? Theme.raised2
                : Color(red: 0.12, green: 0.14, blue: 0.19)
        )
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Theme.sand.opacity(0.6) : Theme.ink.opacity(0.07),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    var thumbnailView: some View {
        if let thumb = clip.thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Theme.raised)
                .overlay(
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.ink.opacity(0.55))
                )
        }
    }

    var captionOverlay: some View {
        let words = clip.words.prefix(6)
        let preview = words.map(\.word).joined(separator: " ")
        return Text(preview.isEmpty ? "" : preview)
            .font(.system(size: 13, weight: .heavy))
            .foregroundColor(Theme.ink)
            .shadow(color: .black, radius: 2, x: 0, y: 1)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
    }

    var waveformBars: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<24, id: \.self) { i in
                let h = waveformHeight(for: i)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.ink.opacity(0.25))
                    .frame(width: 2.5, height: h)
            }
        }
        .frame(maxWidth: .infinity)
    }

    func waveformHeight(for index: Int) -> CGFloat {
        let pattern: [CGFloat] = [4, 8, 12, 16, 20, 14, 10, 18, 22, 16, 8, 14, 20, 12, 6, 16, 22, 18, 10, 14, 8, 20, 12, 6]
        return pattern[index % pattern.count]
    }

    func toggleLike() {
        if let onToggleLike { onToggleLike(); return }
        var updated = clip
        updated.isLiked.toggle()
        LibraryService.shared.updateClip(updated, in: project)
    }
}
