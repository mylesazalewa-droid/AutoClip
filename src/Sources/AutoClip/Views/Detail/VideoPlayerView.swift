import SwiftUI
import AVKit
import AVFoundation

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let captionStyle: CaptionStyle
    let currentWord: Word?
    let showCaptionBg: Bool
    let captionBgOpacity: Double
    let captionBgColor: NSColor

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

class ClipPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer
    @Published var isPlaying = false
    @Published var currentTime: CMTime = .zero
    @Published var duration: CMTime = .zero
    @Published var currentWord: Word?
    @Published var playbackRate: Float = 1.0

    private var timeObserver: Any?
    private var clip: Clip?

    init() {
        self.player = AVPlayer()
    }

    func loadClip(_ clip: Clip, project: Project) {
        self.clip = clip
        let videoURL = URL(fileURLWithPath: project.videoPath)
        let asset = AVURLAsset(url: videoURL)

        let startCMTime = CMTime(seconds: clip.startTime, preferredTimescale: 600)
        let endCMTime = CMTime(seconds: clip.endTime, preferredTimescale: 600)

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.seek(to: startCMTime)
        self.duration = CMTime(seconds: clip.duration, preferredTimescale: 600)

        // Set up time observer
        removeTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            guard let self, let clip = self.clip else { return }
            let relTime = time.seconds - clip.startTime
            self.currentTime = CMTime(seconds: max(0, relTime), preferredTimescale: 600)
            self.updateCurrentWord(at: time.seconds)

            // Loop at end
            if time.seconds >= clip.endTime {
                self.player.seek(to: CMTime(seconds: clip.startTime, preferredTimescale: 600))
                if self.isPlaying {
                    self.player.play()
                }
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
            player.rate = playbackRate
        }
        isPlaying.toggle()
    }

    func seek(by seconds: Double) {
        guard let clip else { return }
        let current = player.currentTime().seconds
        let target = max(clip.startTime, min(clip.endTime, current + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func seekToStart() {
        guard let clip else { return }
        player.seek(to: CMTime(seconds: clip.startTime, preferredTimescale: 600))
    }

    // Seek to a position in [0,1] relative to clip duration
    func seekToFraction(_ fraction: Double, duration: Double) {
        guard let clip else { return }
        let target = clip.startTime + fraction * duration
        player.seek(to: CMTime(seconds: max(clip.startTime, min(clip.endTime, target)), preferredTimescale: 600))
    }

    // Seek to seconds offset from clip start (used by transcript/quotes word tap)
    func seekToTime(_ offsetSeconds: Double) {
        guard let clip else { return }
        let target = clip.startTime + max(0, offsetSeconds)
        player.seek(to: CMTime(seconds: min(clip.endTime, target), preferredTimescale: 600))
    }

    private func updateCurrentWord(at time: Double) {
        guard let clip else { return }
        currentWord = clip.words.first { $0.startTime <= time && $0.endTime > time }
    }

    private func removeTimeObserver() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
    }

    deinit {
        removeTimeObserver()
    }
}
