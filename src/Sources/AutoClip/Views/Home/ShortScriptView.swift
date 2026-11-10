import SwiftUI
import AppKit

/// Checks a Shorts script as you type, and (with AI) rewrites it with a stronger hook,
/// turns instead of "and then", and an ending that loops back to the start.
enum ScriptCheck {
    struct Finding: Identifiable {
        var id: String
        var good: Bool
        var title: String
        var detail: String
        var example: String? = nil
    }

    static let wordsPerSecond = 2.6

    static func lines(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: "\n.!?")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
    }

    static func seconds(_ s: String) -> Double { Double(words(s).count) / wordsPerSecond }

    static func check(_ script: String) -> [Finding] {
        let text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var out: [Finding] = []
        let ls = lines(text)
        let all = words(text)
        let secs = seconds(text)
        let first = ls.first ?? ""
        let lower = " " + text.lowercased() + " "

        // Length
        if secs < 15 {
            out.append(.init(id: "len", good: false, title: "Quite short (about \(Int(secs)) seconds)",
                             detail: "Under 15 seconds rarely has room for a turn. Add the moment it changes."))
        } else if secs > 60 {
            out.append(.init(id: "len", good: false, title: "Long for a Short (about \(Int(secs)) seconds)",
                             detail: "Most Shorts that hold people are 25–50 seconds. Cut anything that repeats the point."))
        } else {
            out.append(.init(id: "len", good: true, title: "Good length (about \(Int(secs)) seconds)", detail: "\(all.count) words, read at a natural pace."))
        }

        // Hook
        let warmUps = ["so ", "today ", "hey ", "hi ", "in this video", "welcome", "i want to talk", "let me tell you", "good morning", "alright", "okay "]
        let hookScore = HookLab.wordScore(first)
        let firstLower = first.lowercased()
        if warmUps.contains(where: { firstLower.hasPrefix($0) || firstLower.contains("in this video") }) {
            out.append(.init(id: "hook", good: false, title: "The first line is a warm-up",
                             detail: "People decide in about a second. Start with the most surprising thing you'll say.",
                             example: "Instead of “So today I want to talk about worry” → “Worry is a prayer to the wrong god.”"))
        } else if HookLab.dependsOnEarlier(first) {
            out.append(.init(id: "hook", good: false, title: "The first line leans on something before it",
                             detail: "Words like “and”, “but”, “that” or “this” at the start make people feel they missed something."))
        } else if words(first).count > 16 {
            out.append(.init(id: "hook", good: false, title: "The hook is long (\(words(first).count) words)",
                             detail: "Split it into two short lines. The first should land in under three seconds.",
                             example: "“You've been praying for the wrong thing. And it's why nothing's changed.”"))
        } else if hookScore >= 70 {
            out.append(.init(id: "hook", good: true, title: "Strong opening line", detail: "It's short and gives people a reason to stay."))
        } else {
            out.append(.init(id: "hook", good: false, title: "The opening could grab harder",
                             detail: "Try a question, a bold claim, or a number. Speak to “you”.",
                             example: "“Most Christians get this verse backwards.”"))
        }

        // Turns: BUT / THEREFORE instead of AND THEN
        let andThen = ["and then", "and so", "and also", "then we", "then i"].reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
        let turns = [" but ", " so ", " until ", " except ", " therefore ", " which meant ", " that's why "].reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
        if turns == 0 {
            out.append(.init(id: "turn", good: false, title: "No turn yet",
                             detail: "A Short holds attention when something changes. Add a “but” or “so” moment where it flips.",
                             example: "“I prayed every day for a year. But the answer came the day I stopped asking.”"))
        } else if andThen > turns {
            out.append(.init(id: "turn", good: false, title: "More “and then” than turns",
                             detail: "“And then” lists events. “But” and “so” move the story. Swap a few."))
        } else {
            out.append(.init(id: "turn", good: true, title: "It has a turn", detail: "There's a moment where things change."))
        }

        // Long sentences
        let long = ls.filter { words($0).count > 22 }
        if !long.isEmpty {
            out.append(.init(id: "long", good: false, title: "\(long.count) long sentence\(long.count == 1 ? "" : "s")",
                             detail: "Over 22 words is hard to follow on a phone. Break it at the comma.",
                             example: "“\(long[0].prefix(90))…”"))
        }

        // Filler
        let fillers = ["just", "really", "very", "actually", "basically", "literally"]
        let phrases = ["kind of", "sort of", "i think", "you know", "i mean"]
        let found = fillers.filter { all.contains($0) } + phrases.filter { lower.contains(" \($0) ") }
        if found.count >= 2 {
            out.append(.init(id: "filler", good: false, title: "Soft words to cut: \(found.prefix(4).joined(separator: ", "))",
                             detail: "They soften every line. Most can go without changing the meaning."))
        }

        // Ending
        let last = ls.last?.lowercased() ?? ""
        let signOffs = ["thanks for watching", "comment below", "like and subscribe", "follow for more", "let me know", "see you"]
        if ls.count > 1 && signOffs.contains(where: { last.contains($0) }) {
            out.append(.init(id: "end", good: false, title: "Ends on a sign-off",
                             detail: "People swipe at a sign-off. End on your strongest line, ideally one that leads back into the first.",
                             example: "Last line: “…and that's why I stopped asking.” → loops into the first line about prayer."))
        } else if ls.count > 1 {
            let firstWords = Set(words(first).filter { $0.count > 3 })
            let loops = !firstWords.intersection(Set(words(ls.last ?? "").filter { $0.count > 3 })).isEmpty
            out.append(loops
                ? .init(id: "end", good: true, title: "The ending loops back", detail: "The last line echoes the first, so a replay feels natural.")
                : .init(id: "end", good: false, title: "The ending doesn't loop",
                        detail: "If the last line leads back into the first, people watch twice. Echo a word or idea from the opening."))
        }
        return out
    }
}

