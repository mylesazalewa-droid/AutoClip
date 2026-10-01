import SwiftUI

struct ClipListRow: View {
    let clip: Clip
    let project: Project
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ZStack {
                if let thumb = clip.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(red: 0.12, green: 0.14, blue: 0.20)
                    Image(systemName: "film")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.2))
                }
            }
            .frame(width: 56, height: 64)
            .cornerRadius(6)
            .clipped()

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(clip.formattedDuration)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))
                    Text(clip.formattedStartTime)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))

                    if !clip.tags.isEmpty, let tag = clip.tags.first {
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(red: 1.0, green: 0.5, blue: 0.1))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 1.0, green: 0.5, blue: 0.1).opacity(0.15))
                            .cornerRadius(4)
                    }
                }

                StarRatingView(rating: clip.starRating, interactive: false)
            }

            Spacer()

            // Excerpt
            Text(clip.transcriptText)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.4))
                .lineLimit(2)
                .frame(maxWidth: 220, alignment: .leading)

            // Score + heart
            ScoreBadge(score: clip.score, size: 32)

            Image(systemName: clip.isLiked ? "heart.fill" : "heart")
                .font(.system(size: 12))
                .foregroundColor(clip.isLiked ? Color(red: 1, green: 0.3, blue: 0.4) : Color.white.opacity(0.3))
                .onTapGesture {
                    var updated = clip
                    updated.isLiked.toggle()
                    LibraryService.shared.updateClip(updated, in: project)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color(red: 0.18, green: 0.20, blue: 0.28) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}
