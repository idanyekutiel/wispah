## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Fixed the "Thank you for watching" bug.** When you had custom vocabulary set, recordings could come back as just "Thank you for watching!" — sometimes dropping a big chunk of what you actually said. The cause was how your vocabulary was being sent to the transcriber: a bare list of words was confusing the model into producing canned video-style endings and cutting transcripts short. Vocabulary is now sent as a proper glossary, which eliminates it (verified: the exact recording that used to fail every time now comes back clean every time).
- **Better recognition of custom words.** The new glossary format also helps the transcriber spell your custom terms correctly (names, product names, etc.), and the cleanup pass continues to correct close-sounding mistakes against your vocabulary list.
- **Smarter automatic retry.** If a result comes back empty or suspicious, the automatic re-roll now actually varies its decoding so it can recover — previously it could repeat the same bad result.
- **Less silence sent to the transcriber.** Recordings are trimmed to your speech again before upload, reducing a known source of hallucinations on quiet audio.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
