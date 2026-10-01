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
                Image(systemName: "scissors")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.0))

                Text("AutoClip")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)

                Text("AI-powered video clip generator")
                    .font(.system(size: 16))
                    .foregroundColor(Color.white.opacity(0.5))
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 60)

            // AI Model setup
            VStack(spacing: 16) {
                Text("Download AI Transcription Model")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text("AutoClip uses on-device AI to transcribe and analyze your videos.\nNo internet connection or API keys required after setup.")
                    .font(.system(size: 14))
                    .foregroundColor(Color.white.opacity(0.5))
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
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.35))

                if isDownloading {
                    VStack(spacing: 8) {
                        ProgressView(value: downloadProgress)
                            .accentColor(Color(red: 1.0, green: 0.75, blue: 0.0))
                            .frame(maxWidth: 360)

                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                } else {
                    if let error = downloadError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
                            .padding(.horizontal, 40)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: startDownload) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 16))
                            Text("Download AI Model")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 13)
                        .background(Color(red: 1.0, green: 0.75, blue: 0.0))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(width: 560, height: 500)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    func modelFeature(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.0))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.6))
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
