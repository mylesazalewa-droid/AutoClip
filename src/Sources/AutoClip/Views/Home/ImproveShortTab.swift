import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Drop in a finished short and get a review, with each fix ready to switch on or off,
/// then compare before and after. The original file is never changed.
struct ImproveShortTab: View {
    @ObservedObject private var model = ShortDoctorModel.shared
    @State private var dropping = false
    @State private var confirmDelete: ShortReview?

    var body: some View {
        Group {
            if let status = model.status { working(status) }
            else if let r = model.current { ShortReviewPage(review: r).id(r.path) }
            else { landing }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func working(_ text: String) -> some View {
        VStack(spacing: 12) {
            Text("Reviewing your short").font(Theme.display(26, weight: .medium)).foregroundColor(.white)
            ProgressView(value: model.progress).tint(Theme.action).frame(width: 340)
            Text(text).font(.system(size: 12)).foregroundColor(Theme.muted)
            Button("Cancel") { model.cancel() }.buttonStyle(SecondaryButtonStyle(compact: true))
        }
    }

    private var landing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                CinematicHero(path: nil, eyebrow: "Create", title: "Improve a Short",
                              detail: "Drop in a video you've already made. AutoClip looks for a stronger hook, silences to cut and a better order, and you choose what to keep. Your original file isn't changed.",
                              height: 400, icon: "wand.and.stars") {
                    Button { choose() } label: { Label("Choose a video", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                }
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.sand, lineWidth: dropping ? 2 : 0))
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    guard let p = providers.first else { return false }
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        DispatchQueue.main.async { model.start(url) }
                    }
                    return true
                }
                if let e = model.error {
                    Text(e).font(.system(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                Text("Works best on someone talking to camera, from the version without music or captions. On-screen text and music can't be separated once they're in the video.")
                    .font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if !model.reviews.isEmpty {
                    SectionTitle(title: "Your reviews", count: model.reviews.count)
                    ForEach(model.reviews) { r in row(r) }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
        }
        .confirmationDialog("Delete this review?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { r in
            Button("Delete", role: .destructive) { model.delete(r) }
            Button("Cancel", role: .cancel) { }
        } message: { r in
            Text("This removes the review of \(r.title). Your video isn't deleted.")
        }
    }

    private func row(_ r: ShortReview) -> some View {
        HStack(spacing: 8) {
            Button { model.currentPath = r.path } label: {
                HStack(spacing: 14) {
                    VideoFrameView(path: r.path, width: 320).frame(width: 64, height: 84).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream).lineLimit(1)
                        Text("\(assessTime(r.duration)) · reviewed \(r.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 11)).foregroundColor(Theme.muted)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { confirmDelete = r } label: { Image(systemName: "trash").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundColor(Theme.muted).padding(8).help("Delete this review")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseDirectories = false
        panel.message = "Choose the short you'd like to improve"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.start(url)
    }
}

/// One review: the video on the left, the suggestions on the right.
private struct ShortReviewPage: View {
    @State var review: ShortReview
    @ObservedObject private var model = ShortDoctorModel.shared
    @State private var player = AVPlayer()
    @State private var showAfter = true
    @State private var aspect: CGFloat = 9 / 16
    @State private var time = 0.0
    @State private var observer: Any?
    @State private var buildError: String?
    @State private var saving: Double?
    @State private var saveTask: Task<Void, Never>?
    @State private var saved: URL?
    @State private var saveError: String?
    private let gold = Theme.sand

    private var ranges: [ClosedRange<Double>] { ShortDoctor.ranges(review) }
    private var lines: [ReelDraft.Sentence] { review.lines }
    /// Anything that changes the edit, to know when to rebuild the "after"
    private var editKey: String { "\(ranges.map { "\($0.lowerBound)-\($0.upperBound)" })|\(showAfter)" }

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            videoColumn.frame(width: aspect < 1 ? 380 : 620)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scores
                    warnings
                    hookCard
                    pacingCard
                    if review.order != nil { orderCard }
                    if review.ending != nil { endingCard }
                    linesCard
                }
                .padding(.bottom, 30).padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 14)
        .task(id: editKey) { await reloadPlayer() }
        .onAppear {
            Backdrop.shared.path = review.path
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { t in time = t.seconds.isNaN ? 0 : t.seconds }
        }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
        }
        .onChange(of: review) { r in model.save(r) }
    }

    private func reloadPlayer() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        buildError = nil
        if let track = try? await AVURLAsset(url: URL(fileURLWithPath: review.path)).loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let box = CGRect(origin: .zero, size: size).applying(t)
            if box.height != 0 { aspect = abs(box.width / box.height) }
        }
        if showAfter {
            do {
                let (comp, mix, _, _) = try await ShortDoctor.composition(review)
                let item = AVPlayerItem(asset: comp)
                item.audioMix = mix
                player.replaceCurrentItem(with: item)
            } catch { buildError = error.localizedDescription }
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: review.path)))
        }
    }

    // MARK: Video

    private var videoColumn: some View {
        VStack(spacing: 12) {
            HStack {
                Button { player.pause(); model.currentPath = nil } label: {
                    Label("All shorts", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)).foregroundColor(gold)
                }
                .buttonStyle(.plain)
                Spacer()
                PillTabs(selection: $showAfter, items: [(false, "Before"), (true, "After")], compact: true)
            }
            ZStack(alignment: .top) {
                VideoPlayer(player: player)
                if showAfter, review.choices.useHookText, time < 3, !review.choices.hookText.isEmpty {
                    Text(review.choices.hookText).font(.system(size: 17, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.7)))
                        .padding(.top, 54).padding(.horizontal, 16)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: 720)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))

            if let buildError { Text(buildError).font(.system(size: 11)).foregroundColor(Theme.danger) }
            let after = ShortDoctor.length(of: ranges)
            Text("\(assessTime(review.duration)) → \(assessTime(after)) · \(Int((review.duration - after).rounded()))s shorter")
                .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text).monospacedDigit()
            if let p = saving {
                HStack(spacing: 10) {
                    ProgressView(value: p).tint(Theme.action)
                    Button("Cancel") { saveTask?.cancel() }.controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    Button { save() } label: { Label("Save improved video", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(ranges.isEmpty)
                    if let saved {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            if let saveError { Text(saveError).font(.system(size: 11)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = "Save the improved video"
        panel.nameFieldStringValue = "\(review.title) (improved).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = URL(fileURLWithPath: review.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.pause()
        saved = nil; saveError = nil; saving = 0
        let r = review
        saveTask = Task {
            do {
                try await ShortDoctor.export(r, to: url) { p in Task { @MainActor in if saving != nil { saving = p } } }
                saved = url
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { saveError = error.localizedDescription }
            }
            saving = nil
        }
    }

    // MARK: Review

    private var scores: some View {
        let original = 0...review.duration
        let pacingBefore = ShortDoctor.pacingScore(words: review.words, ranges: [original])
        let pacingAfter = ShortDoctor.pacingScore(words: review.words, ranges: ranges)
        let hookAfter = review.choices.useHook ? review.hook?.scoreAfter : nil
        return VStack(alignment: .leading, spacing: 14) {
            Text(review.title).font(Theme.display(26, weight: .medium)).foregroundColor(.white).lineLimit(2)
            if !review.summary.isEmpty {
                Text(review.summary).font(.system(size: 13)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 14) {
                score("Hook", review.hookScore, after: hookAfter, why: "How quickly and strongly the video grabs attention. An opinion from \(engineName), not a measurement.")
                score("Pacing", pacingBefore, after: pacingAfter, why: "Measured: how much of the time someone is talking, less filler words.")
                score("Clarity", review.clarityScore, after: nil, why: "How easy the message is to follow. An opinion from \(engineName), not a measurement.")
                score("Ending", review.endingScore, after: nil, why: "Whether it finishes strongly. An opinion from \(engineName), not a measurement.")
            }
            Text("Reviewed by \(engineName).").font(.system(size: 10)).foregroundColor(Theme.faint)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }

    private var engineName: String {
        switch review.engine { case "cloud": return "your AI"; case "local": return "on-device AI"; default: return "simple rules" }
    }

    private func score(_ title: String, _ before: Int, after: Int?, why: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScoreRing(title: title, value: before, why: why)
            if let after, after != before {
                Text("\(before) → \(after) after").font(.system(size: 10, weight: .medium)).foregroundColor(after > before ? Theme.good : Theme.warn).padding(.leading, 68)
            }
        }
    }

    @ViewBuilder private var warnings: some View {
        if review.hasMusic || review.hasBurnedText || ShortDoctor.mostlyUnheard(review) {
            VStack(alignment: .leading, spacing: 6) {
                if ShortDoctor.mostlyUnheard(review) {
                    Label("About \(Int(review.unheardSeconds)) seconds have sound but no words AutoClip could make out, such as singing. Those parts stay in when nothing's moved, but a new hook or order leaves them out, so bigger changes start switched off.", systemImage: "waveform")
                }
                if review.hasMusic {
                    Label("Music is mixed into this video, so it will jump at each cut. Your version without music will sound much better.", systemImage: "music.note")
                }
                if review.hasBurnedText {
                    Label("Captions look burned into the picture. They can't be removed, and they stay with their words wherever a cut lands.", systemImage: "captions.bubble")
                }
            }
            .font(.system(size: 12)).foregroundColor(Theme.warn)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warn.opacity(0.09)))
        }
    }

    private func line(_ i: Int) -> String {
        lines.indices.contains(i) ? ShortDoctor.spokenText(lines[i]) : ""
    }

    private func toggle(_ on: Binding<Bool>, _ title: String, _ detail: String? = nil) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream)
                if let detail { Text(detail).font(.system(size: 11)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .toggleStyle(.switch).tint(Theme.sand)
    }

    private var hookCard: some View {
        AssessCard(title: "Hook") {
            if let h = review.hook {
                toggle($review.choices.useHook, "Open on this line", h.why)
                Text("“\(line(h.line))”").font(Theme.display(16).italic()).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
                if review.choices.useHook {
                    Toggle("Also keep it where it was said (play it twice, as a teaser)", isOn: $review.choices.keepHookInPlace)
                        .toggleStyle(.checkbox).font(.system(size: 12)).foregroundColor(Theme.text)
                }
            } else {
                Text("Your opening line is already the strongest one in the video.").font(.system(size: 12)).foregroundColor(Theme.text)
                Text("“\(line(0))”").font(Theme.display(14).italic()).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            toggle($review.choices.useHookText, "Add on-screen hook text", "Shows for the first 3 seconds.")
            if review.choices.useHookText {
                TextField("A few punchy words", text: $review.choices.hookText).textFieldStyle(.roundedBorder).font(.system(size: 13))
            }
        }
        .onAppear {
            if review.choices.hookText.isEmpty, let t = review.hook?.text { review.choices.hookText = t }
        }
    }

    private var pacingCard: some View {
        let c = ShortDoctor.cuts(review)
        return AssessCard(title: "Pacing") {
            toggle($review.choices.removeSilences, "Remove silences", String(format: "%.1f seconds of pauses to tighten", c.silence))
            toggle($review.choices.removeFillers, "Remove ums and uhs", c.fillers == 0 ? "None found. The speech model often leaves them out." : "\(c.fillers) found")
            toggle($review.choices.removeStutters, "Remove stutters and false starts", c.stutters == 0 ? "None found" : "\(c.stutters) found")
        }
    }

    private var orderCard: some View {
        AssessCard(title: "Better order") {
            toggle($review.choices.useOrder, "Rearrange the lines", review.orderWhy.isEmpty ? nil : review.orderWhy)
            Text("Listen through after using this: a moved line can lose what it depended on.").font(.system(size: 11)).foregroundColor(Theme.muted)
        }
    }

    private var endingCard: some View {
        AssessCard(title: "Ending") {
            if let last = review.ending?.line {
                toggle($review.choices.useEnding, "Finish on this line", review.ending?.note)
                Text("“\(line(last))”").font(Theme.display(14).italic()).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
            } else if let note = review.ending?.note {
                Text(note).font(.system(size: 12)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var linesCard: some View {
        let order = ShortDoctor.lineOrder(review)
        return AssessCard(title: "The new edit, in order", subtitle: "Untick a line to take it out. Suggested cuts are marked.") {
            ForEach(Array(order.enumerated()), id: \.offset) { position, i in
                lineRow(i, moved: i != position)
            }
            let out = lines.indices.filter { !order.contains($0) }
            if !out.isEmpty {
                Text("TAKEN OUT").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundColor(Theme.faint).padding(.top, 6)
                ForEach(out, id: \.self) { i in lineRow(i, moved: false) }
            }
        }
    }

    private func lineRow(_ i: Int, moved: Bool) -> some View {
        let isDropped = review.choices.dropped.contains(i)
        let suggestion = review.drops.first { $0.line == i }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                if isDropped { review.choices.dropped.remove(i) } else { review.choices.dropped.insert(i) }
            } label: {
                Image(systemName: isDropped ? "square" : "checkmark.square.fill").foregroundColor(isDropped ? Theme.faint : gold)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(line(i)).font(.system(size: 13)).foregroundColor(isDropped ? Theme.faint : Theme.text)
                    .strikethrough(isDropped).fixedSize(horizontal: false, vertical: true)
                if let suggestion, !isDropped {
                    Text("Suggested cut: \(suggestion.why)").font(.system(size: 10)).foregroundColor(Theme.warn)
                }
            }
            Spacer(minLength: 4)
            if moved && !isDropped {
                Text("Moved").font(.system(size: 9, weight: .semibold)).foregroundColor(gold)
            }
            if lines.indices.contains(i) {
                Text(assessTime(lines[i].start)).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.faint)
            }
        }
    }
}
