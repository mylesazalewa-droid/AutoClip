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
    private static var openedFullScreen = false

    /// The app opens full screen, once per launch. Leaving it with the green button stays left.
    private static func openFullScreen() {
        guard !openedFullScreen else { return }
        openedFullScreen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }), !window.styleMask.contains(.fullScreen) else { return }
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.toggleFullScreen(nil)
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
            .onAppear { Self.openFullScreen() }
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
            Group {
                if appState.selectedProject != nil && !appState.isAnalyzing {
                    ProjectDetailView(project: selectedProjectBinding)
                        .transition(.opacity)
                } else {
                    HomeView()
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
