import SwiftUI

enum AnalyzePhase: Int {
    case transcribing = 0
    case analyzing = 1
    case clips = 2
}

struct ProcessingOverlayView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var subtitleIndex = 0
    @State private var glowOpacity: Double = 0.4
    @State private var barHeights: [CGFloat] = [0.3, 0.6, 1.0, 0.7, 0.4, 0.8, 0.5, 0.9, 0.6, 0.3]
    @State private var barPhase: Double = 0
    private let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()
    private let glowTimer = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()
    private let barTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    private let gold = Color(red: 1.0, green: 0.75, blue: 0.0)

    private var phase: AnalyzePhase {
        if appState.analyzeProgress < 0.25 { return .transcribing }
        if appState.analyzeProgress < 0.70 { return .transcribing }
        if appState.analyzeProgress < 0.95 { return .analyzing }
        return .clips
    }

    private var phaseTitle: String {
        switch phase {
        case .transcribing: return "Transcribing Audio"
        case .analyzing:    return "Analyzing Clips"
        case .clips:        return "Generating Clips"
        }
    }

    private var subtitleSets: [[String]] {
        [
            // transcribing
            ["Listening to every word...", "Catching every syllable...",
             "Processing your audio...", "Mapping the conversation...",
             "Neural engine at work..."],
            // analyzing
            ["Finding your best moments...", "Scoring viral potential...",
             "Detecting emotional peaks...", "Reading engagement signals...",
             "Building your highlight reel..."],
            // clips
            ["Assembling your clips...", "Adding timestamps...",
             "Almost there...", "Packaging your content..."]
        ]
    }

    private var currentSubtitles: [String] { subtitleSets[phase.rawValue] }
    private var currentSubtitle: String { currentSubtitles[subtitleIndex % currentSubtitles.count] }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.12)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                // Glowing waveform icon
                ZStack {
                    // Glow rings
                    Circle()
                        .fill(gold.opacity(glowOpacity * 0.12))
                        .frame(width: 130, height: 130)
                        .blur(radius: 20)
                    Circle()
                        .fill(gold.opacity(glowOpacity * 0.18))
                        .frame(width: 100, height: 100)
                        .blur(radius: 12)

                    // Main circle
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.85, green: 0.6, blue: 0.1),
                                    Color(red: 0.6, green: 0.4, blue: 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 78, height: 78)

                    // Animated waveform bars inside circle
                    HStack(spacing: 3.5) {
                        ForEach(0..<10, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 3, height: max(6, barHeights[i] * 30))
                        }
                    }
                }
                .padding(.bottom, 28)
                .animation(.easeInOut(duration: 1.0), value: glowOpacity)

                // Title
                Text(phaseTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .animation(.easeInOut(duration: 0.3), value: phase.rawValue)

                // Rotating subtitle
                Text(currentSubtitle)
                    .font(.system(size: 15))
                    .foregroundColor(Color.white.opacity(0.5))
                    .padding(.top, 6)
                    .id(subtitleIndex)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.4), value: subtitleIndex)

                // Progress bar
                VStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [gold, gold.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(12, 340 * appState.analyzeProgress), height: 6)
                            .animation(.easeOut(duration: 0.3), value: appState.analyzeProgress)
                    }
                    .frame(width: 340)

                    Text("\(Int(appState.analyzeProgress * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .padding(.top, 24)

                // Step pipeline
                HStack(spacing: 0) {
                    stepBadge(label: "Transcribe", icon: "waveform", stepPhase: .transcribing)
                    stepConnector(active: phase.rawValue >= 1)
                    stepBadge(label: "Analyze", icon: "brain.head.profile", stepPhase: .analyzing)
                    stepConnector(active: phase.rawValue >= 2)
                    stepBadge(label: "Clips", icon: "scissors", stepPhase: .clips)
                }
                .padding(.top, 32)

                // Cancel / Background buttons
                HStack(spacing: 12) {
                    Button(action: {
                        appState.isAnalyzing = false
                        appState.overlayVisible = false
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Cancel")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        appState.overlayVisible = false
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Background")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(gold)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 11)
                        .background(gold.opacity(0.12))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(gold.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 36)

                Spacer()
            }
        }
        .onReceive(timer) { _ in
            withAnimation { subtitleIndex += 1 }
        }
        .onReceive(glowTimer) { _ in
            withAnimation { glowOpacity = glowOpacity > 0.5 ? 0.3 : 0.65 }
        }
        .onReceive(barTimer) { _ in
            barPhase += 0.15
            withAnimation(.easeInOut(duration: 0.1)) {
                barHeights = (0..<10).map { i in
                    let t = barPhase + Double(i) * 0.7
                    return CGFloat((sin(t) + 1.0) / 2.0 * 0.8 + 0.2)
                }
            }
        }
    }

    func stepBadge(label: String, icon: String, stepPhase: AnalyzePhase) -> some View {
        let isActive = phase == stepPhase
        let isDone = phase.rawValue > stepPhase.rawValue
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isDone ? gold : (isActive ? gold.opacity(0.2) : Color.white.opacity(0.07)))
                    .frame(width: 34, height: 34)
                Image(systemName: isDone ? "checkmark" : icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isDone ? .black : (isActive ? gold : Color.white.opacity(0.3)))
            }
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .white : Color.white.opacity(0.35))
        }
    }

    func stepConnector(active: Bool) -> some View {
        Rectangle()
            .fill(active ? gold.opacity(0.6) : Color.white.opacity(0.1))
            .frame(width: 40, height: 2)
            .padding(.bottom, 18)
    }
}
