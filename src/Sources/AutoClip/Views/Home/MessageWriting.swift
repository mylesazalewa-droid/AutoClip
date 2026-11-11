import SwiftUI
import AppKit

/// Things to read, written from the whole message: a small-group guide, a week of devotionals,
/// a newsletter recap and a YouTube description with chapters.
enum WritingKind: String, CaseIterable, Identifiable, Codable {
    case guide, devotional, newsletter, youtube
    var id: String { rawValue }

    var title: String {
        switch self {
        case .guide: return "Small-group guide"
        case .devotional: return "5-day devotional"
        case .newsletter: return "Newsletter recap"
        case .youtube: return "YouTube description"
        }
    }
    var icon: String {
        switch self {
        case .guide: return "person.3"
        case .devotional: return "sun.max"
        case .newsletter: return "envelope.open"
        case .youtube: return "play.rectangle"
        }
    }
    var blurb: String {
        switch self {
        case .guide: return "An icebreaker, the big idea, the passage, discussion questions and a next step for the week."
        case .devotional: return "Monday to Friday: a verse, a short reflection from the message, a question and a prayer."
        case .newsletter: return "A warm recap for the church email, with the main points and a line to watch the full message."
        case .youtube: return "A description for the full video, with chapters and their times, ready to paste."
        }
    }

    func instructions(kind: ContentKind, church: String, serviceTimes: String) -> String {
        let who = church.isEmpty ? "the church" : church
        switch self {
        case .guide:
            return """
Write a small-group discussion guide for this \(kind.noun). Plain text, with these parts in this order, each under its own heading in capitals:
ICEBREAKER (one light question anyone can answer)
THE BIG IDEA (one or two sentences)
READ (the main Bible passage the speaker used, by reference only; list others they leaned on)
DISCUSS (6 to 8 open questions that move from understanding, to honesty, to application; no yes/no questions)
THIS WEEK (one concrete next step)
PRAY (two or three prayer prompts)
"""
        case .devotional:
            return """
Write a five-day devotional (Monday to Friday) that walks through this \(kind.noun) in order. Plain text. For each day:
the day and a short title on one line, then
VERSE: one Bible reference the speaker used (reference only, no quoted text unless the speaker read it aloud)
A reflection of 90 to 130 words in a warm, direct voice, built on what the speaker actually said
ASK: one question to sit with
PRAY: a one or two sentence prayer
Leave a blank line between days.
"""
        case .newsletter:
            return """
Write a recap of this \(kind.noun) for \(who)'s email newsletter. Plain text, 170 to 240 words:
a subject line on the first line starting "Subject: ", then a blank line,
a warm opening that names the message,
the big idea in a sentence,
three short takeaways as lines starting with "• ",
one line inviting people to watch the full message (write [link] where the link goes)\(serviceTimes.isEmpty ? "" : ",\nand a closing line inviting them to join in person: \(serviceTimes)").
Write like a person on staff, not like an advert.
"""
        case .youtube:
            return """
Write a YouTube description for the full video of this \(kind.noun). Plain text:
two or three sentences on what it's about, with the words people would search for,
a blank line, then "CHAPTERS" and 6 to 10 chapters. Each chapter is one line: the time, a space, then a title of 2 to 6 words. The first chapter must be 0:00. Use only times that appear in the transcript below, at the moments the subject changes, in order, at least a minute apart.
a blank line, then the Bible passages used as "SCRIPTURE: …",
a blank line, then a line about \(who)\(serviceTimes.isEmpty ? "" : " (\(serviceTimes))"),
a blank line, then 5 to 8 hashtags on one line.
"""
        }
    }
}

struct WritingPiece: Codable, Equatable {
    var text: String
    var made = Date()
}

/// Writing saved per message, and the jobs that are making it (they carry on if you leave the tab).
@MainActor
final class WritingStore: ObservableObject {
    static let shared = WritingStore()
    @Published private(set) var pieces: [UUID: [String: WritingPiece]] = [:]
    @Published private(set) var working: Set<String> = []
    @Published var errors: [String: String] = [:]

