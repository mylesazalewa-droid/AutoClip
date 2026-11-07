import SwiftUI

struct ClipListRow: View {
    let clip: Clip
    let project: Project
    let isSelected: Bool
    var onToggleLike: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ZStack {
                if let thumb = clip.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.raised
                    Image(systemName: "film")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.ink.opacity(0.55))
                }
            }
            .frame(width: 56, height: 64)
            .cornerRadius(6)
            .clipped()

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(clip.formattedDuration)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.ink.opacity(0.55))
                    Text(clip.formattedStartTime)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.ink.opacity(0.55))

                    if !clip.tags.isEmpty, let tag = clip.tags.first {
                        Text(tag)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Theme.warn)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.warn.opacity(0.15))
                            .cornerRadius(4)
                    }
                }

                StarRatingView(rating: clip.starRating, interactive: false)
            }

            Spacer()

            // Excerpt
            Text(clip.transcriptText)
                .font(.system(size: 12))
                .foregroundColor(Theme.ink.opacity(0.55))
                .lineLimit(2)
                .frame(maxWidth: 220, alignment: .leading)

            // Score + heart
            ScoreBadge(score: clip.score, size: 32)

            Image(systemName: clip.isLiked ? "heart.fill" : "heart")
                .font(.system(size: 13))
                .foregroundColor(clip.isLiked ? Theme.danger : Theme.ink.opacity(0.3))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let onToggleLike { onToggleLike(); return }
                    var updated = clip
                    updated.isLiked.toggle()
                    LibraryService.shared.updateClip(updated, in: project)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Theme.raised2 : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Theme.sand.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}
