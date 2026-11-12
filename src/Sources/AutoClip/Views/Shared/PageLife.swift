import SwiftUI

// Pages stay alive once opened, so their work and their place survive changing tabs.
// What used to happen when a page went away now happens when it's hidden.

private struct PageVisibleKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while this page is kept alive behind another one.
    var pageVisible: Bool {
        get { self[PageVisibleKey.self] }
        set { self[PageVisibleKey.self] = newValue }
    }
}

private struct PageWatcher: ViewModifier {
    @Environment(\.pageVisible) private var visible
    let onHide: () -> Void
    let onShow: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: visible) { now in if now { onShow() } else { onHide() } }
    }
}

private struct WorkReporter: ViewModifier {
    let tab: HomeTab
    let key: String
    let busy: Bool
    func body(content: Content) -> some View {
        content
            .onAppear { TabActivity.shared.set(tab, key, busy) }
            .onChange(of: busy) { TabActivity.shared.set(tab, key, $0) }
    }
}

extension View {
    /// Stops playback when the page is hidden, so nothing plays from a page you can't see.
    func pausesWhenHidden(_ pause: @escaping () -> Void) -> some View { modifier(PageWatcher(onHide: pause, onShow: { })) }
    /// Runs each time you come back to the page, for anything that may have changed meanwhile.
    func onPageShown(_ action: @escaping () -> Void) -> some View { modifier(PageWatcher(onHide: { }, onShow: action)) }
    /// Marks the page as working, which shows on its sidebar link while you're elsewhere.
    func reportsWork(_ tab: HomeTab, _ key: String, _ busy: Bool) -> some View { modifier(WorkReporter(tab: tab, key: key, busy: busy)) }
}

/// Which pages have work running.
@MainActor
final class TabActivity: ObservableObject {
    static let shared = TabActivity()
    @Published private var working: Set<String> = []
    private var started: [String: Date] = [:]

    func set(_ tab: HomeTab, _ key: String, _ busy: Bool) {
        let id = "\(tab.rawValue)|\(key)"
        if busy {
            if working.insert(id).inserted {
                started[id] = Date()
                AppLog.write("Started: \(id) (using \(AppLog.memoryMB()) MB)")
            }
        } else if working.remove(id) != nil {
            // Long work that finished while you were in another app gets a notification
            let ran = started.removeValue(forKey: id).map { Date().timeIntervalSince($0) } ?? 0
            AppLog.write("Finished: \(id) after \(Int(ran)) s (using \(AppLog.memoryMB()) MB)")
            if ran >= 45, !isWorking(tab) { Task { await Notifier.pageDone(tab) } }
        }
    }

    func isWorking(_ tab: HomeTab) -> Bool { working.contains { $0.hasPrefix(tab.rawValue + "|") } }

    /// Anything at all running in the app, on any page.
    var anythingRunning: Bool {
        !working.isEmpty || AppState.shared.isAnalyzing || AutoImport.shared.status != nil
            || AutoReelsStore.shared.activeJobs.contains { !$0.isFinished }
            || !PodcastStore.shared.status.isEmpty || ShortDoctorModel.shared.status != nil
    }
}
