import SwiftUI
import UniformTypeIdentifiers

/// How posted shorts really did, and what the numbers say so far.
struct ResultsTab: View {
    @ObservedObject private var store = ShortResultsStore.shared
    @State private var editing: PostedShort?
    @State private var confirmDelete: PostedShort?

    private var insights: [ResultInsight] { ShortResults.insights(store.shorts) }
    private var hasLinks: Bool { store.shorts.contains { !$0.link.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                CinematicHero(path: nil, eyebrow: "Review", title: "Results",
                              detail: "Add the shorts you've posted and how they did. Once there are enough, AutoClip shows what's working for your audience and uses it in the Hook lab.",
                              height: 320, icon: "chart.line.uptrend.xyaxis") {
                    Button { editing = PostedShort() } label: { Label("Add a posted short", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                }
                if !store.shorts.isEmpty { totals }
                patterns
                if !store.shorts.isEmpty {
                    HStack {
                        SectionTitle(title: "Posted shorts", count: store.shorts.count)
                        Spacer()
                        if store.refreshing { ProgressView().controlSize(.small) }
                        else if hasLinks {
                            Button { Task { await store.refreshAll() } } label: { Label("Update numbers from links", systemImage: "arrow.clockwise") }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                        }
                    }
                    if let note = store.refreshNote { Text(note).font(.ui(size: 12)).foregroundColor(Theme.muted) }
                    ForEach(store.shorts) { row($0) }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
        }
        .sheet(item: $editing) { s in PostedShortSheet(draft: s) }
        .confirmationDialog("Delete these results?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { s in
            Button("Delete", role: .destructive) { store.delete(s) }
            Button("Cancel", role: .cancel) { }
        } message: { s in
            Text("This removes the numbers for \(s.title.isEmpty ? "this short" : s.title). Your video isn't deleted.")
        }
    }

    private var totals: some View {
        let watched = store.shorts.compactMap(\.percentWatched).sorted()
        let views = store.shorts.compactMap(\.views).sorted()
        return HStack(spacing: 34) {
            stat("\(store.shorts.count)", "shorts posted")
            stat(views.isEmpty ? "–" : compact(views[views.count / 2]), "typical views")
            stat(watched.isEmpty ? "–" : "\(Int(watched[watched.count / 2].rounded()))%", "typically watched")
            Spacer()
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(30, weight: .medium)).foregroundColor(Theme.ink).monospacedDigit()
            Text(label).font(.ui(size: 12)).foregroundColor(Theme.muted)
        }
    }

    @ViewBuilder private var patterns: some View {
        let needed = ShortResults.neededForPatterns(store.shorts)
        AssessCard(title: "What's working", subtitle: "Early patterns from your own shorts. They show what went together, not proof of why.") {
            if needed > 0 {
                Text("Add average watch time and length for \(needed) more \(needed == 1 ? "short" : "shorts") and patterns can start to show. With fewer than that, any difference is mostly chance.")
                    .font(.ui(size: 13)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
            } else if insights.isEmpty {
                Text("No clear pattern yet. Your shorts are performing about the same, or each group needs at least \(ShortResults.enough) shorts to compare.")
                    .font(.ui(size: 13)).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(insights) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i.difference > 0 ? "+" : "")\(i.difference)%").font(Theme.display(20, weight: .medium))
                            .foregroundColor(i.difference > 0 ? Theme.good : Theme.warn).monospacedDigit().frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title).font(.ui(size: 13, weight: .semibold)).foregroundColor(Theme.cream)
                            Text("\(i.detail) \(i.count) shorts compared with \(i.others).").font(.ui(size: 12)).foregroundColor(Theme.muted)
                        }
                    }
                }
            }
        }
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1_000 ? String(format: "%.1fK", Double(n) / 1_000) : "\(n)"
    }

    private func row(_ s: PostedShort) -> some View {
        HStack(spacing: 8) {
            Button { editing = s } label: {
                HStack(spacing: 14) {
                    if let path = s.videoPath {
                        VideoFrameView(path: path, width: 320).frame(width: 54, height: 72).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title.isEmpty ? "Untitled short" : s.title).font(.ui(size: 13, weight: .semibold)).foregroundColor(Theme.cream).lineLimit(1)
                        Text("\(s.platform) · \(s.postedAt.formatted(date: .abbreviated, time: .omitted))\(s.version.map { " · \($0) version" } ?? "")")
                            .font(.ui(size: 12)).foregroundColor(Theme.muted)
                        if !s.opening.isEmpty {
                            Text("“\(s.opening)”").font(.ui(size: 12)).foregroundColor(Theme.faint).lineLimit(1)
                        }
                    }
                    Spacer()
                    number(s.views.map(compact), "views")
                    number(s.percentWatched.map { "\(Int($0.rounded()))%" }, "watched")
                    number(s.likes.map(compact), "likes")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { confirmDelete = s } label: { Image(systemName: "trash").font(.ui(size: 13)) }
                .buttonStyle(.plain).foregroundColor(Theme.muted).padding(8).help("Delete these results")
        }
    }

    private func number(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value ?? "–").font(.ui(size: 14, weight: .semibold)).foregroundColor(value == nil ? Theme.faint : .white).monospacedDigit()
            Text(label).font(.ui(size: 11)).foregroundColor(Theme.faint)
        }
        .frame(width: 58, alignment: .trailing)
    }
}

