## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Onboarding bug fixes** — API key links now open correctly, test transcription uses the right model for your provider
- **Hotkey duplicate protection** — setting both hotkeys to the same key automatically clears the other one
- **Fn key warning** — emoji picker warning only shows when Fn is set as toggle key (holding Fn doesn't trigger it)
- **Retry improvements** — retry now uses your selected transcription model and language instead of defaults
- **Provider-aware UI** — run log shows actual provider and model, error messages no longer hardcode "Groq"
- **Settings API key link** — clickable link to get an API key now works correctly on the settings page
- **Disabled notarization** — releases build and sign via CI without the notarization step (right-click > Open on first launch)

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
