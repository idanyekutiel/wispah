## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Long recordings now transcribe reliably.** Recordings longer than ~1.5 minutes used to degrade, repeat themselves, or cut off entirely. Wispah now automatically splits long recordings at natural pauses, transcribes the pieces, and stitches them back together — so even a 30-minute dictation comes through cleanly and completely.
- **Faster long transcriptions.** The pieces are transcribed in parallel, so long recordings finish noticeably quicker.
- **Graceful handling of API rate limits.** When your provider is busy (especially on Groq's free tier), Wispah now paces and retries automatically instead of failing — tuned for each provider.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
