import Foundation

/// Spots the moments a speaker points people to the stage screen ("look at the screen", "as you
/// can see"), so a vertical clip can cut to the whole wide picture for those lines.
enum ScreenCues {
    static let key = "wide_for_screen"
    static var onByDefault: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Seconds a wide shot lasts at least
    static let minimumHold = 4.0

    private static let phrases = [
        "on the screen", "on screen", "on the screens", "at the screen", "at the screens", "up on the screen",
        "behind me", "this slide", "next slide", "on the slide", "that slide",
        "put it up", "put that up", "put this up", "put it on", "throw it up", "pull that up", "pull it up",
        "as you can see", "you can see here", "you can see it", "see it up", "see it there", "look up here",
        "take a look at this", "look at this", "look at the", "this picture", "this photo", "this image",
        "this chart", "this graph", "this diagram", "this map", "this quote",
        "read this with me", "read it with me", "read with me", "read along",
        "it says right here", "says right here", "look at what it says", "look at verse", "look at that verse"
    ]

    static func mentionsScreen(_ raw: String) -> Bool {
        let text = " " + raw.lowercased().map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " }
            .reduce(into: "") { $0.append($1) }.split(separator: " ").joined(separator: " ") + " "
        return phrases.contains { text.contains(" " + $0 + " ") }
    }
}
