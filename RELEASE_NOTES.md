## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Preserves chunk files when the master recording is chosen** — The recorder no longer deletes chunk checkpoints as soon as the primary `.caf` file wins, so the automatic fallback retry still has real audio files left to assemble if the primary transcription comes back empty.
- **Fixed updater checks when GitHub’s REST API is rate-limited** — Update checks now send proper GitHub API headers and fall back to the public latest-release page if the API returns a `403` rate-limit response, so the updater no longer dead-ends on that error.
- **Moves recovered chunk audio into a separate retry file** — Automatic fallback transcription now assembles chunk recovery into its own temporary audio file instead of mutating the original capture path in place, which avoids the missing-file failure that could still abort recovery.
- **Automatically retries transcription with recovered chunk audio** — If the fast primary recording returns an empty transcript or fails during transcription, the app now assembles the preserved fallback chunks and retries automatically instead of leaving recovery to manual retranscribe.
- **Keeps fallback chunks alive until transcription finishes** — Recording cleanup no longer destroys chunk checkpoints immediately after stop, so the app can still recover from a bad primary file during the same transcription pass.
- **Fixed stuck error overlays** — Error banners now always schedule a managed auto-dismiss cleanup instead of relying on an unmanaged timer path, so file and recording errors no longer get stranded on screen.
- **Added a manual dismiss control for recording errors** — Error overlays now expose an explicit close button, so even if the automatic cleanup path is delayed you can still clear the banner immediately.
- **Rebuilt recording for fast start and fallback recovery** — Recording now enters its active state immediately after the mic session and writers are armed, instead of waiting for the first analyzed buffer before the UI can proceed.
- **Added master recording plus rolling chunk checkpoints** — The recorder now writes one fast primary file and rolling `5s` checkpoint chunks from the same live PCM buffers, so normal stops stay fast while long recordings still have validated fallback audio if the primary file goes bad.
- **Improved long-recording failure detection** — The app now validates actual written audio against wall-clock recording time and refuses to send obviously broken one-second files into transcription.
- **Fixed intermittent near-empty recordings** — Recording startup now waits for both the first live audio buffer and AVFoundation's file-output start callback before the app considers the recorder ready, which closes the race that could occasionally produce `0:01` recordings.
- **Tightened record-start timing on macOS** — The recorder now opts into AVFoundation's sample-accurate file-recording start path so stop events cannot beat the file writer as easily on short or fast interactions.
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
