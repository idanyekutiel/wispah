<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="FreeFlow icon">
</p>

<h1 align="center">FreeFlow</h1>

<p align="center">
  Dictate text anywhere on your Mac.<br>
  Hold a key to record, release to transcribe.
</p>

---

- **Hold** your push-to-talk key to record
- **Release** to stop and transcribe
- Text is **typed at your cursor** and copied to your clipboard

## Setup

FreeFlow uses [Groq](https://console.groq.com/keys) for fast, high-accuracy transcription. You'll need a free Groq API key.

1. Download the latest build from [Releases](https://github.com/zachlatta/freeflow/releases) (or build from source)
2. Open the app and follow the setup wizard
3. Grant the requested permissions (microphone, accessibility, screen recording)
4. Pick your push-to-talk key and start dictating

## Building from Source

```bash
git clone https://github.com/zachlatta/freeflow.git
cd freeflow
swift build
```

## License

MIT
