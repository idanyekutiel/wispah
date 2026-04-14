## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Fixed Studio Display microphone export corruption** — Recording export now follows AVFoundation's documented writer configuration path so device-native external microphone formats are serialized correctly instead of producing cursed playback or bad transcriptions.
- **Safer audio writer fallback settings** — When AVFoundation does not provide recommended writer settings, the recorder now lets `sourceFormatHint` fill in the channel and PCM details rather than constructing an invalid multichannel audio dictionary.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