/// Adds or edits one posted short's numbers.
struct PostedShortSheet: View {
    @State var draft: PostedShort
    @Environment(\.dismiss) private var dismiss
    @State private var length = ""
    @State private var views = ""
    @State private var watched = ""
    @State private var likes = ""
    @State private var comments = ""
    @State private var shares = ""
    @State private var saves = ""
    @State private var at3 = ""
    @State private var half = ""
    @State private var end = ""
    @State private var busy = false
    @State private var note: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Posted short").font(Theme.display(24, weight: .medium)).foregroundColor(Theme.ink)
                    field("Title") { TextField("Name of the short", text: $draft.title) }
                    HStack(spacing: 12) {
                        field("Platform") {
                            Picker("", selection: $draft.platform) { ForEach(ShortResults.platforms, id: \.self) { Text($0) } }.labelsHidden()
                        }
                        field("Posted") { DatePicker("", selection: $draft.postedAt, displayedComponents: .date).labelsHidden() }
                    }
                    field("Link (fills in public views, likes and comments)") {
                        HStack {
                            TextField("https://…", text: $draft.link)
                            Button("Get numbers") { fetch() }.disabled(busy || draft.link.isEmpty)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { screenshot() } label: { Label("Read an analytics screenshot", systemImage: "text.viewfinder") }.disabled(busy)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let note { Text(note).font(.ui(size: 12)).foregroundColor(Theme.good).fixedSize(horizontal: false, vertical: true) }
                    if let problem { Text(problem).font(.ui(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
                    field("Opening line, as posted") { TextField("The first thing you say", text: $draft.opening) }
                    grid([("Length", "0:45", $length), ("Average watched", "0:27", $watched), ("Views", "12.4K", $views)])
                    grid([("Likes", "", $likes), ("Comments", "", $comments), ("Shares", "", $shares), ("Saves", "", $saves)])
                    Text("STILL WATCHING, FROM YOUR ANALYTICS").font(.ui(size: 11, weight: .semibold)).tracking(1.2).foregroundColor(Theme.faint)
                    grid([("At 3 seconds", "%", $at3), ("At halfway", "%", $half), ("At the end", "%", $end)])
                    Text("Average watched and length are what power the patterns. Platforms keep those private, so they come from your analytics.")
                        .font(.ui(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .textFieldStyle(.roundedBorder)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(compact: true)).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
        .background(Theme.bg)
        .onAppear { load() }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(size: 12, weight: .medium)).foregroundColor(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ items: [(String, String, Binding<String>)]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(items, id: \.0) { item in field(item.0) { TextField(item.1, text: item.2) } }
        }
    }

    private func load() {
        length = draft.length.map(assessClock) ?? ""
        watched = draft.averageWatched.map(assessClock) ?? ""
        views = draft.views.map(String.init) ?? ""
        likes = draft.likes.map(String.init) ?? ""
        comments = draft.comments.map(String.init) ?? ""
        shares = draft.shares.map(String.init) ?? ""
        saves = draft.saves.map(String.init) ?? ""
        func percent(_ v: Double?) -> String { v.map { String(format: "%g", $0) } ?? "" }
        at3 = percent(draft.heldAt3s); half = percent(draft.heldAtHalf); end = percent(draft.heldAtEnd)
    }

    /// Reads the fields into the draft. A whole-second box can't improve on what's stored, so unchanged text keeps it exact.
    private func commit() {
        if length != (draft.length.map(assessClock) ?? "") { draft.length = ShortResults.seconds(length) }
        if watched != (draft.averageWatched.map(assessClock) ?? "") { draft.averageWatched = ShortResults.seconds(watched) }
        draft.views = ShortResults.number(views)
        draft.likes = ShortResults.number(likes)
        draft.comments = ShortResults.number(comments)
        draft.shares = ShortResults.number(shares)
        draft.saves = ShortResults.number(saves)
        draft.heldAt3s = ShortResults.percent(at3)
        draft.heldAtHalf = ShortResults.percent(half)
        draft.heldAtEnd = ShortResults.percent(end)
    }

    private func fetch() {
        commit()
        busy = true; note = nil; problem = nil
        Task {
            do {
                let stats = try await YTDLP.publicStats(draft.link)
                YTDLP.PublicStats.apply(stats, to: &draft)
                if let posted = stats.postedAt { draft.postedAt = posted }
                load()
                note = "Filled in what the post shows publicly."
            } catch { problem = error.localizedDescription }
            busy = false
        }
    }

    private func screenshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a screenshot of this short's analytics"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commit()
        busy = true; note = nil; problem = nil
        Task {
            let lines = await ShortResults.readText(in: url)
            // What's on the screenshot replaces what's there, so clear only what it can fill
            var read = PostedShort()
            let found = ShortResults.fill(&read, fromLines: lines)
            draft.views = read.views ?? draft.views
            draft.averageWatched = read.averageWatched ?? draft.averageWatched
            draft.likes = read.likes ?? draft.likes
            draft.comments = read.comments ?? draft.comments
            draft.shares = read.shares ?? draft.shares
            draft.saves = read.saves ?? draft.saves
            load()
            if found == 0 { problem = "Couldn't find any numbers in that screenshot, so enter them yourself." }
            else { note = "Read \(found) \(found == 1 ? "number" : "numbers") from the screenshot. Check them against your analytics before saving." }
            busy = false
        }
    }

    private func save() {
        commit()
        ShortResultsStore.shared.save(draft)
        dismiss()
    }
}
