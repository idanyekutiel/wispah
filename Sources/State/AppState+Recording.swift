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
        // Don't try to stop if the audio engine hasn't finished starting — defer it
        guard !isStartingRecording else {
            os_log(.info, log: recordingLog, "stopAndTranscribe() deferred — still starting")
            pendingStop = true
            return
        }
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

        audioRecorder.stopRecordingAsync { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                self.transcribingIndicatorTask?.cancel()
                self.transcribingIndicatorTask = nil
                self.errorMessage = "No audio recorded"
                self.isTranscribing = false
                self.statusText = "Error"
                self.overlayManager.dismiss()
                return
            }

            let hasSevereWriteMismatch = wallClockDuration > 5 && writtenDuration < (wallClockDuration * 0.5)
            if hasSevereWriteMismatch {
                self.transcribingIndicatorTask?.cancel()
                self.transcribingIndicatorTask = nil
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

            // Skip transcription if no actual audio or no speech detected
            // (Whisper hallucinates on silent/near-silent audio — "thank you", etc.)
            if trimDuration <= 0 || !self.audioRecorder.detectedSpeech {
                if !self.audioRecorder.detectedSpeech {
                    os_log(.info, log: recordingLog, "no speech detected — skipping transcription")
                }
                self.transcribingIndicatorTask?.cancel()
                self.transcribingIndicatorTask = nil
                self.isTranscribing = false
                self.statusText = "Nothing to transcribe"
                self.overlayManager.dismiss()
                self.audioRecorder.cleanup()
                try? FileManager.default.removeItem(at: fileURL)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.statusText == "Nothing to transcribe" {
                        self.statusText = "Ready"
                    }
                }
                return
            }

            let savedAudioFileName = Self.saveAudioFile(from: fileURL)
            self.debugStatusMessage = "Processing audio"

            let transcriptionService = TranscriptionService(apiKey: self.activeAPIKey, baseURL: self.activeBaseURL, model: self.whisperModelId, language: self.transcriptionLanguage)
            let postProcessingService = PostProcessingService(apiKey: self.activeAPIKey, baseURL: self.activeBaseURL, model: self.llmModelId)

            self.transcriptionTask?.cancel()
            self.transcriptionTask = Task {
                var effectiveSavedAudioFileName = savedAudioFileName
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
                    // own re-roll + network retries and the persisted saved audio (manual
                    // retry). Additional sources can be appended here without touching the
                    // main path.
                    let sources: [AudioSource] = [
                        AudioSource(label: "primary_recording", applyPreprocessing: true, replaceSavedAudio: true, applySpeechTrimming: true) {
                            primarySourceURL
                        },
                    ]

                    let outcome = try await self.runUnifiedTranscription(
                        sources: sources,
                        savedAudioFileName: effectiveSavedAudioFileName,
                        expectedDurationSeconds: expectedDuration,
                        vocabularyPrompt: self.vocabularyOnlySTTPrompt(customVocabulary: self.customVocabulary),
                        transcriptionService: transcriptionService
                    )
                    effectiveSavedAudioFileName = outcome.effectiveAudioFileName ?? effectiveSavedAudioFileName
                    let successfulTranscriptionPath = outcome.path
                    let resolvedRawTranscript = outcome.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    let transcriptionMethod = (resolvedRawTranscript.isEmpty
                        ? TranscriptionMethod.failed
                        : TranscriptionMethod.live(succeeded: outcome.succeeded, usedFallback: outcome.usedFallback)).rawValue
                    let transcriptionDiagnostics = outcome.diagnosticsSummary
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
                    if self.postProcessingEnabled {
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
                            finalTranscript = resolvedRawTranscript
                            processingStatus = "Post-processing failed, using raw transcript"
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
                        self.transcribingIndicatorTask?.cancel()
                        self.transcribingIndicatorTask = nil
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
                        self.transcribingIndicatorTask?.cancel()
                        self.transcribingIndicatorTask = nil
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
