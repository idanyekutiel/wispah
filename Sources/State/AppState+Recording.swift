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
        let speechRange = audioRecorder.speechTimeRange
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
                    var temporaryUploadURLs: [URL] = []
                    var temporarySourceURLs: [URL] = []
                    var recoveredSourceURL: URL?
                    var hasAttemptedRecoveredRetry = false
                    var hasAttemptedSuspiciousTranscriptRetry = false
                    var hasAttemptedSegmentRetry = false
                    let shouldUseSegmentRetry = max(wallClockDuration, trimDuration) >= 60
                    var successfulTranscriptionPath = "full_saved_audio"
                    var fallbackReason: String?

                    defer {
                        for temporaryUploadURL in temporaryUploadURLs {
                            try? FileManager.default.removeItem(at: temporaryUploadURL)
                        }
                        for temporarySourceURL in temporarySourceURLs {
                            try? FileManager.default.removeItem(at: temporarySourceURL)
                        }
                    }

                    func transcribeUploadWithoutPrompt(_ uploadURL: URL) async throws -> TranscriptionResult {
                        do {
                            return try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: nil)
                        } catch let error where Self.isTransientNetworkError(error) {
                            os_log(.info, log: recordingLog, "chunk transcription hit transient error — retrying once: %{public}@", error.localizedDescription)
                            return try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: nil)
                        }
                    }

                    func looksIncompleteForLongRecording(_ result: TranscriptionResult) -> Bool {
                        guard shouldUseSegmentRetry, let coveredAudioDuration = result.coveredAudioDuration else {
                            return false
                        }

                        let expectedDuration = max(trimDuration, wallClockDuration)
                        guard expectedDuration >= 60 else { return false }
                        let minimumExpectedCoverage = expectedDuration * 0.75
                        let isIncomplete = coveredAudioDuration < minimumExpectedCoverage
                        if isIncomplete {
                            os_log(
                                .info,
                                log: recordingLog,
                                "transcript coverage %.1fs below expected %.1fs — treating as incomplete",
                                coveredAudioDuration,
                                minimumExpectedCoverage
                            )
                        }
                        return isIncomplete
                    }

                    func retryWithTranscriptionSegments(reason: String) async -> String? {
                        guard shouldUseSegmentRetry else { return nil }
                        guard !hasAttemptedSegmentRetry else {
                            os_log(.info, log: recordingLog, "skipping duplicate segment retry after %{public}@", reason)
                            return nil
                        }
                        hasAttemptedSegmentRetry = true

                        let segmentURLs = self.audioRecorder.assembleTranscriptionSegmentsIfAvailable(targetDurationSeconds: 30)
                        guard !segmentURLs.isEmpty else {
                            os_log(.error, log: recordingLog, "no transcription segments available after %{public}@", reason)
                            return nil
                        }
                        temporarySourceURLs.append(contentsOf: segmentURLs)

                        os_log(.info, log: recordingLog, "retrying transcription as %d segments after %{public}@", segmentURLs.count, reason)
                        var transcripts: [String] = []

                        for (index, segmentURL) in segmentURLs.enumerated() {
                            await MainActor.run { [weak self] in
                                self?.debugStatusMessage = "Transcribing chunk \(index + 1)/\(segmentURLs.count)"
                            }
                            let prepared = await self.prepareTranscriptionUpload(
                                from: segmentURL,
                                savedAudioFileName: nil,
                                applySpeechTrimming: false,
                                trimDuration: trimDuration,
                                speechStart: speechRange?.start ?? 0,
                                replaceSavedAudio: false
                            )
                            if let temporaryUploadURL = prepared.temporaryUploadURL {
                                temporaryUploadURLs.append(temporaryUploadURL)
                            }
                            do {
                                let result = try await transcribeUploadWithoutPrompt(prepared.uploadURL)
                                let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !transcript.isEmpty {
                                    transcripts.append(transcript)
                                }
                            } catch {
                                os_log(.error, log: recordingLog, "segment %d transcription failed: %{public}@", index + 1, error.localizedDescription)
                            }
                        }

                        let joinedTranscript = transcripts.joined(separator: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !joinedTranscript.isEmpty {
                            successfulTranscriptionPath = "segment_chunks"
                            fallbackReason = reason
                        }
                        return joinedTranscript.isEmpty ? nil : joinedTranscript
                    }

                    func retryWithRecoveredAudio(reason: String) async throws -> String? {
                        guard !hasAttemptedRecoveredRetry else {
                            os_log(.info, log: recordingLog, "skipping duplicate recovered-audio retry after %{public}@", reason)
                            return nil
                        }
                        hasAttemptedRecoveredRetry = true

                        if recoveredSourceURL == nil {
                            recoveredSourceURL = self.audioRecorder.assembleFallbackRecordingIfAvailable()
                        }

                        guard let recoveredSourceURL else {
                            os_log(.error, log: recordingLog, "no recovered chunk audio available for retry after %{public}@", reason)
                            return nil
                        }

                        if recoveredSourceURL != fileURL && !temporarySourceURLs.contains(recoveredSourceURL) {
                            temporarySourceURLs.append(recoveredSourceURL)
                        }
                        os_log(.info, log: recordingLog, "retrying transcription with recovered chunk audio after %{public}@", reason)
                        await MainActor.run { [weak self] in
                            self?.debugStatusMessage = "Recovering audio and retrying"
                        }
                        let recoveredAttempt = try await self.transcribeSavedAudioAttempt(
                            sourceURL: recoveredSourceURL,
                            savedAudioFileName: effectiveSavedAudioFileName,
                            transcriptionService: transcriptionService,
                            customVocabulary: self.customVocabulary,
                            applySpeechTrimming: false,
                            trimDuration: trimDuration,
                            speechStart: speechRange?.start ?? 0,
                            replaceSavedAudio: true,
                            useVocabularyPrompt: true,
                            debugStatusMessage: "Recovering audio and retrying"
                        )
                        if let temporaryUploadURL = recoveredAttempt.temporaryUploadURL {
                            temporaryUploadURLs.append(temporaryUploadURL)
                        }
                        effectiveSavedAudioFileName = recoveredAttempt.effectiveAudioFileName
                            ?? effectiveSavedAudioFileName
                        let recoveredResult = recoveredAttempt.transcriptionResult
                        if !recoveredResult.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            successfulTranscriptionPath = "recovered_chunk_audio"
                            fallbackReason = reason
                        }
                        return recoveredResult.transcript
                    }

                    func retryWithAutomaticFallbacks(reason: String) async throws -> String? {
                        if let segmentedResult = await retryWithTranscriptionSegments(reason: reason) {
                            return segmentedResult
                        }
                        if let recoveredResult = try await retryWithRecoveredAudio(reason: reason) {
                            return recoveredResult
                        }
                        if let savedAudioResult = await retryWithSavedAudioLikeManualRetry(reason: reason) {
                            return savedAudioResult
                        }
                        return nil
                    }

                    func retryWithSavedAudioLikeManualRetry(reason: String) async -> String? {
                        let candidateNames = [effectiveSavedAudioFileName, savedAudioFileName]
                            .compactMap { $0 }
                            .reduce(into: [String]()) { names, name in
                                if !names.contains(name) {
                                    names.append(name)
                                }
                            }

                        for audioFileName in candidateNames {
                            let savedURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
                            guard FileManager.default.fileExists(atPath: savedURL.path) else { continue }

                            os_log(.info, log: recordingLog, "last-chance saved-audio retry after %{public}@: %{public}@", reason, audioFileName)
                            await MainActor.run { [weak self] in
                                self?.debugStatusMessage = "Retrying saved audio"
                            }

                            do {
                                let retryAttempt = try await self.transcribeSavedAudioAttempt(
                                    sourceURL: savedURL,
                                    savedAudioFileName: effectiveSavedAudioFileName,
                                    transcriptionService: transcriptionService,
                                    customVocabulary: self.customVocabulary,
                                    applySpeechTrimming: false,
                                    trimDuration: trimDuration,
                                    speechStart: speechRange?.start ?? 0,
                                    replaceSavedAudio: true,
                                    useVocabularyPrompt: true,
                                    debugStatusMessage: "Retrying saved audio"
                                )
                                if let temporaryUploadURL = retryAttempt.temporaryUploadURL {
                                    temporaryUploadURLs.append(temporaryUploadURL)
                                }
                                effectiveSavedAudioFileName = retryAttempt.effectiveAudioFileName
                                    ?? effectiveSavedAudioFileName
                                let result = retryAttempt.transcriptionResult
                                let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !transcript.isEmpty {
                                    successfulTranscriptionPath = "saved_audio_last_chance"
                                    fallbackReason = reason
                                    return result.transcript
                                }
                            } catch let error where Self.isTransientNetworkError(error) {
                                os_log(.info, log: recordingLog, "saved-audio retry hit transient error — retrying once: %{public}@", error.localizedDescription)
                                do {
                                    let retryAttempt = try await self.transcribeSavedAudioAttempt(
                                        sourceURL: savedURL,
                                        savedAudioFileName: effectiveSavedAudioFileName,
                                        transcriptionService: transcriptionService,
                                        customVocabulary: self.customVocabulary,
                                        applySpeechTrimming: false,
                                        trimDuration: trimDuration,
                                        speechStart: speechRange?.start ?? 0,
                                        replaceSavedAudio: true,
                                        useVocabularyPrompt: true,
                                        debugStatusMessage: "Retrying saved audio"
                                    )
                                    if let temporaryUploadURL = retryAttempt.temporaryUploadURL {
                                        temporaryUploadURLs.append(temporaryUploadURL)
                                    }
                                    effectiveSavedAudioFileName = retryAttempt.effectiveAudioFileName
                                        ?? effectiveSavedAudioFileName
                                    let result = retryAttempt.transcriptionResult
                                    let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !transcript.isEmpty {
                                        successfulTranscriptionPath = "saved_audio_last_chance"
                                        fallbackReason = reason
                                        return result.transcript
                                    }
                                } catch {
                                    os_log(.error, log: recordingLog, "saved-audio retry failed after transient retry: %{public}@", error.localizedDescription)
                                }
                            } catch {
                                os_log(.error, log: recordingLog, "saved-audio retry failed: %{public}@", error.localizedDescription)
                            }
                        }

                        return nil
                    }

                    func incompleteTranscriptError(path: String) -> NSError {
                        NSError(
                            domain: "WispahTranscription",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Transcription was incomplete after \(path)"]
                        )
                    }

                    let rawResult: String
                    var primaryFailure: Error?

                    do {
                        let primaryAttempt = try await self.transcribeSavedAudioAttempt(
                            sourceURL: fileURL,
                            savedAudioFileName: effectiveSavedAudioFileName,
                            transcriptionService: transcriptionService,
                            customVocabulary: self.customVocabulary,
                            applySpeechTrimming: false,
                            trimDuration: trimDuration,
                            speechStart: speechRange?.start ?? 0,
                            replaceSavedAudio: true,
                            useVocabularyPrompt: true
                        )
                        if let temporaryUploadURL = primaryAttempt.temporaryUploadURL {
                            temporaryUploadURLs.append(temporaryUploadURL)
                        }
                        effectiveSavedAudioFileName = primaryAttempt.effectiveAudioFileName
                            ?? effectiveSavedAudioFileName
                        let primaryFullResult = primaryAttempt.transcriptionResult
                        let primaryFullTranscript = primaryFullResult.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        let shouldRetrySuspiciousPrimary = primaryFullResult.hadSuspiciousOutro && !hasAttemptedSuspiciousTranscriptRetry

                        if !primaryFullTranscript.isEmpty &&
                            !primaryFullResult.hadSuspiciousOutro &&
                            !looksIncompleteForLongRecording(primaryFullResult) {
                            successfulTranscriptionPath = "full_saved_audio"
                            rawResult = primaryFullResult.transcript
                        } else if shouldRetrySuspiciousPrimary {
                            hasAttemptedSuspiciousTranscriptRetry = true
                            os_log(.info, log: recordingLog, "suspicious primary transcript detected — switching directly to chunk-based fallback recovery")
                            if let fallbackResult = try await retryWithAutomaticFallbacks(reason: "suspicious primary transcript") {
                                rawResult = fallbackResult
                            } else {
                                rawResult = ""
                            }
                        } else if let fallbackResult = try await retryWithAutomaticFallbacks(
                            reason: primaryFullTranscript.isEmpty ? "empty primary transcript" : "incomplete primary transcript"
                        ) {
                            rawResult = fallbackResult
                        } else {
                            if primaryFullTranscript.isEmpty {
                                rawResult = primaryFullResult.transcript
                            } else {
                                throw incompleteTranscriptError(path: "primary full saved audio")
                            }
                        }
                    } catch {
                        primaryFailure = error
                        if let fallbackResult = try await retryWithAutomaticFallbacks(reason: error.localizedDescription) {
                            rawResult = fallbackResult
                        } else {
                            throw primaryFailure ?? error
                        }
                    }
                    var rawTranscript = rawResult
                    if rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let fallbackResult = try await retryWithAutomaticFallbacks(reason: "empty automatic transcript") {
                        rawTranscript = fallbackResult
                    }
                    let resolvedRawTranscript = rawTranscript
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
                    let sttDebugStatus = fallbackReason.map {
                        "Done · STT: \(successfulTranscriptionPath) · fallback: \($0)"
                    } ?? "Done · STT: \(successfulTranscriptionPath)"
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
                            recordingDurationSeconds: trimDuration > 0 ? trimDuration : nil
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
                            recordingDurationSeconds: trimDuration > 0 ? trimDuration : nil
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