struct ShortScriptView: View {
    @AppStorage("short_script") private var script = ""
    @AppStorage("short_script_topic") private var topic = ""
    @State private var previous: String?
    @State private var working = false
    @State private var error: String?
    @State private var hooks: [String] = []
    @State private var rewrite: String?
    @State private var why: [String] = []
    @State private var copied = false

    private var findings: [ScriptCheck.Finding] { ScriptCheck.check(script) }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR SCRIPT").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                TextField("What's it about? (optional, helps the AI)", text: $topic).textFieldStyle(.roundedBorder)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $script)
                        .font(.system(size: 15)).scrollContentBackground(.hidden)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    if script.isEmpty {
                        Text("Paste or write your Short here, one line per thought.\n\nStart with the line that stops the scroll.")
                            .font(.system(size: 15)).foregroundColor(Theme.faint).padding(16).allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 300)
                HStack(spacing: 10) {
                    Text("\(ScriptCheck.words(script).count) words · about \(Int(ScriptCheck.seconds(script))) seconds")
                        .font(.system(size: 12)).foregroundColor(Theme.muted)
                    Spacer()
                    if let previous {
                        Button { script = previous; self.previous = nil } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                    Button { copy(script) } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(script.isEmpty)
                    Button { improve() } label: {
                        if working { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Rewriting…") } }
                        else { Label("Make it better", systemImage: "sparkles") }
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    .help("AI rewrites it with a stronger hook, real turns and a looping ending, in your voice. One AI request.")
                }
                if let error { Text(error).font(.system(size: 12.5)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                if !hooks.isEmpty || rewrite != nil { aiCard }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                Text("CHECKS").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                if findings.isEmpty {
                    Text("Start typing and AutoClip checks the hook, length, turns and ending as you go. No AI needed for this part.")
                        .font(.system(size: 12.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(findings) { f in findingRow(f) }
                }
            }
            .frame(width: 330)
        }
    }

    private func findingRow(_ f: ScriptCheck.Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: f.good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(f.good ? Theme.good : Theme.warn).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.ink)
                Text(f.detail).font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if let e = f.example {
                    Text(e).font(.system(size: 12).italic()).foregroundColor(Theme.sand).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hooks.isEmpty {
                Text("HOOKS TO TRY").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                ForEach(hooks, id: \.self) { h in
                    HStack(alignment: .top) {
                        Text(h).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Theme.cream).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Use") { useHook(h) }.buttonStyle(SecondaryButtonStyle(compact: true))
                            .help("Put this at the top of your script in place of the first line")
                    }
                }
            }
            if let rewrite {
                Text("REWRITTEN").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                Text(rewrite).font(.system(size: 13.5)).foregroundColor(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !why.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(why, id: \.self) { w in Label(w, systemImage: "arrow.turn.down.right").font(.system(size: 12)).foregroundColor(Theme.muted) }
                    }
                }
                HStack {
                    Button { previous = script; script = rewrite; self.rewrite = nil } label: { Label("Use this version", systemImage: "checkmark") }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                    Button { copy(rewrite) } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(SecondaryButtonStyle(compact: true))
                    Text("Your version is kept: Undo brings it back.").font(.system(size: 11.5)).foregroundColor(Theme.faint)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sand.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.sand.opacity(0.35)))
    }

    private func useHook(_ h: String) {
        previous = script
        var ls = script.components(separatedBy: "\n")
        if let i = ls.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { ls[i] = h } else { ls = [h] }
        script = ls.joined(separator: "\n")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func improve() {
        error = nil; working = true
        let kind = ContentKind.current
        let prompt = """
You are an editor for short vertical videos (YouTube Shorts, Reels, TikTok)\(kind == .sermon ? " for a church" : ""). Improve the script below so it holds attention to the end. Keep the speaker's voice, their story and their meaning. Never invent facts, stories or Bible verses that aren't there.
\(topic.isEmpty ? "" : "It's about: \(topic)\n")
Rules:
- Hook: the first one or two lines must stop the scroll in under 3 seconds. Lead with the most surprising or emotional line. No warm-ups ("So today…", "Hey guys…").
- Use turns, not lists: connect beats with "but" and "so", not "and then".
- One idea only. Cut anything that repeats it.
- 25 to 50 seconds read aloud (about 65 to 130 words). Short sentences, one thought per line.
- End on the strongest line, and make it lead back into the first line so a replay feels natural. No "like and subscribe".

Reply with JSON only:
{"hooks": ["three different opening lines to try, each under 14 words"], "script": "the full improved script, one line per thought", "why": ["three short notes on what you changed"]}

SCRIPT:
\(script)
"""
        Task {
            do {
                let text = try await LLMClipService.shared.complete(prompt, light: false)
                guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
                      let obj = try? JSONSerialization.jsonObject(with: Data(String(text[a...b]).utf8)) as? [String: Any] else {
                    throw NSError(domain: "AutoClip", code: 1, userInfo: [NSLocalizedDescriptionKey: "The AI's answer couldn't be read. Try again."])
                }
                hooks = (obj["hooks"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                rewrite = (obj["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                why = obj["why"] as? [String] ?? []
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
