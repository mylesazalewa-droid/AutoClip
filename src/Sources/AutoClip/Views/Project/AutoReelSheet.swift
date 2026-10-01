import SwiftUI
import AppKit
import AVFoundation

struct AutoReelSheet: View {
    let project: Project
    @Binding var isPresented: Bool

    @State private var targetDuration: Double = 90
    @State private var hookClip: Clip? = nil
    @State private var restClips: [Clip] = []

    // Export options
    @State private var selectedFormat: VideoExportService.ExportFormat = .vertical9x16
    @State private var burnCaptions: Bool = true
    @State private var captionStyleIndex: Int = 0

    private var selectedClips: [Clip] {
        guard let hook = hookClip else { return [] }
        return [hook] + restClips
    }

    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportStatus = ""
    @State private var exportDone = false
    @State private var exportError: String?
    @State private var outputURL: URL?

    @State private var transcriptSegments: [Clip] = []
    @State private var isLoadingSegments = true
    @State private var reelPlayer: AVPlayer?
    @State private var reelIsPlaying = false

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)
    private let svc = VideoExportService.shared
    private let captionStyles = CaptionStyle.all

    // All transcript words reconstructed from clips
    private var allWords: [Word] {
        project.clips.flatMap { $0.words }.sorted { $0.startTime < $1.startTime }
    }

    private var totalSelectedDuration: Double {
        selectedClips.reduce(0) { $0 + ($1.endTime - $1.startTime) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Reel")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text("Hook-first · word-trimmed · best moments stitched together")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(Color(red: 0.09, green: 0.10, blue: 0.15))

            Divider().background(Color.white.opacity(0.08))

            if exportDone, let url = outputURL {
                exportSuccessView(url: url)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        // Config sliders
                        configSection

                        // Selected clips preview
                        if isLoadingSegments {
                            loadingState
                        } else if !selectedClips.isEmpty {
                            clipsPreviewSection
                        } else {
                            emptyState
                        }
                    }
                    .padding(20)
                }

                Divider().background(Color.white.opacity(0.08))

                // Footer actions
                footerBar
            }
        }
        .frame(width: 520)
        .background(Color(red: 0.11, green: 0.12, blue: 0.17))
        .onAppear { buildTranscriptSegments() }
        .onChange(of: targetDuration) { _, _ in if !isLoadingSegments { refreshSelection() } }
    }

    // MARK: - Subviews

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.4))
                .textCase(.uppercase)

            VStack(spacing: 12) {
                sliderRow(label: "Target length", value: $targetDuration,
                          range: 30...300, display: formatDuration(targetDuration))
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)

            // Format picker
            VStack(alignment: .leading, spacing: 10) {
                Text("Format")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.4))
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    ForEach(VideoExportService.ExportFormat.allCases, id: \.self) { fmt in
                        formatButton(fmt)
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)

            // Captions
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Captions")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.4))
                        .textCase(.uppercase)
                    Spacer()
                    Toggle("", isOn: $burnCaptions)
                        .toggleStyle(.switch)
                        .scaleEffect(0.75)
                        .labelsHidden()
                }

                if burnCaptions {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(captionStyles.enumerated()), id: \.element.id) { i, style in
                                Button(action: { captionStyleIndex = i }) {
                                    Text(style.name)
                                        .font(.system(size: 11, weight: captionStyleIndex == i ? .semibold : .regular))
                                        .foregroundColor(captionStyleIndex == i ? .black : Color.white.opacity(0.6))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(captionStyleIndex == i ? gold : Color.white.opacity(0.08))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)
            .animation(.easeInOut(duration: 0.15), value: burnCaptions)
        }
    }

    private func formatButton(_ fmt: VideoExportService.ExportFormat) -> some View {
        let active = selectedFormat == fmt
        return Button(action: { selectedFormat = fmt }) {
            VStack(spacing: 4) {
                Image(systemName: fmt.icon)
                    .font(.system(size: 14))
                    .foregroundColor(active ? .black : Color.white.opacity(0.5))
                Text(fmt.rawValue)
                    .font(.system(size: 9, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? .black : Color.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(active ? gold : Color.white.opacity(0.06))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 1)
                .accentColor(gold)
            Text(display)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(gold)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var clipsPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Best moments")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.4))
                        .textCase(.uppercase)
                    Text("From \(transcriptSegments.count) transcript segments")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.25))
                }
                Spacer()
                HStack(spacing: 8) {
                    Label("\(selectedClips.count) clips", systemImage: "scissors")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))
                    Text("·")
                        .foregroundColor(Color.white.opacity(0.3))
                    Label(formatDuration(totalSelectedDuration), systemImage: "clock")
                        .font(.system(size: 11))
                        .foregroundColor(gold)
                }
            }

            VStack(spacing: 2) {
                ForEach(Array(selectedClips.enumerated()), id: \.element.id) { index, clip in
                    clipRow(index: index, clip: clip, isHook: index == 0)
                }
            }
        }
    }

    private func clipRow(index: Int, clip: Clip, isHook: Bool) -> some View {
        HStack(spacing: 10) {
            if isHook {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(gold.opacity(0.2))
                    Text("HOOK")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(gold)
                }
                .frame(width: 34, height: 16)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(width: 34, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title)
                    .font(.system(size: 12, weight: isHook ? .semibold : .medium))
                    .foregroundColor(isHook ? gold : .white)
                    .lineLimit(1)
                Text(formatTimeRange(clip.startTime, clip.endTime))
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.4))
            }
            Spacer()
            Text(formatDuration(clip.endTime - clip.startTime))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.4))
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(scoreColor(clip.score).opacity(0.15))
                Text("\(Int(clip.score))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(scoreColor(clip.score))
            }
            .frame(width: 30, height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHook ? gold.opacity(0.05) : (index % 2 == 0 ? Color.white.opacity(0.03) : Color.clear))
        .cornerRadius(6)
        .overlay(
            isHook ? RoundedRectangle(cornerRadius: 6).stroke(gold.opacity(0.2), lineWidth: 1) : nil
        )
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Segmenting transcript...")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 28))
                .foregroundColor(Color.white.opacity(0.2))
            Text("No clips available")
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.4))
            Text("Analyze the video first to generate clips")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private var footerBar: some View {
        VStack(spacing: 0) {
            if isExporting {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundColor(gold)
                        Text(exportStatus)
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.7))
                        Spacer()
                        Text("\(Int(exportProgress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(gold)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(gold)
                                .frame(width: geo.size.width * exportProgress, height: 4)
                                .animation(.easeOut(duration: 0.2), value: exportProgress)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(16)
                .background(Color.black.opacity(0.2))
            }

            if let err = exportError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(Color.red.opacity(0.85))
                        .lineLimit(2)
                    Spacer()
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
            }

            HStack(spacing: 10) {
                Button(action: { isPresented = false }) {
                    Text("Cancel")
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: startExport) {
                    HStack(spacing: 6) {
                        Image(systemName: isExporting ? "hourglass" : "play.fill")
                            .font(.system(size: 11))
                        Text(isExporting ? "Creating Reel..." : "Create Reel")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(selectedClips.isEmpty || isExporting ? Color.white.opacity(0.4) : .black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(selectedClips.isEmpty || isExporting ? Color.white.opacity(0.1) : gold)
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(selectedClips.isEmpty || isExporting)
            }
            .padding(16)
        }
    }

    private func exportSuccessView(url: URL) -> some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(gold)
                        .font(.system(size: 14))
                    Text("Reel Created")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("·")
                        .foregroundColor(Color.white.opacity(0.3))
                    Text("\(selectedClips.count) clips · \(formatDuration(totalSelectedDuration))")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text("Finder")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: { isPresented = false }) {
                        Text("Done")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.6))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 0.09, green: 0.10, blue: 0.14))

            Divider().background(Color.white.opacity(0.08))

            // Inline video player
            ZStack {
                Color.black

                if let player = reelPlayer {
                    VideoPlayerView(
                        player: player,
                        captionStyle: CaptionStyle.all[0],
                        currentWord: nil,
                        showCaptionBg: false,
                        captionBgOpacity: 0,
                        captionBgColor: .black
                    )
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(gold)
                }

                // Play/pause tap overlay
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let player = reelPlayer else { return }
                        if reelIsPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                        reelIsPlaying.toggle()
                    }

                // Pause indicator (shows briefly on pause)
                if !reelIsPlaying {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 8)
                }
            }
            .frame(height: 340)
            .onAppear {
                let player = AVPlayer(url: url)
                reelPlayer = player
                player.play()
                reelIsPlaying = true
                // Loop
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: player.currentItem,
                    queue: .main
                ) { _ in player.seek(to: .zero); player.play() }
            }
            .onDisappear {
                reelPlayer?.pause()
                reelPlayer = nil
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Logic

    private func refreshSelection() {
        let candidates = transcriptSegments.isEmpty ? project.clips : transcriptSegments
        let (hook, rest) = svc.selectHookAndClips(
            from: candidates,
            targetDuration: targetDuration
        )
        hookClip = hook
        restClips = rest
    }

    private func buildTranscriptSegments() {
        isLoadingSegments = true
        let words = allWords
        Task.detached(priority: .userInitiated) {
            let segs = VideoExportService.shared.autoSegmentsFromWords(words)
            await MainActor.run {
                self.transcriptSegments = segs
                self.isLoadingSegments = false
                self.refreshSelection()
            }
        }
    }

    private func startExport() {
        let panel = NSSavePanel()
        panel.title = "Save Highlight Reel"
        panel.nameFieldStringValue = "\(project.title) – Reel.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await self.runExport(to: url)
            }
        }
    }

    @MainActor
    private func runExport(to url: URL) async {
        isExporting = true
        exportError = nil
        exportProgress = 0
        exportStatus = "Preparing..."

        let videoURL = URL(fileURLWithPath: project.videoPath)
        let clips = selectedClips

        var opts = VideoExportService.ExportOptions()
        opts.format = selectedFormat
        opts.burnCaptions = burnCaptions && !captionStyles.isEmpty
        if burnCaptions && captionStyleIndex < captionStyles.count {
            opts.captionStyle = captionStyles[captionStyleIndex]
        }

        do {
            try await svc.createHighlightReel(
                clips: clips,
                sourceVideoURL: videoURL,
                outputURL: url,
                options: opts,
                progress: { p, msg in
                    self.exportProgress = p
                    self.exportStatus = msg
                }
            )
            outputURL = url
            isExporting = false
            exportDone = true
        } catch {
            isExporting = false
            exportError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let m = total / 60
        let sec = total % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }

    private func formatTimeRange(_ start: Double, _ end: Double) -> String {
        "\(formatTimestamp(start)) → \(formatTimestamp(end))"
    }

    private func formatTimestamp(_ s: Double) -> String {
        let total = Int(s)
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 80 { return Color(red: 0.2, green: 0.85, blue: 0.4) }
        if score >= 60 { return gold }
        return Color.white.opacity(0.5)
    }
}
