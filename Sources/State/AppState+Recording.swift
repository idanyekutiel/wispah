import Foundation
import AppKit
import AVFoundation
import Combine
import os.log

extension AppState {
    private func hotkeyModifierTriggerStyles() -> [HotkeyBinding: HotkeyManager.ModifierTriggerStyle] {
        var styles: [HotkeyBinding: HotkeyManager.ModifierTriggerStyle] = [:]
        if toggleHotkey.isModifier {
            styles[toggleHotkey] = .onReleaseIfSolo
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
            guard !isTranscribing else { return }
            toggleRecording()
        } else {
            switch recordingMode {
            case .holdToRecord:
                guard !isRecording && !isTranscribing else { return }
                startRecording(trigger: .hold)
            case .toggleToRecord:
                guard !isTranscribing else { return }
                toggleRecording()
            }
        }
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

    func startRecording(trigger: RecordingTrigger = .direct) {
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

        isRecording = true
        isStartingRecording = true
        pendingStop = false
        statusText = "Starting..."
        hasShownScreenshotPermissionAlert = false
        handleAudioOnRecordingStart()

        var overlayShown = false
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        initTimer.schedule(deadline: .now() + 0.5)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
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
                self.statusText = "Recording..."
                if !overlayShown {
                    self.overlayManager.showRecording()
                    overlayShown = true
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
                    self.isStartingRecording = false
                    self.statusText = "Recording..."
                    if overlayShown {
                        self.overlayManager.transitionToRecording()
                    } else {
                        self.overlayManager.showRecording()
                        overlayShown = true
                    }
                    if self.playSoundsEnabled { NSSound(named: "Purr")?.play() }
                    if self.pendingStop {
                        self.pendingStop = false
                        self.stopAndTranscribe()
                        return
                    }
                    self.startContextCapture()
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                }
            } catch {
                DispatchQueue.main.async {
                    initTimer.cancel()
                    self.handleAudioOnRecordingStop()
                    self.isStartingRecording = false
                    self.pendingStop = false
                    self.isRecording = false
                    self.errorMessage = self.formattedRecordingStartError(error)
                    self.statusText = "Error"
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

            // Build Whisper prompt as a fictitious preceding transcript.
            // Whisper treats the prompt as prior transcript text and matches its style —
            // it does NOT follow instructions. Longer prompts are more reliable.
            // Terms embedded in natural sentences work better than glossary lists.
            // Max 224 tokens (only the final 224 are considered). See:
            // https://developers.openai.com/cookbook/examples/whisper_prompting_guide
            let whisperPrompt: String? = {
                var sentences: [String] = []
                if self.developerModeEnabled {
                    sentences.append("So I pushed the commit to the repo and opened a PR for the API changes. The CI pipeline ran the tests and everything passed. I need to refactor the config and update the env variables before deploying.")
                }
                let vocab = self.customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !vocab.isEmpty {
                    let terms = vocab
                        .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if !terms.isEmpty {
                        let joined = terms.joined(separator: ", ")
                        sentences.append("Some of the key terms we've been discussing include \(joined). These come up frequently in conversation.")
                    }
                }
                return sentences.isEmpty ? nil : sentences.joined(separator: " ")
            }()

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
                    let hasSpeechTrimBounds = (speechRange?.start ?? 0) > 0 || trimDuration > 0
                    let shouldUseSegmentRetry = max(wallClockDuration, trimDuration) >= 60

                    defer {
                        for temporaryUploadURL in temporaryUploadURLs {
                            try? FileManager.default.removeItem(at: temporaryUploadURL)
                        }
                        for temporarySourceURL in temporarySourceURLs {
                            try? FileManager.default.removeItem(at: temporarySourceURL)
                        }
                    }

                    func prepareUploadURL(
                        from sourceURL: URL,
                        applySpeechTrimming: Bool,
                        replaceSavedAudio: Bool = true
                    ) async -> URL {
                        do {
                            let uploadURL = try await self.audioRecorder.preprocessAudio(
                                inputURL: sourceURL,
                                trimToSeconds: applySpeechTrimming && trimDuration > 0 ? trimDuration : nil,
                                skipLeadingSeconds: applySpeechTrimming ? (speechRange?.start ?? 0) : 0
                            )
                            if uploadURL != sourceURL {
                                temporaryUploadURLs.append(uploadURL)
                            }
                            if replaceSavedAudio {
                                effectiveSavedAudioFileName = Self.replaceAudioFile(
                                    named: effectiveSavedAudioFileName,
                                    with: uploadURL,
                                    preferredExtension: uploadURL.pathExtension
                                )
                            }
                            return uploadURL
                        } catch {
                            os_log(.error, log: recordingLog, "audio preprocessing failed, using original: %{public}@", error.localizedDescription)
                            await MainActor.run { [weak self] in
                                self?.debugStatusMessage = "Audio preprocessing failed, using original"
                            }
                            return sourceURL
                        }
                    }

                    func transcribeWithRetry(uploadURL: URL) async throws -> TranscriptionResult {
                        await MainActor.run { [weak self] in
                            self?.debugStatusMessage = "Transcribing audio"
                        }

                        var result: TranscriptionResult
                        do {
                            result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: whisperPrompt)
                        } catch let error where Self.isTransientNetworkError(error) {
                            os_log(.info, log: recordingLog, "transcription failed with transient error — retrying once: %{public}@", error.localizedDescription)
                            await MainActor.run { [weak self] in
                                self?.debugStatusMessage = "Connection issue, retrying…"
                            }
                            result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: whisperPrompt)
                        }

                        if result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimDuration > 1.5 {
                            os_log(.info, log: recordingLog, "empty transcript on %.1fs recording — retrying once", trimDuration)
                            result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: whisperPrompt)
                        }

                        return result
                    }

