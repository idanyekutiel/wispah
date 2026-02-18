# Technical Guide

For general information and download, see [README.md](README.md).

## Build from Source

```bash
git clone https://github.com/idanyekutiel/wispah.git
cd wispah

make watch        # Dev build + auto-rebuild on changes (requires fswatch)
make dev          # One-shot dev build
make dev-run      # Build and launch

ARCH=universal make all   # Release build (universal binary)
make dmg                  # Create DMG installer
make clean                # Delete build/
```

**Requirements:** Xcode Command Line Tools and [fswatch](https://github.com/emcrisostomo/fswatch) (`brew install fswatch`) for `make watch`.

No Xcode project — compiles with `swiftc` directly via Makefile. Minimum deployment target is macOS 13.0.

## Stack

- **Language:** Swift (no SwiftUI previews, no storyboards)
- **Build system:** Makefile + `swiftc` — no `.xcodeproj`/`.xcworkspace`
- **UI framework:** SwiftUI (menu bar app via `MenuBarExtra`)
- **Audio:** AVAudioEngine for recording, CoreAudio for device enumeration
- **Screen capture:** ScreenCaptureKit
- **Accessibility:** AX APIs for paste-at-cursor and leading space detection
- **Persistence:** CoreData (programmatic model, no `.xcdatamodeld`), UserDefaults, file-based key storage
- **Networking:** URLSession (Groq API only)
- **Media control:** [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) for macOS 15.4+ MediaRemote restrictions

## Architecture

Menu bar app (`LSUIElement`). Central `AppState` (ObservableObject) owns all state.

### Pipeline

1. **Hotkey** — `HotkeyManager` detects key press (toggle or hold mode)
2. **Record** — `AudioRecorder` captures via AVAudioEngine → AAC/m4a
3. **Context** — `AppContextService` captures screenshot + frontmost app in parallel (ScreenCaptureKit)
4. **Preprocess** — downsample to 16kHz mono, trim trailing silence
5. **Transcribe** — `TranscriptionService` → Groq Whisper API
6. **Post-process** — `PostProcessingService` → Groq LLM with screen context
7. **Paste** — clipboard + `Cmd+V` via accessibility
8. **Store** — `PipelineHistoryStore` (CoreData) + `StatsStore` (JSON)

### Recording Overlay

Floating glass pill at screen top: initializing (spinner) → recording (live waveform) → slide-to-notch → transcribing (dots) → done (checkmark).

## Signing & Codesigning

| | Dev builds | Release builds |
|---|---|---|
| Identity | Ad-hoc (`-`) | Developer ID cert |
| Architecture | Host arch only | Universal (arm64 + x86_64) |
| Bundle ID | `com.idanyekutiel.wispah.dev` | `com.idanyekutiel.wispah` |

Override dev signing identity by creating a `.env` file (gitignored):

```bash
DEV_CODESIGN_IDENTITY=your-cert-name
```

## Versioning

Date-based: `YYYY.MM.DD` (e.g., `2026.02.19`). Multiple same-day releases: `.2`, `.3`, etc.

To release, push a version tag:

```bash
git tag v2026.02.19
git push origin v2026.02.19
```

This triggers the release workflow (`.github/workflows/release.yml`) which builds, signs, and creates a GitHub Release with a DMG.

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| `build.yml` | Push + PR | Builds universal binary, uploads DMG artifact |
| `release.yml` | Tag push `v*` | Builds + signs + creates GitHub Release |

Both workflows fall back to ad-hoc signing when Apple Developer secrets aren't configured.

**Optional secrets:** `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`

## Data Storage

| Data | Location |
|------|----------|
| API key | `~/Library/Application Support/Wispah/groq_api_key` |
| Audio files | `~/Library/Application Support/Wispah/audio/` |
| History DB | `~/Library/Application Support/Wispah/PipelineHistory.sqlite` |
| Stats | `~/Library/Application Support/Wispah/stats.json` |
| Settings | `UserDefaults` (standard) |

## Permissions

| Permission | Purpose |
|---|---|
| Microphone | Audio recording |
| Accessibility | Paste at cursor, detect text field content |
| Screen Recording | Screenshot for context-aware transcription |

## AI-Assisted Development

This project includes full [Claude Code](https://claude.com/claude-code) configuration:

- **`.claude/CLAUDE.md`** — project context, architecture docs, coding standards
- **`.claude/commands/release.md`** — `/release` skill for automated date-based releases

Any contributor using Claude Code gets full project context automatically.
