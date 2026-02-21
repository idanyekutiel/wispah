# Wispah Flow

macOS menu bar app for voice-to-text. Press a hotkey, speak, and the transcription is pasted at your cursor. Supports Groq (free) and OpenAI as API providers — both use OpenAI-compatible endpoints with provider-specific models.

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

- **Do NOT run `make dev` or `make clean` while `make watch` is running** — it causes build collisions and signing errors. The user runs `make watch` during dev; just edit files and let it auto-rebuild.
- **No Xcode project** — compiles with `swiftc` directly via Makefile
- Minimum macOS 13.0
- Dev builds: ad-hoc signed (`DEV_CODESIGN_IDENTITY=-`) by default, arm64 only
- Release builds: Developer ID signed, universal binary (arm64 + x86_64)
- `.env` file (gitignored) overrides `DEV_CODESIGN_IDENTITY` for persistent permissions across rebuilds. Value must be unquoted (Make handles spaces). If the cert chain isn't installed locally, fall back to `DEV_CODESIGN_IDENTITY=-` (ad-hoc)
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
4. On stop: audio preprocessed (downsample to 16kHz mono, trim to speech boundaries with 0.5s trailing padding)
5. `TranscriptionService` sends audio to Whisper API (Groq or OpenAI, based on active provider). Custom vocabulary is sent as natural context in the `prompt` parameter ("Glossary of terms that may appear: ...") — never as a bare list, which causes hallucinations.
6. `PostProcessingService` refines transcript using LLM with screen context. This is a **transcription cleanup tool**, not a writing assistant — the prompt must preserve the speaker's original words and sentence structure. Custom prompt can override this.
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
│   └── APIProvider.swift            — Enum: groq, openai — base URLs, model lists, display info
├── Services/
│   ├── AppContextService.swift      — Screenshot capture via ScreenCaptureKit, context inference via LLM
│   ├── KeychainStorage.swift        — File-based storage in ~/Library/Application Support/Wispah/
│   ├── PostProcessingService.swift  — LLM post-processing (formatting, context integration)
│   └── TranscriptionService.swift   — Whisper API client (OpenAI-compatible), audio upload
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
        └── SetupView.swift          — Onboarding wizard (API key, permissions, preferences, test recording)
