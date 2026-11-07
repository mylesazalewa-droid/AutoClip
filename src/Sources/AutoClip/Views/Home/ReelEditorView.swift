import SwiftUI
import TipKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Review & export hub (one record = one import, several reels)

/// Lists the reels made from one video. Nothing is rendered until you export; each reel can
/// be opened in the editor, trimmed, restyled and re-exported at any time.
struct ReelDraftsView: View {
    let recordID: UUID
    let gold: Color
    var onDelete: () -> Void
    /// In the reel window, clicking a row previews that reel on the right
    var previewingID: UUID? = nil
    var onPreview: ((UUID) -> Void)? = nil

    @ObservedObject private var store = AutoReelsStore.shared
    @ObservedObject private var volunteer = VolunteerMode.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var exportRequests = ExportRequests.shared
    @State private var exporting: [UUID: Double] = [:]
    @State private var exportErrors: [UUID: String] = [:]
    @State private var moreCount = 3
    @State private var genStatus: String?
    @State private var genError: String?
    @State private var request = ""
    @State private var topics: [String] = []
    @State private var showGraphics = false
    @State private var showKit = false
    @State private var showReview = false
    @State private var showCleanup = false
    @State private var confirmDelete = false
    @State private var celebrating: Set<UUID> = []

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }
    private var drafts: [ReelDraft] { record?.drafts ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            TipView(QuickReviewTip()).padding(.horizontal, 16).padding(.bottom, 8)
            if !volunteer.enabled { generateBar }
            Divider().background(Theme.ink.opacity(0.08))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(drafts.enumerated()), id: \.element.id) { i, d in row(i, d) }
                }
                .padding(16)
            }
            Divider().background(Theme.ink.opacity(0.08))
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Theme.bg)
        .appLook()
        .onReceive(exportRequests.$pending) { t in
            guard let t, t.record == recordID else { return }
            exportRequests.pending = nil
            export([t.draft])
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record?.title ?? "Clips").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                Text("\(drafts.count) clip\(drafts.count == 1 ? "" : "s") · pick which to export, or open one to edit")
                    .font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
            }
            Spacer()
            Button { showReview = true } label: {
                Label("Quick review", systemImage: "rectangle.stack").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(gold).cornerRadius(6)
            }
            .buttonStyle(.plain).foregroundColor(Theme.onSand)
            .keyboardShortcut("r", modifiers: .command)
            .help("Go through the clips one at a time: → keep, ← toss (⌘R)")
            .disabled(drafts.isEmpty)
            .onChange(of: showReview) { on in
                if on { UserDefaults.standard.set(true, forKey: AutoReelsStore.reviewedKey(recordID)); QuickReviewTip().invalidate(reason: .actionPerformed) }
            }
            .onAppear { if store.reviewOnOpen == recordID { store.reviewOnOpen = nil; showReview = true } }
            .sheet(isPresented: $showReview) {
                ReviewModeView(recordID: recordID, selected: $selected, onToss: { notForMe($0) }, onExport: { export($0) })
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Image(systemName: "trash").foregroundColor(Theme.ink.opacity(0.55))
            }
            .buttonStyle(.plain).help("Delete all of these clips")
            .opacity(volunteer.enabled ? 0 : 1).disabled(volunteer.enabled)
            .confirmationDialog("Delete all \(drafts.count) clips from this project?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { onDelete(); dismiss() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the project and its edits from AutoClip. It can't be undone.")
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: Generate

    private var generateBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { generateMore() } label: {
                    Label("Generate more", systemImage: "plus.square.on.square").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.ink.opacity(0.08)).cornerRadius(7)
                }.buttonStyle(.plain).foregroundColor(Theme.ink).disabled(genStatus != nil)
                Stepper("\(moreCount)", value: $moreCount, in: 1...5).font(.system(size: 13)).fixedSize()
                Spacer()
                Button { generateFire() } label: {
                    Label("Teaser", systemImage: "flame.fill").font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.1), Color(red: 1, green: 0.65, blue: 0.0)],
                                                   startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain).foregroundColor(Theme.onColor).disabled(genStatus != nil)
                .help("One teaser clip with a title, description and hashtags, built to end on a cliffhanger")
                Button { showGraphics = true } label: {
                    Label("Graphics", systemImage: "photo.on.rectangle.angled").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.ink.opacity(0.08)).cornerRadius(7)
                }
                .buttonStyle(.plain).foregroundColor(Theme.ink)
                .help("Quote cards, a carousel and a thumbnail for the full message")
                Button { showKit = true } label: {
                    Label("Content kit", systemImage: "shippingbox").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.terracotta).cornerRadius(7)
                }
                .buttonStyle(.plain).foregroundColor(Theme.onColor)
                .help("Every clip, captions and hashtags, notes, graphics and a posting plan — in one folder")
                Button { showCleanup = true } label: {
                    Label("Clean up", systemImage: "scissors").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.ink.opacity(0.08)).cornerRadius(7)
                }
                .buttonStyle(.plain).foregroundColor(Theme.ink)
                .help("Save a tighter copy of the full video: fillers, false starts and long pauses cut")
            }
            .sheet(isPresented: $showKit) { ContentKitSheet(recordID: recordID) }
            .sheet(isPresented: $showCleanup) { CleanupSheet(recordID: recordID) }
            .sheet(isPresented: $showGraphics) {
                if let rec = record { SocialGraphicsView(record: rec, gold: gold) }
            }
            // Chat: ask for a short about something the talk covers
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(gold).font(.system(size: 13))
                TextField("Ask for a clip… e.g. \"a 60-second clip about forgiveness\"", text: $request)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.ink)
                    .onSubmit { askForShort(request) }
                Button("Create") { askForShort(request) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.onSand)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(request.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.ink.opacity(0.15) : gold).cornerRadius(6)
                    .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty || genStatus != nil)
            }
            .padding(8).background(Theme.ink.opacity(0.06)).cornerRadius(8)
            if topics.isEmpty {
                Button("What does this talk cover?") { suggestTopics() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    .disabled(genStatus != nil)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(topics, id: \.self) { t in
                            Button(t) { request = t; askForShort(t) }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.ink)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Theme.ink.opacity(0.08)).cornerRadius(12)
                                .disabled(genStatus != nil)
                        }
                    }
                }
            }
            if let st = genStatus {
                HStack(spacing: 6) { ProgressView().scaleEffect(0.5); Text(st).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.6)) }
            } else if let e = genError {
                Text(e).font(.system(size: 12)).foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func generateMore() {
        guard let rec = record else { return }
        genError = nil; genStatus = "Starting…"
        let n = moreCount
        Task { await CostTag.$video.withValue(rec.title) {
            do {
                let new = try await ReelGenerator.moreDrafts(for: rec, count: n) { msg in
                    Task { @MainActor in genStatus = msg }
                }
                append(new)
            } catch { genError = error.localizedDescription }
            genStatus = nil
        } }
    }

    private func askForShort(_ text: String) {
        let req = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, let rec = record else { return }
        genError = nil; genStatus = "Starting…"
        Task { await CostTag.$video.withValue(rec.title) {
            do {
                let d = try await ReelGenerator.requestedShort(req, for: rec) { msg in
                    Task { @MainActor in genStatus = msg }
                }
                append([d], atTop: true)
                request = ""
            } catch { genError = error.localizedDescription }
            genStatus = nil
        } }
    }

    private func suggestTopics() {
        guard let rec = record else { return }
        genError = nil; genStatus = "Starting…"
        Task { await CostTag.$video.withValue(rec.title) {
            do {
                topics = try await ReelGenerator.topics(for: rec) { msg in
                    Task { @MainActor in genStatus = msg }
                }
            } catch { genError = error.localizedDescription }
            genStatus = nil
        } }
    }

    private func generateFire() {
        guard let rec = record else { return }
        genError = nil; genStatus = "Starting…"
        Task { await CostTag.$video.withValue(rec.title) {
            do {
                let d = try await ReelGenerator.fireShort(for: rec) { msg in
                    Task { @MainActor in genStatus = msg }
                }
                append([d], atTop: true)
            } catch { genError = error.localizedDescription }
            genStatus = nil
        } }
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
            if !seo.hookText.isEmpty { seoLine("On-screen hook", seo.hookText) }
            Button("Copy all") { copy(seo.asText) }.buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08)).cornerRadius(8)
    }

    private func seoLine(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55))
                .frame(width: 84, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundColor(Theme.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { copy(text) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55)).help("Copy")
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
                    .font(.system(size: 18)).foregroundColor(isSel ? gold : Theme.ink.opacity(0.3))
            }.buttonStyle(.plain)

            ScrubThumb(draft: d, path: d.pieces.first?.sourceVideoPath ?? "", faceAspect: 9 / 16)
                .frame(width: 42, height: 74).clipShape(RoundedRectangle(cornerRadius: 5))
                .environment(\.colorScheme, .dark)
                .draggableClip(d.editedSinceExport ? nil : d.exportedPath)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(i + 1). \(d.title)").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                HStack(spacing: 8) {
                    Text(formatDur(d.duration)).font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
                    Text("\(d.pieces.count) moment\(d.pieces.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    statusPill(d)
                    GuardBadge(draft: d)
                }
                if let p = exporting[d.id] {
                    ProgressView(value: p).tint(Theme.action).frame(height: 4)
                } else if let err = exportErrors[d.id] {
                    Text(err).font(.system(size: 11.5)).foregroundColor(Theme.danger).lineLimit(2)
                }
            }
            Spacer()
            if let path = d.exportedPath, FileManager.default.fileExists(atPath: path) {
                if ShareOut.canAirDrop {
                    Button { ShareOut.airDrop(path) } label: { Image(systemName: "iphone.and.arrow.forward") }
                        .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.6)).help("Send to iPhone with AirDrop")
                        .accessibilityLabel("Send to iPhone")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.6)).help("Show in Finder").accessibilityLabel("Show in Finder")
            }
            if !volunteer.enabled {
                Button { notForMe(d) } label: { Image(systemName: "hand.thumbsdown") }
                    .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.55))
                    .help("Not for me — remove this clip, and AutoClip learns to pick fewer like it")
            }
            Button { openWindow(id: "reel-editor", value: EditorTarget(record: recordID, draft: d.id)) } label: {
                Label("Edit", systemImage: "slider.horizontal.3").font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.ink.opacity(0.08)).cornerRadius(6)
            }.buttonStyle(.plain).foregroundColor(Theme.ink)
            Button { export([d.id]) } label: {
                Text(d.exportedPath == nil ? "Export" : "Re-export").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(gold).cornerRadius(6)
            }.buttonStyle(.plain).foregroundColor(Theme.onSand).disabled(exporting[d.id] != nil)
            Menu {
                Section("Also export as") {
                    ForEach(ReelEditorView.sizes.filter { $0.0.rawValue != d.formatRaw }, id: \.0) { f, label in
                        Button(label) { exportSize(d, f) }
                    }
                }
            } label: { Image(systemName: "aspectratio") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Export a copy in another size (4:5, 1:1, original…)")
            .disabled(exporting[d.id] != nil)
            .opacity(volunteer.enabled ? 0 : 1)
        }
        .padding(12)
        .background(previewingID == d.id ? gold.opacity(0.12) : Theme.ink.opacity(isSel ? 0.07 : 0.04))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(previewingID == d.id ? gold.opacity(0.6) : .clear, lineWidth: 1))
        .cornerRadius(10)
        .overlay(alignment: .trailing) {
            if celebrating.contains(d.id) { CelebrationBurst(size: 26).padding(.trailing, 70).transition(.opacity) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onPreview?(d.id) }
    }

    @ViewBuilder private func statusPill(_ d: ReelDraft) -> some View {
        let (text, color): (String, Color) = {
            if d.exportedPath == nil { return ("Not exported", Theme.ink.opacity(0.35)) }
            if d.editedSinceExport { return ("Edited — re-export", Color.orange) }
            return ("Exported", Color.green)
        }()
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var footer: some View {
        HStack {
            Button(selected.count == drafts.count ? "Select none" : "Select all") {
                selected = selected.count == drafts.count ? [] : Set(drafts.map(\.id))
            }.buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.6)).font(.system(size: 13))
            Spacer()
            Button { export(Array(selected)) } label: {
                Text("Export selected (\(selected.count))").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(selected.isEmpty ? Theme.ink.opacity(0.08) : gold).cornerRadius(8)
            }
            .buttonStyle(.plain).foregroundColor(selected.isEmpty ? Theme.ink.opacity(0.3) : .black)
            .disabled(selected.isEmpty)
        }
        .padding(16)
    }

    // MARK: Actions

    private func save(_ draft: ReelDraft) { store.saveDraft(draft, in: recordID) }

    /// Throws a reel out and remembers it as the kind the user doesn't want.
    private func notForMe(_ d: ReelDraft) {
        guard var rec = record else { return }
        TasteStore.shared.rejected(d, kind: rec.kind)
        rec.drafts = (rec.drafts ?? []).filter { $0.id != d.id }
        rec.reelTitles = (rec.drafts ?? []).map(\.title)
        store.update(rec)
        selected.remove(d.id)
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
                    Delight.success()
                    celebrating.insert(d.id)
                    let id = d.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { celebrating.remove(id) }
                    if let rec = record { TasteStore.shared.liked(done, kind: rec.kind) }
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

    /// Render a copy of the reel in another size, next to its main export (or a folder you pick).
    private func exportSize(_ d: ReelDraft, _ format: VideoExportService.ExportFormat) {
        let label = ReelEditorView.sizes.first { $0.0 == format }?.1 ?? format.rawValue
        let folder: URL
        if let p = d.exportedPath { folder = URL(fileURLWithPath: p).deletingLastPathComponent() }
        else if let f = ReelExportLocation.pick(title: "Choose where to save the \(label) version") { folder = f }
        else { return }
        var copy = d
        copy.formatRaw = format.rawValue
        let url = ReelExportLocation.fileURL(in: folder, title: "\(d.title) (\(label.replacingOccurrences(of: ":", with: "x")))")
        exporting[d.id] = 0.01; exportErrors[d.id] = nil
        Task {
            do {
                try await copy.render(to: url) { p, _ in exporting[d.id] = max(0.01, p) }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { exportErrors[d.id] = error.localizedDescription }
            exporting[d.id] = nil
        }
    }

    private func formatDur(_ s: Double) -> String {
        let i = Int(s.rounded()); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

// MARK: - Reel editor

struct ReelEditorView: View {
    enum Workspace: String { case edit = "Edit", reframe = "Reframe", audio = "Audio", captions = "Captions" }
    @State var draft: ReelDraft
    @State var workspace: Workspace = .edit
    /// People in the first clip, when there's a choice of who to follow
    @State private var crew: [ReframePerson] = []
    @State private var previewAsset: AVAsset?
    @State private var mediaToken = 0
    @State private var splitNote: [UUID: String] = [:]
    let gold: Color
    /// The project this reel belongs to, for "Apply to all clips"
    var recordID: UUID? = nil
    var onSave: (ReelDraft) -> Void
    var onExport: (ReelDraft) -> Void
    @State private var editorWindow: NSWindow?
    @State private var closeGuard = CloseGuard()
    @State private var draggingPiece: UUID?
    @State private var applyNote: String?

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var reelWords: [Word] = []
    @State private var time: Double = 0
    @State private var total: Double = 1
    @State private var isPlaying = false
    @State private var observer: Any?
    @State private var reloadToken = 0
    @State private var sourceAspect: CGFloat = 16.0 / 9.0
    /// While the pointer is over the list it stays still, so buttons don't move out from under a click
    @State private var listHovered = false
    @State private var undoStack: [ReelDraft] = []
    @State private var redoStack: [ReelDraft] = []
    @State private var lastDraft: ReelDraft?
    @State private var lastChange = Date.distantPast
    @State private var movingInHistory = false
    @State private var original: ReelDraft?
    @State private var confirmDiscard = false
    /// After a nudge, play across that cut once the preview has rebuilt
    @State private var auditionAt: Double?
    /// Reel-timeline position of every kept sentence (rebuilt with the preview)
    @State private var timeline: [ReelDraft.TimedSentence] = []
    @State private var editingSentence: UUID?
    @State private var editText = ""
    @State private var lastWordClick: (sentence: UUID, index: Int)?
    @State private var following = false
    @State private var followTask: Task<Void, Never>?
    @State private var overlayItems: [ReelOverlays.Placed] = []
    @State private var hookStatus: String?
    @State private var fillerNote: String?
    @State private var endingStatus: String?
    @State private var neighbourNote: (piece: UUID, text: String)?
    @ObservedObject private var volunteer = VolunteerMode.shared
    @AppStorage("phone_view") private var phoneRaw = PhoneView.off.rawValue
    private var phone: PhoneView {
        get { PhoneView(rawValue: phoneRaw) ?? .off }
        nonmutating set { phoneRaw = newValue.rawValue }
    }
    @AppStorage("editor_focus") private var focusMode = false
    @State private var showKeys = false
    @State private var keyMonitor: Any?
    @State private var askText = ""
    @State private var askBusy = false
    @State private var askNote: (text: String, ok: Bool)?
    @State private var guardBusy = false
    @State private var guardError: String?
    @AppStorage("guard_translation") private var translation = "Any"
    @State private var zooms: [ReelMotion.Zoom] = []
    @ObservedObject private var seriesStore = SeriesStore.shared
    @State private var newSeriesName = ""
    @State private var showNewSeries = false
    @State private var seriesNote: String?

    /// The sentence being spoken at the playhead, and which of its words.
    private var playing: (id: UUID, word: Int)? {
        guard let ts = timeline.last(where: { $0.start <= time + 0.05 }), time <= ts.end + 0.4 else { return nil }
        let w = ts.wordStarts.lastIndex(where: { $0 <= time + 0.05 }) ?? 0
        return (ts.id, w)
    }

    private var look: CaptionLook { draft.styledLook }
    private var previewAspect: CGFloat {
        switch VideoExportService.ExportFormat(rawValue: draft.formatRaw) ?? .vertical9x16 {
        case .vertical9x16: return 9.0 / 16.0
        case .portrait4x5: return 4.0 / 5.0
        case .square1x1: return 1
        default: return sourceAspect
        }
    }

    /// Sizes a reel can be previewed / exported in
    static let sizes: [(VideoExportService.ExportFormat, String)] = [
        (.vertical9x16, "9:16"), (.portrait4x5, "4:5"), (.square1x1, "1:1"), (.original, "Original")
    ]

    private var sizeSection: some View {
        HStack {
            Text("SIZE").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
            Spacer()
            Picker("", selection: $draft.formatRaw) {
                ForEach(Self.sizes, id: \.0) { f, label in Text(label).tag(f.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
        }
        .padding(12).background(Theme.ink.opacity(0.04)).cornerRadius(10)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Clip title", text: $draft.title)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                Spacer()
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).foregroundColor(undoStack.isEmpty ? Theme.ink.opacity(0.2) : .white)
                    .disabled(undoStack.isEmpty).keyboardShortcut("z", modifiers: .command).help("Undo (⌘Z)")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(.plain).foregroundColor(redoStack.isEmpty ? Theme.ink.opacity(0.2) : .white)
                    .disabled(redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo (⇧⌘Z)")
                Text(formatDur(draft.duration)).font(.system(size: 13, design: .monospaced)).foregroundColor(gold).padding(.leading, 8)
                Button { showKeys.toggle() } label: { Image(systemName: "keyboard") }
                    .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.6)).padding(.leading, 8)
                    .help("Keyboard shortcuts (?)")
                    .popover(isPresented: $showKeys, arrowEdge: .bottom) { EditorKeysHelp() }
            }
            .padding(16)
            Divider().background(Theme.ink.opacity(0.08))

            if !volunteer.enabled {
                PillTabs(selection: $workspace, items: [Workspace.edit, .reframe, .audio, .captions].map { ($0, $0.rawValue) })
                    .padding(.top, 12)
            }

            Group {
                switch workspace {
                case .edit: editWorkspace
                case .reframe:
                    ReframeWorkspace(draft: $draft, people: { p in await peopleIn(p) }) { i in framingRow(i) }
                        .padding(16)
                case .audio: audioWorkspace
                case .captions: captionsWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider().background(Theme.ink.opacity(0.08))
            HStack {
                Button("Cancel") {
                    if let original, original != draft { confirmDiscard = true } else { closeEditor() }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave(draft); original = draft; closeEditor() }
                Button {
                    onExport(draft); original = draft; closeEditor()
                } label: {
                    Text(draft.exportedPath == nil ? "Save & Export" : "Save & Re-export")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.onSand)
                        .padding(.horizontal, 14).padding(.vertical, 6).background(gold).cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(draft.includedSentenceCount == 0)
            }
            .padding(16)
        }
        .frame(minWidth: 960, idealWidth: 1280, minHeight: 640, idealHeight: 860)
        .background(Theme.bg)
        .background(WindowAccessor { w in
            editorWindow = w
            closeGuard.allow = {
                if let original, original != draft { confirmDiscard = true; return false }
                player.pause(); return true
            }
            closeGuard.attach(to: w)
        })
        .appLook()
        .confirmationDialog("Discard your changes to this clip?", isPresented: $confirmDiscard) {
            Button("Discard changes", role: .destructive) { closeEditor() }
            Button("Keep editing", role: .cancel) { }
        }
        .onAppear {
            if original == nil { original = draft; lastDraft = draft }
            installKeys()
            // Keys work straight away instead of typing into the title
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.keyWindow?.makeFirstResponder(nil) }
            CommandBar.shared.editorItems = { editorCommands }
            CommandBar.shared.editorAsk = { ask($0) }
        }
        .onChange(of: draft) { new in rememberForUndo(new) }
        .task(id: reloadToken) { await reloadPreview() }
        .task { await askWhoToFollow() }
        .onChange(of: draft.pieces) { _ in reloadToken += 1 }
        .onChange(of: draft.tightenPauses) { _ in reloadToken += 1 }
        .onChange(of: draft.hookText) { _ in rebuildOverlays() }
        .onChange(of: draft.verseCards) { _ in rebuildOverlays() }
        .onChange(of: draft.look) { _ in rebuildOverlays() }
        .onChange(of: draft.formatRaw) { _ in rebuildOverlays() }
        .onChange(of: draft.motion) { _ in rebuildOverlays() }
        .onChange(of: draft.hookStyle) { _ in rebuildOverlays() }
        .onChange(of: draft.seriesTag) { _ in rebuildOverlays() }
        .onChange(of: draft.keywords) { _ in rebuildOverlays() }
        .onDisappear {
            if let o = observer { player.removeTimeObserver(o) }
            player.pause()
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            CommandBar.shared.editorItems = nil
            CommandBar.shared.editorAsk = nil
        }
    }

    // MARK: Asking for a change

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble").foregroundColor(gold).font(.system(size: 13))
                TextField("Say what to change: cut the part about my brother, start at the question…", text: $askText)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.ink)
                    .onSubmit { ask(askText) }
                if askBusy { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) }
                Button("Change") { ask(askText) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.onSand)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(askText.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.ink.opacity(0.15) : gold).cornerRadius(6)
                    .disabled(askText.trimmingCharacters(in: .whitespaces).isEmpty || askBusy)
            }
            .padding(8).background(Theme.ink.opacity(0.06)).cornerRadius(8)
            if let askNote {
                HStack(spacing: 8) {
                    Image(systemName: askNote.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundColor(askNote.ok ? Theme.good : Theme.warn).font(.system(size: 12))
                    Text(askNote.text).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if askNote.ok, !undoStack.isEmpty {
                        Button("Undo") { undo(); self.askNote = nil }.buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(gold)
                    }
                }
            }
        }
    }

    /// What the typed request does. Plain requests are followed here. The rest go to AI, if there is any.
    private func ask(_ raw: String) {
        let req = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty, !askBusy else { return }
        workspace = .edit
        askBusy = true; askNote = nil
        let title = draft.title
        Task { await CostTag.$video.withValue(title) {
            // Plain requests are followed here, so they don't touch the key or cost anything
            if let edits = AskEdit.local(req, draft: draft, aiAvailable: true) {
                applyEdits(edits, note: "")
                askText = ""
            } else if await LLMClipService.shared.canComplete() {
                do {
                    let plan = try await AskEdit.plan(req, draft: draft)
                    if plan.edits.isEmpty { askNote = (plan.note.isEmpty ? "AI wasn't sure what to change." : plan.note, false) }
                    else { applyEdits(plan.edits, note: plan.note); askText = "" }
                } catch { askNote = (error.localizedDescription, false) }
            } else if let edits = AskEdit.local(req, draft: draft, aiAvailable: false), !edits.isEmpty {
                applyEdits(edits, note: "")
                askText = ""
            } else {
                askNote = ("I couldn't find that in this clip. Without AI I can only follow plain requests, like: cut \"these words\", start at the question, or remove the ums.", false)
            }
            askBusy = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        } }
    }

    private func applyEdits(_ edits: [ReelEdit], note: String) {
        var copy = draft
        let r = copy.apply(edits)
        lastChange = .distantPast
        draft = copy
        if r.done.isEmpty {
            askNote = (r.skipped.first ?? "Nothing changed.", false)
        } else {
            askNote = ((r.done + r.skipped).joined(separator: ". ") + ".", true)
        }
    }

    // MARK: Context Guard

    private var guardCard: some View {
        ContextGuardCard(draft: $draft, translation: $translation, busy: guardBusy, error: guardError) { deepCheck() }
    }

    private func deepCheck() {
        guardBusy = true; guardError = nil
        let d = draft, t = translation
        Task { await CostTag.$video.withValue(d.title) {
            do { draft.guardReview = try await ContextGuard.deep(d, translation: t) }
            catch { guardError = error.localizedDescription }
            guardBusy = false
        } }
    }

    // MARK: Keyboard

    /// Letters only act when nothing's being typed, and never while the command bar is up.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handleKey(event) ? nil : event }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !CommandBar.shared.showing, !confirmDiscard,
              event.window === NSApp.keyWindow, event.window != nil, event.window === editorWindow,
              !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlay(); return true                                 // space
        case 123: seekBy(shift ? -1 : -0.1); return true                   // left
        case 124: seekBy(shift ? 1 : 0.1); return true                     // right
        case 126: seekSentence(-1); return true                            // up
        case 125: seekSentence(1); return true                             // down
        case 51, 117: toggleCurrentSentence(); return true                 // delete
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j":
            if player.currentItem?.canPlayReverse == true {
                player.rate = player.rate < 0 ? max(-2, player.rate - 0.5) : -1
                isPlaying = true
            } else { seekBy(-5) }
        case "k":
            player.pause(); isPlaying = false
        case "l":
            if !isPlaying { if time >= total - 0.1 { player.seek(to: .zero) }; player.rate = 1; isPlaying = true }
            else { player.rate = player.rate <= 0 ? 1 : min(2, player.rate + 0.5) }
        case "i": setInOut(isIn: true)
        case "o": setInOut(isIn: false)
        case "x": toggleCurrentSentence()
        case "f": if !volunteer.enabled { focusMode.toggle() }
        case "p": phone = phone.next
        case "?", "/": showKeys.toggle()
        default: return false
        }
        return true
    }

    private func seekBy(_ delta: Double) {
        let t = max(0, min(total, time + delta))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func seekSentence(_ step: Int) {
        guard !timeline.isEmpty else { return }
        let now = timeline.lastIndex { $0.start <= time + 0.05 } ?? 0
        // Going back from partway through a sentence returns to its start first
        let target = step < 0 && time - timeline[now].start > 0.6 ? now : now + step
        guard timeline.indices.contains(target) else { return }
        time = timeline[target].start
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The word at the playhead, even between words.
    private var playheadWord: (id: UUID, word: Int)? {
        guard let ts = timeline.last(where: { $0.start <= time + 0.05 }) ?? timeline.first else { return nil }
        let word = ts.wordStarts.lastIndex { $0 >= 0 && $0 <= time + 0.05 } ?? ts.wordStarts.firstIndex { $0 >= 0 }
        return word.map { (ts.id, $0) }
    }

    private func setInOut(isIn: Bool) {
        guard let w = playheadWord else { return }
        var copy = draft
        if isIn { copy.setIn(sentence: w.id, word: w.word) } else { copy.setOut(sentence: w.id, word: w.word) }
        guard copy.includedSentenceCount > 0 else { return }
        lastChange = .distantPast
        draft = copy
    }

    private func toggleCurrentSentence() {
        guard let w = playheadWord, let (i, j) = draft.locate(sentence: w.id) else { return }
        var copy = draft
        copy.pieces[i].sentences[j].included.toggle()
        guard copy.includedSentenceCount > 0 else { return }
        lastChange = .distantPast
        draft = copy
    }

    // MARK: Command bar

    private var editorCommands: [CommandBar.Item] {
        func item(_ id: String, _ title: String, _ icon: String, _ words: String = "", _ run: @escaping () -> Void) -> CommandBar.Item {
            CommandBar.Item(id: id, title: title, detail: nil, icon: icon, keywords: words, run: run)
        }
        var out: [CommandBar.Item] = [
            item("fillers", "Remove filler words", "scissors", "ums uhs stutters clean") { applyEdits([ReelEdit(op: "fillers")], note: "") },
            item("pauses", draft.pausesTight ? "Leave long pauses in" : "Shorten long pauses", "pause", "silence pace") { applyEdits([ReelEdit(op: "pauses", on: !draft.pausesTight)], note: "") },
            item("captions", draft.captions ? "Turn captions off" : "Turn captions on", "textformat", "subtitles") { applyEdits([ReelEdit(op: "captions", on: !draft.captions)], note: "") },
            item("bigger", "Make captions bigger", "textformat.size.larger", "size font") { applyEdits([ReelEdit(op: "caption_size", value: 1.15)], note: "") },
            item("smaller", "Make captions smaller", "textformat.size.smaller", "size font") { applyEdits([ReelEdit(op: "caption_size", value: 0.87)], note: "") },
            item("phone", phone == .off ? "Preview on a phone" : "Next phone view", "iphone", "shorts clips tiktok safe") { phone = phone.next },
            item("after", "Add the next sentence", "plus.circle", "extend longer") { applyEdits([ReelEdit(op: "extend", text: "after")], note: "") },
            item("before", "Add the sentence before", "plus.circle", "extend longer") { applyEdits([ReelEdit(op: "extend", text: "before")], note: "") },
            item("guard", "Check with Context Guard", "checkmark.shield", "meaning scripture verse") { workspace = .edit; deepCheck() },
        ]
        if !volunteer.enabled {
            out.append(item("focus", focusMode ? "Leave focus mode" : "Focus mode", "rectangle.expand.vertical", "hide distraction") { focusMode.toggle() })
            for w in [Workspace.edit, .reframe, .audio, .captions] {
                out.append(item("tab." + w.rawValue, "Go to \(w.rawValue)", "square.on.square", "tab workspace") { workspace = w })
            }
        }
        out.append(item("keys", "Keyboard shortcuts", "keyboard", "help") { showKeys = true })
        return out
    }

    private func closeEditor() {
        player.pause()
        if let w = editorWindow { w.close() } else { dismiss() }
    }

    // MARK: Undo

    /// Quick changes in a row, like typing a title, undo together.
    private func rememberForUndo(_ new: ReelDraft) {
        defer { lastDraft = new }
        if movingInHistory { movingInHistory = false; return }
        guard let previous = lastDraft, previous != new else { return }
        if Date().timeIntervalSince(lastChange) > 0.6 || undoStack.isEmpty {
            undoStack.append(previous)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        lastChange = Date()
        redoStack = []
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draft)
        movingInHistory = true
        lastChange = .distantPast
        draft = previous
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draft)
        movingInHistory = true
        lastChange = .distantPast
        draft = next
    }

    // MARK: Workspaces

    private var editWorkspace: some View {
        VStack(spacing: 10) {
            HSplitView {
                previewColumn.padding(.trailing, 12)
                    .frame(minWidth: 220, idealWidth: focusMode ? 420 : 320, maxWidth: 760, maxHeight: .infinity, alignment: .top)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            askBar
                            if !focusMode || volunteer.enabled { guardCard }
                            if !focusMode && !volunteer.enabled {
                                whoBanner
                                sizeSection
                                polishSection
                            }
                            Text("MOMENTS — click words to cut them (shift-click a range) · ▶ plays · ✏️ fixes caption text · ? for shortcuts")
                                .font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
                            ForEach(Array(draft.pieces.enumerated()), id: \.element.id) { i, _ in pieceCard(i) }
                        }
                        .padding(.trailing, 6)
                    }
                    // Follow along while playing (not while paused, so manual scrolling isn't fought)
                    .onHover { listHovered = $0 }
                    .onChange(of: playing?.id) { id in
                        guard isPlaying, !listHovered, let id else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .padding(.leading, 12)
                .frame(minWidth: 420, maxHeight: .infinity)
            }
            EditTimeline(draft: draft, timeline: timeline, zooms: zooms, overlays: overlayItems, total: total, time: time) { t in
                time = t
                player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .padding(16)
    }

    private var audioWorkspace: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(draft.pieces.enumerated()), id: \.element.id) { i, piece in
                                ForEach(Array(piece.sentences.enumerated()), id: \.element.id) { j, s in
                                    wordFlow(i, j, activeWord: playing?.id == s.id ? playing?.word : nil, large: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(s.id)
                                }
                            }
                        }
                        .padding(.trailing, 8)
                    }
                    .onHover { listHovered = $0 }
                    .onChange(of: playing?.id) { id in
                        guard isPlaying, !listHovered, let id else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                previewColumn.frame(width: previewAspect < 1 ? 200 : 420)
            }
            .frame(maxHeight: .infinity)
            ReelStrip(asset: previewAsset, token: mediaToken, duration: total, time: time) { t in
                time = t
                player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            audioBar
        }
        .padding(16)
    }

    private var captionsWorkspace: some View {
        HStack(alignment: .top, spacing: 24) {
            previewColumn.frame(maxWidth: previewAspect < 1 ? 280 : .infinity)
                .frame(maxWidth: .infinity)
            CaptionPanel(captions: $draft.captions,
                         look: Binding(get: { look }, set: { var l = $0; l.keywords = []; draft.look = l }), gold: gold)
        }
        .padding(16)
    }

    // MARK: Who to follow

    private func peopleIn(_ piece: ReelDraft.Piece) async -> [ReframePerson] {
        guard let first = piece.sentences.first, let last = piece.sentences.last else { return [] }
        return await Reframe.people(in: piece.sourceVideoPath, from: first.start, to: last.end)
    }

    /// With more than one person on screen, ask who to follow (once per reel).
    private func askWhoToFollow() async {
        guard draft.reframeAsked != true, previewAspect < sourceAspect,
              draft.pieces.allSatisfy({ $0.framing == nil }), let first = draft.pieces.first else { return }
        let found = await peopleIn(first)
        if found.count >= 2 { crew = found }
    }

    private func follow(_ framing: ReelDraft.Framing?) {
        draft.reframeAsked = true
        for i in draft.pieces.indices { draft.pieces[i].framing = framing }
        crew = []
    }

    @ViewBuilder private var whoBanner: some View {
        if !crew.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(crew.count) people found. Who should this clip follow?").font(Theme.display(15)).foregroundColor(Theme.cream)
                HStack(spacing: 12) {
                    ForEach(Array(crew.enumerated()), id: \.element.id) { i, person in
                        ReframeTile(title: "Person \(i + 1)", selected: false) {
                            Image(nsImage: person.face).resizable().scaledToFill()
                        } action: { follow(ReelDraft.Framing(mode: "person", x: person.x, t: person.time)) }
                    }
                    ReframeTile(title: "Whoever's talking", selected: false) {
                        Image(systemName: "waveform").font(.system(size: 20)).foregroundColor(gold)
                    } action: { follow(nil) }
                    Spacer()
                    Button("See before & after") { workspace = .reframe }.controlSize(.small)
                }
            }
            .padding(12).background(gold.opacity(0.08)).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(gold.opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                FillPlayerView(player: player)
                    .scaleEffect(ReelMotion.scale(at: time, zooms))
                    .animation(.linear(duration: 0.05), value: time)
                if let img = ReelOverlays.previewImage(overlayItems, time: time, size: overlaySize) {
                    Image(nsImage: img).resizable().allowsHitTesting(false)
                }
                if draft.captions, let img = captionOverlay() {
                    Image(nsImage: img).resizable().allowsHitTesting(false)
                }
                if phone != .off, draft.formatRaw == VideoExportService.ExportFormat.vertical9x16.rawValue { PhoneChrome(view: phone) }
            }
            .aspectRatio(previewAspect, contentMode: .fit)
            .clipped()
            .cornerRadius(phone == .off ? 8 : 18)
            .phoneBezel(draft.formatRaw == VideoExportService.ExportFormat.vertical9x16.rawValue ? phone : .off)
            .onTapGesture { togglePlay() }

            HStack(spacing: 8) {
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").foregroundColor(gold)
                }.buttonStyle(.plain)
                Slider(value: Binding(get: { time }, set: { t in
                    time = t; player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }), in: 0...max(total, 0.1)).tint(Theme.action)
                Text(formatDur(time)).font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.ink.opacity(0.55))
            }
            PhoneViewMenu(view: Binding(get: { phone }, set: { phone = $0 }))
            TipView(PhoneViewTip())
            if phone != .off, draft.formatRaw != VideoExportService.ExportFormat.vertical9x16.rawValue {
                Text("Phone view is for 9:16 clips.").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
            } else if phone != .off, draft.captions, phone.captionsCovered(look) {
                VStack(spacing: 4) {
                    Text("Captions sit behind \(phone.label)'s text.").font(.system(size: 11.5)).foregroundColor(Theme.warn).multilineTextAlignment(.center)
                    Button("Move them up") { applyEdits([ReelEdit(op: "caption_position", value: phone.safeCaptionPosition)], note: "") }
                        .controlSize(.small)
                }
            } else if phone != .off {
                Text("Shaded areas are close estimates of what the app covers.").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55)).multilineTextAlignment(.center)
            }
            Text(following ? "Finding the speaker…" : "The preview follows the speaker like the export does.")
                .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55)).multilineTextAlignment(.center)
        }
    }

    /// Re-crops the preview to follow whoever is talking (same tracking as the export, cached)
    private func followSpeaker(_ item: AVPlayerItem) {
        followTask?.cancel()
        following = true
        let d = draft
        followTask = Task {
            let vc = await Task.detached(priority: .userInitiated) { await d.followComposition(for: item) }.value
            guard !Task.isCancelled else { return }
            if player.currentItem === item, let vc { item.videoComposition = vc }
            following = false
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
        previewAsset = item.asset
        followSpeaker(item)
        reelWords = words
        rebuildOverlays()
        timeline = draft.sentenceTimeline
        if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = size.applying(t)
            if abs(r.height) > 0 { sourceAspect = abs(r.width) / abs(r.height) }
        }
        total = max(0.1, draft.duration)
        mediaToken += 1
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
        look.overlayImage(words: reelWords, time: time, size: CGSize(width: 540, height: 540 / previewAspect))
    }

    // MARK: Captions

    // MARK: Polish (hook, verses, pauses, fillers)

    private var overlaySize: CGSize { CGSize(width: 540, height: 540 / previewAspect) }

    private func rebuildOverlays() {
        let verses = draft.showVerses ? VerseDetector.find(in: reelWords) : []
        zooms = ReelMotion.zooms(draft)
        overlayItems = ReelOverlays.layout(hook: draft.hook, verses: verses, look: look,
                                           size: overlaySize, duration: max(total, draft.duration),
                                           hookStyle: draft.hookAnimation, tag: draft.seriesTag)
    }

    private var detectedVerses: [String] {
        var seen: [String] = []
        for v in VerseDetector.find(in: reelWords) where !seen.contains(v.text) { seen.append(v.text) }
        return seen
    }

    private var polishSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("POLISH").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55)).tracking(1)
                Spacer()
                if recordID != nil, otherDraftCount > 0 {
                    Menu("Apply to all \(otherDraftCount + 1) clips") {
                        Button("Caption style") { applyToAll([.captions]) }
                        Button("Hook animation") { applyToAll([.hookStyle]) }
                        Button("Movement") { applyToAll([.motion]) }
                        Button("Size") { applyToAll([.size]) }
                        Button("Voice and music") { applyToAll([.audio]) }
                        Button("Verse cards and pauses") { applyToAll([.toggles]) }
                        Divider()
                        Button("All of these") { applyToAll(ApplyPart.allCases) }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                    .help("Use this clip's settings on every clip from this sermon")
                }
            }
            if let applyNote { Text(applyNote).font(.system(size: 11.5)).foregroundColor(Theme.good) }

            // Hook text
            VStack(alignment: .leading, spacing: 5) {
                Text("Hook text (first 3 seconds)").font(.system(size: 13)).foregroundColor(Theme.ink)
                HStack(spacing: 6) {
                    TextField("e.g. \"You\'re carrying something you were never meant to\"",
                              text: Binding(get: { draft.hookText ?? draft.seo?.hookText ?? "" },
                                            set: { draft.hookText = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.ink)
                        .padding(6).background(Theme.ink.opacity(0.06)).cornerRadius(5)
                    Button { writeHook() } label: { Label("Write", systemImage: "sparkles") }
                        .controlSize(.small).disabled(hookStatus != nil)
                        .help("Have AI write a hook from what's said in this clip")
                    if draft.hook != nil {
                        Button { draft.hookText = "" } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.55)).help("No hook")
                    }
                }
                if let hookStatus {
                    Text(hookStatus).font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
            }

            // How the hook arrives
            HStack(spacing: 8) {
                Text("Hook animation").font(.system(size: 13)).foregroundColor(Theme.ink)
                Spacer()
                Picker("", selection: Binding(get: { draft.hookAnimation }, set: { draft.hookStyle = $0.rawValue })) {
                    ForEach(HookStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                Button { replayFromStart() } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.6)).help("Watch the opening again")
            }

            TipView(MovementTip())
            // Movement in the picture
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Movement").font(.system(size: 13)).foregroundColor(Theme.ink)
                    Text(zooms.isEmpty ? "A punch-in on the strongest lines, a slow push through long stretches"
                                       : "\(zooms.filter(\.punch).count) punch-in\(zooms.filter(\.punch).count == 1 ? "" : "s"), \(zooms.filter { !$0.punch }.count) slow push\(zooms.filter { !$0.punch }.count == 1 ? "" : "es")")
                        .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
                Spacer()
                Picker("", selection: Binding(get: { ReelMotion.Style(rawValue: draft.motion ?? "") ?? .off }, set: { draft.motion = $0.rawValue; MovementTip().invalidate(reason: .actionPerformed) })) {
                    ForEach(ReelMotion.Style.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }

            seriesRow

            Divider().background(Theme.ink.opacity(0.06))

            // Highlighted caption words
            VStack(alignment: .leading, spacing: 5) {
                Text("Key words in the captions").font(.system(size: 13)).foregroundColor(Theme.ink)
                TextField("e.g. grace, free, enough",
                          text: Binding(get: { (draft.keywords ?? []).joined(separator: ", ") },
                                        set: { draft.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.ink)
                    .padding(6).background(Theme.ink.opacity(0.06)).cornerRadius(5)
                Text("These words stand out in the caption's key-word colour\(draft.showVerses ? ", along with Bible references" : "").")
                    .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
            }

            Divider().background(Theme.ink.opacity(0.06))

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hopeful ending").font(.system(size: 13)).foregroundColor(Theme.ink)
                    Text(endingStatus ?? "Ends on a downer? AI adds a \"But God…\" moment from this message as the last clip")
                        .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { addHopefulEnding() } label: { Label("Add", systemImage: "sparkles") }
                    .controlSize(.small).disabled(endingStatus == "Finding the hope in this message…")
            }

            Divider().background(Theme.ink.opacity(0.06))

            Toggle(isOn: Binding(get: { draft.showVerses }, set: { draft.verseCards = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bible verse cards").font(.system(size: 13)).foregroundColor(Theme.ink)
                    let found = detectedVerses
                    Text(found.isEmpty ? "Shows the reference when Scripture is quoted — none spoken in this clip"
                                       : "Found: " + found.joined(separator: ", "))
                        .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55)).lineLimit(2)
                }
            }.toggleStyle(.switch).tint(Theme.action)

            Toggle(isOn: Binding(get: { draft.pausesTight }, set: { draft.tightenPauses = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shorten long pauses").font(.system(size: 13)).foregroundColor(Theme.ink)
                    Text("Trims silences longer than half a second for a faster pace")
                        .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
            }.toggleStyle(.switch).tint(Theme.action)

            HStack {
                let n = draft.fillerWordIDs.count
                VStack(alignment: .leading, spacing: 1) {
                    Text("Filler words").font(.system(size: 13)).foregroundColor(Theme.ink)
                    Text(fillerNote ?? (n == 0 ? "No ums, uhs or stutters left" : "\(n) um/uh/stutter\(n == 1 ? "" : "s") found"))
                        .font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
                Spacer()
                Button("Remove all") {
                    let removed = draft.cutFillers()
                    fillerNote = "Removed \(removed) — click a word to bring one back"
                }
                .controlSize(.small).disabled(n == 0)
            }
        }
        .padding(12).background(Theme.ink.opacity(0.04)).cornerRadius(10)
    }

    enum ApplyPart: CaseIterable { case captions, hookStyle, motion, size, audio, toggles }

    private var otherDraftCount: Int {
        guard let recordID, let rec = AutoReelsStore.shared.reels.first(where: { $0.id == recordID }) else { return 0 }
        return (rec.drafts ?? []).filter { $0.id != draft.id }.count
    }

    /// Copies this clip's settings onto the other clips from the same sermon, and saves them.
    private func applyToAll(_ parts: [ApplyPart]) {
        guard let recordID, var rec = AutoReelsStore.shared.reels.first(where: { $0.id == recordID }) else { return }
        var changed = 0
        rec.drafts = (rec.drafts ?? []).map { other in
            guard other.id != draft.id else { return other }
            var o = other
            for p in parts {
                switch p {
                case .captions: o.captions = draft.captions; o.look = draft.look
                case .hookStyle: o.hookStyle = draft.hookStyle
                case .motion: o.motion = draft.motion
                case .size: o.formatRaw = draft.formatRaw
                case .audio: o.audio = draft.audio
                case .toggles: o.verseCards = draft.verseCards; o.tightenPauses = draft.tightenPauses
                }
            }
            if o != other {
                changed += 1
                if o.exportedPath != nil { o.editedSinceExport = true }
            }
            return o
        }
        AutoReelsStore.shared.update(rec)
        applyNote = changed == 0 ? "The other clips already match." : "Applied to \(changed) other clip\(changed == 1 ? "" : "s")."
    }

    private func replayFromStart() {
        time = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); isPlaying = true
    }

    // MARK: Series look

    private var sourcePath: String { draft.pieces.first?.sourceVideoPath ?? "" }

    @ViewBuilder private var seriesRow: some View {
        let series = seriesStore.series(containing: sourcePath)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundColor(gold.opacity(0.8))
                if let series {
                    Text("Series: \(series.name)").font(.system(size: 13)).foregroundColor(Theme.ink).lineLimit(1)
                    Spacer()
                    if series.look != nil {
                        Button("Use series look") { draft.applySeries(series); seriesNote = "Series look applied." }.controlSize(.small)
                    }
                    Button(series.look == nil ? "Save as series look" : "Update series look") { saveSeriesLook(series) }.controlSize(.small)
                        .help("Every new clip from this series' messages will look like this one")
                } else {
                    Text("Not part of a series").font(.system(size: 13)).foregroundColor(Theme.ink.opacity(0.6))
                    Spacer()
                    Menu("Add to a series") {
                        ForEach(seriesStore.series) { s in Button(s.name) { addToSeries(s) } }
                        if !seriesStore.series.isEmpty { Divider() }
                        Button("New series…") { showNewSeries = true }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if let series {
                Toggle(isOn: Binding(get: { draft.seriesTag != nil }, set: { on in
                    if on {
                        let part = series.videos.firstIndex(of: sourcePath).map { " · PART \($0 + 1)" } ?? ""
                        draft.seriesTag = ((series.look?.tag?.isEmpty == false ? series.look!.tag! : series.name) + part).uppercased()
                    } else { draft.seriesTag = nil }
                })) {
                    Text("Show the series name on the clip").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.7))
                }
                .toggleStyle(.switch).controlSize(.mini).tint(Theme.action)
            }
            if showNewSeries {
                HStack {
                    TextField("Series name, like Baggage", text: $newSeriesName).textFieldStyle(.roundedBorder).font(.system(size: 13))
                        .onSubmit { createSeries() }
                    Button("Create") { createSeries() }.controlSize(.small).disabled(newSeriesName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { showNewSeries = false }.controlSize(.small)
                }
            }
            if let seriesNote { Text(seriesNote).font(.system(size: 11.5)).foregroundColor(Theme.good) }
        }
    }

    private func saveSeriesLook(_ s: SermonSeries) {
        var copy = s
        copy.look = SeriesLook(look: draft.look ?? CaptionLook.load(), hookStyle: draft.hookStyle, motion: draft.motion,
                               tag: copy.look?.tag, showTag: draft.seriesTag != nil)
        seriesStore.upsert(copy)
        seriesNote = "Saved. New clips from \(s.name) will use this look."
    }

    private func addToSeries(_ s: SermonSeries) {
        var copy = s
        if !copy.videos.contains(sourcePath) { copy.videos.append(sourcePath) }
        seriesStore.upsert(copy)
        if copy.look != nil { draft.applySeries(copy); seriesNote = "Added, and the series look applied." } else { seriesNote = "Added to \(s.name)." }
    }

    private func createSeries() {
        let name = newSeriesName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        seriesStore.upsert(SermonSeries(name: name, videos: [sourcePath]))
        newSeriesName = ""; showNewSeries = false
        seriesNote = "Created \(name). Save this clip's look to use it for the whole series."
    }

    /// Appends the talk's "But God…" moment (picked by AI) as a final clip.
    private func addHopefulEnding() {
        guard let source = draft.pieces.last?.sourceVideoPath ?? draft.pieces.first?.sourceVideoPath else { return }
        endingStatus = "Finding the hope in this message…"
        let reelText = draft.renderClips.flatMap(\.words).map(\.word).joined(separator: " ")
        let inReelWords = Set(draft.pieces.flatMap { $0.sentences.filter(\.included).flatMap { $0.words.map(\.id) } })
        Task {
            do {
                let provider = LLMClipService.AIProvider(rawValue: UserDefaults.standard.string(forKey: "ar_provider") ?? "") ?? .google
                guard let key = await LLMClipService.shared.loadAPIKey(for: provider), !key.isEmpty else {
                    endingStatus = "Add an API key in AutoClip → Settings → AI to use this."
                    return
                }
                guard let words = TranscriptCache.load(for: source) else {
                    endingStatus = "Couldn't find this message's transcript."
                    return
                }
                let sentences = ReelDraft.sentences(from: words)
                var inReel = Set<Int>()
                for (i, s) in sentences.enumerated() where s.words.contains(where: { inReelWords.contains($0.id) }) { inReel.insert(i) }
                let r = try await LLMClipService.shared.findHopefulEnding(
                    sentences: sentences.map { ($0.start, $0.end, $0.text) }, reelText: reelText,
                    inReel: inReel, provider: provider, apiKey: key)
                draft.pieces.append(ReelDraft.Piece(sourceVideoPath: source, sentences: Array(sentences[r])))
                let added = sentences[r].map(\.text).joined(separator: " ")
                endingStatus = "Added as the last clip: \"\(added.prefix(110))\(added.count > 110 ? "…" : "")\""
            } catch {
                endingStatus = error.localizedDescription
            }
        }
    }

    private func writeHook() {
        hookStatus = "Writing a hook…"
        let transcript = reelWords.map(\.word).joined(separator: " ")
        let title = draft.title
        Task {
            do {
                let provider = LLMClipService.AIProvider(rawValue: UserDefaults.standard.string(forKey: "ar_provider") ?? "") ?? .google
                let key = await LLMClipService.shared.loadAPIKey(for: provider) ?? ""
                let local = key.isEmpty ? await LocalAI.ready() : false
                guard !key.isEmpty || local else {
                    hookStatus = "Add an API key in AutoClip → Settings → AI (or turn on on-device AI) to write hooks with AI."
                    return
                }
                let hook = try await LLMClipService.shared.writeHook(transcript: transcript, title: title,
                                                                    provider: provider, apiKey: key)
                draft.hookText = hook
                hookStatus = nil
            } catch {
                hookStatus = error.localizedDescription
            }
        }
    }

    // MARK: Audio

    private var audio: Binding<AudioSettings> {
        Binding(get: { draft.audioSettings }, set: { draft.audio = $0; $0.save() })
    }

    private var audioBar: some View {
        HStack(spacing: 18) {
            Toggle(isOn: audio.cleanVoice) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean up voice").font(.system(size: 13)).foregroundColor(Theme.ink)
                    Text("Removes echo, hum and noise").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
            }.toggleStyle(.switch).tint(Theme.action).fixedSize()
            if audio.wrappedValue.cleanVoice {
                Slider(value: audio.strength, in: 0.3...1).tint(Theme.action).frame(width: 90).help("How strongly the voice is cleaned")
            }
            Toggle(isOn: audio.levelVoice) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Even out volume").font(.system(size: 13)).foregroundColor(Theme.ink)
                    Text("Steady loud and quiet moments").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
            }.toggleStyle(.switch).tint(Theme.action).fixedSize()
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text("Background music").font(.system(size: 13)).foregroundColor(Theme.ink)
                Text(audio.wrappedValue.musicName ?? "Dips under speech").font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55)).lineLimit(1)
            }.frame(maxWidth: 130, alignment: .leading)
            if audio.wrappedValue.musicPath != nil {
                Slider(value: audio.musicVolume, in: 0.03...0.35).tint(Theme.action).frame(width: 80).help("Music volume")
                Button { audio.wrappedValue.musicPath = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.55)).help("Remove music")
            }
            Button("Choose…") { chooseMusic() }.controlSize(.small)
        }
        .padding(12).background(Theme.ink.opacity(0.04)).cornerRadius(10)
        .help("Audio changes are applied when you export.")
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.title = "Choose background music"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        audio.wrappedValue.musicPath = url.path
    }

    // MARK: Clips

    private func pieceCard(_ i: Int) -> some View {
        let piece = draft.pieces[i]
        let dur = draft.playingLength(ofPiece: i)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    .help("Drag to move this moment")
                    .onDrag { draggingPiece = piece.id; return NSItemProvider(object: piece.id.uuidString as NSString) }
                Text("Moment \(i + 1)").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                Text(formatDur(dur)).font(.system(size: 12, design: .monospaced)).foregroundColor(gold)
                Spacer()
                Button { jump(toPiece: i) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(0.6)).help("Preview from here")
                Button { move(i, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(i == 0 ? 0.15 : 0.6)).disabled(i == 0)
                Button { move(i, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.plain).foregroundColor(Theme.ink.opacity(i == draft.pieces.count - 1 ? 0.15 : 0.6))
                    .disabled(i == draft.pieces.count - 1)
                Button { draft.pieces.remove(at: i) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundColor(Theme.danger).help("Remove this moment")
            }
            framingRow(i)
            neighbourButton(i, before: true)
            ForEach(Array(piece.sentences.enumerated()), id: \.element.id) { j, s in
                // A sentence with every word cut has nothing to adjust, so the row goes to the next one that plays
                let plays = { (k: Int) in piece.sentences.indices.contains(k) && !piece.sentences[k].keptWords.isEmpty }
                let startsRun = plays(j) && !plays(j - 1)
                let endsRun = plays(j) && !plays(j + 1)
                if startsRun { nudgeRow(piece: i, sentence: j, isStart: true) }
                let now = playing?.id == s.id ? playing : nil
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        draft.pieces[i].sentences[j].included.toggle()
                        if !draft.pieces[i].sentences[j].included { TasteStore.shared.removedSentence() }
                    } label: {
                        Image(systemName: s.included ? "checkmark.square.fill" : "square")
                            .foregroundColor(s.included ? gold : Theme.ink.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help(s.included ? "Cut this sentence out" : "Put this sentence back")
                    if editingSentence == s.id {
                        TextField("Caption text", text: $editText, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(Theme.ink)
                            .padding(4).background(Theme.ink.opacity(0.08)).cornerRadius(4)
                            .onSubmit { commitEdit(i, j) }
                        Button("Done") { commitEdit(i, j) }.buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(gold)
                        Button("Cancel") { editingSentence = nil }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    } else {
                        wordFlow(i, j, activeWord: now?.word)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if s.included {
                            Button { play(from: s.id) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
                                .help("Play from this sentence")
                        }
                        Button { editText = s.text; editingSentence = s.id } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
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
            neighbourButton(i, before: false)
            Text("Words in red were cut — click one to put it back. Untick a sentence to drop it.")
                .font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
        }
        .padding(12)
        .background(Theme.ink.opacity(draggingPiece == piece.id ? 0.1 : 0.04))
        .cornerRadius(10)
        .opacity(piece.sentences.filter(\.included).isEmpty ? 0.5 : 1)
        .onDrop(of: [.text], delegate: PieceDrop(target: piece.id, draft: $draft, dragging: $draggingPiece))
    }

    /// Brings in the sentence just before or after this clip from the full message.
    private func neighbourButton(_ i: Int, before: Bool) -> some View {
        HStack(spacing: 8) {
        Button {
            if draft.addNeighbour(piece: i, before: before) == nil {
                neighbourNote = (draft.pieces[i].id, before ? "This moment already starts at the beginning of the message." : "This moment already runs to the end of the message.")
            } else {
                neighbourNote = nil
                TasteStore.shared.addedSentence(before: before)
                if let s = before ? draft.pieces[i].sentences.first : draft.pieces[i].sentences.last {
                    // Let the new words settle into the preview, then play them
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { play(from: s.id) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: before ? "plus.circle" : "plus.circle")
                Text(before ? "Add the sentence before" : "Add the sentence after")
            }
            .font(.system(size: 11.5, weight: .medium)).foregroundColor(gold.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().stroke(gold.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(before ? "Bring back what was said just before this clip" : "Bring back what was said just after this clip")
        if let note = neighbourNote, note.piece == draft.pieces[i].id, note.text.contains("beginning") == before {
            Text(note.text).font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
        }
        }
    }

    /// Split screen: find where the two people sit so each half frames one of them.
    private func findTwoPeople(_ i: Int) {
        let piece = draft.pieces[i]
        guard let first = piece.sentences.first, let last = piece.sentences.last else { return }
        splitNote[piece.id] = "Finding the two people…"
        Task {
            let xs = await VideoExportService.shared.twoPeople(in: piece.sourceVideoPath, from: first.start, to: last.end)
            guard let k = draft.pieces.firstIndex(where: { $0.id == piece.id }), draft.pieces[k].framing?.mode == "split" else { return }
            if let xs {
                draft.pieces[k].framing = ReelDraft.Framing(mode: "split", x: (xs[0] * 100).rounded() / 100, x2: (xs[1] * 100).rounded() / 100)
                splitNote[piece.id] = "Found two people. Drag to adjust who's on top or bottom."
            } else {
                splitNote[piece.id] = "Couldn't find two people clearly, so it's split down the middle. Drag to adjust."
            }
        }
    }

    /// How the vertical crop follows the speaker in this clip.
    private func framingRow(_ i: Int) -> some View {
        let f = draft.pieces[i].framing ?? ReelDraft.Framing(mode: "auto")
        let mode = Binding<String>(get: { f.mode }, set: { m in
            var nf = draft.pieces[i].framing ?? ReelDraft.Framing(mode: m)
            nf.mode = m
            if m == "split" { nf.x = 0.25; nf.x2 = 0.75 }
            draft.pieces[i].framing = m == "auto" ? nil : nf
            if m == "split" { findTwoPeople(i) }
        })
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle").font(.system(size: 11.5)).foregroundColor(gold.opacity(0.8))
                Text("Framing").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55))
                PillTabs(selection: mode, items: (f.mode == "person" ? [("person", "Chosen person")] : []) + [("auto", "Follow speaker"), ("careful", "Look closer"), ("fixed", "Hold still"), ("split", "Split screen")], compact: true)
                Spacer(minLength: 0)
            }
            if f.mode == "careful" {
                Text("Checks this clip twice as often and catches smaller faces. Use it where the frame drifted off the person.")
                    .font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
            } else if f.mode == "fixed" {
                HStack(spacing: 6) {
                    Text("Left").font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
                    Slider(value: Binding(get: { f.x }, set: { v in
                        draft.pieces[i].framing = ReelDraft.Framing(mode: "fixed", x: (v * 100).rounded() / 100)
                    }), in: 0...1)
                    .controlSize(.mini)
                    Text("Right").font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
                }
                Text("The frame stays put on this part of the video for the whole clip.")
                    .font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
            }
            else if f.mode == "split" {
                ForEach(0..<2, id: \.self) { k in
                    HStack(spacing: 6) {
                        Text(k == 0 ? "Top" : "Bottom").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.ink.opacity(0.55))
                            .frame(width: 40, alignment: .leading)
                        Text("Left").font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
                        Slider(value: Binding(get: { k == 0 ? f.x : (f.x2 ?? 0.75) }, set: { v in
                            var nf = draft.pieces[i].framing ?? ReelDraft.Framing(mode: "split")
                            if k == 0 { nf.x = (v * 100).rounded() / 100 } else { nf.x2 = (v * 100).rounded() / 100 }
                            draft.pieces[i].framing = nf
                        }), in: 0...1)
                        .controlSize(.mini)
                        Text("Right").font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
                    }
                }
                Text(splitNote[draft.pieces[i].id] ?? "Two people stacked: one on top, one below. Best for interviews and podcasts shot wide.")
                    .font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(Theme.ink.opacity(0.03)).cornerRadius(5)
    }

    /// The sentence as clickable words. Click a word to cut it (click again to restore);
    /// shift-click to cut/restore everything from the last clicked word. While playing,
    /// the spoken word lights up in gold.
    private func wordFlow(_ i: Int, _ j: Int, activeWord: Int?, large: Bool = false) -> some View {
        let s = draft.pieces[i].sentences[j]
        return WordFlowLayout(spacing: 4, lineSpacing: 2) {
            ForEach(Array(s.words.enumerated()), id: \.element.id) { k, w in
                let cut = s.isCut(w)
                let isActive = activeWord == k && !cut
                Text(w.word)
                    .font(.system(size: large ? 15 : 12, weight: isActive ? .bold : .regular))
                    .foregroundColor(!s.included ? Theme.ink.opacity(0.3)
                                     : cut ? (large ? Theme.ink.opacity(0.3) : Theme.danger.opacity(0.7))
                                     : isActive ? gold
                                     : (activeWord.map { k < $0 } ?? false) ? .white : Theme.ink.opacity(0.85))
                    .strikethrough(!s.included || cut, color: cut && !large ? Theme.danger : nil)
                    .padding(.horizontal, 1)
                    .background(cut ? Theme.danger.opacity(0.12) : Color.clear)
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
        NSApp.keyWindow?.makeFirstResponder(nil)
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
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isStart ? "arrow.right.to.line" : "arrow.left.to.line")
                    .font(.system(size: 11.5)).foregroundColor(gold.opacity(0.8))
                Text(isStart ? "Starts" : "Ends").font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.ink.opacity(0.55))
                Text("drag the handle").font(.system(size: 11)).foregroundColor(Theme.ink.opacity(0.55))
                Spacer(minLength: 0)
                nudgeButton("−0.1", i, j, isStart, -0.1)
                Text(value == 0 ? "0.0s" : String(format: "%+.2fs", value))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(value == 0 ? Theme.ink.opacity(0.4) : gold)
                    .frame(width: 48)
                nudgeButton("+0.1", i, j, isStart, 0.1)
                if value != 0 {
                    Button("Reset") { setNudge(i, j, isStart, nil) }
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundColor(Theme.ink.opacity(0.55))
                }
                Button { audition(i, j, isStart) } label: { Image(systemName: "ear") }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.ink.opacity(0.55))
                    .help("Play across this cut")
            }
            CutTrimmer(path: draft.pieces[i].sourceVideoPath, base: isStart ? s.startBase : s.endBase, isStart: isStart, value: value,
                       sentenceWords: s.words, cutIDs: Set(s.cutWordIDs ?? [])) { v in
                setNudge(i, j, isStart, v == 0 ? nil : v)
                audition(i, j, isStart)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(Theme.ink.opacity(0.03)).cornerRadius(5)
    }

    private func nudgeButton(_ label: String, _ i: Int, _ j: Int, _ isStart: Bool, _ delta: Double) -> some View {
        Button(label) {
            let s = draft.pieces[i].sentences[j]
            let cur = (isStart ? s.startNudge : s.endNudge) ?? 0
            // Limit to ±5s so a cut can't swallow a neighbouring thought by accident
            let next = (min(5, max(-5, cur + delta)) * 100).rounded() / 100
            setNudge(i, j, isStart, next == 0 ? nil : next)
            audition(i, j, isStart)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
        .foregroundColor(Theme.ink)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Theme.ink.opacity(0.08)).cornerRadius(4)
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
struct FillPlayerView: NSViewRepresentable {
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
