## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Improved transcription quality** — Whisper prompt restructured to use natural context sentences instead of word lists, following OpenAI's prompting guide. Trailing speech padding increased to prevent clipping final words.
- **Post-processing prompt overhaul** — Restructured with XML-scoped sections to eliminate contradicting instructions. Removed "fix grammar" (was causing sentence rewrites). Vocabulary matching softened to reduce false corrections.
- **GPT-5 model family** — Added GPT-5 Nano (new default, cheapest), GPT-5 Mini, and GPT-5 as LLM options for OpenAI users. GPT-4.1 family still available.
- **Developer mode improvements** — Now hints Whisper to expect technical speech. Post-processing preserves shorthand (won't expand "repo"), wraps inline code terms in backticks, and combines spelled-out acronyms.
- **Expanded app context** — Added Claude Code, Replit, Xcode, JetBrains IDEs, Brave, Telegram, Teams, Linear, and more. Removed opinionated tone suggestions from messaging apps.
- **Security** — XML wrapping on context inference inputs to prevent prompt injection. Saved audio files now get restricted permissions.
- **Debug menu moved to dev builds only** — Debug Logs and Debug Overlay no longer appear for users with Developer Mode enabled in production.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
