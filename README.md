<p align="center">
  <img src="Resources/AppIcon-README.png" width="128" height="128" alt="Wispah Flow icon">
</p>

<h1 align="center">Wispah Flow</h1>

<p align="center">
  Free, open source voice-to-text for macOS. Press a hotkey, speak, and your words appear at the cursor — adapted to what's on screen.
</p>

<p align="center">
  <a href="https://github.com/idanyekutiel/wispah/releases/latest/download/Wispah.dmg"><b>Download Wispah.dmg</b></a><br>
  <sub>macOS 13+ &middot; Apple Silicon + Intel</sub>
</p>

---

## Features

- **Context-aware transcription** — takes a screenshot when you start recording, then uses it to get names, terminology, and formatting right. Replying to an email? It'll spell the person's name correctly. Writing code? It'll match the syntax.
- **Two recording modes** — hold-to-record (push-to-talk style) and toggle (press to start, press to stop), each with its own hotkey
- **Live recording overlay** — floating pill with waveform visualization, state transitions, and a smooth slide-to-notch animation
- **Paste at cursor** — transcription goes straight to wherever your cursor is, with smart leading-space detection so it doesn't smash into existing text
- **Transcription history** — searchable log of every transcription with audio playback
- **Usage stats** — words transcribed, recording time, streaks, words per minute
- **Auto-updates** — checks GitHub Releases in the background, downloads and installs with one click
- **Pause media while recording** — optionally pauses music/video during recording, resumes when done (macOS 15.4+)
- **Privacy-first** — no servers, no accounts, no telemetry. The only network calls are to Groq's API.

## Why Groq

Wispah Flow uses [Groq](https://groq.com) for both transcription (Whisper) and post-processing (LLM). Two reasons:

1. **It's free.** Groq offers free API access, so using Wispah Flow costs nothing. No subscription, no credits, no hidden limits that matter for normal use. Just grab an API key and go.
2. **It's fast.** Groq runs on custom LPU hardware designed for inference speed. Transcriptions come back near-instantly, making the whole flow feel like native dictation.

## Setup

1. Download from [Releases](https://github.com/idanyekutiel/wispah/releases)
2. Get a free API key at [console.groq.com](https://console.groq.com)
3. Open the app and follow the setup wizard

The wizard walks you through granting permissions (microphone, accessibility, screen recording) and configuring your hotkeys.

## Build from source

```bash
git clone https://github.com/idanyekutiel/wispah.git
cd wispah

make watch        # Dev build + auto-rebuild on changes
make dev          # One-shot dev build
make dev-run      # Build and launch

ARCH=universal make all   # Release build (universal binary)
make dmg                  # Create DMG installer
```

Requires Xcode Command Line Tools and fswatch (`brew install fswatch`).

No Xcode project — compiles with `swiftc` directly via Makefile.

## Stack

- **Swift + SwiftUI** — menu bar app, no Xcode project
- **Groq API** — Whisper large-v3 for transcription, LLM for context-aware post-processing
- **macOS Accessibility API** — cursor detection, text pasting
- **ScreenCaptureKit** — screenshot capture for context
- **CoreData** — transcription history (programmatic model, no .xcdatamodeld)
- **[mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)** — media pause/resume on macOS 15.4+ (works around Apple's MediaRemote restrictions)

## Auto-Update

The app checks GitHub Releases every 7 days. New releases have a 3-day stability buffer before auto-prompting. Manual "Check for Updates" in settings bypasses the buffer. Updates download the DMG, mount it, replace the app, and relaunch.

## Deployment

<details>
<summary><b>Releasing a new version</b></summary>

Versions follow a date format: `2026.02.19`, with `.2`, `.3` suffixes for multiple same-day releases.

To release: push a version tag. The release workflow handles the rest.

```bash
# Update Info.plist version, commit, tag, push
plutil -replace CFBundleShortVersionString -string "2026.02.19" Info.plist
plutil -replace CFBundleVersion -string "2026.02.19" Info.plist
git add Info.plist && git commit -m "Release v2026.02.19"
git tag v2026.02.19
git push origin main && git push origin v2026.02.19
```

The tag push triggers `.github/workflows/release.yml` which builds a universal binary, creates a DMG, and publishes a GitHub Release.

**Without an Apple Developer account:** releases are ad-hoc signed. Users get a Gatekeeper "unidentified developer" prompt (right-click > Open bypasses it).

**With an Apple Developer account ($99/year):** releases are Developer ID signed and Apple notarized. No Gatekeeper warnings.

</details>

<details>
<summary><b>Setting up code signing</b></summary>

1. Join the [Apple Developer Program](https://developer.apple.com/programs/) ($99/year)
2. Create a "Developer ID Application" certificate at [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list)
3. Export as .p12 from Keychain Access, base64 encode: `base64 -i cert.p12 | pbcopy`
4. Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com) (Sign-In and Security > App-Specific Passwords)
5. Add these GitHub repository secrets:

| Secret | Value |
|--------|-------|
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded .p12 certificate |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the .p12 |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | 10-character Team ID from developer.apple.com/account |
| `APPLE_APP_PASSWORD` | The app-specific password |

Once set, all releases are automatically signed and notarized.

</details>

<details>
<summary><b>Media detection (macOS 15.4+)</b></summary>

Since macOS 15.4, Apple blocks third-party apps from using `MediaRemote.framework` directly. We use [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3-Clause) to work around this:

1. `/usr/bin/perl` has bundle ID `com.apple.perl`, which Apple's `mediaremoted` trusts
2. A Perl script loads a compiled Objective-C framework via `DynaLoader`
3. The framework calls MediaRemote APIs to check playback state
4. Result comes back as JSON — we parse the `"playing"` boolean

The framework is pre-built and bundled in `Resources/MediaRemoteAdapter/`.

</details>

## Privacy

No servers, no accounts, no tracking. The only network calls are to Groq's API for transcription and context processing. Audio is processed and discarded — nothing is stored or retained externally.

## Credits

Wispah Flow is a fork of [FreeFlow](https://github.com/zachlatta/freeflow) by [Zach Latta](https://github.com/zachlatta). Original project licensed under MIT.

## License

MIT License. See [LICENSE](LICENSE).

Third-party dependencies are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
