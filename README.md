<p align="center">
  <img src="Resources/AppIcon-README.png" width="128" height="128" alt="Wispah icon">
</p>

<h1 align="center">Wispah</h1>

<p align="center">
  Free, open source voice-to-text for macOS. Context-aware transcription that pastes at your cursor.
</p>

<p align="center">
  <a href="https://github.com/idanyekutiel/wispah/releases/latest/download/Wispah.dmg"><b>Download Wispah.dmg</b></a><br>
  <sub>macOS 13+ (Apple Silicon + Intel)</sub>
</p>

---

## How it works

1. Press a hotkey to start recording
2. Speak — Wispah captures audio and takes a screenshot for context
3. Release (or press again) to stop
4. Your transcription is pasted at the cursor, adapted to context

Context-aware: if you're replying to an email, it reads names and spells them correctly. Same for terminal commands, code, or any app.

## Setup

1. Download from [Releases](https://github.com/idanyekutiel/wispah/releases)
2. Get a free API key from [groq.com](https://groq.com/)
3. Run the app and follow the setup wizard

## Build from source

```bash
# Clone
git clone https://github.com/idanyekutiel/wispah.git
cd wispah

# Dev build + auto-reload
make watch

# Release build (universal binary)
ARCH=universal make all
```

Requires: Xcode Command Line Tools, fswatch (`brew install fswatch`)

## Stack

- Swift + SwiftUI (no Xcode project — built with `swiftc` directly)
- Groq API for transcription (Whisper) and post-processing (LLM)
- macOS Accessibility API for cursor detection and text pasting
- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) for media pause/resume detection on macOS 15.4+

## Privacy

No servers. The only network calls are to Groq's API for transcription and context processing. Nothing is stored or retained externally.

## Credits

Wispah is a fork of [FreeFlow](https://github.com/zachlatta/freeflow) by [Zach Latta](https://github.com/zachlatta). Original project licensed under MIT.

## License

MIT License. See [LICENSE](LICENSE).

Third-party dependencies are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