    nonisolated static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AutoClip/Writing")
    }
    private func file(_ id: UUID) -> URL { Self.dir.appendingPathComponent(id.uuidString + ".json") }
    private static func key(_ id: UUID, _ k: WritingKind) -> String { id.uuidString + "|" + k.rawValue }

    func load(_ id: UUID) {
        guard pieces[id] == nil else { return }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        pieces[id] = (try? Data(contentsOf: file(id))).flatMap { try? d.decode([String: WritingPiece].self, from: $0) } ?? [:]
    }

    /// Whether anything has been written for this message (for the Messages checklist).
    nonisolated static func count(for id: UUID) -> Int {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let f = dir.appendingPathComponent(id.uuidString + ".json")
        return (try? Data(contentsOf: f)).flatMap { try? d.decode([String: WritingPiece].self, from: $0) }?.count ?? 0
    }

    func piece(_ id: UUID, _ k: WritingKind) -> WritingPiece? { pieces[id]?[k.rawValue] }
    func isWorking(_ id: UUID, _ k: WritingKind) -> Bool { working.contains(Self.key(id, k)) }
    func error(_ id: UUID, _ k: WritingKind) -> String? { errors[Self.key(id, k)] }

    func set(_ id: UUID, _ k: WritingKind, text: String) {
        var all = pieces[id] ?? [:]
        all[k.rawValue] = WritingPiece(text: text, made: all[k.rawValue]?.made ?? Date())
        pieces[id] = all
        save(id)
    }

    private func save(_ id: UUID) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted
        try? e.encode(pieces[id] ?? [:]).write(to: file(id), options: .atomic)
        NotificationCenter.default.post(name: Self.changed, object: id)
    }
    static let changed = Notification.Name("WritingStore.changed")

    /// The transcript as timed lines, about one every 25 seconds, so the AI can place chapters.
    nonisolated static func timedTranscript(_ sentences: [ReelDraft.Sentence]) -> String {
        var out: [String] = []
        var line = "", start = 0.0
        func clock(_ t: Double) -> String {
            let i = Int(t); return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
        }
        for s in sentences {
            if line.isEmpty { start = s.start }
            line += (line.isEmpty ? "" : " ") + s.text
            if s.end - start >= 25 { out.append("[\(clock(start))] \(line)"); line = "" }
        }
        if !line.isEmpty { out.append("[\(clock(start))] \(line)") }
        return out.joined(separator: "\n")
    }

    func write(_ k: WritingKind, for rec: AutoReelRecord) {
        let key = Self.key(rec.id, k)
        guard !working.contains(key) else { return }
        guard let src = ReelGenerator.sourceVideoPath(for: rec) else { errors[key] = "The recording for this message can't be found."; return }
        working.insert(key); errors[key] = nil
        let brand = BrandKit.load()
        let kind = rec.kind
        Task {
            defer { working.remove(key) }
            do {
                let words = await Task.detached { TranscriptCache.load(for: src) }.value ?? []
                guard !words.isEmpty else { throw NSError(domain: "AutoClip", code: 1, userInfo: [NSLocalizedDescriptionKey: "This message has no saved transcript yet. Open its clips first so AutoClip can read it."]) }
                let sentences = ReelDraft.sentences(from: SermonFinder.trimCached(words, path: src))
                let prompt = """
You are a writer on a church's communications team. Below is the transcript of a \(kind.noun) titled "\(rec.title)", as timed lines.
\(kind.promptContext)

\(k.instructions(kind: kind, church: brand?.name ?? "", serviceTimes: brand?.serviceTimes ?? ""))

Rules: use only what the speaker said. Never invent stories, facts, quotes or Bible references. Keep the speaker's meaning and tone. No markdown symbols such as # or *. Reply with the finished text only.

TRANSCRIPT:
\(Self.timedTranscript(sentences))
"""
                let text = try await CostTag.$video.withValue(rec.title) {
                    try await LLMClipService.shared.complete(prompt, light: false)
                }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw NSError(domain: "AutoClip", code: 2, userInfo: [NSLocalizedDescriptionKey: "The AI sent back nothing. Try again."]) }
                load(rec.id)
                var all = pieces[rec.id] ?? [:]
                all[k.rawValue] = WritingPiece(text: clean)
                pieces[rec.id] = all
                save(rec.id)
            } catch { errors[key] = error.localizedDescription }
        }
    }
}

