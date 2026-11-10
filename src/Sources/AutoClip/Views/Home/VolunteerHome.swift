import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Three big buttons, and no way to break anything.
struct VolunteerHome: View {
    @ObservedObject private var mode = VolunteerMode.shared
    @ObservedObject private var store = AutoReelsStore.shared
    @ObservedObject private var auto = AutoImport.shared
    @Environment(\.openWindow) private var openWindow

    /// The newest real sermon. The built-in sample doesn't count as this week's.
    private var latest: AutoReelRecord? {
        store.reels.first { !($0.drafts ?? []).isEmpty && !SampleSermon.isSample(path: $0.sourceVideoPath ?? "") }
    }
    private var working: Bool { auto.status != nil || store.activeJobs.contains { !$0.isFinished } }
    private var kept: Int { (latest?.drafts ?? []).filter { $0.exportedPath != nil }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thanks for serving today").font(Theme.display(34, weight: .medium)).foregroundColor(Theme.ink)
                    Text(mode.style.map { "Using \($0.name), so your clips will match without changing anything." }
                         ?? "Follow the three steps. Everything is already set up.")
                        .font(.ui(size: 13)).foregroundColor(Theme.muted)
                }
                HStack(alignment: .top, spacing: 16) {
                    step(1, "Add the sermon", detail: working ? (auto.status ?? "Working on it. You can leave this open.") : "Choose this week's video. AutoClip finds the clips for you.",
                         button: working ? nil : "Choose the video", icon: "plus", primary: latest == nil) { addSermon() }
                    step(2, "Pick the best clips", detail: latest == nil ? "After step 1, you'll keep or toss each clip." : "Keep or toss each clip from “\(latest!.title)”.",
                         button: latest == nil ? nil : "Start reviewing", icon: "rectangle.stack", primary: latest != nil && kept == 0) {
                        guard let id = latest?.id else { return }
                        store.reviewOnOpen = id
                        openWindow(id: "reel-window", value: id)
                    }
                    step(3, "Export them", detail: latest == nil ? "Your finished clips will be saved to a folder." : "\(kept) of \(latest?.drafts?.count ?? 0) exported so far.",
                         button: latest == nil ? nil : "Open the clips", icon: "square.and.arrow.up", primary: kept > 0) {
                        guard let id = latest?.id else { return }
                        openWindow(id: "reel-window", value: id)
                    }
                }
                if store.reels.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Earlier sermons").font(.ui(size: 13, weight: .semibold)).foregroundColor(Theme.cream)
                        ForEach(store.reels.prefix(8)) { r in
                            Button { openWindow(id: "reel-window", value: r.id) } label: {
                                HStack {
                                    Image(systemName: "film").foregroundColor(Theme.sand)
                                    Text(r.title).font(.ui(size: 13)).foregroundColor(Theme.text).lineLimit(1)
                                    Spacer()
                                    Text("\(r.drafts?.count ?? r.paths.count) clips").font(.ui(size: 12)).foregroundColor(Theme.muted)
                                }
                                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface)).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 20)
            }
            .padding(36)
        }
    }

    private func step(_ n: Int, _ title: String, detail: String, button: String?, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(n)").font(Theme.display(26, weight: .medium)).foregroundColor(primary ? Theme.bg : Theme.sand)
                .frame(width: 44, height: 44).background(Circle().fill(primary ? Theme.sand : Theme.sand.opacity(0.14)))
            Text(title).font(Theme.display(21, weight: .medium)).foregroundColor(Theme.cream)
            Text(detail).font(.ui(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let button {
                if primary {
                    Button(action: action) { Label(button, systemImage: icon).frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button(action: action) { Label(button, systemImage: icon).frame(maxWidth: .infinity) }.buttonStyle(SecondaryButtonStyle())
                }
            } else if n == 1 {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(primary ? Theme.sand.opacity(0.1) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(primary ? Theme.sand.opacity(0.5) : Theme.line))
    }

    private func addSermon() {
        let p = NSOpenPanel()
        p.title = "Choose this week's sermon"
        p.allowedContentTypes = [.movie, .audio]
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await AutoImport.shared.makeReelsNow(from: url) }
    }
}

/// Sidebar control: set up Volunteer Mode, or leave it.
struct VolunteerChip: View {
    @ObservedObject private var mode = VolunteerMode.shared
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.enabled ? "lock.fill" : "person.2").font(.ui(size: 12))
                Text(mode.enabled ? "Volunteer mode" : "Volunteer mode").font(.ui(size: 13, weight: .medium))
            }
            .foregroundColor(mode.enabled ? Theme.sand : Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Theme.ink.opacity(0.04)))
            .overlay(Capsule().stroke(Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("A simple, locked-down AutoClip for whoever's serving this week")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VolunteerSettings(close: { show = false })
        }
    }
}

