## Installation

1. Download the DMG below
2. Open it and drag Wispah to Applications
3. Launch Wispah Flow and follow the setup wizard

## Changelog

- **Replaces the crashy speculative `Fn` toggle path with a safer manager-level debounce** — Bare modifier toggles no longer spin up the recorder invisibly on key down, avoiding the stop-time crash introduced in `v2026.05.23` while keeping the hotkey logic simple and stable.
- **Keeps solo `Fn` toggle responsive without the old release-only lag** — Modifier-only toggle recognition now uses a very short solo-tap debounce in the hotkey manager, which is faster than the previous release-only behavior without reintroducing the speculative recorder path.
- **Preserves combo and system-action cancellation for bare modifiers** — `Fn + J`, `Fn + Option`, keyboard backlight, media, brightness, and other system-defined actions still cancel bare modifier triggers instead of leaking into recording.
- **Keeps onboarding aligned with the corrected hotkey behavior** — The setup wizard now matches the shipped bare-modifier debounce path instead of a separate speculative toggle flow.
- **Makes `Fn` behave like a real combo modifier** — Hotkeys now treat `Fn` as part of actual chord matching, so `Fn + J`, `Fn + Command`, `Fn + Option`, and similar combos no longer leak through and trigger bare-`Fn` recording.
- **Allows modifier-only combo bindings** — You can now record and use modifier combinations like `Fn + Command` or `Fn + Option`, not just standalone modifier keys or modifier-plus-letter bindings.
- **Cancels bare modifier hotkeys on system keyboard actions** — If `Fn` is being used for keyboard backlight, media, brightness, or similar system-defined actions, the app now cancels the standalone hotkey instead of recording anyway.
- **Aligns onboarding hotkey behavior with the real app** — The setup wizard now uses the same modifier trigger semantics as the main recorder, so `Fn` and other modifier hotkeys behave consistently during onboarding and after setup.
- **Blocks onboarding from continuing with unusable hotkeys** — Setup now requires at least one real recording shortcut before proceeding, and the test step routes back to hotkey setup if none are configured.
- **Refreshes microphone permission state after returning from Settings** — Onboarding now re-checks mic access when the app becomes active again and sends denied users to Settings instead of repeating the broken request path.
- **Keeps onboarding microphone selection coherent with remembered devices** — If setup is using a selected external mic, the onboarding picker now includes that device instead of silently hiding it.
- **Restores your chosen microphone automatically after reconnect** — If you explicitly picked a mic like Studio Display or AirPods, the app now falls back to `System Default` only while that device is unavailable, then restores your chosen mic when it reconnects.
- **Sends suspicious `Thanks for watching` transcripts straight to chunk recovery** — Known corrupted-audio hallucinations now jump directly into the chunk-based fallback path instead of first trusting the normal full-audio retry.
- **Defers recorder errors until automatic recovery actually gives up** — Stop-time recorder teardown no longer flashes an error banner while the chunk/saved-audio retry path is still running, so successful automatic recovery stays silent.
- **Treats bogus `thank you` transcripts as suspicious too** — Gratitude-only hallucinations like `thank you`, `thanks`, and the old `thank you for watching` variants are now rejected and retried instead of being accepted as final dictation.
- **Stops accepting a suspicious second retry as final** — If the full-audio retry still looks hallucinated, the app now falls through to chunk or saved-audio recovery instead of pasting that bad result.
- **Checks for new updates daily** — Automatic update checks now re-run every day instead of every week, which better matches the current release cadence.
- **Fixed `Fn` shortcut behavior for both toggle and hold modes** — Bare `Fn` now fires on release only if it stayed solo, so `Fn + key` combos no longer trigger recording, while hold-to-record `Fn` still starts immediately on press like before.
- **Added long-recording segment transcription fallback** — Long recordings that fail or come back incomplete now assemble larger transcription segments from the checkpoint chunks and transcribe those before surfacing an error.
- **Detects incomplete long transcripts by segment coverage** — If a long recording only transcribes the first portion of the audio, the app now treats that as incomplete and automatically switches to the segment fallback path.
- **Added a final saved-audio retry that mirrors manual retranscribe** — Automatic transcription now makes one last no-trim/no-prompt attempt using the saved run-log audio before recording a failure, matching the path that previously only worked from the history view.
- **Rewrote recording error banners to one deterministic panel** — Recording errors now use a single top-of-screen banner with one dismiss path instead of the old pill-plus-drop animation flow that could leave stale UI stranded onscreen.
- **Added reliable manual and timed error dismissal** — Error banners can now always be cleared with `x` or by tapping the banner, and they auto-dismiss after `12s`.
- **Fixed automatic transcription mismatching manual retranscribe** — When the first automatic upload fails or comes back empty after speech-boundary trimming, the app now retries the full saved audio before falling back to recovered chunk audio.
- **Treats `"Thank you for watching"` endings as a suspect transcript** — The recorder now mistrusts that known hallucinated outro and retries automatically instead of accepting a truncated transcript as final.
- **Caps hallucination-triggered retries to one extra attempt** — Known suspicious outro detection can only trigger one automatic retry, so it cannot spin through repeated fallback loops.
- **Prevents duplicate recovered-audio retries inside one transcription task** — The app now assembles fallback audio at most once per recording and reuses that recovery source instead of re-entering destructive chunk recovery with stale file paths.
- **Fixed the stuck recording error-banner race** — Error overlays now cancel their delayed label-drop work item when dismissed, so they cannot reappear after dismissal and get stranded onscreen.
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
