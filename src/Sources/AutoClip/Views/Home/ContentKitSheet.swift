import SwiftUI
import AppKit

/// Makes a content kit for one video: pick what goes in, pick a folder, and it builds the lot.
struct ContentKitSheet: View {
    let recordID: UUID
    @ObservedObject private var store = AutoReelsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var options = ContentKit.Options()
    @State private var status: String?
    @State private var result: ContentKit.Result?
    @State private var error: String?

    private var record: AutoReelRecord? { store.reels.first { $0.id == recordID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 7) {
                Image(systemName: "diamond.fill").font(.system(size: 5)).foregroundColor(Theme.sand)
                Text("ONE VIDEO, A WEEK OF POSTS").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Content kit").font(Theme.display(28)).foregroundColor(Theme.cream)
                Text(record?.title ?? "").font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
            }

            if let r = result {
                done(r)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    item($options.reels, "film.stack", "Every reel", "\(record?.drafts?.count ?? 0) reels, rendered and numbered")
                    item($options.posts, "text.bubble", "Captions & hashtags", "A ready-to-paste post for each reel")
                    item($options.notes, "doc.text", record?.kind == .sermon ? "Sermon notes" : "Notes",
                         record?.kind == .sermon ? "Outline, Scripture, quotes, small-group questions" : "Summary, key points, quotes, questions")
                    item($options.graphics, "photo.on.rectangle.angled", "Graphics", "Quote cards, a carousel and a thumbnail")
                    item($options.transcript, "captions.bubble", "Transcript & captions file", "Text with times, plus an .srt for the full video")
                }
                Text("Includes a posting plan. Reels you've already exported are copied, not rendered again.")
                    .font(.system(size: 11)).foregroundColor(Theme.faint)
                if let e = error { Text(e).font(.system(size: 11)).foregroundColor(Theme.danger) }
                HStack {
                    if let s = status {
                        ProgressView().scaleEffect(0.6)
                        Text(s).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).disabled(status != nil)
                    Button { make() } label: { Label("Make kit", systemImage: "shippingbox") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(status != nil || record == nil)
                }
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    private func item(_ on: Binding<Bool>, _ icon: String, _ title: String, _ detail: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(Theme.sand).frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.sand.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream)
                    Text(detail).font(.system(size: 11)).foregroundColor(Theme.muted)
                }
                Spacer()
                Image(systemName: on.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundColor(on.wrappedValue ? Theme.sand : Theme.faint)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on.wrappedValue ? Theme.raised : Color.white.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status != nil)
    }

    private func done(_ r: ContentKit.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(Theme.good)
                Text("Your kit is ready").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.cream)
            }
            Text(r.folder.path).font(.system(size: 11)).foregroundColor(Theme.muted).textSelection(.enabled)
            ForEach(r.skipped, id: \.self) { s in
                Label(s, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundColor(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func make() {
        guard let rec = record, let parent = ReelExportLocation.pick(title: "Choose where to save the content kit") else { return }
        error = nil; status = "Starting…"
        let opts = options
        Task {
            do {
                let r = try await ContentKit.build(record: rec, in: parent, options: opts) { status = $0 }
                // Keep the new captions on the reels so they show in the list too
                if !r.seo.isEmpty, var latest = store.reels.first(where: { $0.id == rec.id }) {
                    latest.drafts = latest.drafts?.map { d in
                        var d = d
                        if let s = r.seo[d.id], d.seo == nil { d.seo = s }
                        return d
                    }
                    store.update(latest)
                }
                result = r
            } catch { self.error = error.localizedDescription }
            status = nil
        }
    }
}
