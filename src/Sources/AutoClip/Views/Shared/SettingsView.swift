import SwiftUI
import TipKit

/// AutoClip → Settings (⌘,): everything that was spread around the app, in one place.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            ReelSettings().tabItem { Label("Clips", systemImage: "play.rectangle.on.rectangle") }
            AutoImportView().tabItem { Label("Autopilot", systemImage: "dot.radiowaves.left.and.right") }
            PlanSettings().tabItem { Label("Plan", systemImage: "key") }
        }
        .frame(width: 560)
        .appLook()
        .tint(Theme.action)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.ui(size: 11.5, weight: .semibold)).tracking(1.4).foregroundColor(Theme.faint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Row<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(size: 13))
                if let detail { Text(detail).font(.ui(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("sounds_on") private var sounds = true
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.dark.rawValue
    @AppStorage(TextSize.key) private var textSize = TextSize.standard.rawValue
    @AppStorage("menubar_on") private var menuBar = true
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var auto = AutoImport.shared
    @State private var tipsNote: String?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Look") {
                Row(title: "Appearance", detail: "Light is easier to read in a bright office") {
                    Picker("", selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                Row(title: "Text size", detail: "Larger is easier to read at arm's length. Your graphics and captions don't change") {
                    Picker("", selection: $textSize) { ForEach(TextSize.allCases) { Text($0.label).tag($0.rawValue) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
            }
            SettingsSection(title: "Backup") {
                BackupRows()
            }
            SettingsSection(title: "App") {
                Row(title: "Open AutoClip when this Mac starts", detail: auto.loginNote) {
                    Toggle("", isOn: Binding(get: { auto.opensAtLogin }, set: { auto.setOpensAtLogin($0) })).labelsHidden().toggleStyle(.switch)
                }
                Row(title: "Show in the menu bar") { Toggle("", isOn: $menuBar).labelsHidden().toggleStyle(.switch) }
                Row(title: "Play sounds", detail: "A short chime when a clip finishes exporting") { Toggle("", isOn: $sounds).labelsHidden().toggleStyle(.switch) }
            }
            SettingsSection(title: "Updates") {
                Row(title: "Check for updates automatically", detail: "You're on \(AppInfo.version)") {
                    Toggle("", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })).labelsHidden().toggleStyle(.switch)
                }
                HStack {
                    Button("Check now") { Task { await updater.check(manual: true) } }
                    if let s = updater.status { Text(s).font(.ui(size: 12)).foregroundColor(.secondary) }
                }
            }
            SettingsSection(title: "Check setup") {
                SetupCheckView()
            }
            SettingsSection(title: "Help") {
                HStack {
                    Button("Show tips again") { UserDefaults.standard.set(true, forKey: "tips_reset"); tipsNote = "Tips come back the next time AutoClip opens." }
                    Button("Open the help guide") { HelpPages.open() }
                }
                if let tipsNote { Text(tipsNote).font(.ui(size: 12)).foregroundColor(.secondary) }
            }
        }
        .padding(24)
        }
        .frame(minHeight: 420, idealHeight: 640, maxHeight: 760)
    }
}

private struct AISettings: View {
    @AppStorage("ar_provider") private var providerRaw = LLMClipService.AIProvider.anthropic.rawValue
    @AppStorage("ar_useAI") private var useAI = false
    @State private var localOn = LocalAI.enabled
    @State private var newKey = ""
    @State private var hasKey: [LLMClipService.AIProvider: Bool] = [:]
    @State private var note: String?

    private var provider: LLMClipService.AIProvider { LLMClipService.AIProvider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Choosing clips") {
                Row(title: "Use AI to pick and order clips", detail: "Off uses the built-in picker on this Mac, at no cost.") {
                    Toggle("", isOn: $useAI).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsSection(title: "AI provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(LLMClipService.AIProvider.allCases) { p in Text(p.rawValue).tag(p.rawValue) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("Model: \(provider.modelLabel)").font(.ui(size: 12, design: .monospaced)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: hasKey[provider] == true ? "checkmark.seal.fill" : "key")
                        .foregroundColor(hasKey[provider] == true ? Theme.good : .secondary)
                    Text(hasKey[provider] == true ? "A key for \(provider.rawValue) is saved in your Keychain." : "No key saved for \(provider.rawValue).")
                        .font(.ui(size: 13))
                    Spacer()
                    if hasKey[provider] == true {
                        Button("Remove") { save("") }.controlSize(.small)
                    }
                }
                HStack {
                    SecureField(hasKey[provider] == true ? "Paste a new key to replace it" : provider.keyPlaceholder, text: $newKey)
                        .textFieldStyle(.roundedBorder).font(.ui(size: 13, design: .monospaced))
                        .onSubmit { save(newKey) }
                    Button("Save key") { save(newKey) }.disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("The key stays in your Keychain and is only sent to \(provider.rawValue). The AI company bills you directly, so set a spending limit in your account.")
                    .font(.ui(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.ui(size: 12)).foregroundColor(note.contains("didn't work") ? Theme.warn : Theme.good)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            SettingsSection(title: "On this Mac") {
                Row(title: "Use on-device AI for simple jobs", detail: "Hooks, captions and topic lists run free and private through Ollama, when it's installed and running.") {
                    Toggle("", isOn: $localOn).labelsHidden().toggleStyle(.switch)
                        .onChange(of: localOn) { LocalAI.enabled = $0 }
                }
            }
        }
        .padding(24)
        .task(id: providerRaw) { await refresh() }
    }

    private func refresh() async {
        var out: [LLMClipService.AIProvider: Bool] = [:]
        for p in LLMClipService.AIProvider.allCases { out[p] = !((await LLMClipService.shared.loadAPIKey(for: p)) ?? "").isEmpty }
        hasKey = out
    }

    private func save(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = provider
        Task {
            await LLMClipService.shared.saveAPIKey(k, for: p)
            newKey = ""
            note = k.isEmpty ? "Key removed." : "Key saved."
            await refresh()
            // A Claude key is checked straight away, for free, so a bad one shows here and not mid-sermon
            if !k.isEmpty, p == .anthropic {
                note = "Key saved. Checking it with Claude…"
                if let problem = await LLMClipService.shared.checkAnthropicKey(k) {
                    note = "Key saved, but it didn't work: \(problem)"
                } else {
                    note = "Key saved and working."
                }
            }
        }
    }
}

private struct ReelSettings: View {
    @AppStorage("ar_findSermon") private var findSermon = true
    @AppStorage(ScreenCues.key) private var wideForScreen = true
    @AppStorage("ar_motion") private var motion = ReelMotion.Style.both.rawValue
    @AppStorage("ar_hookStyle") private var hookStyle = HookStyle.pop.rawValue
    @AppStorage("ar_targetDur") private var target: Double = 90
    @AppStorage("ar_lastOutputDir") private var exportFolder = ""
    @AppStorage(OneClickSunday.key) private var autoGraphics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "One-click Sunday") {
                Row(title: "Make social graphics with every sermon",
                    detail: "When the clips are ready, AI also writes the carousel and a week of posts, and the plan is set. Uses one more AI request per sermon.") {
                    Toggle("", isOn: $autoGraphics).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsSection(title: "New clips") {
                Row(title: "Find the sermon in a full service", detail: "For recordings over 30 minutes") { Toggle("", isOn: $findSermon).labelsHidden().toggleStyle(.switch) }
                Row(title: "Wide shot when the screen is mentioned", detail: "Vertical clips cut to the whole picture on lines like “look at the screen”, then back to the speaker") { Toggle("", isOn: $wideForScreen).labelsHidden().toggleStyle(.switch) }
                Row(title: "Length") {
                    Picker("", selection: $target) {
                        Text("30 seconds").tag(30.0); Text("45 seconds").tag(45.0); Text("60 seconds").tag(60.0); Text("90 seconds").tag(90.0); Text("2 minutes").tag(120.0)
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Movement") {
                    Picker("", selection: $motion) { ForEach(ReelMotion.Style.allCases) { Text($0.label).tag($0.rawValue) } }.labelsHidden().fixedSize()
                }
                Row(title: "Hook animation") {
                    Picker("", selection: $hookStyle) { ForEach(HookStyle.allCases) { Text($0.label).tag($0.rawValue) } }.labelsHidden().fixedSize()
                }
            }
            SettingsSection(title: "Exports") {
                Row(title: "Save exports to", detail: exportFolder.isEmpty ? "You'll be asked the first time" : exportFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { exportFolder = u.path }
                    }
                }
            }
            Text("Caption style is set in the editor's Captions tab, and new clips use the last one you chose.").font(.ui(size: 12)).foregroundColor(.secondary)
        }
        .padding(24)
    }
}

private struct PlanSettings: View {
    @ObservedObject private var license = License.shared
    @State private var show = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(license.status).font(Theme.display(22)).foregroundColor(Theme.cream)
            if let info = license.info {
                Text("Licensed to \(info.name). \(info.expires.map { "Ends \($0.formatted(date: .long, time: .omitted))." } ?? "Never ends.")")
                    .font(.ui(size: 13)).foregroundColor(.secondary)
            } else {
                Text("The free trial makes clips from \(License.trialSermons) sermons. Trial exports carry a small “Made with AutoClip” mark.")
                    .font(.ui(size: 13)).foregroundColor(.secondary)
            }
            HStack {
                Button(license.licensed ? "Manage license…" : "Enter a license key…") { show = true }
                if license.canBuy && !license.licensed { Button("Buy AutoClip") { license.openPurchasePage() } }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $show) { ActivationSheet() }
    }
}


/// Back up everything to one file, or restore from one (for a new Mac or after a problem).
private struct BackupRows: View {
    @State private var includeVideos = false
    @State private var sizes: (small: Int64, withVideos: Int64)?
    @State private var status: String?
    @State private var done: String?
    @State private var error: String?
    @State private var confirmRestore: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Row(title: "Back up AutoClip", detail: "One file with your sermons, edits, brand kit, graphics, reviews and settings. Keep it on a drive or in iCloud.") {
                Button("Back up…") { backUp() }.buttonStyle(SecondaryButtonStyle(compact: true)).disabled(status != nil)
            }
            Toggle(isOn: $includeVideos) {
                Text(sizeText).font(.ui(size: 12)).foregroundColor(Theme.muted)
            }
            .toggleStyle(.checkbox)
            Row(title: "Restore from a backup", detail: "For a new Mac. What's here now goes to the Trash first. Your AI key isn't in backups, so add it again in Settings → AI.") {
                Button("Restore…") { pickRestore() }.buttonStyle(SecondaryButtonStyle(compact: true)).disabled(status != nil)
            }
            if let status { HStack(spacing: 8) { LoadingBar(status: status); Text(status).font(.ui(size: 12)).foregroundColor(Theme.muted) } }
            if let done { Label(done, systemImage: "checkmark.circle.fill").font(.ui(size: 12)).foregroundColor(Theme.good) }
            if let error { Text(error).font(.ui(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
        }
        .task { sizes = await Backup.estimate() }
        .alert("Replace everything in AutoClip with this backup?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore", role: .destructive) { if let u = confirmRestore { restore(u) }; confirmRestore = nil }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("Your current sermons, graphics and settings go to the Trash, then AutoClip restarts with the backup.")
        }
    }

    private var sizeText: String {
        guard let s = sizes else { return "Include sermon videos (bigger, but nothing to find again)" }
        let f = ByteCountFormatter.string(fromByteCount:countStyle:)
        return "Include sermon videos: \(f(s.withVideos, .file)) instead of \(f(s.small, .file))"
    }

    private func backUp() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "AutoClip Backup \(Date().formatted(.iso8601.year().month().day())).zip"
        p.allowedContentTypes = [.zip]
        guard p.runModal() == .OK, let url = p.url else { return }
        error = nil; done = nil; status = "Starting…"
        Task {
            do {
                try await Backup.make(to: url, includeVideos: includeVideos) { msg in Task { @MainActor in status = msg } }
                done = "Saved \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = error.localizedDescription }
            status = nil
        }
    }

    private func pickRestore() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.zip]
        p.message = "Choose an AutoClip backup"
        guard p.runModal() == .OK, let url = p.url else { return }
        confirmRestore = url
    }

    private func restore(_ url: URL) {
        error = nil; done = nil; status = "Starting…"
        Task {
            do {
                try await Backup.restore(from: url) { msg in Task { @MainActor in status = msg } }
                status = "Restarting…"
                let app = Bundle.main.bundleURL
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(app.path)\""]
                try? task.run()
                NSApp.terminate(nil)
            } catch { self.error = error.localizedDescription; status = nil }
        }
    }
}
