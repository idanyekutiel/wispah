## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Fixed stop-to-transcribe hangs on macOS** — Pressing the hotkey to stop recording now hands file finalization off asynchronously instead of blocking the app while AVFoundation finishes the recording file, so transcription can begin reliably after stop.
- **Removed main-thread audio finalization stalls** — The recorder now finalizes long recordings in the background and only returns to the app once the audio file is actually ready, which avoids the blank stopped state where the waveform froze but transcription never started.
- **Reworked long recording stability on macOS** — The recorder now uses `AVCaptureAudioFileOutput` for the actual on-disk recording file instead of manually appending audio buffers through `AVAssetWriterInput`, which is a safer fit for longer-running captures.
- **Separated recording from waveform analysis** — `AVCaptureAudioDataOutput` is now used only for waveform and speech detection, while file writing is handled by AVFoundation's dedicated file output path.
- **Improved Studio Display compatibility** — External microphones like Studio Display now go through the same dedicated file-recording path, which should avoid the corrupted playback and transcription issues that only showed up on longer recordings.

## Requirements

- macOS 13.0 or later
- Microphone permission
- Accessibility permission
- Screen Recording permission (optional)
- API key from [Groq](https://console.groq.com/keys) (free) or [OpenAI](https://platform.openai.com/api-keys)
