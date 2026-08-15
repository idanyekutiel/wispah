import Foundation
import AppKit
import AVFoundation
import Combine
import os.log

extension AppState {
    private func hotkeyModifierTriggerStyles() -> [HotkeyBinding: HotkeyManager.ModifierTriggerStyle] {
        var styles: [HotkeyBinding: HotkeyManager.ModifierTriggerStyle] = [:]
        if toggleHotkey == holdHotkey, toggleHotkey.isModifier {
            styles[toggleHotkey] = recordingMode == .holdToRecord ? .onPress : .speculativePressIfSolo
            return styles
        }
        if toggleHotkey.isModifier {
            styles[toggleHotkey] = .speculativePressIfSolo
        }
        if holdHotkey.isModifier {
            styles[holdHotkey] = .onPress
        }
        return styles
    }

    func startHotkeyMonitoring() {
        hotkeyManager.onKeyDown = { [weak self] binding in
            DispatchQueue.main.async {
                self?.handleHotkeyDown(binding: binding)
            }
        }
        hotkeyManager.onKeyUp = { [weak self] binding in
            DispatchQueue.main.async {
                self?.handleHotkeyUp(binding: binding)
            }
        }
        hotkeyManager.onSpeculativeKeyDown = { [weak self] binding in
            DispatchQueue.main.async {
                self?.handleHotkeySpeculativePress(binding: binding)
            }
        }
        hotkeyManager.onSpeculativeCancel = { [weak self] binding in
            DispatchQueue.main.async {
                self?.handleHotkeySpeculativeCancel(binding: binding)
            }
        }
        let uniqueBindings = Array(Set([toggleHotkey, holdHotkey]))
        hotkeyManager.start(bindings: uniqueBindings, modifierTriggerStyles: hotkeyModifierTriggerStyles())
    }

    func restartHotkeyMonitoring() {
        let uniqueBindings = Array(Set([toggleHotkey, holdHotkey]))
        hotkeyManager.start(bindings: uniqueBindings, modifierTriggerStyles: hotkeyModifierTriggerStyles())
    }

    func handleHotkeyDown(binding: HotkeyBinding) {
        os_log(.info, log: recordingLog, "handleHotkeyDown() fired, key=%{public}@, isRecording=%{public}d, isTranscribing=%{public}d", binding.displayName, isRecording, isTranscribing)
        if binding == holdHotkey && binding != toggleHotkey {
            guard !isRecording && !isTranscribing else { return }
            startRecording(trigger: .hold)
        } else if binding == toggleHotkey && binding != holdHotkey {
            if commitSpeculativeToggleStartIfNeeded(for: binding) {
                return
            }
            guard !isTranscribing else { return }
            toggleRecording()
        } else {
            switch recordingMode {
            case .holdToRecord:
                guard !isRecording && !isTranscribing else { return }
                startRecording(trigger: .hold)
            case .toggleToRecord:
                if commitSpeculativeToggleStartIfNeeded(for: binding) {
                    return
                }
                guard !isTranscribing else { return }
                toggleRecording()
            }
        }
    }

    func handleHotkeySpeculativePress(binding: HotkeyBinding) {
        guard binding.isModifier else { return }
        guard recordingMode == .toggleToRecord else { return }
        let bindingIsToggle = binding == toggleHotkey || (binding == holdHotkey && holdHotkey == toggleHotkey)
        guard bindingIsToggle else { return }
        guard !isRecording && !isStartingRecording && !isTranscribing else { return }
        guard speculativeToggleState == .none else { return }

        speculativeToggleState = .startingHidden
        speculativeToggleCommitted = false
        speculativeToggleCancellationRequested = false
        startRecording(trigger: .toggle, presentation: .speculativeHiddenUntilCommit)
    }

    func handleHotkeySpeculativeCancel(binding: HotkeyBinding) {
        guard binding.isModifier else { return }
        let bindingIsToggle = binding == toggleHotkey || (binding == holdHotkey && holdHotkey == toggleHotkey)
        guard bindingIsToggle else { return }
        cancelSpeculativeToggleStart()
    }

