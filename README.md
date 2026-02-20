<p align="center">
  <img src="Resources/AppIcon-README.png" width="128" height="128" alt="Wispah Flow icon">
</p>

<h1 align="center">Wispah Flow</h1>

<p align="center">
  Free and open source alternative to <a href="https://wisprflow.ai">Wispr Flow</a>, <a href="https://superwhisper.com">Superwhisper</a>, and <a href="https://monologue.to">Monologue</a>.<br>
  Press a hotkey, speak, and your words appear at the cursor - adapted to what's on screen.
</p>

<p align="center">
  <a href="https://github.com/idanyekutiel/wispah/releases/latest/download/Wispah.dmg"><b>⬇ Download Wispah.dmg</b></a><br>
  <sub>macOS 13+ &middot; Apple Silicon + Intel</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="Wispah Flow demo" width="600">
</p>

## Features

- **Context-aware transcription** - takes a screenshot when you start recording, then uses it to get names, terminology, and formatting right. Replying to an email? It'll spell the person's name correctly. Writing code? It'll match the syntax.
- **Customizable post-processing** - everything is a toggle. Want raw transcription with no processing? Turn it all off. Want the full pipeline? Enable smart formatting (auto-detects lists, paragraphs), smart corrections (cleans up "wait no, I meant..." mid-speech), developer mode (recognizes code terms), and screen context - mix and match to fit how you work.
- **Two recording modes** - hold-to-record (push-to-talk style) and toggle (press to start, press to stop), each with its own hotkey
- **Live recording overlay** - floating pill with waveform visualization, state transitions, and a smooth slide-to-notch animation
- **Paste at cursor** - transcription goes straight to wherever your cursor is, with smart leading-space detection so it doesn't smash into existing text
- **Transcription history** - searchable log of every transcription with audio playback
- **Usage stats** - words transcribed, recording time, streaks, words per minute
- **Auto-updates** - checks GitHub Releases in the background with a 3-day stability buffer. Downloads the DMG, replaces the app, and relaunches - all with one click.
- **Pause media while recording** - optionally pauses music/video during recording, resumes when done
- **Privacy-first** - no servers, no accounts, no telemetry. The only network calls are to your chosen provider's API. Audio is processed and discarded, nothing stored externally.

## Why I Built This

Honestly, I built this for myself. I tried Wispr Flow, other open source alternatives, and nothing had everything I wanted in one place. Context-aware formatting existed in some tools. Developer mode existed in others. But they were either too slow, unreliable, buggy, or missing that one feature I really wanted: auto-pausing music while recording. Sounds small, but it was the dealbreaker.

I forked [FreeFlow](https://github.com/zachlatta/freeflow) by [Zach Latta](https://github.com/zachlatta) because it had the best UI/UX and was the most reliable of everything I tried. From there I added everything I was missing: full customizability, stats, optional screen context recording, custom hotkeys, sound toggles, failed transcription retry, post-processing with developer mode, cleanup to ensure the output is always good, and a bunch of other things - and of course, my beloved pause music on record.

I use it every day, so I'll keep improving it - but it'll always be free, open source, and yours to own. Check the [roadmap](#roadmap), it's a fun one.

## API Providers

Wispah Flow supports **Groq** and **OpenAI** as API providers. Pick one during setup, switch anytime in Settings. Both keys are saved — switching is instant.

| Provider | Transcription | Post-Processing | Free Tier |
|----------|--------------|-----------------|-----------|
| [Groq](https://groq.com) | Whisper Large V3 / Turbo | Llama 4 Scout / 3.3 70B | Yes — no credit card needed |
| [OpenAI](https://openai.com) | GPT-4o Mini Transcribe / Transcribe / Whisper 1 | GPT-4.1 Nano / Mini / 4.1 | No — pay-as-you-go |

**Why Groq is the default:** It's free, fast (custom LPU hardware), and what we inherited from FreeFlow. For most users it's all you need.

## Setup

1. Download from [Releases](https://github.com/idanyekutiel/wispah/releases)
2. Get an API key — [Groq](https://console.groq.com) (free) or [OpenAI](https://platform.openai.com/api-keys)
3. Open the app and follow the setup wizard

The wizard walks you through picking a provider, granting permissions (microphone, accessibility, screen recording), and configuring your hotkeys.

## Privacy

No servers, no accounts, no tracking. The only network calls are to your chosen provider's API for transcription and context processing. Audio is processed and discarded - nothing is stored or retained externally.

## Roadmap

- [ ] Local model support - run transcription and post-processing on-device with no API key required
- [x] Bring your own API key - use OpenAI or Groq with provider-specific model selection
- [ ] Supercharged formatting - a mode that rewrites and compresses your speech into polished, pre-written-sounding text instead of just transcribing it
- [ ] Audio file transcription - drag and drop audio files to transcribe them the same way live recordings work
- [ ] IDE integrations - feed workspace file names and active context from Cursor, Windsurf, VS Code for even smarter developer transcription
- [ ] CLI integrations - work alongside Claude Code, Codex, and other AI coding tools
- [x] Standalone app mode - settings/history opens as a proper app window that shows in the dock and app switcher
- [ ] Voice snippets - say a keyword and it expands into a predefined block of text (signatures, addresses, boilerplate)
- [x] Custom post-processing prompt - add your own instructions to the post-processing pipeline (e.g. "I say 'so like' a lot, remove it" or "keep my sentences short and direct") so the output matches your personal writing style
- [ ] Writing styles - presets for how your speech gets formatted depending on context (casual, professional, technical, etc.)
- [ ] Improved dictionary page - tag-based editor, categories, import/export, and per-app vocabulary profiles
- [x] Mute system audio while recording - option to mute all system audio during recording instead of just pausing media
- [ ] Automatic Fn key emoji picker suppression - currently requires a manual System Settings change; working on intercepting it programmatically

## For Developers

See [TECHNICAL_README.md](TECHNICAL_README.md) for build instructions, architecture, and how to contribute. The project includes full [Claude Code](https://claude.com/claude-code) setup (CLAUDE.md + skills) for AI-assisted development.

## Credits

Wispah Flow is a fork of [FreeFlow](https://github.com/zachlatta/freeflow) by [Zach Latta](https://github.com/zachlatta). Original project licensed under MIT.

## License

MIT License. See [LICENSE](LICENSE).

Third-party dependencies are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
