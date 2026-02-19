<p align="center">
  <img src="Resources/AppIcon-README.png" width="128" height="128" alt="Wispah Flow icon">
</p>

<h1 align="center">
  Wispah Flow
  <br>
  <sub>Open Source Wispr Flow Alternative</sub>
</h1>

<p align="center">
  Free, open source, fully local voice-to-text for macOS. No accounts, no subscriptions - just a free API key.<br>
  Press a hotkey, speak, and your words appear at the cursor - adapted to what's on screen.
</p>

<p align="center">
  <a href="https://github.com/idanyekutiel/wispah/releases/latest/download/Wispah.dmg"><b>Download Wispah.dmg</b></a><br>
  <sub>macOS 13+ &middot; Apple Silicon + Intel</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="Wispah Flow demo" width="600">
</p>

## Features

- **Context-aware transcription** - takes a screenshot when you start recording, then uses it to get names, terminology, and formatting right. Replying to an email? It'll spell the person's name correctly. Writing code? It'll match the syntax.
- **Two recording modes** - hold-to-record (push-to-talk style) and toggle (press to start, press to stop), each with its own hotkey
- **Live recording overlay** - floating pill with waveform visualization, state transitions, and a smooth slide-to-notch animation
- **Paste at cursor** - transcription goes straight to wherever your cursor is, with smart leading-space detection so it doesn't smash into existing text
- **Transcription history** - searchable log of every transcription with audio playback
- **Usage stats** - words transcribed, recording time, streaks, words per minute
- **Auto-updates** - checks GitHub Releases in the background with a 3-day stability buffer. Downloads the DMG, replaces the app, and relaunches - all with one click.
- **Pause media while recording** - optionally pauses music/video during recording, resumes when done
- **Privacy-first** - no servers, no accounts, no telemetry. The only network calls are to Groq's API. Audio is processed and discarded, nothing stored externally.

## Why I Built This

Honestly, I built this for myself. I tried Wispr Flow, other open source alternatives, and nothing had everything I wanted in one place. Context-aware formatting existed in some tools. Developer mode existed in others. But they were either too slow, unreliable, buggy, or missing that one feature I really wanted: auto-pausing music while recording. Sounds small, but it was the dealbreaker.

I forked [FreeFlow](https://github.com/zachlatta/freeflow) by [Zach Latta](https://github.com/zachlatta) because it had the best UI/UX and was the most reliable of everything I tried. From there I added everything I was missing: full customizability, stats, optional screen context recording, custom hotkeys, sound toggles, failed transcription retry, post-processing with developer mode, cleanup to ensure the output is always good, and a bunch of other things - and of course, my beloved pause music on record.

I use it every day, so I'll keep improving it - but it'll always be free, open source, and yours to own. Check the [roadmap](#roadmap), it's a fun one.

## Why Groq

Wispah Flow uses [Groq](https://groq.com) for both transcription (Whisper) and post-processing (LLM). Two reasons:

1. **It's free.** Groq offers a free API tier - no credit card, no subscription. The free plan gives you 2,000 transcriptions/day and 8 hours of audio/day, which is far more than normal use. Just grab an API key and go.
2. **It's fast.** Groq runs on custom LPU hardware designed for inference speed. Transcriptions come back near-instantly, making the whole flow feel like native dictation.
3. **It's what we inherited.** Wispah Flow is a fork of FreeFlow, which was built on Groq from the start. It works well, so we kept it - and plan to add local model support down the road.

## Setup

1. Download from [Releases](https://github.com/idanyekutiel/wispah/releases)
2. Get a free API key at [console.groq.com](https://console.groq.com)
3. Open the app and follow the setup wizard

The wizard walks you through granting permissions (microphone, accessibility, screen recording) and configuring your hotkeys.

## Privacy

No servers, no accounts, no tracking. The only network calls are to Groq's API for transcription and context processing. Audio is processed and discarded - nothing is stored or retained externally.

## Roadmap

- [ ] Local model support - run transcription and post-processing on-device instead of requiring Groq
- [ ] Bring your own API key - use OpenAI, Claude, or any other provider instead of just Groq
- [ ] Supercharged formatting - a mode that rewrites and compresses your speech into polished, pre-written-sounding text instead of just transcribing it
- [ ] Audio file transcription - drag and drop audio files to transcribe them the same way live recordings work
- [ ] IDE integrations - feed workspace file names and active context from Cursor, Windsurf, VS Code for even smarter developer transcription
- [ ] CLI integrations - work alongside Claude Code, Codex, and other AI coding tools
- [ ] Standalone app mode - open settings/history as a proper app window that shows in the dock and app switcher
- [ ] Voice snippets - say a keyword and it expands into a predefined block of text (signatures, addresses, boilerplate)
- [ ] Writing styles - customize how your speech gets formatted depending on context (casual, professional, technical, etc.)
- [ ] Better vocabulary UI - proper tag-based editor for custom vocabulary instead of a plain text box
- [ ] Custom recording sounds - replace the default start/stop sounds with better ones

## For Developers

See [TECHNICAL_README.md](TECHNICAL_README.md) for build instructions, architecture, and how to contribute. The project includes full [Claude Code](https://claude.com/claude-code) setup (CLAUDE.md + skills) for AI-assisted development.

## Credits

Wispah Flow is a fork of [FreeFlow](https://github.com/zachlatta/freeflow) by [Zach Latta](https://github.com/zachlatta). Original project licensed under MIT.

## License

MIT License. See [LICENSE](LICENSE).

Third-party dependencies are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