/// The Writing tab in a message's window.
struct MessageWritingPane: View {
    let recordID: UUID
    @ObservedObject private var store = WritingStore.shared
    @ObservedObject private var reels = AutoReelsStore.shared
    @AppStorage("writing_kind") private var selected: WritingKind = .guide
    @State private var draft = ""
    @State private var copied = false

    private var record: AutoReelRecord? { reels.reels.first { $0.id == recordID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(WritingKind.allCases) { k in kindChip(k) } }
            }
            Text(selected.blurb).font(.ui(size: 12.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)

            if store.isWorking(recordID, selected) {
                VStack(spacing: 10) {
                    LoadingBar(width: 220)
                    Text("Reading the whole message and writing…").font(.ui(size: 13)).foregroundColor(Theme.muted)
                    Text("You can switch tabs. It carries on.").font(.ui(size: 11.5)).foregroundColor(Theme.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.piece(recordID, selected) != nil {
                TextEditor(text: $draft)
                    .font(.ui(size: 13.5)).lineSpacing(3).scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    .onChange(of: draft) { _, new in
                        if new != store.piece(recordID, selected)?.text { store.set(recordID, selected, text: new) }
                    }
                HStack(spacing: 8) {
                    Text("\(draft.split { $0 == " " || $0 == "\n" }.count) words · you can edit it here").font(.ui(size: 11.5)).foregroundColor(Theme.faint)
                    Spacer()
                    Button { write() } label: { Label("Write again", systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .help("Replaces this with a new version. Uses \(AICost.phrase())")
                    Button { saveFile() } label: { Label("Save as text…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    Button { copy() } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: selected.icon).font(.system(size: 30)).foregroundColor(Theme.sand)
                    Text(selected.title).font(Theme.display(22, weight: .medium)).foregroundColor(Theme.cream)
                    Button { write() } label: { Label("Write it", systemImage: "sparkles") }.buttonStyle(PrimaryButtonStyle())
                    Text("Uses \(AICost.phrase()). It only uses what was said in the message.").font(.ui(size: 11.5)).foregroundColor(Theme.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let e = store.error(recordID, selected) {
                Text(e).font(.ui(size: 12.5)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.load(recordID); sync() }
        .onChange(of: selected) { _, _ in sync() }
        .onChange(of: store.piece(recordID, selected)?.made) { _, _ in sync() }
    }

    private func kindChip(_ k: WritingKind) -> some View {
        let on = selected == k
        let done = store.piece(recordID, k) != nil
        return Button { selected = k } label: {
            HStack(spacing: 8) {
                Image(systemName: k.icon).foregroundColor(on ? Theme.onSand : Theme.sand).frame(width: 18)
                Text(k.title).font(.ui(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                if store.isWorking(recordID, k) { LoadingBar(width: 70) }
                else if done { Image(systemName: "checkmark.circle.fill").foregroundColor(on ? Theme.onSand : Theme.good).font(.ui(size: 12)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundColor(on ? Theme.onSand : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.sand : Theme.ink.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sync() { draft = store.piece(recordID, selected)?.text ?? "" }
    private func write() { if let r = record { store.write(selected, for: r) } }

    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func saveFile() {
        let p = NSSavePanel()
        p.nameFieldStringValue = ((record?.title ?? "Message") + " - " + selected.title).replacingOccurrences(of: "/", with: "-") + ".txt"
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? draft.write(to: url, atomically: true, encoding: .utf8)
    }
}
