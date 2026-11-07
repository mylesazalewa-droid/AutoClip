import Foundation

/// Where AutoClip points people. Fill these in before selling: empty ones hide their buttons.
enum AppInfo {
    /// Support address for problem reports. Empty = reports can be saved but not emailed.
    static let supportEmail = ""
    /// Where people buy a license. Empty = the Buy button opens the website instead.
    static let purchaseURL = ""
    /// The product website. Empty = help opens the copy inside the app.
    static let websiteURL = ""
    /// Where updates come from: the latest release of this GitHub repo.
    static let releasesRepo = "mylesazalewa-droid/AutoClip"

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}
