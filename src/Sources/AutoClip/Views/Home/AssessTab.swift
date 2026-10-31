import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Assess a talk: how many filler words were said, which ones, and where — a dot on the
/// timeline for each one. Click a dot (or a row) to hear it in context.
struct AssessTab: View {
    @ObservedObject private var reelsStore = AutoReelsStore.shared
    @State private var selected: String?
    @State private var words: [Word] = []
    @State private var hits: [FillerReport.Hit] = []
    @State private var duration: Double = 1
    @State private var status: String?
    @State private var error: String?
    @State private var hidden: Set<String> = []
    @State private var hovered: FillerReport.Hit?
    @State private var player = AVPlayer()
    /// Files picked with "Choose…" and videos removed from the list (both remembered)
    @AppStorage("assess_extra") private var extraRaw = ""
    @AppStorage("assess_hidden") private var hiddenRaw = ""
    @State private var ytURL = ""
    @State private var ytStatus: String?
    @State private var ytError: String?
    @State private var pendingDelete: String?
    private var extraVideos: [String] { extraRaw.split(separator: "\n").map(String.init) }
    private var hiddenVideos: Set<String> { Set(hiddenRaw.split(separator: "\n").map(String.init)) }

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    static let colors: [String: Color] = [
        "like": Color(red: 1.0, green: 0.42, blue: 0.42), "um": Color(red: 1.0, green: 0.75, blue: 0.0),
        "uh": Color(red: 1.0, green: 0.58, blue: 0.2), "ah": Color(red: 0.95, green: 0.45, blue: 0.85),
        "well": Color(red: 0.4, green: 0.8, blue: 1.0), "so": Color(red: 0.45, green: 0.9, blue: 0.55),
        "you see": Color(red: 0.7, green: 0.6, blue: 1.0), "i mean": Color(red: 0.95, green: 0.95, blue: 0.95)
    ]
    private func color(_ k: String) -> Color { Self.colors[k] ?? .white }

    /// Videos already in AutoClip (Auto Reels sources + YouTube downloads) plus any picked here.
    private var videos: [String] {
        var out: [String] = []
        let fm = FileManager.default
        for r in reelsStore.reels {
            if let p = ReelGenerator.sourceVideoPath(for: r), fm.fileExists(atPath: p), !out.contains(p) { out.append(p) }
        }
        let dir = YTDLP.videosDir
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["mp4", "mov", "m4v", "webm", "mkv"].contains(f.pathExtension.lowercased()) && !YTDLP.isPartialStream(f) {
            if !out.contains(f.path) { out.append(f.path) }
        }
        let hidden = hiddenVideos
        return (extraVideos.filter { !out.contains($0) && fm.fileExists(atPath: $0) } + out).filter { !hidden.contains($0) }
    }

    /// Auto Reels projects made from this video (its file must stay)
    private func reelsUsing(_ path: String) -> Int {
        reelsStore.reels.filter { ReelGenerator.sourceVideoPath(for: $0) == path }.count
    }

    private var shown: [FillerReport.Hit] { hits.filter { !hidden.contains($0.kind) } }

