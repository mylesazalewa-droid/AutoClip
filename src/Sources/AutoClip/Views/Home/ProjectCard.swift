import SwiftUI

struct ProjectCard: View {
    let project: Project
    @State private var isHovered = false
    @ObservedObject private var appState = AppState.shared

    private var isProcessing: Bool {
        appState.isAnalyzing && appState.selectedProject?.id == project.id
    }

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack(alignment: .bottomLeading) {
                if let thumbnail = project.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 160)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 160)
                        .overlay(
                            Image(systemName: "film")
                                .font(.system(size: 32))
                                .foregroundColor(Color.white.opacity(0.15))
                        )
                }

                // Processing progress overlay
                if isProcessing {
                    VStack(spacing: 0) {
                        Spacer()
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 10))
                                    .foregroundColor(gold)
                                Text(appState.analyzeStatus)
                                    .font(.system(size: 10))
                                    .foregroundColor(Color.white.opacity(0.7))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Int(appState.analyzeProgress * 100))%")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(gold)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.15))
                                        .frame(height: 3)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(gold)
                                        .frame(width: geo.size.width * appState.analyzeProgress, height: 3)
                                        .animation(.easeOut(duration: 0.3), value: appState.analyzeProgress)
                                }
                            }
                            .frame(height: 3)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75))
                    }
                }

                // Hover action buttons
                if isHovered && !isProcessing {
                    VStack {
                        HStack(spacing: 6) {
                            Spacer()
                            Button(action: { AppState.shared.reanalyzeProject(project) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Reanalyze")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.65))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)

                            Button(action: { LibraryService.shared.deleteProject(project) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Delete")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.35))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.65))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        Spacer()
                    }
                }
            }
            .frame(height: 160)
            .cornerRadius(8, corners: [.topLeft, .topRight])

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(project.formattedDuration)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))
                    Circle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 2.5, height: 2.5)
                    Text("\(project.clipCount) clips")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))
                    Spacer()
                    Text(project.relativeDate)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.13, green: 0.15, blue: 0.20))
        }
        .background(Color(red: 0.13, green: 0.15, blue: 0.20))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        var topLeft: CGFloat = 0
        var topRight: CGFloat = 0
        var bottomLeft: CGFloat = 0
        var bottomRight: CGFloat = 0
        if corners.contains(.topLeft) { topLeft = radius }
        if corners.contains(.topRight) { topRight = radius }
        if corners.contains(.bottomLeft) { bottomLeft = radius }
        if corners.contains(.bottomRight) { bottomRight = radius }

        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: topLeft, y: 0))
        path.addLine(to: CGPoint(x: w - topRight, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: topRight), control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h - bottomRight))
        path.addQuadCurve(to: CGPoint(x: w - bottomRight, y: h), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: bottomLeft, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - bottomLeft), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: topLeft))
        path.addQuadCurve(to: CGPoint(x: topLeft, y: 0), control: CGPoint(x: 0, y: 0))
        return path
    }
}

struct UIRectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = UIRectCorner(rawValue: 1 << 0)
    static let topRight = UIRectCorner(rawValue: 1 << 1)
    static let bottomLeft = UIRectCorner(rawValue: 1 << 2)
    static let bottomRight = UIRectCorner(rawValue: 1 << 3)
    static let allCorners: UIRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}
