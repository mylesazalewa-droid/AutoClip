import SwiftUI
import AppKit
import TipKit

/// ⌘K from anywhere: jump to a page, open a reel, search your sermons or, inside the reel
/// editor, ask for a change. It floats in its own panel so it works over sheets and windows.
@MainActor
final class CommandBar: ObservableObject {
    static let shared = CommandBar()

    struct Item: Identifiable {
        var id: String
        var title: String
        var detail: String?
        var icon: String
        var keywords = ""
        var run: () -> Void
    }

    @Published var query = ""
    @Published var selection = 0
    @Published private(set) var showing = false

    /// Set by the reel editor while it's open
    var editorItems: (() -> [Item])?
    var editorAsk: ((String) -> Void)?
    /// Set by the main window so reels can open and pages can change
    var openReel: ((UUID) -> Void)?

    private var panel: CommandPanel?
    private var previousKey: NSWindow?
    private var keyMonitor: Any?
    private var resignObserver: Any?

    /// Called once at launch.
    func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "k" { toggle(); return true }
        guard showing else { return false }
        switch event.keyCode {
        case 125: selection = min(selection + 1, max(items.count - 1, 0)); return true
        case 126: selection = max(selection - 1, 0); return true
        case 36, 76: runSelected(); return true
        case 53: close(); return true
        default: return false
        }
    }

    func toggle() { showing ? close() : open() }

    func open() {
        CommandBarTip().invalidate(reason: .actionPerformed)
        previousKey = NSApp.keyWindow
        query = ""; selection = 0
        let p = panel ?? makePanel()
        panel = p
        let host = previousKey ?? NSApp.mainWindow
        if let f = host?.frame ?? NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - min(120, f.height * 0.14)))
        }
        showing = true
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard showing else { return }
        showing = false
        panel?.orderOut(nil)
        previousKey?.makeKey()
        previousKey = nil
    }

    private func makePanel() -> CommandPanel {
        let p = CommandPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
                             styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        p.contentView = NSHostingView(rootView: CommandBarView(bar: self).appLook())
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        return p
    }

    // MARK: What's on offer

    var inEditor: Bool { editorItems != nil }

    private var globalItems: [Item] {
        var out: [Item] = []
        let volunteer = VolunteerMode.shared.enabled
        func page(_ title: String, _ icon: String, _ tab: HomeTab, _ words: String = "") {
            out.append(Item(id: "tab." + tab.rawValue, title: title, detail: "Go to page", icon: icon, keywords: words) { HomeNav.shared.open(tab) })
        }
        page("Home", "house", .projects, "start main")
        page("Results", "chart.line.uptrend.xyaxis", .results, "analytics views posted")
        if !volunteer {
            page("Messages", "rectangle.stack", .messages, "sermons checklist progress next step everything")
            page("Clips", "play.rectangle.on.rectangle", .autoReels, "shorts clips")
            page("Social Graphics", "rectangle.split.3x1", .social, "carousel instagram quote cards thumbnail posts")
            page("Improve a Clip", "wand.and.stars", .improve, "fix doctor")
            page("Podcast", "mic", .podcast, "episode")
            page("Rehearse", "text.book.closed", .rehearse, "practice notes prepare sunday")
            page("Assess", "waveform.badge.magnifyingglass", .assess, "delivery report coach")
            page("Worship", "music.note", .worship, "singing band")
            page("Search your sermons", "magnifyingglass", .search, "find transcript")
            page("Storage", "internaldrive", .storage, "disk space clean")
            page("Brand kit", "paintpalette", .brand, "logo colours colors fonts church name handle")
            page("Approvals", "checkmark.seal", .approvals, "review approve pastor volunteer phone")
            if LicenseIssuer.isOwnerMac { page("Licences", "key", .licenses, "license keys activate church customer renew") }
            out.append(Item(id: "new", title: "Make clips from a sermon", detail: "Choose a video", icon: "plus", keywords: "new add import") {
                AutoReelsStore.shared.requestNewReel = true
                HomeNav.shared.open(.autoReels)
            })
        }
        out.append(Item(id: "sample", title: "Open the sample sermon", detail: "See finished clips without any setup", icon: "sparkles", keywords: "demo try example") {
            SampleSermon.open()
        })
        for r in AutoReelsStore.shared.reels.prefix(30) {
            out.append(Item(id: "reel." + r.id.uuidString, title: r.title, detail: "\(r.drafts?.count ?? r.paths.count) clips", icon: "film", keywords: "open reel clip") { [weak self] in
                self?.openReel?(r.id)
            })
        }
        return out
    }

    private static func score(_ item: Item, _ q: String) -> Int? {
        let title = item.title.lowercased(), all = title + " " + item.keywords.lowercased() + " " + (item.detail ?? "").lowercased()
        if title.hasPrefix(q) { return 0 }
        if title.contains(q) { return 1 }
        let parts = q.split(separator: " ")
        if parts.allSatisfy({ all.contains($0) }) { return 2 }
        return nil
    }

    var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = editorItems?() ?? globalItems
        guard !q.isEmpty else { return Array(base.prefix(9)) }
        var out = base.compactMap { i in Self.score(i, q).map { (i, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        let typed = query.trimmingCharacters(in: .whitespaces)
        if let ask = editorAsk {
            let item = Item(id: "ask", title: "Ask: \(typed)", detail: "Change this clip", icon: "text.bubble") { ask(typed) }
            // A close match stays first. Otherwise what they typed is a request.
            if out.isEmpty || (Self.score(out[0], q) ?? 9) > 1 { out.insert(item, at: 0) } else { out.append(item) }
        } else if !VolunteerMode.shared.enabled {
            out.append(Item(id: "search", title: "Search your sermons for “\(typed)”", detail: "Everything you've preached", icon: "magnifyingglass") {
                HomeNav.shared.searchQuery = typed
                HomeNav.shared.open(.search)
            })
        }
        return Array(out.prefix(9))
    }

    func run(_ item: Item) {
        close()
        item.run()
    }

    func runSelected() {
        let list = items
        if list.indices.contains(selection) { run(list[selection]) }
    }
}

private final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CommandBarView: View {
    @ObservedObject var bar: CommandBar
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: bar.inEditor ? "text.bubble" : "command").foregroundColor(Theme.sand)
                TextField(bar.inEditor ? "Say what to change, or pick an action…" : "Go to a page, open a clip, or search your sermons…", text: $bar.query)
                    .textFieldStyle(.plain).font(.system(size: 16)).foregroundColor(Theme.ink)
                    .focused($focused)
                    .onChange(of: bar.query) { _ in bar.selection = 0 }
                Text("esc").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.faint)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
            }
            .padding(14)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        let list = bar.items
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            Button { bar.run(item) } label: { row(item, selected: i == bar.selection) }
                                .buttonStyle(.plain).id(i)
                        }
                        if list.isEmpty {
                            Text("Nothing matches. Try another word.").font(.system(size: 13)).foregroundColor(Theme.muted).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: bar.selection) { proxy.scrollTo($0) }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 12) {
                Text("↑↓ move").font(.system(size: 11.5)).foregroundColor(Theme.faint)
                Text("return to run").font(.system(size: 11.5)).foregroundColor(Theme.faint)
                Spacer()
                if bar.inEditor { Text("Try: cut the part about my brother · start at the question · remove the ums").font(.system(size: 11.5)).foregroundColor(Theme.faint).lineLimit(1) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 620, height: 430)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.ink.opacity(0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: bar.showing) { on in if on { focused = true } }
        .onAppear { focused = true }
    }

    private func row(_ item: CommandBar.Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).font(.system(size: 13)).foregroundColor(selected ? Theme.bg : Theme.sand).frame(width: 22)
            Text(item.title).font(.system(size: 13, weight: .medium)).foregroundColor(selected ? Theme.bg : Theme.text).lineLimit(1)
            Spacer()
            if let d = item.detail { Text(d).font(.system(size: 12)).foregroundColor(selected ? Theme.bg.opacity(0.7) : Theme.faint).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.sand : Color.clear))
        .contentShape(Rectangle())
    }
}
