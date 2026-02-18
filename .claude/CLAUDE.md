# Wispah Flow

macOS menu bar app for voice-to-text. Press a hotkey, speak, and the transcription is pasted at your cursor. Uses Groq's Whisper API for transcription and Groq LLM for context-aware post-processing.

Fork of [FreeFlow](https://github.com/zachlatta/freeflow) by Zach Latta (MIT).

**Naming convention:** User-facing display name is "Wispah Flow". Internal identifiers (bundle ID, code, file names, repo) use "wispah"/"Wispah". `DISPLAY_NAME` Makefile variable controls `CFBundleDisplayName`.

## Build & Run

```bash
make watch        # Dev build + auto-rebuild on file changes (requires fswatch)
make dev          # One-shot dev build (ad-hoc signed)
make dev-run      # Build and launch
make all          # Release build (production signing)
make dmg          # Build + create DMG installer
make clean        # Delete build/
```

- **No Xcode project** — compiles with `swiftc` directly via Makefile
- Minimum macOS 13.0
- Dev builds: ad-hoc signed (`CODESIGN_IDENTITY=-`), arm64 only
- Release builds: Developer ID signed, universal binary (arm64 + x86_64)
- `.env` file (gitignored) can override `DEV_CODESIGN_IDENTITY` for persistent permissions across rebuilds
- Entitlements: `Wispah.entitlements` — only `com.apple.security.device.audio-input`

### Makefile Variables

| Variable | Default (dev) | Release |
|----------|---------------|---------|
| `APP_NAME` | `Wispah Dev` | `Wispah` |
| `DISPLAY_NAME` | `Wispah Flow Dev` | `Wispah Flow` |
| `BUNDLE_ID` | `com.idanyekutiel.wispah.dev` | `com.idanyekutiel.wispah` |
| `ARCH` | host arch | `universal` |
| `CODESIGN_IDENTITY` | `Wispah Dev` | Developer ID cert |
| `DEV_CODESIGN_IDENTITY` | `-` (ad-hoc) | — |

## Architecture

Menu bar app (`LSUIElement` in Info.plist). Central `AppState` (ObservableObject) owns all state and orchestrates the pipeline.

### Pipeline Flow

1. `HotkeyManager` detects key press (toggle or hold) → `AppState.startRecording()`
2. `AudioRecorder` captures audio via `AVAudioEngine` → AAC/m4a file
3. `AppContextService` captures screenshot + frontmost app context in parallel (via ScreenCaptureKit)
4. On stop: audio preprocessed (downsample to 16kHz mono, trim trailing silence)
5. `TranscriptionService` sends audio to Groq Whisper API
6. `PostProcessingService` refines transcript using Groq LLM with screen context
7. Result copied to clipboard and pasted at cursor via accessibility (`Cmd+V` simulation)
8. Entry saved to `PipelineHistoryStore` (CoreData), stats accumulated in `StatsStore`

### Recording Overlay

`RecordingOverlayManager` shows a floating glass pill at the top of screen:
- Initializing state (spinner) → Recording state (live waveform from audio levels) → Slide-up-to-notch animation → Transcribing state → Done checkmark

## Source Structure

```
Sources/
├── App/
│   ├── App.swift                    — @main entry, MenuBarExtra scene
│   ├── AppDelegate.swift            — Window management (setup/settings windows), lifecycle
│   └── Notification+VoiceToText.swift — Notification name declarations
├── Managers/
│   ├── AudioRecorder.swift          — AVAudioEngine recording, preprocessing, silence detection
│   ├── HotkeyManager.swift          — NSEvent global/local monitors, dual hotkey system
│   ├── RecordingOverlay.swift       — NSPanel floating overlay with waveform animation
│   └── UpdateManager.swift          — GitHub Releases API polling, DMG download + install + relaunch
├── Models/
│   ├── AudioDevice.swift            — CoreAudio device enumeration (filters aggregate/virtual)
│   ├── AudioWhileRecording.swift    — Enum: doNothing, pauseMedia, muteSystem
│   ├── PipelineHistoryItem.swift    — Data model for transcription history entries
│   ├── PipelineHistoryStore.swift   — CoreData store (programmatic NSManagedObjectModel, no .xcdatamodeld)
│   ├── RecordingMode.swift          — Enum: holdToRecord, toggleToRecord
│   ├── SettingsTab.swift            — Enum: stats, runLog, general (tab order)
│   ├── StatsStore.swift             — Persistent JSON stats with daily breakdowns
│   └── WhisperModel.swift           — Enum: largeV3, largeV3Turbo
├── Services/
│   ├── AppContextService.swift      — Screenshot capture via ScreenCaptureKit, context inference via Groq
│   ├── KeychainStorage.swift        — File-based storage in ~/Library/Application Support/Wispah/
│   ├── PostProcessingService.swift  — Groq LLM post-processing (formatting, context integration)
│   └── TranscriptionService.swift   — Groq Whisper API client, audio upload
├── State/
│   ├── AppState.swift               — Central ObservableObject: all @Published settings, init
│   ├── AppState+Accessibility.swift — Permission checks/alerts, paste-at-cursor, leading space detection
│   ├── AppState+Audio.swift         — Mic enumeration, media pause/mute, system audio control
│   ├── AppState+Context.swift       — Screen context capture orchestration, fallback context
│   ├── AppState+History.swift       — Pipeline history CRUD, stats accumulation on transcription
│   ├── AppState+Recording.swift     — Hotkey handlers, recording lifecycle, transcription pipeline
│   └── AppState+Settings.swift      — API key persistence, audio file storage, launch-at-login
└── Views/
    ├── MenuBarView.swift            — Menu bar dropdown (mic selector, screen context toggle, settings)
    ├── PipelineDebugContentView.swift — Debug info display (raw/processed transcript, context, screenshot)
    ├── PipelineDebugPanelView.swift — Debug overlay panel wrapper
    ├── Components/
    │   ├── FlowLayout.swift         — Flow/wrap layout for tags
    │   └── PipelineStepView.swift   — Reusable pipeline step row component
    ├── Settings/
    │   ├── AudioPlayerView.swift    — Audio playback for history entries
    │   ├── GeneralSettingsView.swift — Settings page (API key, hotkeys, mic, permissions, etc.)
    │   ├── RunLogEntryView.swift    — Individual transcription history entry view
    │   ├── RunLogView.swift         — Transcriptions list with search
    │   ├── SettingsComponents.swift — Shared settings UI components (HotkeyRecorderButton, MicrophoneOptionRow)
    │   ├── SettingsView.swift       — Settings window shell with sidebar navigation
    │   └── StatsView.swift          — Usage stats dashboard (overview, speed, activity cards)
    └── Setup/
        ├── SetupHelpers.swift       — GitHub metadata cache (stars, stargazers)
        └── SetupView.swift          — Onboarding wizard (API key, permissions, test recording)
```

## Key Patterns

### Settings Persistence
All settings use `@Published` properties on `AppState` with `didSet` saving to `UserDefaults`. API key uses file-based storage via `KeychainStorage` (not actual Keychain — file in App Support dir).

### Hotkey System
Dual hotkey support: separate "toggle" key (press to start/stop) and "hold" key (hold to record, release to stop). Both stored as `HotkeyBinding` (Codable struct with keyCode + modifiers). If both are set to the same key, `recordingMode` determines behavior.

### Stats System
`StatsStore` persists to `~/Library/Application Support/Wispah/stats.json`. Stores both all-time aggregates and per-day breakdowns (`dailyStats` dictionary keyed by `yyyy-MM-dd`). Supports period filtering via `stats(from: Date?)`. Stats collection is opt-in (toggle in Settings > Log Settings). Disabling shows confirmation and deletes all data. Stats tab is hidden when collection is disabled.

### Media Detection (macOS 15.4+)
Uses [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) — runs `/usr/bin/perl` (which has `com.apple.perl` bundle ID) to load a compiled Obj-C framework that calls MediaRemote APIs. Needed because Apple blocks third-party bundle IDs from accessing `mediaremoted`. Framework + Perl script bundled in `Resources/MediaRemoteAdapter/`.

### Auto-Update
`UpdateManager` checks GitHub Releases API (`idanyekutiel/wispah`). Compares `WispahBuildTag` from Info.plist against latest release tag using numeric version comparison. Downloads DMG → mounts → copies .app → relaunches. 3-day stability buffer for auto-checks (skips very recent releases).

### CoreData
`PipelineHistoryStore` uses a programmatic `NSManagedObjectModel` (no .xcdatamodeld file). SQLite at `~/Library/Application Support/Wispah/PipelineHistory.sqlite`. Stores transcription entries with raw/processed text, context, audio file reference, recording duration.

## Data Storage Paths

| Data | Location |
|------|----------|
| API key | `~/Library/Application Support/Wispah/groq_api_key` |
| Audio files | `~/Library/Application Support/Wispah/audio/` |
| History DB | `~/Library/Application Support/Wispah/PipelineHistory.sqlite` |
| Stats | `~/Library/Application Support/Wispah/stats.json` |
| Settings | `UserDefaults` (standard) |

## Required Permissions

| Permission | Purpose | Requested via |
|------------|---------|---------------|
| Microphone | Audio recording | `AVCaptureDevice.requestAccess` |
| Accessibility | Paste at cursor, window title detection | `AXIsProcessTrustedWithOptions` |
| Screen Recording | Screenshot for context | `SCShareableContent` / `CGPreflightScreenCaptureAccess` |

## Versioning & Releases

Date-based versioning: `YYYY.MM.DD` (e.g., `2026.02.19`). Multiple same-day releases: `2026.02.19.2`, `2026.02.19.3`, etc.

**Release process** (use `/release` skill or just ask):
1. Ensure clean working tree
2. Determine version from today's date (check existing tags for same-day conflicts)
3. Update `CFBundleShortVersionString` + `CFBundleVersion` in Info.plist
4. Commit, tag `v{version}`, push commit + tag
5. Tag push triggers release workflow automatically

**Version in builds:**
- Release builds: `WispahBuildTag` injected into Info.plist by release workflow (date version string)
- Dev builds: no `WispahBuildTag` — UpdateManager skips auto-checks, allows manual checks

**UpdateManager** compares versions numerically (dot-separated segments). `2026.02.20` > `2026.02.19.2` > `2026.02.19`.

## CI/CD

### build.yml (on push + PR)
Builds universal binary. Uses Developer ID signing when secrets exist, falls back to ad-hoc for fork PRs. Uploads DMG as artifact.

### release.yml (on tag push `v*`)
Triggered by pushing a version tag (e.g., `v2026.02.19`). Always creates a GitHub Release with DMG. When signing secrets exist: Developer ID signed + Apple notarized. Without secrets: ad-hoc signed (users get Gatekeeper "unidentified developer" prompt, bypassed with right-click > Open).

Optional secrets for signing: `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.

## Development Guidelines

### UX/UI Standards
- Always provide visual feedback for async operations (spinners, progress, status text, timers)
- Every action should have clear state transitions: idle -> in-progress -> success/failure
- Success states should auto-dismiss after a reasonable delay (2-3s)
- Error states should persist until user dismisses, with option to retry
- Use animations (withAnimation) for state transitions
- Truncate long text with lineLimit + truncationMode, not by cutting strings
- Click targets should be generous — entire rows should be clickable, not just text
- Empty states should use consistent pattern: large icon (.system(size: 40)) + headline + caption

### Git
- **NEVER push without explicit user approval.** Always wait for the user to confirm before running `git push`.

### Code Standards
- Keep files focused — split large files into logical units (AppState extensions pattern)
- Use MARK comments for sections within files
- Prefer @Published + UserDefaults for settings persistence
- Use async/await for all network calls
- Handle errors gracefully — never silently fail on user-visible operations
- Use os_log for debug logging, not print()
- CoreData model is programmatic — update the model code directly, not an .xcdatamodeld
