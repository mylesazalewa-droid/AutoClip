import SwiftUI

struct SetupView: View {
    @ObservedObject private var whisper = WhisperService.shared
    @State private var downloadProgress: Double = 0
    @State private var statusText = "Ready to download"
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // Logo
            VStack(spacing: 12) {
                LogoMark(size: 72)

                Text("AutoClip")
                    .font(.ui(size: 32, weight: .bold))
                    .foregroundColor(Theme.ink)

                Text("Sermon clips, ready by Monday")
                    .font(.ui(size: 16))
                    .foregroundColor(Theme.ink.opacity(0.55))
            }

            Divider()
                .background(Theme.ink.opacity(0.1))
                .padding(.horizontal, 60)

            // AI Model setup
            VStack(spacing: 16) {
                Text("Download AI Transcription Model")
                    .font(.ui(size: 18, weight: .semibold))
                    .foregroundColor(Theme.ink)

                Text("AutoClip uses on-device AI to transcribe and analyze your videos.\nNo internet connection or API keys required after setup.")
                    .font(.ui(size: 14))
                    .foregroundColor(Theme.ink.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                // Model info
                HStack(spacing: 20) {
                    modelFeature(icon: "cpu", text: "On-device")
                    modelFeature(icon: "lock.fill", text: "Private")
                    modelFeature(icon: "wifi.slash", text: "Offline")
                }

                // Model size info
                Text("Model: Whisper Small (English) · ~230 MB")
                    .font(.ui(size: 13))
                    .foregroundColor(Theme.ink.opacity(0.55))

                if isDownloading {
                    VStack(spacing: 8) {
                        ProgressView(value: downloadProgress)
                            .accentColor(Theme.sand)
                            .frame(maxWidth: 360)

                        Text(statusText)
                            .font(.ui(size: 13))
                            .foregroundColor(Theme.ink.opacity(0.55))
                    }
                } else {
                    if let error = downloadError {
                        Text(error)
                            .font(.ui(size: 13))
                            .foregroundColor(Theme.danger)
                            .padding(.horizontal, 40)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: startDownload) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.ui(size: 16))
                            Text("Download AI Model")
                                .font(.ui(size: 16, weight: .semibold))
                        }
                        .foregroundColor(Theme.onSand)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 13)
                        .background(Theme.sand)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    if SampleSermon.available {
                        Button("See a finished example first") {
                            AppState.shared.showOnboarding = false
                            SampleSermon.open()
                        }
                        .buttonStyle(.plain).font(.ui(size: 13)).foregroundColor(Theme.sand)
                    }
                }
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(width: 560, height: 500)
        .background(Theme.bg)
    }

    func modelFeature(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.ui(size: 20))
                .foregroundColor(Theme.sand)
            Text(text)
                .font(.ui(size: 13))
                .foregroundColor(Theme.ink.opacity(0.6))
        }
    }

    func startDownload() {
        isDownloading = true
        downloadError = nil

        Task {
            do {
                try await WhisperService.shared.downloadModel { progress, status in
                    DispatchQueue.main.async {
                        self.downloadProgress = progress
                        self.statusText = status
                    }
                }
                await MainActor.run {
                    AppState.shared.showOnboarding = false
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = error.localizedDescription
                }
            }
        }
    }
}
