import SwiftUI
import TipKit

/// AutoClip → Settings (⌘,): everything that was spread around the app, in one place.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            ReelSettings().tabItem { Label("Reels", systemImage: "play.rectangle.on.rectangle") }
            AutoImportView().tabItem { Label("Autopilot", systemImage: "dot.radiowaves.left.and.right") }
            PlanSettings().tabItem { Label("Plan", systemImage: "key") }
        }
        .frame(width: 560)
        .preferredColorScheme(.dark)
        .tint(Theme.action)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundColor(Theme.faint)
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
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            content
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("sounds_on") private var sounds = true
    @AppStorage("menubar_on") private var menuBar = true
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var auto = AutoImport.shared
    @State private var tipsNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                    if let s = updater.status { Text(s).font(.system(size: 11)).foregroundColor(.secondary) }
                }
            }
            SettingsSection(title: "Help") {
                HStack {
                    Button("Show tips again") { UserDefaults.standard.set(true, forKey: "tips_reset"); tipsNote = "Tips come back the next time AutoClip opens." }
                    Button("Open the help guide") { HelpPages.open() }
                }
                if let tipsNote { Text(tipsNote).font(.system(size: 11)).foregroundColor(.secondary) }
            }
        }
        .padding(24)
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
                Text("Model: \(provider.modelLabel)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: hasKey[provider] == true ? "checkmark.seal.fill" : "key")
                        .foregroundColor(hasKey[provider] == true ? Theme.good : .secondary)
                    Text(hasKey[provider] == true ? "A key for \(provider.rawValue) is saved in your Keychain." : "No key saved for \(provider.rawValue).")
                        .font(.system(size: 12))
                    Spacer()
                    if hasKey[provider] == true {
                        Button("Remove") { save("") }.controlSize(.small)
                    }
                }
                HStack {
                    SecureField(hasKey[provider] == true ? "Paste a new key to replace it" : provider.keyPlaceholder, text: $newKey)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .onSubmit { save(newKey) }
                    Button("Save key") { save(newKey) }.disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("The key stays in your Keychain and is only sent to \(provider.rawValue). The AI company bills you directly, so set a spending limit in your account.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(.system(size: 11)).foregroundColor(Theme.good) }
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
        }
    }
}

private struct ReelSettings: View {
    @AppStorage("ar_findSermon") private var findSermon = true
    @AppStorage("ar_motion") private var motion = ReelMotion.Style.both.rawValue
    @AppStorage("ar_hookStyle") private var hookStyle = HookStyle.pop.rawValue
    @AppStorage("ar_targetDur") private var target: Double = 90
    @AppStorage("ar_lastOutputDir") private var exportFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "New reels") {
                Row(title: "Find the sermon in a full service", detail: "For recordings over 30 minutes") { Toggle("", isOn: $findSermon).labelsHidden().toggleStyle(.switch) }
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
            Text("Caption style is set in the editor's Captions tab, and new reels use the last one you chose.").font(.system(size: 11)).foregroundColor(.secondary)
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
                    .font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                Text("The free trial makes clips from \(License.trialSermons) sermons. Trial exports carry a small “Made with AutoClip” mark.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
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
