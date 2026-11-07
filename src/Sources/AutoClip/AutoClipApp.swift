import SwiftUI

@main
struct AutoClipApp: App {
    var body: some Scene {
        WindowGroup {
            MainWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Project") {
                Button("Import Video...") { AppState.shared.triggerImport() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Command Bar…") { CommandBar.shared.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        // Auto Reels: one window per video's reels, with a large preview
        WindowGroup("Reels", id: "reel-window", for: UUID.self) { $id in
            if let id { ReelWindowView(recordID: id).tint(Theme.action).preferredColorScheme(.dark) }
        }
        .defaultSize(width: 1280, height: 820)
    }
}

struct MainWindow: View {
    private static var sizedWindow = false

    /// Opens corner to corner in a normal window, keeping the red, yellow and green buttons.
    /// Once per launch, so resizing it afterwards sticks.
    private static func fillScreen() {
        guard !sizedWindow else { return }
        sizedWindow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
            func fill() { if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true, animate: false) } }
            // macOS may bring back true full screen from the last run
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { fill() }
            } else { fill() }
        }
    }

    @ObservedObject private var appState = AppState.shared

    var body: some View {
        ContentView()
            .sheet(isPresented: $appState.showOnboarding) {
                SetupView()
            }
            .alert("Error", isPresented: $appState.showError, presenting: appState.errorMessage) { _ in
                Button("OK") { }
            } message: { message in
                Text(message)
            }
            .frame(minWidth: 900, idealWidth: 1280, minHeight: 600, idealHeight: 800)
            .tint(Theme.action)
            .preferredColorScheme(.dark)
            .task { AutoImport.shared.start() }
            .modifier(CommandBarHost())
            .onAppear { Self.fillScreen() }
    }
}

/// Lets the command bar open reels in their own windows.
private struct CommandBarHost: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            CommandBar.shared.install()
            CommandBar.shared.openReel = { id in
                if AutoReelsStore.shared.reels.first(where: { $0.id == id })?.drafts != nil {
                    openWindow(id: "reel-window", value: id)
                } else {
                    AutoReelsStore.shared.navigateToReelID = id
                    HomeNav.shared.open(.autoReels)
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var library = LibraryService.shared

    var selectedProjectBinding: Binding<Project> {
        Binding(
            get: { appState.selectedProject ?? Project(id: UUID(), title: "", videoPath: "", duration: 0, dateCreated: 0, clipCount: 0, thumbnailData: nil, clips: []) },
            set: { updated in
                appState.selectedProject = updated
                library.updateProject(updated)
            }
        )
    }

    var body: some View {
        ZStack {
            let inProject = appState.selectedProject != nil && !appState.isAnalyzing
            ZStack {
                // Stays alive behind a project, so work on its pages keeps going
                HomeView()
                    .opacity(inProject ? 0 : 1)
                    .allowsHitTesting(!inProject)
                    .disabled(inProject)
                    .environment(\.pageVisible, !inProject)
                if inProject {
                    ProjectDetailView(project: selectedProjectBinding)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(!appState.overlayVisible)
            .animation(.easeInOut(duration: 0.2), value: appState.selectedProject?.id)

            // Full-screen processing overlay — hidden when running in background
            if appState.overlayVisible {
                ProcessingOverlayView()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: appState.overlayVisible)
                    .zIndex(10)
            }
        }
    }
}