                    func attemptTranscription(
                        sourceURL: URL,
                        reason: String,
                        applySpeechTrimming: Bool
                    ) async throws -> TranscriptionResult {
                        let uploadURL = await prepareUploadURL(from: sourceURL, applySpeechTrimming: applySpeechTrimming)
                        os_log(
                            .info,
                            log: recordingLog,
                            "transcription attempt: %{public}@ (%{public}@ trimming)",
                            reason,
                            applySpeechTrimming ? "with" : "without"
                        )
                        return try await transcribeWithRetry(uploadURL: uploadURL)
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
                            let uploadURL = await prepareUploadURL(
                                from: segmentURL,
                                applySpeechTrimming: false,
                                replaceSavedAudio: false
                            )
                            do {
                                let result = try await transcribeUploadWithoutPrompt(uploadURL)
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
                        let recoveredResult = try await attemptTranscription(
                            sourceURL: recoveredSourceURL,
                            reason: "recovered audio after \(reason)",
                            applySpeechTrimming: false
                        )
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

                            let uploadURL = await prepareUploadURL(from: savedURL, applySpeechTrimming: false)
                            do {
                                let result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: nil)
                                let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !transcript.isEmpty {
                                    return result.transcript
                                }
                            } catch let error where Self.isTransientNetworkError(error) {
                                os_log(.info, log: recordingLog, "saved-audio retry hit transient error — retrying once: %{public}@", error.localizedDescription)
                                do {
                                    let result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: nil)
                                    let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !transcript.isEmpty {
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

                    let rawResult: String
                    var primaryFailure: Error?

                    do {
                        let primaryTrimmedResult = try await attemptTranscription(
                            sourceURL: fileURL,
                            reason: "primary recording",
                            applySpeechTrimming: true
                        )
                        let primaryTrimmedTranscript = primaryTrimmedResult.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        let shouldRetrySuspiciousPrimary = primaryTrimmedResult.hadSuspiciousOutro && !hasAttemptedSuspiciousTranscriptRetry
                        let shouldRetryPrimaryWithoutTrim = shouldRetrySuspiciousPrimary || hasSpeechTrimBounds

                        if !primaryTrimmedTranscript.isEmpty &&
                            !primaryTrimmedResult.hadSuspiciousOutro &&
                            !looksIncompleteForLongRecording(primaryTrimmedResult) {
                            rawResult = primaryTrimmedResult.transcript
                        } else if shouldRetryPrimaryWithoutTrim {
                            if primaryTrimmedResult.hadSuspiciousOutro {
                                hasAttemptedSuspiciousTranscriptRetry = true
                            }
                            os_log(.info, log: recordingLog, "retrying full saved audio after suspicious trimmed primary result")
                            do {
                                let fullPrimaryResult = try await attemptTranscription(
                                    sourceURL: fileURL,
                                    reason: "full saved audio fallback",
                                    applySpeechTrimming: false
                                )
                                let fullPrimaryTranscript = fullPrimaryResult.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !fullPrimaryTranscript.isEmpty &&
                                    !fullPrimaryResult.hadSuspiciousOutro &&
                                    !looksIncompleteForLongRecording(fullPrimaryResult) {
                                    rawResult = fullPrimaryResult.transcript
                                } else if fullPrimaryResult.hadSuspiciousOutro {
                                    os_log(.info, log: recordingLog, "full saved audio retry also looked hallucinated — switching to fallback recovery")
                                    if let fallbackResult = try await retryWithAutomaticFallbacks(reason: "suspicious full saved audio fallback") {
                                        rawResult = fallbackResult
                                    } else {
                                        rawResult = ""
                                    }
                                } else if let fallbackResult = try await retryWithAutomaticFallbacks(reason: "empty full saved audio fallback") {
                                    rawResult = fallbackResult
                                } else {
                                    rawResult = fullPrimaryResult.transcript
                                }
                            } catch {
                                primaryFailure = error
                                if let fallbackResult = try await retryWithAutomaticFallbacks(reason: error.localizedDescription) {
                                    rawResult = fallbackResult
                                } else {
                                    throw error
                                }
                            }
                        } else if let fallbackResult = try await retryWithAutomaticFallbacks(reason: "empty primary transcript") {
                            rawResult = fallbackResult
                        } else {
                            rawResult = primaryTrimmedResult.transcript
                        }
                    } catch {
                        primaryFailure = error
                        if hasSpeechTrimBounds {
                            os_log(.info, log: recordingLog, "primary transcription failed after trimmed attempt — retrying full saved audio: %{public}@", error.localizedDescription)
                            do {
                                let fullPrimaryResult = try await attemptTranscription(
                                    sourceURL: fileURL,
                                    reason: "full saved audio after primary failure",
                                    applySpeechTrimming: false
                                )
                                let fullPrimaryTranscript = fullPrimaryResult.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !fullPrimaryTranscript.isEmpty &&
                                    !fullPrimaryResult.hadSuspiciousOutro &&
                                    !looksIncompleteForLongRecording(fullPrimaryResult) {
                                    rawResult = fullPrimaryResult.transcript
                                } else if fullPrimaryResult.hadSuspiciousOutro {
                                    if let fallbackResult = try await retryWithAutomaticFallbacks(reason: "suspicious full saved audio after primary failure") {
                                        rawResult = fallbackResult
                                    } else {
                                        rawResult = ""
                                    }
                                } else if let fallbackResult = try await retryWithAutomaticFallbacks(reason: "empty full saved audio after primary failure") {
                                    rawResult = fallbackResult
                                } else {
                                    rawResult = fullPrimaryResult.transcript
                                }
                            } catch {
                                if let fallbackResult = try await retryWithAutomaticFallbacks(reason: error.localizedDescription) {
                                    rawResult = fallbackResult
                                } else {
                                    throw primaryFailure ?? error
                                }
                            }
                        } else if let fallbackResult = try await retryWithAutomaticFallbacks(reason: error.localizedDescription) {
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
                        self.debugStatusMessage = "Done"

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
    private static func isTransientNetworkError(_ error: Error) -> Bool {
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
