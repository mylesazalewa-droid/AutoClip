import SwiftUI
import AppKit

/// Header chip: whether auto-import is watching, and its settings.
struct AutoImportChip: View {
    @ObservedObject private var auto = AutoImport.shared
    @State private var show = false
    @State private var hover = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: auto.settings.enabled ? "dot.radiowaves.left.and.right" : "tray.and.arrow.down")
                    .font(.ui(size: 12))
                    .symbolEffect(.pulse, isActive: auto.status != nil)
                Text(auto.settings.enabled ? "Autopilot on" : "Autopilot").font(.ui(size: 13, weight: .medium))
            }
            .foregroundColor(auto.settings.enabled ? Theme.good : (hover ? Theme.cream : Theme.sand))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink.opacity(hover ? 0.08 : 0.04)))
            .overlay(Capsule().stroke((auto.settings.enabled ? Theme.good : Theme.sand).opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(auto.status ?? "Preach Sunday. Your clips are ready Monday.")
        .popover(isPresented: $show, arrowEdge: .bottom) { AutoImportView() }
    }
}

struct AutoImportView: View {
    @ObservedObject private var auto = AutoImport.shared
    @State private var channel = AutoImport.shared.settings.channel
    @State private var folder = AutoImport.shared.settings.folder
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "diamond.fill").font(.ui(size: 5)).foregroundColor(Theme.sand)
                Text("AUTOPILOT").font(.ui(size: 11.5, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
            }
            Text("Preach Sunday. Clips ready Monday.").font(Theme.display(22)).foregroundColor(Theme.cream)
            Text("When a recording lands in a folder, or a new video goes up on your channel, AutoClip makes clips with your Clips settings and checks them with Context Guard. They wait on Home for you to review. Nothing is ever posted for you.")
                .font(.ui(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("YOUTUBE CHANNEL OR PLAYLIST").font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                TextField("https://www.youtube.com/@yourchurch", text: $channel)
                    .textFieldStyle(.roundedBorder).font(.ui(size: 13))
                Text("WATCH FOLDER").font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint).padding(.top, 4)
                HStack {
                    Text(folder.isEmpty ? "None" : folder).font(.ui(size: 12)).foregroundColor(folder.isEmpty ? Theme.faint : Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if !folder.isEmpty { Button("Clear") { folder = "" }.controlSize(.small) }
                    Button("Choose…") { if let f = pickFolder("Choose a folder to watch for new videos or audio") { folder = f.path } }.controlSize(.small)
                }
            }

            Toggle(isOn: Binding(get: { auto.settings.makeKit }, set: { auto.settings.makeKit = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also build the content kit").font(.ui(size: 13, weight: .medium)).foregroundColor(Theme.cream)
                    Text("Into \(auto.kitFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                        .font(.ui(size: 11.5)).foregroundColor(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            .toggleStyle(.switch).tint(Theme.sand)
            HStack {
                Text("Check every").font(.ui(size: 12)).foregroundColor(Theme.muted)
                Picker("", selection: Binding(get: { auto.settings.everyMinutes }, set: { auto.settings.everyMinutes = $0 })) {
                    Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("hour").tag(60); Text("3 hours").tag(180)
                }
                .labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                Button("Kit folder…") { if let f = pickFolder("Where should content kits go?") { auto.settings.kitFolder = f.path } }
                    .controlSize(.small)
            }

            HStack {
                Text("At most").font(.ui(size: 12)).foregroundColor(Theme.muted)
                Picker("", selection: Binding(get: { auto.settings.dailyLimit }, set: { auto.settings.maxPerDay = $0 })) {
                    Text("1 video a day").tag(1); Text("3 videos a day").tag(3); Text("5 videos a day").tag(5); Text("10 videos a day").tag(10)
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .help("A limit on unattended work, so a folder of old videos can't run up your AI bill")
                Spacer()
            }
            Toggle(isOn: Binding(get: { auto.opensAtLogin }, set: { auto.setOpensAtLogin($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open AutoClip when this Mac starts").font(.ui(size: 13, weight: .medium)).foregroundColor(Theme.cream)
                    Text(auto.loginNote ?? "Autopilot only works while AutoClip is open and the Mac is awake.")
                        .font(.ui(size: 11.5)).foregroundColor(auto.loginNote == nil ? Theme.muted : Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(Theme.sand)

            if let s = auto.status {
                HStack(spacing: 6) { LoadingBar(status: s, width: 100); Text(s).font(.ui(size: 12)).foregroundColor(Theme.muted).lineLimit(2) }
            } else if let c = auto.lastCheck {
                Text("Last checked \(c.formatted(date: .omitted, time: .shortened))").font(.ui(size: 11.5)).foregroundColor(Theme.faint)
            }

            HStack(spacing: 8) {
                if auto.settings.enabled {
                    Button("Turn off") { auto.settings.enabled = false }.buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("Check now") { save(); Task { await auto.check() } }.buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(auto.status != nil)
                    if !auto.settings.channel.isEmpty {
                        Button("Do the latest video now") { save(); Task { await auto.doLatestNow() } }
                            .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(auto.status != nil)
                            .help("Make clips from the newest video on the channel, even though it was there before you started watching")
                    }
                } else {
                    Button { startWatching() } label: { Label("Turn on Autopilot", systemImage: "dot.radiowaves.left.and.right") }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        .disabled(starting || (channel.trimmingCharacters(in: .whitespaces).isEmpty && folder.isEmpty))
                }
            }
            if !auto.settings.enabled {
                Text("Videos already there are skipped. Only new ones become clips.")
                    .font(.ui(size: 11.5)).foregroundColor(Theme.faint)
            }

            if !auto.log.isEmpty {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text("RECENT").font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                ForEach(auto.log.suffix(5).reversed()) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.ui(size: 12)).foregroundColor(e.ok ? Theme.good : Theme.warn)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.ui(size: 12, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1)
                            Text(e.detail).font(.ui(size: 11.5)).foregroundColor(Theme.muted).lineLimit(2)
                        }
                        Spacer()
                        Text(Date(timeIntervalSince1970: e.date).formatted(date: .abbreviated, time: .shortened))
                            .font(.ui(size: 11)).foregroundColor(Theme.faint)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.surface)
        .onDisappear { save() }
    }

    private func save() {
        auto.settings.channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        auto.settings.folder = folder
    }

    private func startWatching() {
        save()
        starting = true
        Task {
            await auto.markCurrentAsSeen()
            auto.settings.enabled = true
            starting = false
        }
    }

    private func pickFolder(_ title: String) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Choose"
        return p.runModal() == .OK ? p.url : nil
    }
}
