import SwiftUI
import AVFoundation

enum DetailTab: String, CaseIterable {
    case actions = "Actions"
    case captions = "Captions"
    case transcript = "Transcript"

    var icon: String {
        switch self {
        case .actions: return "bolt.fill"
        case .captions: return "textformat.abc"
        case .transcript: return "text.quote"
        }
    }
}

struct ClipDetailPanel: View {
    @Binding var clip: Clip
    let project: Project

    @StateObject private var playerVM = ClipPlayerViewModel()
    @State private var selectedTab: DetailTab = .transcript
    @State private var captionBgEnabled = true
    @State private var captionBgOpacity: Double = 0.55
    @State private var captionBgColor: NSColor = .black

    var body: some View {
        VStack(spacing: 0) {
            // Video preview
            videoPreview

            // Trim controls
            trimPanel

            Divider().background(Color.white.opacity(0.08))

            // Tab bar
            tabBar

            // Tab content
            tabContent
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.14))
        .onChange(of: clip.id) { _, _ in
            playerVM.loadClip(clip, project: project)
        }
        .onAppear {
            playerVM.loadClip(clip, project: project)
        }
    }

    var videoPreview: some View {
        ZStack {
            Color.black

            VideoPlayerView(
                player: playerVM.player,
                captionStyle: CaptionStyle.named(clip.captionStyleName),
                currentWord: playerVM.currentWord,
                showCaptionBg: captionBgEnabled,
                captionBgOpacity: captionBgOpacity,
                captionBgColor: captionBgColor
            )

            // Caption overlay
            VStack {
                Spacer()
                if let word = playerVM.currentWord {
                    captionOverlay(word: word.word)
                        .padding(.bottom, 20)
                } else {
                    captionOverlay(word: clip.words.first?.word ?? "")
                        .opacity(0.3)
                        .padding(.bottom, 20)
                }
            }
        }
        .frame(height: 180)
    }

    @ViewBuilder
    func captionOverlay(word: String) -> some View {
        let style = CaptionStyle.named(clip.captionStyleName)
        ZStack {
            if captionBgEnabled {
                Text(word)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundColor(.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: captionBgColor).opacity(captionBgOpacity))
                    .cornerRadius(4)
            }
            Text(word)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(style.textColor)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    var trimPanel: some View {
        VStack(spacing: 0) {
            // Skimmer / scrubber
            VideoSkimmerView(
                clip: clip,
                project: project,
                progress: playerVM.currentTime.seconds / max(clip.duration, 1),
                onSeek: { fraction in playerVM.seekToFraction(fraction, duration: clip.duration) }
            )
            .frame(height: 26)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Player controls
            HStack(spacing: 12) {
                Button(action: { playerVM.seek(by: -5) }) {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.7))
                }
                .buttonStyle(.plain)

                Button(action: { playerVM.togglePlay() }) {
                    Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.0))
                }
                .buttonStyle(.plain)

                Button(action: { playerVM.seek(by: 5) }) {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 14))
                        .foregroundColor(Color.white.opacity(0.7))
                }
                .buttonStyle(.plain)

                Text(formatTime(playerVM.currentTime.seconds) + " / " + formatTime(clip.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.6))

                Spacer()

                Button(action: { playerVM.seekToStart() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // TRIM section
            VStack(alignment: .leading, spacing: 4) {
                Text("TRIM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.3))
                    .padding(.horizontal, 14)

                HStack(spacing: 8) {
                    Text("Start")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.6))
                        .frame(width: 36, alignment: .leading)

                    adjustButton(label: "-5s") { adjustTrim(start: true, by: -5) }
                    adjustButton(label: "-1s") { adjustTrim(start: true, by: -1) }

                    Text(clip.formattedStartTime)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 50)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)

                    adjustButton(label: "+1s") { adjustTrim(start: true, by: 1) }
                    adjustButton(label: "+5s") { adjustTrim(start: true, by: 5) }
                }
                .padding(.horizontal, 14)

                HStack(spacing: 8) {
                    Text("End")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.6))
                        .frame(width: 36, alignment: .leading)

                    adjustButton(label: "-5s") { adjustTrim(start: false, by: -5) }
                    adjustButton(label: "-1s") { adjustTrim(start: false, by: -1) }

                    let endSeconds = clip.startTime + clip.duration
                    Text(formatSeconds(endSeconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 50)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)

                    adjustButton(label: "+1s") { adjustTrim(start: false, by: 1) }
                    adjustButton(label: "+5s") { adjustTrim(start: false, by: 5) }
                }
                .padding(.horizontal, 14)

                HStack {
                    Spacer()
                    Text("Duration: \(clip.formattedDuration)")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.4))
                        .padding(.trailing, 14)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    func adjustButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    var waveformView: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(0..<48, id: \.self) { i in
                    let pattern: [CGFloat] = [5, 10, 18, 30, 24, 15, 8, 20, 35, 28, 12, 22, 38, 30, 16, 10]
                    let h = pattern[i % pattern.count]
                    let isActive = Double(i) / 48.0 < (playerVM.currentTime.seconds / max(clip.duration, 1))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isActive ? Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.8) : Color.white.opacity(0.2))
                        .frame(width: 2, height: h)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let fraction = max(0, min(1, drag.location.x / geo.size.width))
                playerVM.seekToFraction(fraction, duration: clip.duration)
            })
        }
    }

    var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundColor(selectedTab == tab ? .white : Color.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(selectedTab == tab ? Color.white.opacity(0.1) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    var tabContent: some View {
        ScrollView {
            switch selectedTab {
            case .actions:
                ActionsPanel(clip: $clip, project: project)
            case .captions:
                CaptionsPanel(clip: $clip, bgEnabled: $captionBgEnabled, bgOpacity: $captionBgOpacity, bgColor: $captionBgColor)
            case .transcript:
                TranscriptPanel(clip: clip, seekAction: { t in playerVM.seekToTime(t) })
            }
        }
    }

    func adjustTrim(start: Bool, by seconds: Double) {
        var updated = clip
        if start {
            let newStart = max(0, clip.startTime + seconds)
            if newStart < clip.endTime - 5 {
                updated.startTime = newStart
            }
        } else {
            let newEnd = clip.endTime + seconds
            if newEnd > clip.startTime + 5 {
                updated.endTime = newEnd
            }
        }
        clip = updated
        LibraryService.shared.updateClip(updated, in: project)
    }

    func formatTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }

    func formatSeconds(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }
}
