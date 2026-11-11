import AppKit

/// Tells the user when an export finished but something was left out (like the music).
@MainActor
final class ExportNotes {
    static let shared = ExportNotes()
    private var shown: Set<String> = []

    func add(_ text: String) {
        // Once per session for the same thing, so a batch export doesn't stack them up
        guard shown.insert(text).inserted else { return }
        let alert = NSAlert()
        alert.messageText = "Your clip was exported"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, w.attachedSheet == nil {
            alert.beginSheetModal(for: w)
        } else {
            alert.runModal()
        }
    }
}
