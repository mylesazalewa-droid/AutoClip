import SwiftUI
import AVFoundation
import AppKit

struct VideoSkimmerView: View {
    let clip: Clip
    let project: Project
    let progress: Double          // 0..1, current playback position
    let onSeek: (Double) -> Void  // called with fraction 0..1

    @State private var hoverFraction: Double? = nil
    @State private var isDragging = false
    @State private var thumbnail: NSImage? = nil
    @State private var thumbnailFraction: Double = -1
    private let generator = ThumbnailGenerator()

    private var gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    init(clip: Clip, project: Project, progress: Double, onSeek: @escaping (Double) -> Void) {
        self.clip = clip
        self.project = project
        self.progress = progress
        self.onSeek = onSeek
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let playheadX = CGFloat(progress) * w

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 6)

                // Word tick marks
                ForEach(clip.words.indices, id: \.self) { i in
                    let w2 = clip.words[i]
                    let rel = (w2.startTime - clip.startTime) / max(clip.duration, 1)
                    let x = CGFloat(rel) * w
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 1, height: 4)
                        .offset(x: x, y: 1)
                }

                // Hover fill (ghost preview)
                if let hf = hoverFraction {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.07))
                        .frame(width: CGFloat(hf) * w, height: 6)
                }

                // Progress fill
                RoundedRectangle(cornerRadius: 3)
                    .fill(gold)
                    .frame(width: max(0, playheadX), height: 6)
                    .animation(.linear(duration: 0.05), value: progress)

                // Hover line
                if let hf = hoverFraction {
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 1, height: 18)
                        .offset(x: CGFloat(hf) * w - 0.5, y: -6)
                }

                // Playhead handle
                Circle()
                    .fill(gold)
                    .frame(width: 14, height: 14)
                    .shadow(color: Color.black.opacity(0.5), radius: 3)
                    .offset(x: playheadX - 7, y: -4)
                    .animation(isDragging ? nil : .linear(duration: 0.05), value: progress)
            }
            .frame(height: 6)
            .padding(.vertical, 10)
            .contentShape(Rectangle().size(CGSize(width: w, height: 26)))
            .overlay(
                thumbnailOverlay(geo: geo)
                , alignment: .bottom
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isDragging = true
                        let f = max(0, min(1, v.location.x / w))
                        onSeek(f)
                        hoverFraction = f
                        loadThumbnail(fraction: f)
                    }
                    .onEnded { v in
                        isDragging = false
                        let f = max(0, min(1, v.location.x / w))
                        onSeek(f)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            if !isDragging { hoverFraction = nil; thumbnail = nil }
                        }
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    let f = max(0, min(1, loc.x / w))
                    hoverFraction = f
                    loadThumbnail(fraction: f)
                case .ended:
                    if !isDragging {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if !isDragging { hoverFraction = nil; thumbnail = nil }
                        }
                    }
                }
            }
        }
        .frame(height: 26)
    }

    // MARK: - Thumbnail popup

    @ViewBuilder
    private func thumbnailOverlay(geo: GeometryProxy) -> some View {
        if let hf = hoverFraction {
            let w = geo.size.width
            let popW: CGFloat = 100
            let popH: CGFloat = 56
            let rawX = CGFloat(hf) * w - popW / 2
            let clampedX = max(0, min(w - popW, rawX))
            let time = clip.startTime + hf * clip.duration

            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black)
                        .frame(width: popW, height: popH)
                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: popW, height: popH)
                            .clipped()
                            .cornerRadius(5)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 14))
                            .foregroundColor(Color.white.opacity(0.2))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )

                Text(formatTimestamp(time))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(4)
            }
            .offset(x: clampedX - (w / 2 - popW / 2), y: -72)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.1), value: hoverFraction)
        }
    }

    // MARK: - Frame generation

    private func loadThumbnail(fraction: Double) {
        let snapFraction = (fraction * 20).rounded() / 20  // snap to 5% intervals
        guard abs(snapFraction - thumbnailFraction) > 0.001 else { return }
        thumbnailFraction = snapFraction

        let targetTime = clip.startTime + snapFraction * clip.duration
        let videoURL = URL(fileURLWithPath: project.videoPath)

        Task.detached(priority: .userInitiated) {
            let img = await generator.frame(at: targetTime, videoURL: videoURL)
            await MainActor.run { self.thumbnail = img }
        }
    }

    private func formatTimestamp(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Thumbnail generator (caches per video URL)

actor ThumbnailGenerator {
    private var cache: [String: NSImage] = [:]
    private var activeURL: URL?
    private var gen: AVAssetImageGenerator?

    func frame(at time: Double, videoURL: URL) async -> NSImage? {
        let key = "\(videoURL.lastPathComponent)_\(Int(time))"
        if let cached = cache[key] { return cached }

        if activeURL != videoURL {
            activeURL = videoURL
            let asset = AVURLAsset(url: videoURL)
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 200, height: 120)
            g.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            g.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen = g
        }

        guard let g = gen else { return nil }
        let cm = CMTime(seconds: time, preferredTimescale: 600)
        guard let cgImg = try? g.copyCGImage(at: cm, actualTime: nil) else { return nil }
        let img = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
        cache[key] = img
        return img
    }
}
