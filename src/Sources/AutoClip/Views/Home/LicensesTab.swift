import SwiftUI
import AppKit

/// Manage → Licences, shown only on the owner's Mac: make a key, and find any key again later.
struct LicensesTab: View {
    @ObservedObject private var store = LicenseIssuer.shared
    @State private var name = ""
    @State private var email = ""
    @State private var plan: Plan = .church
    @State private var length = 365
    @State private var search = ""
    @State private var error: String?
    @State private var justMade: IssuedLicense.ID?
    @State private var copied: IssuedLicense.ID?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var pasteError: String?
    @State private var removing: IssuedLicense?

    private static let lengths: [(Int, String)] = [(30, "1 month"), (365, "1 year"), (0, "Never ends")]

    private var shown: [IssuedLicense] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.issued }
        return store.issued.filter { ($0.name + " " + ($0.email ?? "") + " " + $0.note + " " + $0.plan).lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            PageHeader(eyebrow: "Manage", title: "Licences",
                       subtitle: "Make keys for churches and find them again. Only you see this page, on this Mac.") {
                Button { pasting = true } label: { Label("Add a key you gave out before", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            VStack(alignment: .leading, spacing: 18) {
                if !store.keyWorks {
                    Label("The private key in Documents › AutoClip License Keys doesn't match this version of AutoClip, so keys made here won't work.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5)).foregroundColor(Theme.warn)
                }
                newCard
                listCard
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.bottom, 28).padding(.top, 8)
        }
        .onAppear { store.load() }
        .sheet(isPresented: $pasting) { pasteSheet }
        .alert("Take \(removing?.name ?? "this") off the list?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Take off the list", role: .destructive) { if let r = removing { store.remove(r) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This only removes it from your list. The key keeps working until its end date, because AutoClip checks keys without going online.")
        }
    }

    // MARK: New key

    private var newCard: some View {
        AssessCard(title: "New key", subtitle: "Make it, then copy or email it to them.") {
            HStack(spacing: 12) {
                labelled("Church or person") { TextField("Grace Community Church", text: $name).textFieldStyle(.roundedBorder) }
                labelled("Email (optional)") { TextField("office@church.org", text: $email).textFieldStyle(.roundedBorder) }
            }
            HStack(spacing: 18) {
                labelled("Plan") {
                    Picker("", selection: $plan) {
                        Text("Church").tag(Plan.church)
                        Text("Solo").tag(Plan.solo)
                        Text("Lifetime").tag(Plan.lifetime)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
                labelled("Works for") {
                    Picker("", selection: $length) {
                        ForEach(Self.lengths, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                }
                Spacer(minLength: 0)
            }
            Text(planNote).font(.system(size: 11.5)).foregroundColor(Theme.faint)
            HStack(spacing: 10) {
                Button { make() } label: { Label("Make key", systemImage: "key.fill") }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error { Text(error).font(.system(size: 12)).foregroundColor(Theme.danger) }
            }
        }
    }

    private var planNote: String {
        switch plan {
        case .church: return "Church: unlimited sermons, no mark, plus Volunteer Mode and Worship review."
        case .solo: return "Solo: unlimited sermons and no mark. No Volunteer Mode or Worship review."
        case .lifetime: return "Lifetime: everything in Church. Usually set to Never ends."
        case .trial: return ""
        }
    }

    private func make() {
        do {
            let item = try store.issue(name: name, email: email, plan: plan, days: length == 0 ? nil : length)
            error = nil; name = ""; email = ""
            justMade = item.id
            copy(item)
        } catch { self.error = error.localizedDescription }
    }

    // MARK: List

    private var listCard: some View {
        AssessCard(title: "Keys you've given out", subtitle: store.issued.isEmpty ? nil : "\(store.issued.count) in all. Lost key? Find them here and copy it again. It works on any Mac.") {
            if store.issued.isEmpty {
                Text("Keys you make here are kept in a list so you never have to make one again because someone lost theirs.")
                    .font(.system(size: 12.5)).foregroundColor(Theme.muted)
            } else {
                TextField("Find a church, email or note", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        row(item)
                        if item.id != shown.last?.id { Divider().overlay(Theme.line) }
                    }
                }
                if shown.isEmpty { Text("Nothing matches “\(search)”.").font(.system(size: 12.5)).foregroundColor(Theme.muted) }
            }
        }
    }

    private func row(_ item: IssuedLicense) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                    Text(item.planValue.label).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.sand)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.sand.opacity(0.14)))
                    status(item)
                    if justMade == item.id { Text("New").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.good) }
                }
                Text(detail(item)).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
                TextField("Note (who paid, invoice, Mac name…)", text: Binding(
                    get: { item.note },
                    set: { var c = item; c.note = $0; store.update(c) }))
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.faint)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button { copy(item) } label: {
                    Label(copied == item.id ? "Copied" : "Copy key", systemImage: copied == item.id ? "checkmark" : "doc.on.doc").lineLimit(1).fixedSize()
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Copy the key to paste into an email or message")
                Button { mail(item) } label: { Image(systemName: "envelope") }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Start an email with the key and how to use it. You check it and press Send.")
                if item.expires != nil {
                    Button { renew(item) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .help("Renew: a new key for the same length, starting when this one ends")
                }
                Button { removing = item } label: { Image(systemName: "trash") }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Take off the list")
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private func status(_ item: IssuedLicense) -> some View {
        if let end = item.expires {
            let days = Int(ceil(end.timeIntervalSinceNow / 86400))
            if days <= 0 {
                Text("Ended").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.danger)
            } else if days <= 30 {
                Text("Ends in \(days) day\(days == 1 ? "" : "s")").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.warn)
            }
        }
    }

    private func detail(_ item: IssuedLicense) -> String {
        var parts: [String] = []
        if let e = item.email { parts.append(e) }
        parts.append("Made " + item.issued.formatted(date: .abbreviated, time: .omitted))
        parts.append(item.expires.map { "works until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "never ends")
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func copy(_ item: IssuedLicense) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.key, forType: .string)
        copied = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == item.id { copied = nil } }
    }

    private func mail(_ item: IssuedLicense) {
        let until = item.expires.map { "It works until \($0.formatted(date: .long, time: .omitted))." } ?? "It doesn't run out."
        let body = """
        Hi,

        Here's your AutoClip licence key (\(item.planValue.label) plan). \(until)

        \(item.key)

        To use it: open AutoClip, click Activate AutoClip at the bottom of the sidebar, paste the whole key and click Activate. It works on any Mac you use AutoClip on.

        Thanks!
        """
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = item.email ?? ""
        c.queryItems = [URLQueryItem(name: "subject", value: "Your AutoClip licence key"), URLQueryItem(name: "body", value: body)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    private func renew(_ item: IssuedLicense) {
        do {
            let n = try store.renew(item)
            justMade = n.id; copy(n); error = nil
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Adding old keys

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a key you gave out before").font(.system(size: 16, weight: .semibold))
            Text("Paste a key you made with the Terminal tool. The church's name, plan and dates are read from the key.")
                .font(.system(size: 12.5)).foregroundColor(.secondary)
            TextEditor(text: $pasted).font(.system(size: 11.5, design: .monospaced)).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let pasteError { Text(pasteError).font(.system(size: 12)).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Cancel") { pasting = false; pasted = ""; pasteError = nil }
                Button("Add") {
                    var added = 0, bad = 0
                    for line in pasted.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        if store.addExisting(String(line)) { added += 1 } else { bad += 1 }
                    }
                    if bad > 0 { pasteError = bad == 1 && added == 0 ? "That isn't an AutoClip key." : "\(bad) of those aren't AutoClip keys." }
                    else { pasting = false; pasted = ""; pasteError = nil }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func labelled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.muted)
            content()
        }
    }
}
