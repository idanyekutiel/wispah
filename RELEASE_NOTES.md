## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Bring your own API key** — choose between Groq (free, default) and OpenAI as your API provider. Both keys saved independently, switch anytime in Settings
- **Model selection** — pick your transcription model (Whisper, GPT-4o Transcribe) and post-processing model (Llama, GPT-4.1) in Settings
- **Error overlay** — missing API key or failed transcription shows an animated error from the notch with a shake and auto-dismiss
- **Smart retry** — if transcription comes back empty on a recording over 1.5 seconds, it retries automatically
- **Delete audio files** — remove stored audio from individual transcription entries while keeping the transcript
- **Settings persistence** — settings window remembers its open state and selected tab across app restarts
- **Onboarding improvements** — provider picker, toggle descriptions, smarter hotkey instructions
- **Dictionary context hints** — vocabulary terms now signal your domain to the LLM for better related-term recognition

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
