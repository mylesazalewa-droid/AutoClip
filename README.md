# AutoClip

**AutoClip** is a free, open-source macOS app that turns long videos into short, viral-ready clips — entirely on your Mac, no subscription required.

![AutoClip screenshot](https://github.com/mylesazalewa-droid/AutoClip/raw/main/assets/screenshot.png)

---

## Features

### Projects
- Drag-and-drop a video or paste a **YouTube URL** to import
- Automatic face tracking with smooth pan/zoom crop (9:16, 1:1, or original)
- **Karaoke captions** — word-by-word highlight synced to speech
- Trim, preview, and export individual clips with one click

### Auto Reels ✨
- **Local AI mode** — uses [WhisperKit](https://github.com/argmaxinc/WhisperKit) (on-device Whisper) to transcribe audio and detect sentence boundaries; no internet required
- **Smart AI mode** — sends the transcript to [Claude](https://www.anthropic.com/claude) (Haiku) via the Anthropic API for semantic, context-aware clip selection; understands themes, hooks, and complete thoughts
- **Reel mode** — stitches the best moments into a single highlight reel
- **Individual Clips mode** — exports every selected moment as its own `.mp4` file
- Supports sermons, podcasts, interviews, lectures, and any long-form video (30–90+ minutes)
- Background rendering — processing continues even when you switch tabs
- YouTube URL input with automatic download via `yt-dlp`

---

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac
- For YouTube imports: [yt-dlp](https://github.com/yt-dlp/yt-dlp) installed (`brew install yt-dlp`)
- For Smart AI mode: an [Anthropic API key](https://console.anthropic.com/) (optional, ~$0.01–0.03 per video)

---

## Download

Download the latest release from the [**Releases**](https://github.com/mylesazalewa-droid/AutoClip/releases) page.

> **Note:** AutoClip is not notarized. On first launch, right-click the app → Open, then confirm to bypass Gatekeeper.

---

## Build from Source

AutoClip is a pure Swift Package Manager project — no Xcode project file needed.

```bash
git clone https://github.com/mylesazalewa-droid/AutoClip.git
cd AutoClip/src
swift build -c release
```

The binary will be at `.build/release/AutoClip`.

### Dependencies (resolved automatically by SPM)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition
- Apple frameworks: AVFoundation, Vision, SwiftUI, AppKit

---

## Smart AI Setup

1. Go to [console.anthropic.com](https://console.anthropic.com) → **API Keys** → **Create Key**
2. Open AutoClip → **Auto Reels** tab
3. Toggle **Smart AI Selection** on and paste your key
4. Your key is stored securely in the macOS Keychain — it is only ever sent to `api.anthropic.com`

---

## How It Works

```
Video / YouTube URL
       │
       ▼
 WhisperKit (local)
  transcribes audio
       │
       ▼
 Sentence boundary detection
 ─ OR ─
 Claude AI (optional)
  understands context
       │
       ▼
 AVFoundation
  crops · captions · exports
       │
       ▼
  Your clips 🎬
```

---

## License

MIT — free to use, modify, and distribute.

---

## Contributing

Pull requests are welcome. Open an issue to discuss larger changes first.
