import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Review → Approvals: links sent to a pastor or comms lead, and what they said about each clip and post.
struct ApprovalsTab: View {
    @ObservedObject private var store = ReviewStore.shared
    @ObservedObject private var reels = AutoReelsStore.shared
    @State private var sendFor: AutoReelRecord?
    @State private var showLink: ReviewRequest?
    @State private var confirmDelete: ReviewRequest?
    @State private var tick = 0

    private var sermons: [AutoReelRecord] {
        reels.reels.filter { ReelGenerator.sourceVideoPath(for: $0) != nil && !($0.drafts ?? []).isEmpty || CarouselStore.exists($0.id) }
    }

    var body: some View {
        ScrollView {
            PageHeader(eyebrow: "Review", title: "Approvals",
                       subtitle: "Send clips and graphics to whoever signs off. They approve them on their phone.") {
                Menu {
                    ForEach(sermons.prefix(30)) { rec in Button(rec.title) { sendFor = rec } }
                } label: { Label("Send for review", systemImage: "paperplane") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(sermons.isEmpty)
            }
            VStack(alignment: .leading, spacing: 18) {
                status
                if store.requests.isEmpty {
                    EmptyState(icon: "checkmark.seal", title: "Nothing sent for review yet",
                               message: "Choose a sermon above, or use the seal button on Social Graphics. You'll get a link and a QR code to open on a phone on the same Wi-Fi.") { EmptyView() }
                }
                ForEach(store.requests) { requestCard($0) }
            }
            .padding(.horizontal, 32).padding(.bottom, 28).padding(.top, 4)
        }
        .onAppear { store.startIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: ReviewServer.changed)) { _ in tick += 1 }
        .sheet(item: $sendFor) { ReviewSendSheet(record: $0) }
        .sheet(item: $showLink) { r in
            VStack(spacing: 16) {
                Text(r.title).font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
                ReviewLinkView(request: r)
                Button("Done") { showLink = nil }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle(compact: true))
            }
            .padding(26).frame(width: 440).background(Theme.bg)
        }
        .alert("Delete this review?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let r = confirmDelete { store.delete(r.id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("The link stops working and its answers are removed. The clips and graphics themselves stay.")
        }
    }

    @ViewBuilder private var status: some View {
        let _ = tick
        let open = store.requests.contains { !$0.closed }
        if open {
            HStack(spacing: 8) {
                Circle().fill(ReviewServer.shared.running ? Theme.good : Theme.warn).frame(width: 8, height: 8)
                if ReviewServer.shared.running, let ip = ReviewServer.lanAddress() {
                    Text("Sharing on this Mac's Wi-Fi (\(ip)). Keep AutoClip open until they've answered.")
                } else if ReviewServer.lanAddress() == nil {
                    Text("This Mac isn't on a network. Connect to Wi-Fi so phones can open review links.")
                } else {
                    Text("Starting…")
                }
            }
            .font(.ui(size: 12.5)).foregroundColor(Theme.muted)
        }
    }

    private func requestCard(_ r: ReviewRequest) -> some View {
        let n = r.counts
        return AssessCard(title: r.closed ? "Not shared" : "Shared \(r.created.formatted(.relative(presentation: .named)))") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(.ui(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                    Text("\(n.approved) approved · \(n.changes) with changes · \(n.waiting) waiting")
                        .font(.ui(size: 12)).foregroundColor(Theme.muted)
                }
                Spacer()
                if !r.closed {
                    Button { showLink = r } label: { Label("Show link", systemImage: "qrcode") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("Stop sharing") { store.close(r.id) }.buttonStyle(.link).font(.ui(size: 12))
                } else {
                    Button("Share again") { store.reopen(r.id) }.buttonStyle(.link).font(.ui(size: 12))
                }
                Button { confirmDelete = r } label: { Image(systemName: "trash") }
                    .buttonStyle(SecondaryButtonStyle(compact: true)).help("Delete this review")
            }
            VStack(spacing: 0) {
                ForEach(r.items) { it in itemRow(r, it) }
            }
        }
    }

    private func itemRow(_ r: ReviewRequest, _ it: ReviewItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: it.kind == .clip ? "play.rectangle" : it.kind == .carousel ? "rectangle.stack" : "square")
                .foregroundColor(Theme.sand).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(it.title).font(.ui(size: 13)).foregroundColor(Theme.text).lineLimit(1)
                if it.decision == .changes, !it.note.isEmpty {
                    Text("“\(it.note)”").font(.ui(size: 12.5)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                if it.decision != .pending, let at = it.at {
                    Text((it.by.isEmpty ? "" : it.by + " · ") + at.formatted(.relative(presentation: .named)))
                        .font(.ui(size: 11.5)).foregroundColor(Theme.faint)
                }
            }
            Spacer()
            ReviewBadge(item: it, showWaiting: true)
            Menu {
                Button("Mark approved") { store.set(r.id, item: it.id, decision: .approved) }
                Button("Clear the answer") { store.set(r.id, item: it.id, decision: .pending) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }
}

/// A small "Approved" or "Changes" label.
struct ReviewBadge: View {
    let item: ReviewItem
    var showWaiting = false

    var body: some View {
        switch item.decision {
        case .approved:
            Label("Approved", systemImage: "checkmark.seal.fill").font(.ui(size: 11, weight: .semibold))
                .foregroundColor(.white).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color(red: 0.36, green: 0.45, blue: 0.2)))
                .help(item.by.isEmpty ? "Approved" : "Approved by \(item.by)")
        case .changes:
            Label("Changes", systemImage: "exclamationmark.bubble.fill").font(.ui(size: 11, weight: .semibold))
                .foregroundColor(.white).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color(red: 0.72, green: 0.42, blue: 0.13)))
                .help((item.by.isEmpty ? "" : item.by + ": ") + (item.note.isEmpty ? "Asked for changes" : item.note))
        case .pending:
            if showWaiting {
                Text("Waiting").font(.ui(size: 11, weight: .semibold)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Theme.ink.opacity(0.07)))
            }
        }
    }
}

