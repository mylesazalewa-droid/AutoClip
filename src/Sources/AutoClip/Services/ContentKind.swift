import Foundation

/// What kind of videos the user makes. It changes how the AI reads a talk (a sermon lands on
/// grace and Scripture; a podcast on a guest's insight), which words captions highlight, and
/// what the content kit writes (sermon notes vs show notes).
enum ContentKind: String, CaseIterable, Identifiable, Codable {
    case sermon, talk, podcast, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sermon: return "Sermons"
        case .talk: return "Talks & teaching"
        case .podcast: return "Podcasts & interviews"
        case .other: return "Any video"
        }
    }

    var icon: String {
        switch self {
        case .sermon: return "book.closed"
        case .talk: return "person.wave.2"
        case .podcast: return "mic"
        case .other: return "video"
        }
    }

    /// What one video is called in prompts and labels.
    var noun: String {
        switch self {
        case .sermon: return "sermon"
        case .talk: return "talk"
        case .podcast: return "episode"
        case .other: return "video"
        }
    }

    /// Bible references get cards and highlighted words only for sermons.
    var usesScripture: Bool { self == .sermon }

    /// A line for prompts saying what the source is and what a good short looks like for it.
    var promptContext: String {
        switch self {
        case .sermon:
            return "The source is a sermon. Good shorts carry one biblical truth or story with the preacher's own application."
        case .talk:
            return "The source is a talk or teaching (not necessarily religious). Good shorts deliver one clear insight, lesson or story with the speaker's own takeaway. Don't add a spiritual angle that isn't there."
        case .podcast:
            return "The source is a podcast or interview with one or more people talking. Good shorts capture one strong opinion, story, surprising fact or exchange, and can include a short question that sets it up. Don't add a spiritual angle that isn't there."
        case .other:
            return "The source is a video of people talking (vlog, lesson, interview or similar). Good shorts deliver one clear, interesting moment that stands on its own. Don't add a spiritual angle that isn't there."
        }
    }

    /// How a reel may resolve a struggle it raises.
    var resolutionRule: String {
        switch self {
        case .sermon:
            return "If it raises a struggle and the speaker resolves it (grace, forgiveness, a promise, a challenge), include that resolution — but only if it is clearly about the same struggle. Don't end on condemnation."
        default:
            return "If it raises a problem and the speaker answers it, include the answer — but only if it is clearly about the same problem."
        }
    }

    private static let key = "content_kind"

    /// The user's choice (Sermons until they pick something else).
    static var current: ContentKind {
        get { ContentKind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .sermon }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