    var body: some View {
        HStack(spacing: 0) {
            videoList.frame(width: 260)
            Divider().background(Color.white.opacity(0.08))
            Group {
                if selected == nil {
                    placeholder("Pick a video to assess", "AutoClip transcribes it (or reuses the saved transcript) and shows every filler word.")
                } else if let status {
                    VStack(spacing: 10) { ProgressView().controlSize(.small); Text(status).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    placeholder("Couldn't assess this video", error)
                } else {
                    report
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    private func placeholder(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 36)).foregroundColor(gold)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Text(sub).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.5))
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Video list

    private var videoList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("VIDEOS").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
                Spacer()
                Button("Choose…") { chooseVideo() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            // Import from YouTube
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 11)).foregroundColor(gold)
                    TextField("Paste a YouTube link", text: $ytURL)
                        .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(.white)
                        .onSubmit { importYouTube() }
                    Button("Import") { importYouTube() }
                        .controlSize(.small)
                        .disabled(ytURL.trimmingCharacters(in: .whitespaces).isEmpty || ytStatus != nil)
                }
                .padding(7).background(Color.white.opacity(0.06)).cornerRadius(7)
                if let ytStatus {
                    HStack(spacing: 5) { ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                        Text(ytStatus).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.55)) }
                } else if let ytError {
                    Text(ytError).font(.system(size: 10)).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(videos, id: \.self) { path in
                        Button { select(path) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: TranscriptCache.load(for: path) != nil ? "text.bubble.fill" : "film")
                                    .font(.system(size: 11)).foregroundColor(selected == path ? .black : gold.opacity(0.8))
                                Text(YTDLP.title(fromFile: URL(fileURLWithPath: path)))
                                    .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                    .foregroundColor(selected == path ? .black : Color.white.opacity(0.85))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(selected == path ? gold : Color.clear).cornerRadius(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete…") { pendingDelete = path }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                    }
                    if videos.isEmpty {
                        Text("No videos yet. Choose one, or import from YouTube in Auto Reels.")
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4)).padding(10)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.15))
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            if let path = pendingDelete {
                if reelsUsing(path) == 0 {
                    Button("Move Video to Trash", role: .destructive) { trash(path) }
                }
                Button("Remove from This List") { hide(path) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        } message: {
            if let path = pendingDelete {
                let n = reelsUsing(path)
                Text(n > 0 ? "\(n) Auto Reels project\(n == 1 ? " uses" : "s use") this video, so the file stays on your Mac."
                           : "Moving it to the Trash removes the video file. You can put it back from the Trash.")
            }
        }
    }

    private var deleteTitle: String {
        "Delete “\(YTDLP.title(fromFile: URL(fileURLWithPath: pendingDelete ?? "")))”?"
    }

    private func hide(_ path: String) {
        var h = hiddenVideos; h.insert(path)
        hiddenRaw = h.joined(separator: "\n")
        extraRaw = extraVideos.filter { $0 != path }.joined(separator: "\n")
        if selected == path { selected = nil; player.replaceCurrentItem(with: nil) }
        pendingDelete = nil
    }

    private func trash(_ path: String) {
        if selected == path { selected = nil; player.replaceCurrentItem(with: nil) }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        extraRaw = extraVideos.filter { $0 != path }.joined(separator: "\n")
        pendingDelete = nil
    }

    private func importYouTube() {
        let link = ytURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        ytError = nil; ytStatus = "Starting download…"
        Task {
            do {
                let file = try await YTDLP.download(link) { _, msg in Task { @MainActor in ytStatus = msg } }
                ytStatus = nil; ytURL = ""
                // A video removed earlier but downloaded again comes back
                hiddenRaw = hiddenVideos.subtracting([file.path]).joined(separator: "\n")
                select(file.path)
            } catch {
                ytStatus = nil
                ytError = error.localizedDescription
            }
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !extraVideos.contains(url.path) { extraRaw = ([url.path] + extraVideos).joined(separator: "\n") }
        hiddenRaw = hiddenVideos.subtracting([url.path]).joined(separator: "\n")
        select(url.path)
    }

    private func select(_ path: String) {
        selected = path
        error = nil; hits = []; words = []; hidden = []; hovered = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        status = "Reading the transcript…"
        Task {
            do {
                let ws = try await TranscriptCache.transcript(for: path) { msg in Task { @MainActor in status = msg } }
                guard selected == path else { return }
                let dur = CMTimeGetSeconds((try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration)) ?? .zero)
                words = ws
                hits = FillerReport.find(in: ws)
                duration = max(1, dur.isFinite && dur > 0 ? dur : (ws.last?.endTime ?? 1))
                status = nil
            } catch {
                guard selected == path else { return }
                self.error = error.localizedDescription
                status = nil
            }
        }
    }

    // MARK: Report

    private var report: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(YTDLP.title(fromFile: URL(fileURLWithPath: selected ?? "")))
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Button { pendingDelete = selected } label: { Label("Delete", systemImage: "trash") }
                        .controlSize(.small)
                }

                HStack(alignment: .top, spacing: 16) {
                    VideoPlayer(player: player)
                        .frame(width: 360, height: 203).cornerRadius(8)
                    summary
                }

                timeline

                chips

                occurrences
            }
            .padding(20)
        }
    }

    private var speakingMinutes: Double {
        guard let first = words.first, let last = words.last else { return 1 }
        return max(1, (last.endTime - first.startTime) / 60)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(shown.count)").font(.system(size: 44, weight: .bold, design: .rounded)).foregroundColor(gold)
            Text(hidden.isEmpty ? "filler words" : "filler words (filtered)")
                .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.7))
            let perMin = Double(shown.count) / speakingMinutes
            Text(String(format: "%.1f per minute of speaking", perMin))
                .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            Text(perMin < 2 ? "Very clean delivery" : perMin < 4 ? "Typical for live preaching" : "Noticeable — worth working on")
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
            Text("Transcription drops some \"um\"s and \"uh\"s, so those counts may be low.")
                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.35)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line for the whole video with a dot for each filler word.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHERE THEY ARE").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.white.opacity(0.15)).frame(height: 2).offset(y: 23)
                    ForEach(shown) { h in
                        let x = CGFloat(h.time / duration) * w
                        Circle()
                            .fill(color(h.kind))
                            .frame(width: hovered == h ? 14 : 9, height: hovered == h ? 14 : 9)
                            .position(x: x, y: 24)
                            .onHover { inside in hovered = inside ? h : (hovered == h ? nil : hovered) }
                            .onTapGesture { play(h) }
                    }
                    if let h = hovered {
                        let x = min(max(CGFloat(h.time / duration) * w, 120), w - 120)
                        VStack(spacing: 2) {
                            Text("\(fmt(h.time)) · \(h.kind)").font(.system(size: 11, weight: .semibold)).foregroundColor(color(h.kind))
                            Text(h.context).font(.system(size: 10)).foregroundColor(.white).lineLimit(2)
                        }
                        .padding(6).frame(width: 240)
                        .background(Color.black.opacity(0.9)).cornerRadius(6)
                        .position(x: x, y: -14)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 40)
            HStack {
                Text("0:00"); Spacer(); Text(fmt(duration / 2)); Spacer(); Text(fmt(duration))
            }
            .font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.4))
        }
        .padding(.top, 20)
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BY WORD — click to show or hide").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(FillerReport.kinds, id: \.self) { k in
                    let n = hits.filter { $0.kind == k }.count
                    Button {
                        if hidden.contains(k) { hidden.remove(k) } else { hidden.insert(k) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color(k)).frame(width: 9, height: 9)
                            Text("\"\(k)\"").font(.system(size: 12)).foregroundColor(.white)
                            Spacer(minLength: 4)
                            Text("\(n)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(color(k))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.white.opacity(hidden.contains(k) ? 0.02 : 0.07)).cornerRadius(7)
                        .opacity(hidden.contains(k) ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var occurrences: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EVERY ONE — click to play").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { h in
                    Button { play(h) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(fmt(h.time)).font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
                                .frame(width: 52, alignment: .leading)
                            Circle().fill(color(h.kind)).frame(width: 7, height: 7)
                            Text(h.context).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.85)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .background(hovered == h ? Color.white.opacity(0.06) : Color.clear).cornerRadius(5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in if inside { hovered = h } }
                }
            }
        }
    }

    private func play(_ h: FillerReport.Hit) {
        player.seek(to: CMTime(seconds: max(0, h.time - 2), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(max(0, s)); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60)
                                                 : String(format: "%d:%02d", i / 60, i % 60)
    }
}
