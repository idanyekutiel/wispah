## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Lighter, faster transcription pipeline.** Audio is now captured at 16 kHz (Whisper's native rate) instead of being downsampled later — same transcription accuracy, but smaller uploads and less processing between stopping a recording and getting your text.
- **Snappier stop-to-paste.** Removed redundant file work after recording (an unnecessary metadata-rewrite pass and a duplicate duration read) so results come back a little quicker.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
