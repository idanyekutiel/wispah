## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Dictionary page** — dedicated tab for custom vocabulary words, accessible from sidebar and menu bar
- **Smart corrections** — new toggle that removes verbal self-corrections ("wait no", "I mean") keeping only your final intent
- **Settings reorganized** — grouped into logical sections (Recording, Transcription, Data & Privacy) with section headers
- **Flat recording overlay** — cleaner solid design replacing the liquid glass effect
- **Standalone app mode** — app shows in dock and app switcher when any window is open, hides when all close
- **Improved speech detection** — RMS-based speech boundary detection trims silence before and after speech
- **Whisper hallucination fix** — raised no_speech_prob threshold to 0.95, fixing false empty transcripts on clear speech
- **Resume media on quit** — if music was paused during recording and you quit, it resumes
- **Stats reordered** — Activity card shown first
- **Menu bar revamp** — Stats, Dictionary, Transcriptions, and Settings as separate buttons
- **Cmd+Comma** opens Settings (standard macOS shortcut)
- **Retry improvements** — retry available on failed (red) and empty (yellow) transcriptions
- **Debug tools** — debug log viewer, debug overlay, capture audio controls (developer mode only)

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- Free Groq API key ([get one here](https://console.groq.com/keys))
