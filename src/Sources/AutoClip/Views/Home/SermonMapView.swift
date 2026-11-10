import SwiftUI
import AVKit

/// The whole message as one strip: its sound, a heat line of the strongest moments, and the clips
/// already cut from it. Click to play from anywhere; drag across a stretch to make a new clip.
struct SermonMapView: View {
    let recordID: UUID
    /// Called with the new clip so the window can show it
    var onMade: (UUID) -> Void = { _ in }

    @ObservedObject private var store = AutoReelsStore.shared
    @State private var duration = 0.0
    @State private var levels: [Float] = []
    @State private var sentences: [ReelDraft.Sentence] = []
    @State private var heat: [Double] = []
    @State private var peaks: [Peak] = []
    @State private var loading = true
    @State private var noTranscript = false
    @State private var zoom = 1.0
    @State private var hoverTime: Double?
    @State private var dragStart: Double?
    @State private var selection: ClosedRange<Int>?     // sentence indices
    @State private var player = AVPlayer()
    @State private var playhead = 0.0
    @State private var playing = false
    @State private var stopAt: Double?
    @State private var observer: Any?
    @State private var madeNote: String?

    struct Peak: Identifiable { var id: Int { sentence }; var sentence: Int; var score: Double }

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }
    private var source: String? { record.flatMap { ReelGenerator.sourceVideoPath(for: $0) } }
    private let stripHeight: CGFloat = 170
    private static let colours: [Color] = [Theme.sand, Theme.terracottaLight, Theme.oliveLight, Theme.navyLight, Theme.warn]

    /// Each clip's stretches of the message, numbered as in the Clips tab.
    private var blocks: [(n: Int, id: UUID, title: String, range: ClosedRange<Double>)] {
        var out: [(Int, UUID, String, ClosedRange<Double>)] = []
        for (i, d) in (record?.drafts ?? []).enumerated() {
            for p in d.pieces where p.sourceVideoPath == source {
                let kept = p.sentences.filter(\.included)
                guard let a = kept.map(\.start).min(), let b = kept.map(\.end).max(), b > a else { continue }
                out.append((i + 1, d.id, d.title, a...b))
            }
        }
        return out
    }

    private var selectionTimes: ClosedRange<Double>? {
        guard let s = selection, sentences.indices.contains(s.lowerBound), sentences.indices.contains(s.upperBound) else { return nil }
        return sentences[s.lowerBound].start...sentences[s.upperBound].end
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VideoPlayer(player: player)
                        .frame(width: 300, height: 169)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sermon map").font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
                        Text("The whole message at a glance. The line on top rises where the wording and energy are strongest. Coloured blocks are your clips.")
                            .font(.ui(size: 12.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Label("Click anywhere to play from there", systemImage: "cursorarrow.click").font(.ui(size: 12)).foregroundColor(Theme.faint)
                        Label("Drag across a stretch to make a new clip", systemImage: "arrow.left.and.right").font(.ui(size: 12)).foregroundColor(Theme.faint)
                        if noTranscript {
                            Label("This message has no saved transcript, so the heat line and new clips aren't available here.", systemImage: "info.circle")
                                .font(.ui(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Text(hoverTime.map { "\(clock($0))  \(line(at: $0))" } ?? "Move over the map to read what's said there")
                        .font(.ui(size: 12)).foregroundColor(hoverTime == nil ? Theme.faint : Theme.text).lineLimit(1)
                    Spacer()
                    Text("Zoom").font(.ui(size: 12)).foregroundColor(Theme.muted)
                    Picker("", selection: $zoom) {
                        Text("Whole").tag(1.0); Text("4×").tag(4.0); Text("12×").tag(12.0)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 170)
                }

                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: true) {
                        strip(width: max(geo.size.width, geo.size.width * zoom))
                    }
                }
                .frame(height: stripHeight + 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the message…").font(.ui(size: 12)).foregroundColor(Theme.muted) }
                    }
                }

                if let t = selectionTimes, let s = selection { selectionCard(s, t) }
                if let madeNote {
                    Label(madeNote, systemImage: "checkmark.circle.fill").font(.ui(size: 12.5, weight: .semibold)).foregroundColor(Theme.good)
                        .transition(.opacity)
                }
                if !peaks.isEmpty { peaksCard }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: source) { await load() }
        .onChange(of: record?.drafts?.count ?? 0) { _, _ in
            // A clip was added or removed: the moments it now covers leave the list
            let ss = sentences, lv = levels, d = duration, used = blocks.map(\.range)
            Task {
                let r = await Task.detached { Self.heat(sentences: ss, levels: lv, duration: d, used: used) }.value
                peaks = r.peaks
            }
        }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
        }
    }

    // MARK: The strip

    private func strip(width: CGFloat) -> some View {
        let h = stripHeight
        return Canvas { ctx, size in
            guard duration > 0 else { return }
            func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * size.width }
            let waveTop: CGFloat = 46, waveH = size.height - waveTop - 26

            // Clip blocks, behind the sound
            for b in blocks {
                let r = CGRect(x: x(b.range.lowerBound), y: waveTop - 4, width: max(3, x(b.range.upperBound) - x(b.range.lowerBound)), height: waveH + 8)
                let c = Self.colours[(b.n - 1) % Self.colours.count]
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(c.opacity(0.22)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(c.opacity(0.8)), lineWidth: 1)
                if r.width > 14 {
                    ctx.draw(Text("\(b.n)").font(.system(size: 10, weight: .bold)).foregroundColor(c), at: CGPoint(x: r.minX + 8, y: r.maxY + 9))
                }
            }

            // The sound
            if !levels.isEmpty {
                let bw = size.width / CGFloat(levels.count)
                for (i, level) in levels.enumerated() {
                    let bh = max(1, CGFloat(level) * waveH)
                    let r = CGRect(x: CGFloat(i) * bw, y: waveTop + (waveH - bh) / 2, width: max(1, bw - 0.5), height: bh)
                    ctx.fill(Path(r), with: .color(Theme.ink.opacity(0.42)))
                }
            }

            // Heat: a filled line across the top
            if heat.count > 1 {
                var line = Path(), area = Path()
                let top: CGFloat = 6, band: CGFloat = 34
                for (i, v) in heat.enumerated() {
                    let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(heat.count - 1), y: top + band * CGFloat(1 - v))
                    if i == 0 { line.move(to: p); area.move(to: CGPoint(x: 0, y: top + band)); area.addLine(to: p) }
                    else { line.addLine(to: p); area.addLine(to: p) }
                }
                area.addLine(to: CGPoint(x: size.width, y: top + band)); area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [Theme.terracottaLight.opacity(0.55), Theme.terracottaLight.opacity(0.03)]),
                                                     startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + band)))
                ctx.stroke(line, with: .color(Theme.terracottaLight), lineWidth: 1.5)
                for p in peaks where sentences.indices.contains(p.sentence) {
                    let px = x(sentences[p.sentence].start)
                    ctx.fill(Path(ellipseIn: CGRect(x: px - 3.5, y: top - 3, width: 7, height: 7)), with: .color(Theme.cream))
                }
            }

            // Selection
            if let t = selectionTimes {
                let r = CGRect(x: x(t.lowerBound), y: 0, width: max(2, x(t.upperBound) - x(t.lowerBound)), height: size.height - 16)
                ctx.fill(Path(r), with: .color(Theme.sand.opacity(0.2)))
                ctx.stroke(Path(r), with: .color(Theme.sand), lineWidth: 1.5)
            }

            // Time marks
            let step = tick(for: duration / Double(max(1, size.width / 90)))
            var t = 0.0
            while t < duration {
                ctx.draw(Text(clock(t)).font(.system(size: 9.5).monospacedDigit()).foregroundColor(Theme.faint),
                         at: CGPoint(x: x(t) + 2, y: size.height - 7), anchor: .leading)
                t += step
            }

            // Playhead and pointer
            if let hv = hoverTime { ctx.fill(Path(CGRect(x: x(hv), y: 0, width: 1, height: size.height - 16)), with: .color(Theme.ink.opacity(0.35))) }
            ctx.fill(Path(CGRect(x: x(playhead) - 1, y: 0, width: 2, height: size.height - 16)), with: .color(Theme.cream))
        }
        .frame(width: width, height: h)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverTime = duration > 0 ? min(duration, max(0, Double(p.x / width) * duration)) : nil
            case .ended: hoverTime = nil
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard duration > 0 else { return }
                let t = min(duration, max(0, Double(g.location.x / width) * duration))
                if dragStart == nil { dragStart = min(duration, max(0, Double(g.startLocation.x / width) * duration)) }
                if abs(g.translation.width) > 4, let a = dragStart, !sentences.isEmpty { select(from: min(a, t), to: max(a, t)) }
            }
            .onEnded { g in
                let t = min(duration, max(0, Double(g.location.x / width) * duration))
                if abs(g.translation.width) <= 4 { play(from: t, to: nil) }
                dragStart = nil
            })
    }

    private func tick(for rough: Double) -> Double {
        for s in [5.0, 10, 15, 30, 60, 120, 300, 600, 900] where s >= rough { return s }
        return 1800
    }

    // MARK: Selection

    private func select(from a: Double, to b: Double) {
        guard let i = sentences.firstIndex(where: { $0.end > a }) else { return }
        let j = sentences.lastIndex(where: { $0.start < b }) ?? i
        selection = i...max(i, j)
        madeNote = nil
    }

    private func selectionCard(_ s: ClosedRange<Int>, _ t: ClosedRange<Double>) -> some View {
        let length = t.upperBound - t.lowerBound
        let text = sentences[s].map(\.text).joined(separator: " ")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Your selection").font(.ui(size: 12.5, weight: .semibold)).foregroundColor(Theme.sand)
                Text("\(clock(t.lowerBound)) – \(clock(t.upperBound)) · \(Int(length.rounded())) seconds").font(.ui(size: 12).monospacedDigit()).foregroundColor(Theme.muted)
                if length > 90 { Text("Long for a Short").font(.ui(size: 11.5, weight: .semibold)).foregroundColor(Theme.warn) }
                Spacer()
                Button { selection = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(Theme.faint).help("Clear the selection")
            }
            Text("“\(text)”").font(.ui(size: 12.5).italic()).foregroundColor(Theme.text).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { play(from: t.lowerBound, to: t.upperBound) } label: { Label("Play it", systemImage: "play.fill") }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button { nudge(start: -1) } label: { Label("Start earlier", systemImage: "arrow.left.to.line") }.buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Add the sentence before").disabled(s.lowerBound == 0)
                Button { nudge(end: 1) } label: { Label("End later", systemImage: "arrow.right.to.line") }.buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Add the sentence after").disabled(s.upperBound >= sentences.count - 1)
                Spacer()
                Button { makeClip(s) } label: { Label("Make a clip from this", systemImage: "plus.rectangle.on.rectangle") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(length < 4)
                    .help("Free: no AI. It starts and ends on whole sentences, with your usual captions and look.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sand.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.sand.opacity(0.4)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func nudge(start: Int = 0, end: Int = 0) {
        guard let s = selection else { return }
        let a = max(0, s.lowerBound + start), b = min(sentences.count - 1, s.upperBound + end)
        selection = a...max(a, b)
    }

    private func makeClip(_ s: ClosedRange<Int>) {
        guard var rec = record, let src = source else { return }
        let clips = ReelGenerator.clips(for: [s], in: sentences, source: src)
        let words = sentences[s.lowerBound].words.prefix(7).map(\.word).joined(separator: " ")
        let title = words.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\"“” "))
        let d = ReelGenerator.draft(title: title.isEmpty ? "New clip" : title, clips: clips, source: src, settings: ReelGenerator.settings(for: rec))
        rec.drafts = [d] + (rec.drafts ?? [])
        rec.reelTitles = (rec.drafts ?? []).map(\.title)
        store.update(rec)
        withAnimation { selection = nil; madeNote = "Added “\(d.title)” as clip 1. It's in the Clips tab, ready to edit or export." }
        onMade(d.id)
    }

    // MARK: Strong moments

    private var peaksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STRONG MOMENTS NOT IN A CLIP YET").font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
            ForEach(peaks) { p in
                if sentences.indices.contains(p.sentence) {
                    let s = sentences[p.sentence]
                    HStack(spacing: 10) {
                        Button { play(from: s.start, to: nil) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.plain).foregroundColor(Theme.sand).help("Play from here")
                        Text(clock(s.start)).font(.ui(size: 12).monospacedDigit()).foregroundColor(Theme.sand).frame(width: 52, alignment: .leading)
                        Text("“\(s.text)”").font(.ui(size: 12.5)).foregroundColor(Theme.text).lineLimit(1)
                        Spacer()
                        Button("Select") { selectAround(p.sentence) }.buttonStyle(SecondaryButtonStyle(compact: true))
                            .help("Selects about 40 seconds from this line, ready to make a clip")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    /// About 40 seconds of whole sentences starting at this line.
    private func selectAround(_ i: Int) {
        var j = i
        while j < sentences.count - 1, sentences[j].end - sentences[i].start < 38 { j += 1 }
        withAnimation { selection = i...j; madeNote = nil }
        playhead = sentences[i].start
    }

    // MARK: Playing

    private func play(from t: Double, to end: Double?) {
        stopAt = end
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); playing = true
    }

    private func line(at t: Double) -> String {
        guard let s = sentences.first(where: { $0.end >= t }), s.start <= t + 1.5 else { return "" }
        return "“" + s.text + "”"
    }

    private func clock(_ t: Double) -> String {
        let i = Int(max(0, t))
        return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }

    // MARK: Loading

    private func load() async {
        guard let src = source, FileManager.default.fileExists(atPath: src) else { loading = false; return }
        loading = true
        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        let d = (try? await asset.load(.duration).seconds) ?? 0
        guard d.isFinite, d > 0 else { loading = false; return }
        duration = d
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
                playhead = t.seconds
                if let s = stopAt, t.seconds >= s { player.pause(); playing = false; stopAt = nil }
            }
        }
        let words = await Task.detached { TranscriptCache.load(for: src) }.value
        if let words, !words.isEmpty {
            sentences = ReelDraft.sentences(from: SermonFinder.trimCached(words, path: src))
        } else { noTranscript = true }
        levels = await CutWaveform.levels(path: src, from: 0, to: d, bars: 1400)
        let ss = sentences, lv = levels
        let used = blocks.map(\.range)
        let result = await Task.detached { Self.heat(sentences: ss, levels: lv, duration: d, used: used) }.value
        heat = result.heat; peaks = result.peaks
        loading = false
    }

    /// How strong each part of the message is (0–1), from the wording of each sentence and how
    /// much energy is in the voice, plus the best few sentences that no clip uses yet.
    nonisolated static func heat(sentences: [ReelDraft.Sentence], levels: [Float], duration: Double,
                                 used: [ClosedRange<Double>]) -> (heat: [Double], peaks: [Peak]) {
        guard !sentences.isEmpty, duration > 0 else { return ([], []) }
        let bins = 320
        var raw = [Double](repeating: 0, count: bins)
        func energy(_ a: Double, _ b: Double) -> Double {
            guard !levels.isEmpty else { return 0.5 }
            let i = max(0, min(levels.count - 1, Int(a / duration * Double(levels.count))))
            let j = max(i, min(levels.count - 1, Int(b / duration * Double(levels.count))))
            return Double(levels[i...j].reduce(0, +)) / Double(j - i + 1)
        }
        var scored: [(Int, Double)] = []
        for (n, s) in sentences.enumerated() {
            let wording = Double(max(-2, min(8, HookLab.strength(s.text)))) / 8      // about -0.25…1
            let v = max(0, 0.55 * max(0, wording) + 0.45 * energy(s.start, s.end))
            scored.append((n, v))
            let i = max(0, min(bins - 1, Int(s.start / duration * Double(bins))))
            let j = max(i, min(bins - 1, Int(s.end / duration * Double(bins))))
            for k in i...j { raw[k] = max(raw[k], v) }
        }
        // Smooth, then stretch to fill the band
        var smooth = raw
        for _ in 0..<3 {
            var next = smooth
            for k in 0..<bins { next[k] = (smooth[max(0, k - 1)] + smooth[k] * 2 + smooth[min(bins - 1, k + 1)]) / 4 }
            smooth = next
        }
        let lo = smooth.min() ?? 0, hi = smooth.max() ?? 1
        let heat = smooth.map { hi > lo ? ($0 - lo) / (hi - lo) : 0.5 }

        // Best sentences outside every clip, at least 45 seconds apart
        var peaks: [Peak] = []
        for (n, v) in scored.sorted(by: { $0.1 > $1.1 }) {
            let s = sentences[n]
            guard s.text.split(separator: " ").count >= 5, !HookLab.dependsOnEarlier(s.text) else { continue }
            if used.contains(where: { $0.overlaps(s.start...max(s.start, s.end)) }) { continue }
            if peaks.contains(where: { abs(sentences[$0.sentence].start - s.start) < 45 }) { continue }
            peaks.append(Peak(sentence: n, score: v))
            if peaks.count == 5 { break }
        }
        return (heat, peaks.sorted { $0.sentence < $1.sentence })
    }
}
