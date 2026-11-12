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

            Divider().background(Theme.ink.opacity(0.08))

            // Tab bar
            tabBar

            // Tab content
            tabContent
        }
        .background(Theme.surface)
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
                    .font(.ui(size: 18, weight: .heavy))
                    .foregroundColor(.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: captionBgColor).opacity(captionBgOpacity))
                    .cornerRadius(4)
            }
            Text(word)
                .font(.ui(size: 18, weight: .heavy))
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
                        .font(.ui(size: 14))
                        .foregroundColor(Theme.ink.opacity(0.7))
                }
                .buttonStyle(.plain)

                Button(action: { playerVM.togglePlay() }) {
                    Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.ui(size: 28))
                        .foregroundColor(Theme.sand)
                }
                .buttonStyle(.plain)

                Button(action: { playerVM.seek(by: 5) }) {
                    Image(systemName: "goforward.5")
                        .font(.ui(size: 14))
                        .foregroundColor(Theme.ink.opacity(0.7))
                }
                .buttonStyle(.plain)

                Text(formatTime(playerVM.currentTime.seconds) + " / " + formatTime(clip.duration))
                    .font(.ui(size: 12, design: .monospaced))
                    .foregroundColor(Theme.ink.opacity(0.6))

                Spacer()

                Button(action: { playerVM.seekToStart() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.ui(size: 13))
                        .foregroundColor(Theme.ink.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // TRIM section
            VStack(alignment: .leading, spacing: 4) {
                Text("TRIM")
                    .font(.ui(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.ink.opacity(0.55))
                    .padding(.horizontal, 14)

                TrimRangeBar(clip: $clip, project: project)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                HStack(spacing: 8) {
                    Text("Start")
                        .font(.ui(size: 13))
                        .foregroundColor(Theme.ink.opacity(0.6))
                        .frame(width: 36, alignment: .leading)

                    adjustButton(label: "-5s") { adjustTrim(start: true, by: -5) }
                    adjustButton(label: "-1s") { adjustTrim(start: true, by: -1) }

                    Text(clip.formattedStartTime)
                        .font(.ui(size: 13, design: .monospaced))
                        .foregroundColor(Theme.ink)
                        .frame(width: 50)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Theme.ink.opacity(0.1))
                        .cornerRadius(4)

                    adjustButton(label: "+1s") { adjustTrim(start: true, by: 1) }
                    adjustButton(label: "+5s") { adjustTrim(start: true, by: 5) }
                }
                .padding(.horizontal, 14)

                HStack(spacing: 8) {
                    Text("End")
                        .font(.ui(size: 13))
                        .foregroundColor(Theme.ink.opacity(0.6))
                        .frame(width: 36, alignment: .leading)

                    adjustButton(label: "-5s") { adjustTrim(start: false, by: -5) }
                    adjustButton(label: "-1s") { adjustTrim(start: false, by: -1) }

                    let endSeconds = clip.startTime + clip.duration
                    Text(formatSeconds(endSeconds))
                        .font(.ui(size: 13, design: .monospaced))
                        .foregroundColor(Theme.ink)
                        .frame(width: 50)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Theme.ink.opacity(0.1))
                        .cornerRadius(4)

                    adjustButton(label: "+1s") { adjustTrim(start: false, by: 1) }
                    adjustButton(label: "+5s") { adjustTrim(start: false, by: 5) }
                }
                .padding(.horizontal, 14)

                HStack {
                    Spacer()
                    Text("Duration: \(clip.formattedDuration)")
                        .font(.ui(size: 12))
                        .foregroundColor(Theme.ink.opacity(0.55))
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
                .font(.ui(size: 12))
                .foregroundColor(Theme.ink.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Theme.ink.opacity(0.08))
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
                        .fill(isActive ? Theme.sand.opacity(0.8) : Theme.ink.opacity(0.2))
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
                            .font(.ui(size: 12))
                        Text(tab.rawValue)
                            .font(.ui(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundColor(selectedTab == tab ? .white : Theme.ink.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(selectedTab == tab ? Theme.ink.opacity(0.1) : Color.clear)
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

// MARK: - Drag trim bar

private struct TrimRangeBar: View {
    @Binding var clip: Clip
    let project: Project

    @State private var activeHandle: Handle? = nil
    @State private var dragCtxStart: Double = 0
    @State private var dragCtxEnd: Double = 0

    private enum Handle { case start, end }

    // Natural extent of the clip (word boundaries ± small buffer)
    private var naturalStart: Double { (clip.words.first?.startTime ?? clip.startTime) }
    private var naturalEnd: Double   { (clip.words.last?.endTime   ?? clip.endTime) }

    // The visible range covers both the current trim points and the word extent
    private var rangeStart: Double { min(clip.startTime, naturalStart) - 2 }
    private var rangeEnd:   Double { max(clip.endTime,   naturalEnd)   + 2 }
    private var rangeLen:   Double { max(1, rangeEnd - rangeStart) }

    // The range that was locked in at drag start (stays fixed while dragging)
    private var effectiveStart: Double { activeHandle != nil ? dragCtxStart : rangeStart }
    private var effectiveEnd:   Double { activeHandle != nil ? dragCtxEnd   : rangeEnd   }
    private var effectiveLen:   Double { max(1, effectiveEnd - effectiveStart) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let inX  = CGFloat((clip.startTime - effectiveStart) / effectiveLen) * w
            let outX = CGFloat((clip.endTime   - effectiveStart) / effectiveLen) * w

            ZStack(alignment: .topLeading) {
                // Anchor the ZStack to the right size
                Color.clear.frame(width: w, height: 20)

                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.ink.opacity(0.08))
                    .frame(width: w, height: 6)
                    .offset(y: 7)

                // Dimmed left region
                if inX > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                        .frame(width: inX, height: 6)
                        .offset(y: 7)
                }

                // Dimmed right region
                if outX < w {
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                        .frame(width: w - outX, height: 6)
                        .offset(x: outX, y: 7)
                }

                // Selected clip region
                if outX > inX {
                    Rectangle()
                        .fill(Theme.sand.opacity(0.35))
                        .frame(width: outX - inX, height: 6)
                        .offset(x: inX, y: 7)
                }

                // IN bracket handle
                trimHandle(highlighted: activeHandle == .start)
                    .offset(x: max(0, inX - 1.5))

                // OUT bracket handle
                trimHandle(highlighted: activeHandle == .end)
                    .offset(x: max(0, min(w - 3, outX - 1.5)))
            }
            .contentShape(Rectangle().size(CGSize(width: w, height: 20)))
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        let x = max(0, min(w, v.location.x))
                        if activeHandle == nil {
                            dragCtxStart = rangeStart
                            dragCtxEnd   = rangeEnd
                            activeHandle = abs(x - inX) <= abs(x - outX) ? .start : .end
                        }
                        let t = effectiveStart + Double(x / w) * effectiveLen
                        var u = clip
                        switch activeHandle {
                        case .start: u.startTime = max(effectiveStart + 1, min(u.endTime - 2, t))
                        case .end:   u.endTime   = max(u.startTime + 2, min(effectiveEnd - 1, t))
                        case nil: break
                        }
                        clip = u
                        LibraryService.shared.updateClip(u, in: project)
                    }
                    .onEnded { _ in activeHandle = nil }
            )
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private func trimHandle(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(highlighted ? Theme.sand : Theme.sand.opacity(0.75))
            .frame(width: 3, height: 20)
    }
}