```

## Key Patterns

### Settings Persistence
All settings use `@Published` properties on `AppState` with `didSet` saving to `UserDefaults`. API keys use file-based storage via `KeychainStorage` (not actual Keychain — file in App Support dir). Separate keys stored per provider (`groq_api_key`, `openai_api_key`), one active at a time via `APIProvider` enum. `activeAPIKey` / `activeBaseURL` computed properties provide provider-agnostic access.

### Hotkey System
Dual hotkey support: separate "toggle" key (press to start/stop) and "hold" key (hold to record, release to stop). Both stored as `HotkeyBinding` (Codable struct with keyCode + modifiers). If both are set to the same key, `recordingMode` determines behavior. Fn key emoji picker warning in setup is intentionally toggle-only — holding Fn does not trigger the emoji picker on macOS.

### Stats System
`StatsStore` persists to `~/Library/Application Support/Wispah/stats.json`. Stores both all-time aggregates and per-day breakdowns (`dailyStats` dictionary keyed by `yyyy-MM-dd`). Supports period filtering via `stats(from: Date?)`. Stats collection is opt-in (toggle in Settings > Log Settings). Disabling shows confirmation and deletes all data. Stats tab is hidden when collection is disabled.

### Media Detection (macOS 15.4+)
Uses [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) — runs `/usr/bin/perl` (which has `com.apple.perl` bundle ID) to load a compiled Obj-C framework that calls MediaRemote APIs. Needed because Apple blocks third-party bundle IDs from accessing `mediaremoted`. Framework + Perl script bundled in `Resources/MediaRemoteAdapter/`.

### Auto-Update
`UpdateManager` (singleton, lives for app lifetime) checks GitHub Releases API (`idanyekutiel/wispah`). Compares `WispahBuildTag` from Info.plist against latest release tag using numeric version comparison. Downloads DMG → mounts (with signature verification) → verifies extracted .app with `codesign --verify --deep --strict` → copies .app → relaunches. 3-day stability buffer for auto-checks (skips very recent releases). Self-update uses a shell script that waits for the current PID to die before replacing the .app — `NSApp.terminate` after `process.run()` is intentional.

### Onboarding
`SetupView` wizard: welcome → API key → mic → accessibility → screen recording → hotkeys → vocabulary → preferences (language + developer mode) → launch at login → test transcription → ready. Current step persisted to `UserDefaults("setupResumeStep")` so it resumes after app restart. Cleared on completion and on "Re-run Setup". Dev-only notes (e.g., rebuild permission warning) gated on `WispahBuildTag == nil`.

### CoreData
`PipelineHistoryStore` uses a programmatic `NSManagedObjectModel` (no .xcdatamodeld file). SQLite at `~/Library/Application Support/Wispah/PipelineHistory.sqlite`. Stores transcription entries with raw/processed text, context, audio file reference, recording duration.

## Data Storage Paths

| Data | Location |
|------|----------|
| API keys | `~/Library/Application Support/Wispah/groq_api_key`, `openai_api_key` |
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
4. Write human-friendly release notes in `RELEASE_NOTES.md` (not auto-generated commit dumps)
5. Commit, tag `v{version}`, push commit + tag (with explicit user approval)
6. Tag push triggers release workflow automatically

**Version in builds:**
- Release builds: `WispahBuildTag` injected into Info.plist by release workflow (date version string)
- Dev builds: no `WispahBuildTag` — UpdateManager skips auto-checks, allows manual checks

**UpdateManager** compares versions numerically (dot-separated segments). `2026.02.20` > `2026.02.19.2` > `2026.02.19`.

## CI/CD

### build.yml (on push + PR)
Builds universal binary. Uses Developer ID signing when secrets exist, falls back to ad-hoc for fork PRs. Uploads DMG as artifact. Skips non-code changes via `paths-ignore` (markdown, `.claude/`, LICENSE, images).

### release.yml (on tag push `v*`)
Triggered by pushing a version tag (e.g., `v2026.02.19`). Creates a GitHub Release titled "Wispah Flow Version {version}" with DMG attached. Release notes read from `RELEASE_NOTES.md` (human-written per release, not auto-generated). When signing secrets exist: Developer ID signed + Apple notarized. Without secrets: ad-hoc signed (users get Gatekeeper "unidentified developer" prompt, bypassed with right-click > Open).

### Signing & Notarization

All `codesign` calls **must** include `--timestamp` and `--options runtime` for notarization. This applies to:
1. MediaRemoteAdapter.framework (signed before the app)
2. The app bundle (signed with entitlements)
3. The DMG (signed after creation)

Missing `--timestamp` causes Apple to reject the submission with "signature does not include a secure timestamp".

The release workflow verifies all signatures (including timestamp presence) before submitting for notarization. Notarization has a 30-minute timeout; on failure, Apple's diagnostic log is fetched automatically.

Local notarization credentials stored via `xcrun notarytool store-credentials "notarytool-profile"`. Local release: `make codesign-dmg` then `make notarize`.

GitHub Secrets required for CI signing + notarization:
- `DEVELOPER_ID_CERTIFICATE_BASE64` — base64-encoded .p12 export of the Developer ID cert
- `DEVELOPER_ID_CERTIFICATE_PASSWORD` — password set during .p12 export
- `APPLE_ID` — Apple ID email for notarization
- `APPLE_TEAM_ID` — Team ID from Apple Developer account
- `APPLE_APP_PASSWORD` — app-specific password from appleid.apple.com (for `xcrun notarytool`)

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
- **NEVER git add, commit, or push without explicit user approval.** Only run git operations (add, commit, push) when the user explicitly says to. Each approval is one-time — after executing, wait for permission again before the next git operation. Just edit files and wait.
- **NEVER push without explicit user approval.** Always wait for the user to confirm before running `git push`.
- **NEVER add Co-Authored-By, attribution lines, or any self-credit to commit messages or PRs.** All commits should appear as authored solely by the user.

### Onboarding
When modifying any feature, check if it appears in the onboarding wizard (`SetupView.swift`). If it does, update the onboarding to match. The wizard covers: API key, mic, accessibility, screen recording, hotkeys, vocabulary, preferences, launch at login, and test transcription.

### Code Standards
- Keep files focused — split large files into logical units (AppState extensions pattern)
- Use MARK comments for sections within files
- Prefer @Published + UserDefaults for settings persistence
- Use async/await for all network calls
- Handle errors gracefully — never silently fail on user-visible operations. Log with os_log, surface to user when appropriate
- Use os_log for debug logging, not print()
- CoreData model is programmatic — update the model code directly, not an .xcdatamodeld
- Store async Tasks that should be cancellable (e.g., `transcriptionTask`) — cancel before launching a new one
- Use safe array operations (`removeAll(where:)` over index-based `remove(at:)`) to prevent crashes
- Replace force unwraps (`first!`, `as!`) with guard-let or CFTypeID checks for CoreFoundation types
- Set file permissions (0o600) on sensitive files (API key, audio recordings)
- Differentiate HTTP status codes in API error messages (401 vs 429 vs 500)
- Wrap user-supplied content in XML delimiters when sending to LLM (prompt injection protection)
- Base URLs in `APIProvider` are hardcoded enum constants — force unwraps on URL construction from these are safe
- `isStartingRecording` flag in `AppState+Recording` guards against double-start race conditions — do not remove
- Audio speech detection uses dual thresholds: `silenceThresholdRMS` (0.005) for "any audio" and `speechThresholdRMS` (0.015) for "actual speech". Trimming uses the speech threshold with padding. Do not conflate the two.
- OpenAI model defaults: `gpt-5-nano` (LLM), `gpt-5-mini` (vision), `gpt-4o-mini-transcribe` (Whisper). GPT-4.1 family kept as options for users who prefer them.
