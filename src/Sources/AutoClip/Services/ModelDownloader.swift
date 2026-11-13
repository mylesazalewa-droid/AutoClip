import Foundation
import SwiftUI

/// Gets the speech model on a new Mac in the background, so the first thing people see is
/// AutoClip itself instead of a window that has to be dealt with first. Anything that needs the
/// model waits for this download rather than starting a second one.
@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    /// At launch: starts the download when the model isn't on this Mac yet.
    func startIfNeeded() {
        guard !WhisperService.shared.modelExists, task == nil else { return }
        start()
    }

    func start() {
        guard task == nil else { return }
        error = nil; running = true; progress = 0
        task = Task {
            do {
                try DiskSpace.check(600_000_000, for: "the speech model", at: AppPaths.root)
                AppLog.write("Speech model: downloading")
                try await WhisperService.shared.downloadModel { p, _ in
                    Task { @MainActor in ModelDownloader.shared.progress = p }
                }
                AppLog.write("Speech model: ready")
            } catch {
                self.error = error.localizedDescription
                AppLog.write("Speech model download stopped: \(error.localizedDescription)")
            }
            running = false
            task = nil
        }
    }

    /// For transcription: waits while the model is downloading, so only one download runs.
    nonisolated static func waitIfDownloading() async {
        while await ModelDownloader.shared.running {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

/// On Home while the speech model is coming down, or when it couldn't.
struct ModelDownloadBanner: View {
    @ObservedObject private var dl = ModelDownloader.shared

    var body: some View {
        if dl.running || dl.error != nil {
            HStack(spacing: 12) {
                Image(systemName: dl.error == nil ? "arrow.down.circle" : "exclamationmark.triangle")
                    .foregroundColor(dl.error == nil ? Theme.sand : Theme.warn)
                VStack(alignment: .leading, spacing: 5) {
                    Text(dl.error == nil ? "Getting the speech model ready… \(Int(dl.progress * 100))%" : "The speech model didn't finish downloading")
                        .font(.ui(size: 13.5, weight: .semibold)).foregroundColor(Theme.cream)
                    if let e = dl.error {
                        Text(e).font(.ui(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        LoadingBar(fraction: max(0.02, dl.progress), width: 280)
                        Text("A one-time download (about 230 MB) so sermons are turned into text right on this Mac. Look around meanwhile.")
                            .font(.ui(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if dl.error != nil {
                    Button("Try Again") { dl.start() }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.sand.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 32)
        }
    }
}
