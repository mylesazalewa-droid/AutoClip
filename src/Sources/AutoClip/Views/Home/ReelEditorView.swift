import SwiftUI
import AVFoundation
import AppKit

// MARK: - Review & export hub (one record = one import, several reels)

/// Lists the reels made from one video. Nothing is rendered until you export; each reel can
/// be opened in the editor, trimmed, restyled and re-exported at any time.
struct ReelDraftsView: View {
    let recordID: UUID
    let gold: Color
    var onDelete: () -> Void

    @ObservedObject private var store = AutoReelsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var editingID: UUID?
    @State private var exporting: [UUID: Double] = [:]
    @State private var exportErrors: [UUID: String] = [:]
    @State private var moreCount = 3
    @State private var genStatus: String?
    @State private var genError: String?

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }
    private var drafts: [ReelDraft] { record?.drafts ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            generateBar
            Divider().background(Color.white.opacity(0.08))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { i, d in row(i, d) }
                }
                .padding(16)
            }
            Divider().background(Color.white.opacity(0.08))
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
        .preferredColorScheme(.dark)
        .sheet(item: Binding(get: { editingID.map { EditTarget(id: $0) } }, set: { editingID = $0?.id })) { t in
            if let draft = drafts.first(where: { $0.id == t.id }) {
                ReelEditorView(draft: draft, gold: gold,
                               onSave: { save($0) },
                               onExport: { d in save(d); export([d.id]) })
            }
        }
    }

    private struct EditTarget: Identifiable { let id: UUID }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record?.title ?? "Reels").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                Text("\(drafts.count) reel\(drafts.count == 1 ? "" : "s") · pick which to export, or open one to edit")
                    .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
            }
            Spacer()
            Button(role: .destructive) { onDelete(); dismiss() } label: {
                Image(systemName: "trash").foregroundColor(Color.white.opacity(0.4))
            }.buttonStyle(.plain).help("Delete all of these reels")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: Generate

    private var generateBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { generateMore() } label: {
                    Label("Generate more", systemImage: "plus.square.on.square").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.08)).cornerRadius(7)
                }.buttonStyle(.plain).foregroundColor(.white).disabled(genStatus != nil)
                Stepper("\(moreCount)", value: $moreCount, in: 1...5).font(.system(size: 12)).fixedSize()
                Spacer()
                Button { generateFire() } label: {
                    Text("🔥 Fire Short").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.1), Color(red: 1, green: 0.65, blue: 0.0)],
                                                   startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain).foregroundColor(.white).disabled(genStatus != nil)
                .help("One SEO-rich teaser built as a hook rollercoaster that ends on a cliffhanger")
            }
            if let st = genStatus {
                HStack(spacing: 6) { ProgressView().scaleEffect(0.5); Text(st).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.6)) }
            } else if let e = genError {
                Text(e).font(.system(size: 11)).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func generateMore() {
        guard let rec = record else { return }
        genError = nil; genStatus = "Starting…"
        let n = moreCount
        Task {
            do {
                let new = try await ReelGenerator.moreDrafts(for: rec, count: n) { msg in
                    Task { @MainActor in genStatus = msg }
                }
                append(new)
            } catch { genError = error.localizedDescription }
            genStatus = nil
        }
    }

    private func generateFire() {
        guard let rec = record else { return }
        genError = nil; genStatus = "Starting…"
        Task {
            do {
                let d = try await ReelGenerator.fireShort(for: rec) { msg in
                    Task { @MainActor in genStatus = msg }
                }
                append([d], atTop: true)
            } catch { genError = error.localizedDescription }
            genStatus = nil
        }
    }

    private func append(_ new: [ReelDraft], atTop: Bool = false) {
        guard var rec = record else { return }
        var ds = rec.drafts ?? []
        ds = atTop ? new + ds : ds + new
        rec.drafts = ds
        rec.reelTitles = ds.map(\.title)
        store.update(rec)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder private func seoBlock(_ seo: ReelDraft.SEO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            seoLine("Title", seo.title)
            seoLine("Description", seo.description)
            seoLine("Hashtags", seo.hashtags.joined(separator: " "))
            seoLine("On-screen hook", seo.hookText)
            Button("Copy all") { copy(seo.asText) }.buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08)).cornerRadius(8)
    }

    private func seoLine(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.45))
                .frame(width: 84, alignment: .leading)
            Text(text).font(.system(size: 11)).foregroundColor(.white).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.45)).help("Copy")
        }
    }

    private func row(_ i: Int, _ d: ReelDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            rowMain(i, d)
            if let seo = d.seo { seoBlock(seo) }
        }
    }

    private func rowMain(_ i: Int, _ d: ReelDraft) -> some View {
        let isSel = selected.contains(d.id)
        return HStack(spacing: 12) {
            Button { if isSel { selected.remove(d.id) } else { selected.insert(d.id) } } label: {
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundColor(isSel ? gold : Color.white.opacity(0.3))
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(i + 1). \(d.title)").font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                HStack(spacing: 8) {
                    Text(formatDur(d.duration)).font(.system(size: 11, design: .monospaced)).foregroundColor(gold)
                    Text("\(d.pieces.count) clips").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
                    statusPill(d)
                }
                if let p = exporting[d.id] {
                    ProgressView(value: p).tint(gold).frame(height: 4)
                } else if let err = exportErrors[d.id] {
                    Text(err).font(.system(size: 10)).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45)).lineLimit(2)
                }
            }
            Spacer()
            if let path = d.exportedPath, FileManager.default.fileExists(atPath: path) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(.plain).foregroundColor(Color.white.opacity(0.6)).help("Show in Finder")
            }
            Button { editingID = d.id } label: {
                Label("Edit", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.08)).cornerRadius(6)
            }.buttonStyle(.plain).foregroundColor(.white)
            Button { export([d.id]) } label: {
                Text(d.exportedPath == nil ? "Export" : "Re-export").font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(gold).cornerRadius(6)
            }.buttonStyle(.plain).foregroundColor(.black).disabled(exporting[d.id] != nil)
        }
        .padding(12)
        .background(Color.white.opacity(isSel ? 0.07 : 0.04))
        .cornerRadius(10)
    }

    @ViewBuilder private func statusPill(_ d: ReelDraft) -> some View {
        let (text, color): (String, Color) = {
            if d.exportedPath == nil { return ("Not exported", Color.white.opacity(0.35)) }
            if d.editedSinceExport { return ("Edited — re-export", Color.orange) }
            return ("Exported", Color.green)
        }()
        Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var footer: some View {
        HStack {
            Button(selected.count == drafts.count ? "Select none" : "Select all") {
                selected = selected.count == drafts.count ? [] : Set(drafts.map(\.id))
            }.buttonStyle(.plain).foregroundColor(Color.white.opacity(0.6)).font(.system(size: 12))
            Spacer()
            Button { export(Array(selected)) } label: {
                Text("Export selected (\(selected.count))").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(selected.isEmpty ? Color.white.opacity(0.08) : gold).cornerRadius(8)
            }
            .buttonStyle(.plain).foregroundColor(selected.isEmpty ? Color.white.opacity(0.3) : .black)
            .disabled(selected.isEmpty)
        }
        .padding(16)
    }

    // MARK: Actions

    private func save(_ draft: ReelDraft) {
        guard var rec = record, var ds = rec.drafts, let i = ds.firstIndex(where: { $0.id == draft.id }) else { return }
        var d = draft
        // Only content changes (clips, captions, title…) make an exported reel stale —
        // not the export bookkeeping itself
        var a = d, b = ds[i]
        a.exportedPath = nil; a.editedSinceExport = false
        b.exportedPath = nil; b.editedSinceExport = false
        if a != b, d.exportedPath != nil, d.exportedPath == ds[i].exportedPath { d.editedSinceExport = true }
        ds[i] = d
        rec.drafts = ds
        rec.duration = ds.first?.duration ?? rec.duration
        store.update(rec)
    }

    private func export(_ ids: [UUID]) {
        let targets = drafts.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        // Re-exports overwrite their existing file; new exports ask where to save (once per batch)
        var folder: URL?
        if targets.contains(where: { $0.exportedPath == nil }) {
            guard let f = ReelExportLocation.pick(title: "Choose where to save \(targets.count == 1 ? "this reel" : "these reels")") else { return }
            folder = f
        }
        for d in targets { exporting[d.id] = 0.01; exportErrors[d.id] = nil }
        Task {
            for d in targets {
                let url = d.exportedPath.map { URL(fileURLWithPath: $0) }
                    ?? ReelExportLocation.fileURL(in: folder!, title: d.title)
                do {
                    try await d.render(to: url) { p, _ in exporting[d.id] = max(0.01, p) }
                    var done = d
                    done.exportedPath = url.path
                    done.editedSinceExport = false
                    save(done)
                    // keep the record's file list in step so cards/Finder actions see exports
                    if var rec = record {
                        let exported = (rec.drafts ?? []).compactMap(\.exportedPath)
                        if let first = exported.first { rec.path = first; rec.paths = exported }
                        store.update(rec)
                    }
                } catch {
                    exportErrors[d.id] = error.localizedDescription
                }
                exporting[d.id] = nil
            }
            selected.subtract(ids)
        }
    }

    private func formatDur(_ s: Double) -> String {
        let i = Int(s.rounded()); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

// MARK: - Reel editor

struct ReelEditorView: View {
    @State var draft: ReelDraft
    let gold: Color
    var onSave: (ReelDraft) -> Void
    var onExport: (ReelDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var reelWords: [Word] = []
    @State private var time: Double = 0
    @State private var total: Double = 1
    @State private var isPlaying = false
    @State private var observer: Any?
    @State private var reloadToken = 0
    /// After a nudge, play across that cut once the preview has rebuilt
    @State private var auditionAt: Double?
    /// Reel-timeline position of every kept sentence (rebuilt with the preview)
    @State private var timeline: [ReelDraft.TimedSentence] = []
    @State private var editingSentence: UUID?
    @State private var editText = ""
    @State private var lastWordClick: (sentence: UUID, index: Int)?

    /// The sentence being spoken at the playhead, and which of its words.
    private var playing: (id: UUID, word: Int)? {
        guard let ts = timeline.last(where: { $0.start <= time + 0.05 }), time <= ts.end + 0.4 else { return nil }
        let w = ts.wordStarts.lastIndex(where: { $0 <= time + 0.05 }) ?? 0
        return (ts.id, w)
    }

    private var look: CaptionLook { draft.look ?? CaptionLook.load() ?? CaptionLook(preset: CaptionStyle.all[0]) }
    private var previewAspect: CGFloat {
        switch VideoExportService.ExportFormat(rawValue: draft.formatRaw) ?? .vertical9x16 {
        case .vertical9x16: return 9.0 / 16.0
        case .square1x1: return 1
        default: return 16.0 / 9.0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Reel title", text: $draft.title)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Text(formatDur(draft.duration)).font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
            }
            .padding(16)
            Divider().background(Color.white.opacity(0.08))

            HStack(alignment: .top, spacing: 16) {
                previewColumn.frame(width: 260)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            captionsSection
                            Text("CLIPS — click words to cut them (shift-click a range) · ▶ plays · ✏️ fixes caption text")
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
                            ForEach(Array(draft.pieces.enumerated()), id: \.element.id) { i, _ in pieceCard(i) }
                        }
                        .padding(.trailing, 6)
                    }
                    // Follow along while playing (not while paused, so manual scrolling isn't fought)
                    .onChange(of: playing?.id) { id in
                        guard isPlaying, let id else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .padding(16)

            Divider().background(Color.white.opacity(0.08))
            HStack {
                Button("Cancel") { player.pause(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { player.pause(); onSave(draft); dismiss() }
                Button {
                    player.pause(); onExport(draft); dismiss()
                } label: {
                    Text(draft.exportedPath == nil ? "Save & Export" : "Save & Re-export")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6).background(gold).cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(draft.includedSentenceCount == 0)
            }
            .padding(16)
        }
        .frame(minWidth: 860, minHeight: 640)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
        .preferredColorScheme(.dark)
        .task(id: reloadToken) { await reloadPreview() }
        .onChange(of: draft.pieces) { _ in reloadToken += 1 }
        .onDisappear {
            if let o = observer { player.removeTimeObserver(o) }
            player.pause()
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                FillPlayerView(player: player)
                if draft.captions, let img = captionOverlay() {
                    Image(nsImage: img).resizable().allowsHitTesting(false)
                }
            }
            .aspectRatio(previewAspect, contentMode: .fit)
            .cornerRadius(8)
            .onTapGesture { togglePlay() }

            HStack(spacing: 8) {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").foregroundColor(gold)
                }.buttonStyle(.plain)
                Slider(value: Binding(get: { time }, set: { t in
                    time = t; player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }), in: 0...max(total, 0.1)).tint(gold)
                Text(formatDur(time)).font(.system(size: 10, design: .monospaced)).foregroundColor(Color.white.opacity(0.5))
            }
            Text("Quick preview — the export adds face tracking and full quality.")
                .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.35)).multilineTextAlignment(.center)
        }
    }

    private func togglePlay() {
        if isPlaying { player.pause() } else {
            if time >= total - 0.1 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying.toggle()
    }

    private func reloadPreview() async {
        let resumeAt = time
        guard let (item, words) = await draft.previewItem() else { return }
        if let o = observer { player.removeTimeObserver(o); observer = nil }
        player.replaceCurrentItem(with: item)
        reelWords = words
        timeline = draft.sentenceTimeline
        total = max(0.1, draft.duration)
        let seekTo = auditionAt.map { max(0, min($0, total - 0.2)) } ?? min(resumeAt, total)
        await player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seekTo
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { t in
            time = CMTimeGetSeconds(t)
            if time >= total - 0.05 { isPlaying = false }
        }
        if auditionAt != nil { auditionAt = nil; isPlaying = true }
        if isPlaying { player.play() }
    }

    /// Draws the caption for the current moment with the reel's look (same drawing code as export).
    private func captionOverlay() -> NSImage? {
        let look = self.look
        let phrases = CaptionLook.phrases(reelWords, maxWords: look.wordsPerCaption,
                                          text: { $0.word }, start: { $0.startTime }, end: { $0.endTime })
        guard let pi = phrases.firstIndex(where: { p in
            guard let s = p.first?.startTime, let e = p.last?.endTime else { return false }
            return time >= s && time <= e + 0.15
        }) else { return nil }
        let phrase = phrases[pi]
        let active = phrase.lastIndex(where: { $0.startTime <= time }) ?? 0
        let size = CGSize(width: 540, height: 540 / previewAspect)
        return NSImage(size: size, flipped: true) { _ in
            let fs = look.fontSize(forRenderWidth: size.width)  // preview width stands in for the export width
            let maxW = size.width * 0.86
            let texts = phrase.map(\.word)
            let str = look.attributedPhrase(texts, active: active, fontSize: fs)
            let m = look.measure(look.attributedPhrase(texts, active: nil, fontSize: fs), maxWidth: maxW)
            let cy = size.height * CGFloat(look.position)
            if look.bgEnabled {
                let px = fs * 0.35, py = fs * 0.18
                look.bgColor.nsColor.withAlphaComponent(CGFloat(look.bgOpacity)).setFill()
                NSBezierPath(roundedRect: CGRect(x: (size.width - m.width) / 2 - px, y: cy - m.height / 2 - py,
                                                 width: m.width + px * 2, height: m.height + py * 2),
                             xRadius: fs * 0.25, yRadius: fs * 0.25).fill()
            }
            str.draw(with: CGRect(x: (size.width - maxW) / 2, y: cy - m.height / 2, width: maxW, height: m.height + 4),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
    }

    // MARK: Captions

    private var captionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CAPTIONS").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.white.opacity(0.35)).tracking(1)
                Spacer()
                Toggle("", isOn: $draft.captions).toggleStyle(.switch).tint(gold).labelsHidden()
            }
            if draft.captions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(CaptionStyle.all) { style in
                            Button(style.name) { draft.look = CaptionLook(preset: style) }
                                .buttonStyle(.plain).font(.system(size: 11))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.07)).cornerRadius(6)
                        }
                    }
                }
                CaptionEditorView(look: Binding(get: { look }, set: { draft.look = $0 }), gold: gold)
            }
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(10)
    }

    // MARK: Clips

    private func pieceCard(_ i: Int) -> some View {
        let piece = draft.pieces[i]
        let kept = piece.sentences.filter(\.included)
        let dur = kept.reduce(0.0) { $0 + ($1.end - $1.start) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Clip \(i + 1)").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text(formatDur(dur)).font(.system(size: 11, design: .monospaced)).foregroundColor(gold)
                Spacer()
                Button { jump(toPiece: i) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.plain).foregroundColor(Color.white.opacity(0.6)).help("Preview from here")
                Button { move(i, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.plain).foregroundColor(Color.white.opacity(i == 0 ? 0.15 : 0.6)).disabled(i == 0)
                Button { move(i, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.plain).foregroundColor(Color.white.opacity(i == draft.pieces.count - 1 ? 0.15 : 0.6))
                    .disabled(i == draft.pieces.count - 1)
                Button { draft.pieces.remove(at: i) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45)).help("Remove this clip")
            }
            ForEach(Array(piece.sentences.enumerated()), id: \.element.id) { j, s in
                let startsRun = s.included && (j == 0 || !piece.sentences[j - 1].included)
                let endsRun = s.included && (j == piece.sentences.count - 1 || !piece.sentences[j + 1].included)
                if startsRun { nudgeRow(piece: i, sentence: j, isStart: true) }
                let now = playing?.id == s.id ? playing : nil
                HStack(alignment: .top, spacing: 8) {
                    Button { draft.pieces[i].sentences[j].included.toggle() } label: {
                        Image(systemName: s.included ? "checkmark.square.fill" : "square")
                            .foregroundColor(s.included ? gold : Color.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help(s.included ? "Cut this sentence out" : "Put this sentence back")
                    if editingSentence == s.id {
                        TextField("Caption text", text: $editText, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                            .padding(4).background(Color.white.opacity(0.08)).cornerRadius(4)
                            .onSubmit { commitEdit(i, j) }
                        Button("Done") { commitEdit(i, j) }.buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(gold)
                        Button("Cancel") { editingSentence = nil }.buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                    } else {
                        wordFlow(i, j, activeWord: now?.word)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if s.included {
                            Button { play(from: s.id) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.plain).font(.system(size: 9)).foregroundColor(Color.white.opacity(0.45))
                                .help("Play from this sentence")
                        }
                        Button { editText = s.text; editingSentence = s.id } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.45))
                            .help("Fix the caption text for this sentence")
                    }
                }
                .padding(.vertical, 2).padding(.horizontal, 4)
                .background(now != nil ? gold.opacity(0.14) : Color.clear)
                .overlay(alignment: .leading) {
                    if now != nil { Rectangle().fill(gold).frame(width: 2) }
                }
                .cornerRadius(4)
                .id(s.id)
                if endsRun { nudgeRow(piece: i, sentence: j, isStart: false) }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .opacity(kept.isEmpty ? 0.5 : 1)
    }

    /// The sentence as clickable words. Click a word to cut it (click again to restore);
    /// shift-click to cut/restore everything from the last clicked word. While playing,
    /// the spoken word lights up in gold.
    private func wordFlow(_ i: Int, _ j: Int, activeWord: Int?) -> some View {
        let s = draft.pieces[i].sentences[j]
        return WordFlowLayout(spacing: 4, lineSpacing: 2) {
            ForEach(Array(s.words.enumerated()), id: \.element.id) { k, w in
                let cut = s.isCut(w)
                let isActive = activeWord == k && !cut
                Text(w.word)
                    .font(.system(size: 12, weight: isActive ? .bold : .regular))
                    .foregroundColor(!s.included ? Color.white.opacity(0.3)
                                     : cut ? Color(red: 1, green: 0.45, blue: 0.45).opacity(0.7)
                                     : isActive ? gold
                                     : (activeWord.map { k < $0 } ?? false) ? .white : Color.white.opacity(0.85))
                    .strikethrough(!s.included || cut, color: cut ? Color(red: 1, green: 0.45, blue: 0.45) : nil)
                    .padding(.horizontal, 1)
                    .background(cut ? Color(red: 1, green: 0.3, blue: 0.3).opacity(0.12) : Color.clear)
                    .cornerRadius(2)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleWord(i, j, k) }
                    .help(cut ? "Put this word back" : "Cut this word out")
            }
        }
    }

    private func toggleWord(_ i: Int, _ j: Int, _ k: Int) {
        var s = draft.pieces[i].sentences[j]
        guard s.included else { return }
        var cut = Set(s.cutWordIDs ?? [])
        let w = s.words[k]
        let makeCut = !cut.contains(w.id)
        var range = k...k
        if NSEvent.modifierFlags.contains(.shift), let last = lastWordClick, last.sentence == s.id {
            range = min(last.index, k)...max(last.index, k)
        }
        for idx in range { if makeCut { cut.insert(s.words[idx].id) } else { cut.remove(s.words[idx].id) } }
        s.cutWordIDs = cut.isEmpty ? nil : Array(cut)
        draft.pieces[i].sentences[j] = s
        lastWordClick = (s.id, k)
    }

    private func commitEdit(_ i: Int, _ j: Int) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { draft.setText(text, piece: i, sentence: j) }
        editingSentence = nil
    }

    /// Jump the preview to a sentence (excluded sentences aren't in the reel, so they just toggle back on hint).
    private func play(from sentenceID: UUID) {
        guard let ts = timeline.first(where: { $0.id == sentenceID }) else { return }
        time = ts.start
        player.seek(to: CMTime(seconds: ts.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); isPlaying = true
    }

    // MARK: Micro-adjust cuts

    /// Fine-tune where a stitched run starts or ends. Start: earlier ◀ ▶ later.
    /// End: shorter ◀ ▶ longer. Each tap re-plays across that cut.
    private func nudgeRow(piece i: Int, sentence j: Int, isStart: Bool) -> some View {
        let s = draft.pieces[i].sentences[j]
        let value = (isStart ? s.startNudge : s.endNudge) ?? 0
        return HStack(spacing: 6) {
            Image(systemName: isStart ? "arrow.right.to.line" : "arrow.left.to.line")
                .font(.system(size: 10)).foregroundColor(gold.opacity(0.8))
            Text(isStart ? "Starts" : "Ends").font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.5)).frame(width: 38, alignment: .leading)
            nudgeButton("−0.5", i, j, isStart, -0.5)
            nudgeButton("−0.1", i, j, isStart, -0.1)
            Text(value == 0 ? "0.0s" : String(format: "%+.1fs", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(value == 0 ? Color.white.opacity(0.4) : gold)
                .frame(width: 40)
            nudgeButton("+0.1", i, j, isStart, 0.1)
            nudgeButton("+0.5", i, j, isStart, 0.5)
            Text(isStart ? "earlier ◀ ▶ later" : "shorter ◀ ▶ longer")
                .font(.system(size: 9)).foregroundColor(Color.white.opacity(0.3))
            Spacer(minLength: 0)
            if value != 0 {
                Button("Reset") { setNudge(i, j, isStart, nil) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5))
            }
            Button { audition(i, j, isStart) } label: { Image(systemName: "ear") }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.5))
                .help("Play across this cut")
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(Color.white.opacity(0.03)).cornerRadius(5)
    }

    private func nudgeButton(_ label: String, _ i: Int, _ j: Int, _ isStart: Bool, _ delta: Double) -> some View {
        Button(label) {
            let s = draft.pieces[i].sentences[j]
            let cur = (isStart ? s.startNudge : s.endNudge) ?? 0
            // Limit to ±5s so a cut can't swallow a neighbouring thought by accident
            let next = (min(5, max(-5, cur + delta)) * 10).rounded() / 10
            setNudge(i, j, isStart, next == 0 ? nil : next)
            audition(i, j, isStart)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Color.white.opacity(0.08)).cornerRadius(4)
    }

    private func setNudge(_ i: Int, _ j: Int, _ isStart: Bool, _ v: Double?) {
        if isStart { draft.pieces[i].sentences[j].startNudge = v }
        else { draft.pieces[i].sentences[j].endNudge = v }
    }

    /// Queue playback from just before the cut (start: 1.5s of the previous clip; end: last 2s of this run).
    private func audition(_ i: Int, _ j: Int, _ isStart: Bool) {
        let id = draft.pieces[i].sentences[j].id
        if isStart, let t = draft.reelTime(runStartingWith: id) { auditionAt = max(0, t - 1.5) }
        if !isStart, let t = draft.reelTime(runEndingWith: id) { auditionAt = max(0, t - 2.0) }
        reloadToken += 1   // rebuilds the preview (with the new cut) and then plays from auditionAt
    }

    private func move(_ i: Int, by delta: Int) {
        let j = i + delta
        guard draft.pieces.indices.contains(j) else { return }
        draft.pieces.swapAt(i, j)
    }

    /// Seek the preview to where a clip starts in the edited reel.
    private func jump(toPiece i: Int) {
        let before = ReelDraft(title: "", clips: [], sourceVideoPath: "", formatRaw: draft.formatRaw, captions: false,
                               look: nil, crossDissolve: false, emojiOverlays: false, topicKeywords: [])
        var prefix = before; prefix.pieces = Array(draft.pieces.prefix(i))
        let t = prefix.duration
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); isPlaying = true
    }

    private func formatDur(_ s: Double) -> String {
        let i = Int(max(0, s).rounded()); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

/// AVPlayerLayer that fills its frame (center crop), like the exported vertical reel.
private struct FillPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspectFill
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = l
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}

/// Wraps children onto lines like text (used for clickable words).
private struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, p) in r.positions.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            maxX = max(maxX, x - spacing)
        }
        return (positions, CGSize(width: min(maxX, width), height: y + lineH))
    }
}