/// Choose what to send, then get the link.
struct ReviewSendSheet: View {
    let record: AutoReelRecord
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ReviewStore.shared
    @State private var choice = ReviewStore.Choice()
    @State private var made: ReviewRequest?
    @State private var failed = false

    private var clips: Int { record.drafts?.count ?? 0 }
    private var carousel: SermonCarousel? { CarouselStore.load(record.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send for review").font(Theme.display(24, weight: .medium)).foregroundColor(Theme.cream)
                Text(record.title).font(.ui(size: 13)).foregroundColor(Theme.muted)
            }
            if let made {
                ReviewLinkView(request: made)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Clips (\(clips))", isOn: $choice.clips).disabled(clips == 0)
                    Toggle("Carousel" + (carousel.map { " (\($0.slides.count) slides)" } ?? ""), isOn: $choice.carousel).disabled(carousel?.slides.isEmpty ?? true)
                    Toggle("Posts for the week (\(carousel?.postList.count ?? 0))", isOn: $choice.posts).disabled(carousel?.postList.isEmpty ?? true)
                }
                Text("They'll get a page on their phone to watch each clip, swipe the graphics, and tap Approve or Ask for changes. Their answers come straight back here.")
                    .font(.ui(size: 12.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if failed {
                    Text("There was nothing to send. Make clips or graphics for this sermon first.").font(.ui(size: 12.5)).foregroundColor(Theme.warn)
                }
            }
            HStack {
                if let s = store.preparing[record.id] {
                    ProgressView().controlSize(.small)
                    Text(s).font(.ui(size: 12.5)).foregroundColor(Theme.muted)
                }
                Spacer()
                Button(made == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if made == nil {
                    Button {
                        failed = false
                        Task {
                            made = await store.make(for: record, choose: effectiveChoice)
                            failed = made == nil
                        }
                    } label: { Label("Make the link", systemImage: "link") }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.preparing[record.id] != nil || nothingChosen)
                }
            }
        }
        .padding(26).frame(width: 460).background(Theme.bg)
    }

    private var effectiveChoice: ReviewStore.Choice {
        var c = choice
        if clips == 0 { c.clips = false }
        if carousel?.slides.isEmpty ?? true { c.carousel = false }
        if carousel?.postList.isEmpty ?? true { c.posts = false }
        return c
    }
    private var nothingChosen: Bool { let c = effectiveChoice; return !c.clips && !c.carousel && !c.posts }
}

/// The QR code and link for a review.
struct ReviewLinkView: View {
    let request: ReviewRequest
    @State private var url: URL?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            if let url {
                if let qr = Self.qr(url.absoluteString) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 190, height: 190)
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                }
                Text("Scan with the phone's camera, or send them the link.")
                    .font(.ui(size: 12.5)).foregroundColor(Theme.muted)
                Text(url.absoluteString).font(.ui(size: 12).monospaced()).foregroundColor(Theme.text)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open here", systemImage: "safari") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .help("See the page they'll see")
                }
                Text("Their phone needs to be on the same Wi-Fi as this Mac, and AutoClip needs to stay open.")
                    .font(.ui(size: 11.5)).foregroundColor(Theme.faint).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ReviewServer.lanAddress() == nil {
                Text("This Mac isn't connected to a network. Connect it to Wi-Fi and the link will appear here.")
                    .font(.ui(size: 13)).foregroundColor(Theme.warn).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
                Text("Starting the link…").font(.ui(size: 12.5)).foregroundColor(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ReviewServer.changed)) { _ in refresh() }
        .task {
            // The network may come up after the sheet opens
            for _ in 0..<20 where url == nil {
                try? await Task.sleep(nanoseconds: 500_000_000)
                refresh()
            }
        }
    }

    private func refresh() { url = ReviewServer.shared.url(for: request.token) }

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