private struct VolunteerSettings: View {
    let close: () -> Void
    @ObservedObject private var mode = VolunteerMode.shared
    @State private var name = VolunteerMode.shared.style?.name ?? ""
    @State private var pin = ""
    @State private var exitPIN = ""
    @State private var note: String?
    @State private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "diamond.fill").font(.ui(size: 5)).foregroundColor(Theme.sand)
                Text("VOLUNTEER MODE").font(.ui(size: 11.5, weight: .semibold)).tracking(2).foregroundColor(Theme.sand)
            }
            if mode.enabled { leaving } else { setup }
        }
        .padding(20).frame(width: 400).background(Theme.surface)
    }

    private var leaving: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Leave Volunteer Mode").font(Theme.display(22)).foregroundColor(Theme.cream)
            if mode.hasPIN {
                SecureField("PIN", text: $exitPIN).textFieldStyle(.roundedBorder).onSubmit { leave() }
                if wrong { Text("That PIN isn't right.").font(.ui(size: 12)).foregroundColor(Theme.danger) }
            } else {
                Text("This brings back every page and setting.").font(.ui(size: 13)).foregroundColor(Theme.muted)
            }
            Button("Leave Volunteer Mode") { leave() }.buttonStyle(PrimaryButtonStyle(compact: true))
        }
    }

    private func leave() {
        if mode.turnOff(pin: exitPIN) { close() } else { wrong = true }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One style. Three buttons.").font(Theme.display(22)).foregroundColor(Theme.cream)
            Text("Set up your captions, size and length the way you like them in Clips. Save that as your church's style here. Volunteers then see only three steps, and their clips match.")
                .font(.ui(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Style name, like Grace Church", text: $name).textFieldStyle(.roundedBorder).font(.ui(size: 13))
                Button(mode.style == nil ? "Save style" : "Update style") {
                    mode.saveCurrentStyle(name: name); note = "Saved from your current Clips settings."
                }.controlSize(.small)
            }
            if let s = mode.style {
                Text(s.summary).font(.ui(size: 12)).foregroundColor(Theme.text)
            }
            HStack {
                Button("Share style…") { share() }.controlSize(.small).disabled(mode.style == nil)
                    .help("Save a file you can open on another Mac")
                Button("Open a style…") { open() }.controlSize(.small)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PIN TO LEAVE (OPTIONAL)").font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                SecureField(mode.hasPIN ? "Keep the current PIN" : "No PIN", text: $pin).textFieldStyle(.roundedBorder).font(.ui(size: 13))
                Text("Stops accidental changes. It isn't a password, so don't reuse one.").font(.ui(size: 11.5)).foregroundColor(Theme.faint)
            }
            if let note { Text(note).font(.ui(size: 12)).foregroundColor(Theme.good).fixedSize(horizontal: false, vertical: true) }
            if !License.shared.has(.volunteerMode) {
                Text("Volunteer Mode is on the Church and Lifetime plans.").font(.ui(size: 12)).foregroundColor(Theme.warn)
            }
            Button {
                if !pin.isEmpty { mode.setPIN(pin) }
                mode.turnOn()
                HomeNav.shared.open(.projects)
                close()
            } label: { Label("Turn on Volunteer Mode", systemImage: "lock") }
            .buttonStyle(PrimaryButtonStyle(compact: true))
            .disabled(mode.style == nil || !License.shared.has(.volunteerMode))
        }
    }

    private func share() {
        let p = NSSavePanel()
        p.title = "Save your church style"
        p.nameFieldStringValue = (mode.style?.name ?? "Church style") + ".autoclipstyle"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try mode.exportStyle(to: u); note = "Saved. Open it from this panel on the other Mac." }
        catch { note = error.localizedDescription }
    }

    private func open() {
        let p = NSOpenPanel()
        p.title = "Choose a church style file"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try mode.importStyle(from: u); name = mode.style?.name ?? ""; note = "Style loaded." }
        catch { note = "That file isn't a church style." }
    }
}
