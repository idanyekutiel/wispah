## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Far fewer hallucinations on silence and background noise.** An adaptive speech detector now trims long silent lead-ins and tails before upload, preserves short and quiet dictation, and refuses to send recordings that contain only clicks or noise. Instant start/stop recordings are discarded before upload, while common fake endings such as “Thank you for watching,” Amara subtitle credits, and obvious repetition loops are rejected instead of pasted.
- **Groq-first models refreshed.** Groq now uses `whisper-large-v3` for its most accurate production transcription and `openai/gpt-oss-120b` for fast cleanup. Retired Llama models and weaker selectable transcription models have been removed. These models work with Groq's free plan, subject to its rate limits.
- **Safer retries and recovery.** Network timeouts, rate limits, and temporary server failures use bounded backoff. Weak text is no longer rerun through the same model at a higher temperature; an independent provider is consulted only when its API key is already configured.
- **OpenAI transcription upgraded.** The optional OpenAI provider now uses `gpt-transcribe`, including its language and keyword controls, while Groq remains the default workflow.
- **Post-processing restored.** Transcript cleanup uses current low-latency models with reasoning kept minimal, and failed cleanup now falls back to the raw grounded transcript with a useful diagnostic.
- **Onboarding test stabilized.** The setup recording test now runs through the same speech detection and transcription pipeline as normal dictation. Leaving the test while recording or transcribing cleanly cancels and resets it, so returning no longer leaves onboarding stuck.
- **Cancelled recordings are recoverable.** Cancelling a slow transcription now records it as a manually cancelled failure, retains its audio according to the error-retention setting, and keeps the retry action available in Transcriptions.
- **Safer history cleanup.** Clear History now asks for confirmation before permanently deleting transcription entries and their saved audio.
- **Cleaner automatic retries.** Each transcription attempt now uses fresh ephemeral HTTP transport state and Groq-aligned exponential backoff. Full request timeouts get one clean retry instead of repeating three long attempts that are unlikely to recover.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