    func handleHotkeyUp(binding: HotkeyBinding) {
        if binding == holdHotkey && binding != toggleHotkey {
            if !isRecording && isAwaitingMicrophonePermission && pendingPermissionRecordingTrigger == .hold {
                pendingPermissionRecordingTrigger = nil
                return
            }
            guard isRecording else { return }
            stopAndTranscribe()
        } else if binding == toggleHotkey && binding != holdHotkey {
            return
        } else {
            switch recordingMode {
            case .holdToRecord:
                if !isRecording && isAwaitingMicrophonePermission && pendingPermissionRecordingTrigger == .hold {
                    pendingPermissionRecordingTrigger = nil
                    return
                }
                guard isRecording else { return }
                stopAndTranscribe()
            case .toggleToRecord:
                break
            }
        }
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        if isRecording {
            stopAndTranscribe()
        } else {
            startRecording(trigger: .toggle)
        }
    }

    private func commitSpeculativeToggleStartIfNeeded(for binding: HotkeyBinding) -> Bool {
        guard binding.isModifier else { return false }
        guard speculativeToggleState != .none else { return false }
        speculativeToggleCommitted = true

        switch speculativeToggleState {
        case .startingHidden:
            statusText = "Starting..."
            overlayManager.showInitializing()
            if playSoundsEnabled { NSSound(named: "Purr")?.play() }
        case .recordingHidden:
            statusText = "Recording..."
            overlayManager.showRecording()
            if playSoundsEnabled { NSSound(named: "Purr")?.play() }
            speculativeToggleState = .none
            speculativeToggleCommitted = false
            speculativeToggleCancellationRequested = false
        case .none:
            return false
        }
        return true
    }

    private func cancelSpeculativeToggleStart() {
        guard speculativeToggleState != .none else { return }
        speculativeToggleCancellationRequested = true
        errorMessage = nil
        statusText = "Ready"
        overlayManager.dismiss()

        guard !isStartingRecording else { return }

        handleAudioOnRecordingStop()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        isRecording = false
        pendingStop = false
        recordingIntentStartTime = nil
        pendingStopIntentDuration = nil
        _ = audioRecorder.stopRecording()
        audioRecorder.cleanup()
        speculativeToggleState = .none
        speculativeToggleCommitted = false
        speculativeToggleCancellationRequested = false
        recordingStartPresentation = .normal
    }

