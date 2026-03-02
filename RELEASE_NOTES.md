## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **More reliable audio recording** — Recording no longer crashes or fails silently when headphones connect/disconnect, Bluetooth drops, AirPlay routing changes, or audio devices are added/removed mid-session.
- **Automatic recovery on device changes** — If the audio configuration changes during recording (e.g. unplugging headphones), Wispah now attempts to recover and continue recording instead of failing silently.
- **Smart microphone fallback** — If your selected microphone is unavailable when you start recording (e.g. Bluetooth headphones turned off), Wispah automatically falls back to the system default mic instead of erroring out.
- **Selected mic validation** — When audio devices change, Wispah checks if your selected microphone still exists and silently falls back to the system default if it doesn't.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
