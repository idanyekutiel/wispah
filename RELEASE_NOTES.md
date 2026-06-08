## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **More reliable recording.** Rebuilt the audio capture core to eliminate corrupted or garbled audio, especially on longer dictations, with per-buffer format validation and gap detection.
- **More consistent transcriptions.** Deterministic decoding plus an automatic re-try on weak results, and the live recording path now uses the exact same highest-quality pipeline as the manual "retry".
- **Re-transcribe from the menu bar.** Re-run your last recording straight from the menu if something didn't come out right.
- **Richer Run Log.** Each entry now shows how it was transcribed (method) along with retry and network diagnostics, and the audio player is now scrubbable — click or drag anywhere on the progress bar to seek.
- **Onboarding improvements.** Added an audio-behavior setting for what happens while recording, and the test step now runs the real transcription pipeline so a passing test reflects your actual setup.
- **Reliability fixes.** Smarter request timeouts for long recordings, better silence/hallucination handling, and resource-leak cleanups.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