    func startRecording(trigger: RecordingTrigger = .direct, presentation: RecordingStartPresentation = .normal) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        guard !activeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlayManager.showError("\(apiProvider.displayName) API key not configured")
            statusText = "No API Key"
            return
        }
        guard hasAccessibility else {
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            showAccessibilityAlert()
            return
        }
        os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard ensureMicrophoneAccess(trigger: trigger) else { return }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        recordingStartPresentation = presentation
        beginRecording()
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func ensureMicrophoneAccess(trigger: RecordingTrigger) -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            isAwaitingMicrophonePermission = false
            pendingPermissionRecordingTrigger = nil
            return true
        case .notDetermined:
            isAwaitingMicrophonePermission = true
            pendingPermissionRecordingTrigger = trigger
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let pendingTrigger = self.pendingPermissionRecordingTrigger
                    self.pendingPermissionRecordingTrigger = nil
                    self.isAwaitingMicrophonePermission = false

                    if granted {
                        guard pendingTrigger != nil else { return }
                        self.beginRecording()
                    } else {
                        self.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        self.statusText = "No Microphone"
                        self.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            isAwaitingMicrophonePermission = false
            pendingPermissionRecordingTrigger = nil
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            showMicrophonePermissionAlert()
            return false
        }
    }

    func beginRecording() {
        guard !isStartingRecording else { return }
        os_log(.info, log: recordingLog, "beginRecording() entered")
        errorMessage = nil
        let hiddenUntilCommit = recordingStartPresentation == .speculativeHiddenUntilCommit

        isRecording = true
        isStartingRecording = true
        pendingStop = false
        recordingIntentStartTime = CFAbsoluteTimeGetCurrent()
        pendingStopIntentDuration = nil
        hasShownScreenshotPermissionAlert = false
        if !hiddenUntilCommit {
            statusText = "Starting..."
        }
        handleAudioOnRecordingStart()

        var overlayShown = false
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        initTimer.schedule(deadline: .now() + 0.5)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            guard !hiddenUntilCommit || self.speculativeToggleCommitted else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.overlayManager.showInitializing()
        }
        initTimer.resume()

        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                initTimer.cancel()
                os_log(.info, log: recordingLog, "first real audio — recorder fully live")
                if !hiddenUntilCommit || self.speculativeToggleCommitted {
                    self.statusText = "Recording..."
                    if !overlayShown {
                        self.overlayManager.showRecording()
                        overlayShown = true
                    }
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                let result = try self.audioRecorder.startRecording(deviceUID: deviceUID)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                if result.usedFallback {
                    os_log(.info, log: recordingLog, "recording fell back to system default mic (requested: %{public}@)", deviceUID)
                }
                DispatchQueue.main.async {
                    initTimer.cancel()
                    if hiddenUntilCommit && self.speculativeToggleCancellationRequested && !self.speculativeToggleCommitted {
                        self.isStartingRecording = false
                        self.cancelSpeculativeToggleStart()
                        return
                    }
                    self.isStartingRecording = false
                    self.startContextCapture()
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }

                    if hiddenUntilCommit {
                        self.speculativeToggleState = .recordingHidden
                        if self.speculativeToggleCommitted {
                            self.statusText = "Recording..."
                            if overlayShown {
                                self.overlayManager.transitionToRecording()
                            } else {
                                self.overlayManager.showRecording()
                                overlayShown = true
                            }
                            self.speculativeToggleState = .none
                            self.speculativeToggleCommitted = false
                            self.speculativeToggleCancellationRequested = false
                        }
                    } else {
                        self.statusText = "Recording..."
                        if overlayShown {
                            self.overlayManager.transitionToRecording()
                        } else {
                            self.overlayManager.showRecording()
                            overlayShown = true
                        }
                        if self.playSoundsEnabled { NSSound(named: "Purr")?.play() }
                    }
                    self.recordingStartPresentation = .normal
                    if self.pendingStop {
                        self.pendingStop = false
                        self.stopAndTranscribe()
                        return
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    initTimer.cancel()
                    let shouldSurfaceError = !hiddenUntilCommit || self.speculativeToggleCommitted
                    self.handleAudioOnRecordingStop()
                    self.isStartingRecording = false
                    self.pendingStop = false
                    self.recordingIntentStartTime = nil
                    self.pendingStopIntentDuration = nil
                    self.isRecording = false
                    self.speculativeToggleState = .none
                    self.speculativeToggleCommitted = false
                    self.speculativeToggleCancellationRequested = false
                    self.recordingStartPresentation = .normal
                    if shouldSurfaceError {
                        self.errorMessage = self.formattedRecordingStartError(error)
                        self.statusText = "Error"
                    } else {
                        self.errorMessage = nil
                        self.statusText = "Ready"
                    }
                    self.overlayManager.dismiss()
                }
            }
        }
    }

    func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    /// Cleanly reset all recording state after a mid-recording failure (e.g. audio config change recovery failed).
    func handleMidRecordingError(message: String) {
        os_log(.error, log: recordingLog, "handleMidRecordingError: %{public}@", message)
        handleAudioOnRecordingStop()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        isStartingRecording = false
        pendingStop = false
        recordingIntentStartTime = nil
        pendingStopIntentDuration = nil
        isRecording = false
        recordingStartPresentation = .normal
        speculativeToggleState = .none
        speculativeToggleCommitted = false
        speculativeToggleCancellationRequested = false
        _ = audioRecorder.stopRecording()
        audioRecorder.cleanup()
        errorMessage = message
        statusText = "Error"
        overlayManager.showError(message)
    }

    func stopAndTranscribe() {
        let stopIntentDuration = recordingIntentStartTime.map {
            max(CFAbsoluteTimeGetCurrent() - $0, 0)
        }
        // Don't try to stop if the audio engine hasn't finished starting — defer it
        guard !isStartingRecording else {
            os_log(.info, log: recordingLog, "stopAndTranscribe() deferred — still starting")
            pendingStop = true
            pendingStopIntentDuration = stopIntentDuration
            return
        }
        let userIntentDuration = pendingStopIntentDuration ?? stopIntentDuration ?? audioRecorder.wallClockDuration
        recordingIntentStartTime = nil
        pendingStopIntentDuration = nil
        handleAudioOnRecordingStop()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        debugStatusMessage = "Preparing audio"
        let sessionContext = capturedContext
        let inFlightContextTask = contextCaptureTask
        capturedContext = nil
        contextCaptureTask = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"

        let trimDuration = audioRecorder.lastNonSilentDuration
        let writtenDuration = audioRecorder.writtenDuration
        let wallClockDuration = audioRecorder.wallClockDuration
        recordingStartPresentation = .normal
        speculativeToggleState = .none
        speculativeToggleCommitted = false
        speculativeToggleCancellationRequested = false
        isRecording = false
        isTranscribing = true
        statusText = "Transcribing..."
        debugStatusMessage = "Finalizing audio"
        errorMessage = nil
        if playSoundsEnabled { NSSound(named: "Pop")?.play() }
        overlayManager.slideUpToNotch { }

        overlayManager.onTranscribingCancel = { [weak self] in
            self?.cancelTranscription()
        }

        transcribingIndicatorTask?.cancel()
        let indicatorDelay = transcribingIndicatorDelay
        transcribingIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(indicatorDelay * 1_000_000_000))
                let shouldShowTranscribing = self?.isTranscribing ?? false
                guard shouldShowTranscribing else { return }
                await MainActor.run { [weak self] in
                    self?.overlayManager.showTranscribing()
                }
            } catch {}
        }

        // After a threshold with no result, reassure the user it's still working and
        // offer a way out — unless a more specific notice (a retry) is already showing.
        transcribingLongWaitTask?.cancel()
        let longWaitThreshold = transcribingLongWaitThreshold
        transcribingLongWaitTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(longWaitThreshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.isTranscribing else { return }
                    self.overlayManager.showLongWaitNotice("Still working on it…")
                }
            } catch {}
        }

        audioRecorder.stopRecordingAsync { [weak self] fileURL in
            guard let self else { return }
            // A tap/release this fast cannot contain intentional dictation. Capture
            // startup padding can still make the finalized file roughly one second long,
            // which is enough for Whisper to invent subtitle credits or short words.
            // Reject based on the user's press-to-stop interval before any upload.
            if userIntentDuration < 0.30 {
                self.stopTranscribingOverlayTimers()
                self.audioRecorder.cleanup()
                if let fileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                self.isTranscribing = false
                self.statusText = "Ready"
                self.debugStatusMessage = "Ignored empty quick recording"
                self.errorMessage = nil
                self.overlayManager.dismiss()
                os_log(.info, log: recordingLog, "ignored %.0fms start-stop recording before transcription", userIntentDuration * 1000)
                return
            }
            guard let fileURL else {
                self.stopTranscribingOverlayTimers()
                self.errorMessage = "No audio recorded"
                self.isTranscribing = false
                self.statusText = "Error"
                self.overlayManager.dismiss()
                return
            }

            let hasSevereWriteMismatch = wallClockDuration > 5 && writtenDuration < (wallClockDuration * 0.5)
            if hasSevereWriteMismatch {
                self.stopTranscribingOverlayTimers()
                self.audioRecorder.cleanup()
                try? FileManager.default.removeItem(at: fileURL)
                self.errorMessage = String(
                    format: "Recording failed: only %.1fs of audio was written during a %.1fs recording.",
                    writtenDuration,
                    wallClockDuration
                )
                self.isTranscribing = false
                self.statusText = "Error"
                self.overlayManager.showError(self.errorMessage ?? "Recording failed")
                return
            }

            // The streaming meter is intentionally only UI feedback. The finalized file
            // gets an adaptive two-pass VAD scan below; using the old cumulative quiet-
            // buffer counter here both admitted background noise and rejected some quiet
            // real speech before the stronger detector could inspect it.

            let savedAudioFileName = Self.saveAudioFile(from: fileURL)
            self.debugStatusMessage = "Processing audio"

            let transcriptionService = self.makePrimaryTranscriptionService(customVocabulary: self.customVocabulary)
            let recoveryTranscriptionService = self.makeRecoveryTranscriptionService(customVocabulary: self.customVocabulary)
            let postProcessingService = PostProcessingService(apiKey: self.activeAPIKey, baseURL: self.activeBaseURL, model: self.llmModelId)

            self.transcriptionTask?.cancel()
            self.transcriptionTask = Task {
                var effectiveSavedAudioFileName = savedAudioFileName
                var rawTranscriptBeforeCancellation = ""
                var diagnosticsBeforeCancellation = "Stopped before a transcription result"
                do {
                    // Coverage baseline = speech duration (trimDuration), not wall-clock —
                    // wall-clock includes the press→speak gap and trailing silence that
                    // Whisper never "covers", which would falsely flag complete transcripts.
                    let expectedDuration = trimDuration > 0 ? trimDuration : wallClockDuration
                    let primarySourceURL = fileURL

                    // Redundancy, kept out of the way: an ordered list of audio sources
                    // the pipeline runs the one canonical engine against, in turn, until
                    // one returns a high-confidence result. With the single-file capture
                    // core the recording is the source; further redundancy is the engine's
                    // independent recovery + network retries and the persisted saved audio (manual
                    // retry). Keep the original recording in history rather than replacing
                    // it before STT succeeds: a cancelled or failed request must always
                    // retain a valid source that can be retried.
                    let sources: [AudioSource] = [
                        AudioSource(label: "primary_recording", applyPreprocessing: true, replaceSavedAudio: false, applySpeechTrimming: true) {
                            primarySourceURL
                        },
                    ]

                    let onProgress: @Sendable (TranscriptionProgress) -> Void = { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.isTranscribing else { return }
                            switch progress {
                            case .retryingNetwork:
                                self.overlayManager.updateTranscribingStatus("Connection hiccup — retrying…", showCancel: true)
                            case .rateLimited(let attempt, let maxAttempts):
                                self.overlayManager.updateTranscribingStatus("Rate limited — retrying (\(attempt)/\(maxAttempts))…", showCancel: true)
                            case .recovering:
                                self.overlayManager.updateTranscribingStatus("Checking transcription with backup model…", showCancel: true)
                            }
                        }
                    }

                    let outcome = try await self.runUnifiedTranscription(
                        sources: sources,
                        savedAudioFileName: effectiveSavedAudioFileName,
                        expectedDurationSeconds: expectedDuration,
                        vocabularyPrompt: self.vocabularyOnlySTTPrompt(customVocabulary: self.customVocabulary),
                        transcriptionService: transcriptionService,
                        recoveryTranscriptionService: recoveryTranscriptionService,
                        onProgress: onProgress
                    )
                    effectiveSavedAudioFileName = outcome.effectiveAudioFileName ?? effectiveSavedAudioFileName
                    let successfulTranscriptionPath = outcome.path
                    let resolvedRawTranscript = outcome.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    rawTranscriptBeforeCancellation = resolvedRawTranscript
                    let transcriptionMethod = (resolvedRawTranscript.isEmpty
                        ? TranscriptionMethod.failed
                        : TranscriptionMethod.live(succeeded: outcome.succeeded, usedFallback: outcome.usedFallback)).rawValue
                    let transcriptionDiagnostics = outcome.diagnosticsSummary
                    diagnosticsBeforeCancellation = transcriptionDiagnostics
                    let appContext: AppContext
                    if let sessionContext {
                        appContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        appContext = inFlightContext
                    } else {
                        appContext = self.fallbackContextAtStop()
                    }
                    await MainActor.run { [weak self] in
                        self?.debugStatusMessage = "Running post-processing"
                    }
                    let finalTranscript: String
                    let processingStatus: String
                    let postProcessingPrompt: String
                    if resolvedRawTranscript.isEmpty {
                        finalTranscript = ""
                        processingStatus = "Post-processing skipped: no transcript"
                        postProcessingPrompt = ""
                    } else if self.postProcessingEnabled {
                        do {
                            let postProcessingResult = try await postProcessingService.postProcess(
                                transcript: resolvedRawTranscript,
                                context: appContext,
                                customVocabulary: self.customVocabulary,
                                smartFormatting: self.smartFormattingEnabled,
                                smartCorrections: self.smartCorrectionsEnabled,
                                developerMode: self.developerModeEnabled,
                                customPrompt: self.customPostProcessingPrompt
                            )
                            finalTranscript = postProcessingResult.transcript
                            processingStatus = "Post-processing succeeded"
                            postProcessingPrompt = postProcessingResult.prompt
                        } catch {
                            // A user cancellation must abort the pipeline, not fall back to
                            // pasting the raw transcript — route it to the cancellation path.
                            if Task.isCancelled || AppState.isCancellation(error) { throw error }
                            finalTranscript = resolvedRawTranscript
                            processingStatus = "Post-processing failed: \(error.localizedDescription); using raw transcript"
                            postProcessingPrompt = ""
                        }
                    } else {
                        finalTranscript = resolvedRawTranscript
                        processingStatus = "Post-processing disabled"
                        postProcessingPrompt = ""
                    }
                    let sttDebugStatus = "Done · STT: \(successfulTranscriptionPath)"
                    let historyAudioFileName = effectiveSavedAudioFileName
                    await MainActor.run {
                        self.lastContextSummary = appContext.contextSummary
                        self.lastContextScreenshotDataURL = appContext.screenshotDataURL
                        self.lastContextScreenshotStatus = appContext.screenshotError
                            ?? "available (\(appContext.screenshotMimeType ?? "image"))"
                        let trimmedRawTranscript = resolvedRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedFinalTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.lastPostProcessingPrompt = postProcessingPrompt
                        self.lastRawTranscript = trimmedRawTranscript
                        self.lastPostProcessedTranscript = trimmedFinalTranscript
                        self.lastPostProcessingStatus = processingStatus
                        self.debugStatusMessage = sttDebugStatus
                        self.recordPipelineHistoryEntry(
                            rawTranscript: trimmedRawTranscript,
                            postProcessedTranscript: trimmedFinalTranscript,
                            postProcessingPrompt: postProcessingPrompt,
                            context: appContext,
                            processingStatus: processingStatus,
                            audioFileName: historyAudioFileName,
                            recordingDurationSeconds: trimDuration > 0 ? trimDuration : nil,
                            transcriptionMethod: transcriptionMethod,
                            diagnostics: transcriptionDiagnostics
                        )
                        self.stopTranscribingOverlayTimers()
                        self.lastTranscript = trimmedFinalTranscript
                        self.isTranscribing = false

                        if trimmedFinalTranscript.isEmpty {
                            self.statusText = "Nothing to transcribe"
                            self.overlayManager.dismiss()
                        } else {
                            self.overlayManager.showDone()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                self.overlayManager.dismiss()
                            }

                            let textToPaste = self.needsLeadingSpace() ? " " + trimmedFinalTranscript : trimmedFinalTranscript

                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(textToPaste, forType: .string)

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                self.pasteAtCursor()
                            }

                            self.statusText = "Pasted!"
                        }

                        self.audioRecorder.cleanup()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if self.statusText == "Pasted!" || self.statusText == "Nothing to transcribe" {
                                self.statusText = "Ready"
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled || AppState.isCancellation(error) {
                        // Cancellation stops network/model work but does not discard the
                        // recording. Persist it as a recoverable failed run so History can
                        // play it and invoke the normal retranscription path.
                        let cancellationContext = sessionContext ?? self.fallbackContextAtStop()
                        let historyAudioFileName = effectiveSavedAudioFileName
                        await MainActor.run { [weak self] in
                            self?.handleTranscriptionCancelled(
                                context: cancellationContext,
                                audioFileName: historyAudioFileName,
                                recordingDurationSeconds: trimDuration > 0 ? trimDuration : nil,
                                rawTranscript: rawTranscriptBeforeCancellation,
                                diagnostics: diagnosticsBeforeCancellation
                            )
                        }
                        return
                    }
                    let resolvedContext: AppContext
                    if let sessionContext {
                        resolvedContext = sessionContext
                    } else if let inFlightContext = await inFlightContextTask?.value {
                        resolvedContext = inFlightContext
                    } else {
                        resolvedContext = self.fallbackContextAtStop()
                    }
                    let historyAudioFileName = effectiveSavedAudioFileName
                    await MainActor.run {
                        self.stopTranscribingOverlayTimers()
                        self.errorMessage = error.localizedDescription
                        self.isTranscribing = false
                        self.statusText = "Error"
                        self.audioRecorder.cleanup()
                        self.overlayManager.showError(error.localizedDescription)
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = resolvedContext.screenshotError
                            ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                        self.recordPipelineHistoryEntry(
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            context: resolvedContext,
                            processingStatus: "Error: \(error.localizedDescription)",
                            audioFileName: historyAudioFileName,
                            recordingDurationSeconds: trimDuration > 0 ? trimDuration : nil,
                            transcriptionMethod: TranscriptionMethod.failed.rawValue,
                            diagnostics: "Error: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Transcription cancellation

    /// Cancel the transcribing overlay's delayed-indicator and long-wait timers together.
    func stopTranscribingOverlayTimers() {
        transcribingIndicatorTask?.cancel()
        transcribingIndicatorTask = nil
        transcribingLongWaitTask?.cancel()
        transcribingLongWaitTask = nil
    }

    /// User-initiated cancel from the transcribing overlay. Cancelling `transcriptionTask`
    /// aborts the in-flight request (the async `URLSession` upload honors task cancellation)
    /// and unwinds to the cancellation branch in `stopAndTranscribe`, which calls
    /// `handleTranscriptionCancelled` to reset state. Shows immediate feedback meanwhile.
    func cancelTranscription() {
        guard isTranscribing else { return }
        os_log(.info, log: recordingLog, "cancelTranscription() — user cancelled")
        transcriptionTask?.cancel()
        overlayManager.updateTranscribingStatus("Cancelling…", showCancel: false)
    }

    /// Reset after cancellation while retaining a failed history entry and its audio.
    /// No error overlay is shown because cancellation was an intentional user action.
    func handleTranscriptionCancelled(
        context: AppContext,
        audioFileName: String?,
        recordingDurationSeconds: Double?,
        rawTranscript: String,
        diagnostics: String
    ) {
        stopTranscribingOverlayTimers()
        isTranscribing = false
        errorMessage = nil
        statusText = "Cancelled"
        debugStatusMessage = "Cancelled by user"
        lastRawTranscript = rawTranscript
        lastPostProcessedTranscript = ""
        lastPostProcessingStatus = "Error: Manually cancelled"
        lastPostProcessingPrompt = ""
        lastContextSummary = context.contextSummary
        lastContextScreenshotDataURL = context.screenshotDataURL
        lastContextScreenshotStatus = context.screenshotError
            ?? "available (\(context.screenshotMimeType ?? "image"))"
        let audioStatus = audioFileName == nil
            ? "Audio could not be retained"
            : "Audio retained for retry"
        recordPipelineHistoryEntry(
            rawTranscript: rawTranscript,
            postProcessedTranscript: "",
            postProcessingPrompt: "",
            context: context,
            processingStatus: "Error: Manually cancelled",
            audioFileName: audioFileName,
            recordingDurationSeconds: recordingDurationSeconds,
            transcriptionMethod: TranscriptionMethod.failed.rawValue,
            diagnostics: "Cancelled by user · \(audioStatus) · \(diagnostics)"
        )
        overlayManager.dismiss()
        audioRecorder.cleanup()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.statusText == "Cancelled" {
                self.statusText = "Ready"
            }
        }
    }

    /// True for errors that represent a cooperative cancellation (Swift task cancel or a
    /// cancelled `URLSession` request), so the pipeline can treat them as user intent.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: - Network error classification

    /// Returns true for transient network errors that are worth retrying once
    /// (connection lost, timeout, DNS failure, etc.)
    static func isTransientNetworkError(_ error: Error) -> Bool {
        if let transcriptionError = error as? TranscriptionError, transcriptionError.isTimeout {
            return false
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return [-1005, -1009, -1003, -1004, -1200].contains(nsError.code)
        }
        return false
    }

    // MARK: - Debug Overlay

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        overlayManager.showRecording()

        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        overlayManager.dismiss()
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }
}
