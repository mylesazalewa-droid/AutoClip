import SwiftUI
import AVFoundation
import AppKit

/// Save a clean, levelled audio file of a recording for podcast hosts: pick where it starts and
/// ends on the waveform, then export WAV or M4A.
struct CleanAudioSheet: View {
    let path: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var levels: [Float] = []
    @State private var dragging: Handle?
    @State private var options = CleanAudioExport.Options()
    @State private var player = AVPlayer()
    @State private var playing = false
    @State private var stopAt: Double?
    @State private var observer: Any?
    @State private var job: Task<Void, Never>?
    @State private var progress = 0.0
    @State private var status: String?
    @State private var error: String?
    @State private var saved: URL?

    enum Handle { case start, end }
    private let gold = Theme.sand
    private var rangeKey: String { "clean_audio_range|" + path }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clean audio for your podcast").font(Theme.display(24)).foregroundColor(Theme.cream)
                    Text(title).font(.system(size: 13)).foregroundColor(Theme.muted).lineLimit(1)
                }
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }

            // The whole recording
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DRAG THE HANDLES TO CHOOSE THE PART YOU WANT").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                    Spacer()
                    Text("Length \(fmt(end - start))").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundColor(Theme.ink)
                }
                overview.frame(height: 96)
                HStack {
                    Text("0:00").font(.system(size: 11).monospacedDigit()).foregroundColor(Theme.faint)
                    Spacer()
                    Text(fmt(duration)).font(.system(size: 11).monospacedDigit()).foregroundColor(Theme.faint)
                }
            }

            // Fine-tuning each end
            HStack(alignment: .top, spacing: 16) {
                endCard(isStart: true)
                endCard(isStart: false)
            }

            optionsCard

            HStack(spacing: 10) {
                if let status {
                    ProgressView(value: progress).frame(width: 160).tint(gold)
                    Text(status).font(.system(size: 12.5)).foregroundColor(Theme.muted)
                    Button("Stop") { job?.cancel() }.buttonStyle(SecondaryButtonStyle(compact: true))
                } else if let saved {
                    Label("Saved \(saved.lastPathComponent)", systemImage: "checkmark.circle.fill").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.good)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.buttonStyle(SecondaryButtonStyle(compact: true))
                } else if let error {
                    Text(error).font(.system(size: 12.5)).foregroundColor(Theme.danger).lineLimit(2)
                }
                Spacer()
                Button { export() } label: { Label("Export audio…", systemImage: "waveform.badge.plus") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(status != nil || duration == 0 || end - start < 1)
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(Theme.bg)
        .task { await load() }
        .onDisappear { teardown() }
        .onChange(of: start) { _ in remember() }
        .onChange(of: end) { _ in remember() }
    }

    // MARK: Overview waveform

    private var overview: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    guard !levels.isEmpty, duration > 0 else { return }
                    let barW = size.width / CGFloat(levels.count)
                    for (i, level) in levels.enumerated() {
                        let t = duration * Double(i) / Double(levels.count)
                        let h = max(1, CGFloat(level) * (size.height - 8))
                        let rect = CGRect(x: CGFloat(i) * barW, y: (size.height - h) / 2, width: max(1, barW - 0.5), height: h)
                        let inside = t >= start && t <= end
                        ctx.fill(Path(rect), with: .color(inside ? gold.opacity(0.9) : Theme.ink.opacity(0.18)))
                    }
                }
                if levels.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the sound…").font(.system(size: 12)).foregroundColor(Theme.muted) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if duration > 0 {
                    handle(.start, x: x(start, w))
                    handle(.end, x: x(end, w))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard duration > 0 else { return }
                    let t = min(duration, max(0, Double(g.location.x / max(w, 1)) * duration))
                    if dragging == nil { dragging = abs(t - start) < abs(t - end) ? .start : .end }
                    if dragging == .start { start = min(t, end - 1) } else { end = max(t, start + 1) }
                }
                .onEnded { _ in dragging = nil })
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func handle(_ h: Handle, x: CGFloat) -> some View {
        Rectangle().fill(Theme.cream).frame(width: 2)
            .overlay(alignment: h == .start ? .topLeading : .topTrailing) {
                Text(h == .start ? "START" : "END").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.onSand)
                    .padding(.horizontal, 4).padding(.vertical, 2).background(Theme.cream).fixedSize()
                    .offset(x: h == .start ? 0 : 0)
            }
            .offset(x: x - 1)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { duration > 0 ? CGFloat(t / duration) * w : 0 }

    // MARK: Ends

    private func endCard(isStart: Bool) -> some View {
        let t = isStart ? start : end
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isStart ? "Starts at" : "Ends at").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.ink)
                Text(fmt(t, tenths: true)).font(.system(size: 12.5).monospacedDigit()).foregroundColor(gold)
                Spacer()
                Button { preview(isStart: isStart) } label: {
                    Label(isStart ? "Play from here" : "Play to here", systemImage: playing ? "stop.fill" : "play.fill").font(.system(size: 12))
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            if duration > 0 {
                CutTrimmer(path: path, base: t, isStart: isStart, value: 0, sentenceWords: [], cutIDs: []) { v in
                    if isStart { start = min(max(0, start + v), end - 1) } else { end = max(min(duration, end + v), start + 1) }
                }
                .id("\(isStart)-\(t)")
            }
            Text("Drag along the sound to move it a few seconds.").font(.system(size: 11)).foregroundColor(Theme.faint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    // MARK: Options

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 22) {
                Toggle("Clean up the voice", isOn: $options.cleanVoice)
                    .help("Removes room echo, hum, crowd and background noise, like clip exports")
                if options.cleanVoice {
                    HStack(spacing: 6) {
                        Text("Strength").font(.system(size: 12)).foregroundColor(Theme.muted)
                        Slider(value: $options.strength, in: 0.3...1).frame(width: 120)
                    }
                }
                Toggle("Even out the volume", isOn: $options.levelVoice)
                    .help("Evens loud and quiet moments and sets the level podcast apps expect (about −16 LUFS)")
            }
            HStack(spacing: 22) {
                Toggle("Mono", isOn: $options.mono).help("One channel. Smaller, and right for speech")
                Toggle("Fade in and out", isOn: $options.fades)
                Picker("Format", selection: $options.format) {
                    ForEach(CleanAudioExport.Format.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            Text("Spotify, Apple Podcasts, Buzzsprout and Anchor all take WAV or M4A. WAV is the best quality; M4A is a tenth of the size.")
                .font(.system(size: 11.5)).foregroundColor(Theme.faint)
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    // MARK: Work

    private func load() async {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let d = (try? await asset.load(.duration).seconds) ?? 0
        guard d.isFinite, d > 0 else { error = "Couldn't read this recording."; return }
        duration = d
        if let saved = UserDefaults.standard.array(forKey: rangeKey) as? [Double], saved.count == 2, saved[1] <= d, saved[0] < saved[1] {
            start = saved[0]; end = saved[1]
        } else { start = 0; end = d }
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
            if let s = stopAt, t.seconds >= s { player.pause(); playing = false; stopAt = nil }
        }
        levels = await CutWaveform.levels(path: path, from: 0, to: d, bars: 700)
    }

    private func remember() { UserDefaults.standard.set([start, end], forKey: rangeKey) }

    private func preview(isStart: Bool) {
        if playing { player.pause(); playing = false; stopAt = nil; return }
        let from = isStart ? start : max(start, end - 5)
        stopAt = isStart ? min(end, start + 8) : end
        player.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); playing = true
    }

    private func export() {
        player.pause(); playing = false
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + "." + options.format.ext
        panel.allowedContentTypes = [options.format == .wav ? .wav : .mpeg4Audio]
        panel.message = "Save the clean audio"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil; saved = nil; progress = 0; status = "Starting…"
        let o = options, s = start, e = end, p = path
        job = Task {
            do {
                try await CleanAudioExport.export(path: p, start: s, end: e, options: o, to: url) { v, msg in
                    Task { @MainActor in progress = v; if status != nil { status = msg } }
                }
                saved = url
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                self.error = error.localizedDescription
                try? FileManager.default.removeItem(at: url)
            }
            status = nil; job = nil
        }
    }

    private func close() { job?.cancel(); dismiss() }

    private func teardown() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    private func fmt(_ t: Double, tenths: Bool = false) -> String {
        let t = max(0, t)
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return tenths ? base + String(format: ".%d", Int((t - floor(t)) * 10)) : base
    }
}
