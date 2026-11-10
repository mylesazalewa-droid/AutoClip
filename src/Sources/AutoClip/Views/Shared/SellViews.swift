import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Plan

/// Sidebar: which plan this is, and a way to activate.
struct PlanChip: View {
    @ObservedObject private var license = License.shared
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 6) {
                Image(systemName: license.licensed ? "checkmark.seal" : "key").font(.ui(size: 11.5))
                Text(license.status).font(.ui(size: 12)).lineLimit(1)
            }
            .foregroundColor(license.licensed ? Theme.muted : Theme.sand)
            .padding(.horizontal, 12).padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(license.licensed ? "Your AutoClip license" : "Activate AutoClip")
        .sheet(isPresented: $show) { ActivationSheet() }
    }
}

struct ActivationSheet: View {
    @ObservedObject private var license = License.shared
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(license.licensed ? "AutoClip is activated" : "Activate AutoClip").font(Theme.display(24)).foregroundColor(Theme.cream)
            if let info = license.info {
                VStack(alignment: .leading, spacing: 4) {
                    row("Plan", info.planValue.label)
                    row("Licensed to", info.name)
                    row("Ends", info.expires.map { $0.formatted(date: .long, time: .omitted) } ?? "Never")
                    if info.expired { Text("This plan has ended. Your clips still open and export, but new sermons need a new key.").font(.ui(size: 12)).foregroundColor(Theme.warn) }
                }
            } else {
                Text(license.trialLeft > 0
                     ? "You're on the free trial: \(license.trialLeft) of \(License.trialSermons) sermons left. Trial exports carry a small “Made with AutoClip” mark."
                     : License.trialMessage)
                    .font(.ui(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !license.licensed || license.expired {
                Text("LICENSE KEY").font(.ui(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                TextEditor(text: $key).font(.ui(size: 12, design: .monospaced)).frame(height: 70).scrollContentBackground(.hidden)
                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.06)))
                if let error { Text(error).font(.ui(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button("Open a key file…") { openFile() }.controlSize(.small)
                    if license.canBuy { Button("Buy AutoClip") { license.openPurchasePage() }.controlSize(.small) }
                    Spacer()
                    Button("Not now") { dismiss() }
                    Button("Activate") { activate(key) }.buttonStyle(PrimaryButtonStyle(compact: true))
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack {
                    Button("Remove from this Mac") { confirmRemove = true }.controlSize(.small)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 460).background(Theme.bg)
        .confirmationDialog("Remove the license from this Mac?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { license.remove() }
        } message: { Text("You can add it again with the same key.") }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.ui(size: 12)).foregroundColor(Theme.muted).frame(width: 90, alignment: .leading); Text(v).font(.ui(size: 13)).foregroundColor(Theme.text) }
    }

    private func activate(_ text: String) {
        do { try license.activate(text); error = nil; key = "" } catch { self.error = error.localizedDescription }
    }

    private func openFile() {
        let p = NSOpenPanel()
        p.title = "Choose your AutoClip license file"
        guard p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        key = s
        activate(s)
    }
}

/// Shown instead of a page the plan doesn't include.
struct PlanGate<Content: View>: View {
    let feature: PlanFeature
    @ViewBuilder var content: Content
    @ObservedObject private var license = License.shared
    @State private var show = false

    var body: some View {
        if license.has(feature) { content } else {
            EmptyState(icon: "lock", title: "\(feature.label) is on the Church and Lifetime plans",
                       message: "Upgrade to use it. Everything you've made is still here.") {
                Button("Enter a key") { show = true }.buttonStyle(PrimaryButtonStyle())
                if license.canBuy { Button("See plans") { license.openPurchasePage() }.buttonStyle(SecondaryButtonStyle()) }
            }
            .sheet(isPresented: $show) { ActivationSheet() }
        }
    }
}

// MARK: - Updates

struct UpdateChip: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        if let r = updater.available {
            Button { updater.showSheet = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").font(.ui(size: 12))
                    Text("Update to \(r.version)").font(.ui(size: 13, weight: .semibold))
                }
                .foregroundColor(Theme.onSand).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.sand)).contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

struct UpdateSheet: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = updater.available {
                Text("AutoClip \(r.version) is ready").font(Theme.display(24)).foregroundColor(Theme.cream)
                Text("You have \(AppInfo.version).").font(.ui(size: 13)).foregroundColor(Theme.muted)
                ScrollView {
                    Text((try? AttributedString(markdown: r.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(r.notes))
                        .font(.ui(size: 13)).foregroundColor(Theme.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 220).padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
                if let s = updater.status {
                    HStack(spacing: 8) {
                        if let p = updater.progress { ProgressView(value: p).frame(width: 140) } else { ProgressView().controlSize(.small) }
                        Text(s).font(.ui(size: 12)).foregroundColor(Theme.muted)
                    }
                }
                if let e = updater.error ?? updater.blocker { Text(e).font(.ui(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Toggle("Check automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })).toggleStyle(.checkbox).font(.ui(size: 12))
                    Spacer()
                    Button("Later") { updater.showSheet = false }.disabled(updater.status != nil)
                    Button("Install and reopen") { Task { await updater.install() } }
                        .buttonStyle(PrimaryButtonStyle(compact: true)).disabled(updater.status != nil || updater.blocker != nil)
                }
                Text("AutoClip quits and reopens. Your clips and settings stay as they are.").font(.ui(size: 11.5)).foregroundColor(Theme.faint)
            } else {
                Text(updater.error == nil ? "You're up to date" : "Couldn't check").font(Theme.display(24)).foregroundColor(Theme.cream)
                Text(updater.error ?? updater.status ?? "AutoClip \(AppInfo.version) is the latest version.").font(.ui(size: 13)).foregroundColor(Theme.muted)
                HStack {
                    Toggle("Check automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })).toggleStyle(.checkbox).font(.ui(size: 12))
                    Spacer()
                    Button("OK") { updater.showSheet = false }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 480).background(Theme.bg)
    }
}

// MARK: - Problem reports

struct ProblemReportSheet: View {
    @ObservedObject private var reports = ProblemReports.shared
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reports.crashedLastTime ? "AutoClip closed unexpectedly" : "Report a problem").font(Theme.display(24)).foregroundColor(Theme.cream)
            Text(reports.crashedLastTime
                 ? "Sorry about that. A report helps get it fixed. This is everything it contains. Nothing is sent unless you choose to."
                 : "Say what happened. This is everything the report contains. Nothing is sent unless you choose to.")
                .font(.ui(size: 13)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            TextField("What were you doing? (optional)", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            ScrollView {
                Text(reports.report(note: note)).font(.ui(size: 11.5, design: .monospaced)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 200).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
            HStack {
                Button("Don't send") { reports.dismiss() }
                Spacer()
                Button("Save report…") { reports.save(reports.report(note: note)) }
                if reports.canEmail {
                    Button("Email to support") { reports.email(reports.report(note: note)) }.buttonStyle(PrimaryButtonStyle(compact: true))
                }
            }
        }
        .padding(24).frame(width: 540).background(Theme.bg)
    }
}

// MARK: - Help

enum HelpPages {
    static func open() {
        if !AppInfo.websiteURL.isEmpty, let u = URL(string: AppInfo.websiteURL + "/help.html") { NSWorkspace.shared.open(u); return }
        if let p = Bundle.main.path(forResource: "help", ofType: "html") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }
}
