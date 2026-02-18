# Wispah - CLAUDE.md

## Build & Run

```bash
make dev          # Build dev binary (ad-hoc signed)
make dev-run      # Build and launch
make watch        # Auto-rebuild on file changes (requires fswatch)
make all          # Release build (universal binary)
make clean        # Delete build/
```

- Uses `swiftc` directly (no Xcode project)
- Minimum macOS 13.0, targets arm64
- `.env` file (gitignored) holds `DEV_CODESIGN_IDENTITY` for persistent permissions
- Entitlements: `Wispah.entitlements` (audio input)

## Architecture

Menu bar app (LSUIElement). Central `AppState` (ObservableObject) orchestrates everything.

### Pipeline Flow
1. HotkeyManager detects key press → AppState starts recording
2. AudioRecorder captures audio via AVAudioEngine (AAC/m4a)
3. AppContextService captures screenshot + app context in parallel
4. On stop: TranscriptionService sends audio to Groq Whisper API
5. PostProcessingService refines transcript with context via Groq LLM
6. Result pasted at cursor, saved to PipelineHistoryStore (CoreData)

### Source Structure (Sources/)
- **App.swift** — SwiftUI entry point, menu bar extra
- **AppDelegate.swift** — Window management, setup/settings windows
- **AppState.swift** — Central state, recording logic, settings persistence
- **AudioRecorder.swift** — AVAudioEngine recording, device enumeration
- **HotkeyManager.swift** — NSEvent monitors for configurable hotkeys
- **TranscriptionService.swift** — Groq Whisper API client
- **PostProcessingService.swift** — Groq LLM post-processing
- **AppContextService.swift** — Screenshot capture, context inference
- **MenuBarView.swift** — Menu bar dropdown UI
- **SettingsView.swift** — Settings panel with Stats, Transcriptions, Settings tabs
- **StatsView.swift** — Usage stats dashboard with persistent tracking
- **SetupView.swift** — Onboarding wizard
- **RecordingOverlay.swift** — Floating glass overlay during recording
- **PipelineHistoryStore.swift** — CoreData persistence for run history
- **PipelineHistoryItem.swift** — Data model for history entries
- **StatsStore.swift** — Persistent stats accumulator (JSON file)
- **KeychainStorage.swift** — API key + settings in ~/Library/Application Support
- **UpdateManager.swift** — GitHub release checking + auto-update
- **PipelineDebugContentView.swift** / **PipelineDebugPanelView.swift** — Debug views

### External Dependencies
- Groq API (transcription via Whisper + LLM post-processing)
- GitHub API (update checking)
- macOS frameworks: AVFoundation, AppKit, Accessibility, ScreenCaptureKit, CoreData
- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) — media pause/resume on macOS 15.4+

### Data Storage
- API key: ~/Library/Application Support/Wispah/
- Audio files: ~/Library/Application Support/Wispah/audio/
- History DB: ~/Library/Application Support/Wispah/PipelineHistory.sqlite
- Stats: ~/Library/Application Support/Wispah/stats.json
- Settings: UserDefaults

## Development Guidelines

### UX/UI Standards
- Always provide visual feedback for async operations (spinners, progress, status text, timers)
- Every action should have clear state transitions: idle → in-progress → success/failure
- Success states should auto-dismiss after a reasonable delay (2-3s)
- Error states should persist until user dismisses, with option to retry
- Use animations (withAnimation) for state transitions
- Truncate long text with lineLimit + truncationMode, not by cutting strings
- Click targets should be generous — entire rows should be clickable, not just text

### Code Standards
- Keep files focused — split large files into logical units
- Use MARK comments for sections within files
- Prefer @Published + UserDefaults for settings persistence
- Use async/await for all network calls
- Handle errors gracefully — never silently fail on user-visible operations
- Use os_log for debug logging, not print()
