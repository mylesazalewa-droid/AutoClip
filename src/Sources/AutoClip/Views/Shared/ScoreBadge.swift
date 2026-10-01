import SwiftUI

struct ScoreBadge: View {
    let score: Double
    var size: CGFloat = 44

    var color: Color {
        switch score {
        case 90...100: return Color(red: 0.18, green: 0.82, blue: 0.42)
        case 75..<90:  return Color(red: 0.55, green: 0.85, blue: 0.25)
        case 60..<75:  return Color(red: 1.0, green: 0.7, blue: 0.0)
        default:       return Color(red: 1.0, green: 0.4, blue: 0.2)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 2)
                .frame(width: size, height: size)

            Circle()
                .trim(from: 0, to: score / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))

            Text("\(Int(score))")
                .font(.system(size: size * 0.33, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
    }
}

struct TagBadge: View {
    let text: String
    var color: Color = Color(red: 1.0, green: 0.5, blue: 0.1)

    var body: some View {
        HStack(spacing: 3) {
            Text("🔥")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15))
        .cornerRadius(4)
    }
}

struct StarRatingView: View {
    let rating: Int
    let interactive: Bool
    var onRate: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundColor(star <= rating ? Color(red: 1, green: 0.8, blue: 0) : Color.white.opacity(0.3))
                    .onTapGesture {
                        if interactive { onRate?(star) }
                    }
            }
        }
    }
}
