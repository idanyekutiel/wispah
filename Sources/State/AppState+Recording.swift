import Foundation
import AppKit
import AVFoundation
import Combine
import os.log

extension AppState {
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
        hotkeyManager.start(bindings: uniqueBindings)
    }

    func restartHotkeyMonitoring() {
        let uniqueBindings = Array(Set([toggleHotkey, holdHotkey]))
        hotkeyManager.start(bindings: uniqueBindings)
    }

    func handleHotkeyDown(binding: HotkeyBinding) {
        os_log(.info, log: recordingLog, "handleHotkeyDown() fired, key=%{public}@, isRecording=%{public}d, isTranscribing=%{public}d", binding.displayName, isRecording, isTranscribing)
        if binding == holdHotkey && binding != toggleHotkey {
            guard !isRecording && !isTranscribing else { return }
            startRecording()
        } else if binding == toggleHotkey && binding != holdHotkey {
            guard !isTranscribing else { return }
            toggleRecording()
        } else {
            switch recordingMode {
            case .holdToRecord:
                guard !isRecording && !isTranscribing else { return }
                startRecording()
            case .toggleToRecord:
                guard !isTranscribing else { return }
                toggleRecording()
            }
        }
    }

    func handleHotkeyUp(binding: HotkeyBinding) {
        if binding == holdHotkey && binding != toggleHotkey {
            guard isRecording else { return }
            stopAndTranscribe()
        } else if binding == toggleHotkey && binding != holdHotkey {
            return
        } else {
            switch recordingMode {
            case .holdToRecord:
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
            startRecording()
        }
    }

    func startRecording() {
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
        guard ensureMicrophoneAccess() else { return }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        beginRecording()
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func ensureMicrophoneAccess() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        self?.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        self?.statusText = "No Microphone"
                        self?.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
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
                os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
                self.statusText = "Recording..."
                if overlayShown {
                    self.overlayManager.transitionToRecording()
                } else {
                    self.overlayManager.showRecording()
                }
                overlayShown = true
                if self.playSoundsEnabled { NSSound(named: "Purr")?.play() }
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
                    self.isStartingRecording = false
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
        guard let fileURL = audioRecorder.stopRecording() else {
            errorMessage = "No audio recorded"
            isRecording = false
            statusText = "Error"
            overlayManager.dismiss()
            return
        }

        // Skip transcription if no actual audio or no speech detected
        // (Whisper hallucinates on silent/near-silent audio — "thank you", etc.)
        if trimDuration <= 0 || !audioRecorder.detectedSpeech {
            if !audioRecorder.detectedSpeech {
                os_log(.info, log: recordingLog, "no speech detected — skipping transcription")
            }
            isRecording = false
            statusText = "Nothing to transcribe"
            overlayManager.dismiss()
            audioRecorder.cleanup()
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.statusText == "Nothing to transcribe" {
                    self.statusText = "Ready"
                }
            }
            return
        }

        let savedAudioFileName = Self.saveAudioFile(from: fileURL)
        isRecording = false
        isTranscribing = true
        statusText = "Transcribing..."
        debugStatusMessage = "Processing audio"
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

        let transcriptionService = TranscriptionService(apiKey: activeAPIKey, baseURL: activeBaseURL, model: whisperModelId, language: transcriptionLanguage)
        let postProcessingService = PostProcessingService(apiKey: activeAPIKey, baseURL: activeBaseURL, model: llmModelId)

        // Build Whisper prompt as a fictitious preceding transcript.
        // Whisper treats the prompt as prior transcript text and matches its style —
        // it does NOT follow instructions. Longer prompts are more reliable.
        // Terms embedded in natural sentences work better than glossary lists.
        // Max 224 tokens (only the final 224 are considered). See:
        // https://developers.openai.com/cookbook/examples/whisper_prompting_guide
        let whisperPrompt: String? = {
            var sentences: [String] = []
            if developerModeEnabled {
                sentences.append("So I pushed the commit to the repo and opened a PR for the API changes. The CI pipeline ran the tests and everything passed. I need to refactor the config and update the env variables before deploying.")
            }
            let vocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !vocab.isEmpty {
                let terms = vocab
                    .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !terms.isEmpty {
                    // Weave terms into natural sentences so Whisper learns spellings from context
                    let joined = terms.joined(separator: ", ")
                    sentences.append("Some of the key terms we've been discussing include \(joined). These come up frequently in conversation.")
                }
            }
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }()

        transcriptionTask?.cancel()
        transcriptionTask = Task {
            do {
                // Preprocess: downsample to 16KHz mono AAC + trim to speech boundaries
                let uploadURL: URL
                do {
                    uploadURL = try await audioRecorder.preprocessAudio(
                        inputURL: fileURL,
                        trimToSeconds: speechRange?.end,
                        skipLeadingSeconds: speechRange?.start ?? 0
                    )
                    // Overwrite saved audio with the trimmed version (what Whisper hears)
                    if let audioFileName = savedAudioFileName {
                        let savedURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
                        try? FileManager.default.removeItem(at: savedURL)
                        try? FileManager.default.copyItem(at: uploadURL, to: savedURL)
                    }
                } catch {
                    os_log(.error, log: recordingLog, "audio preprocessing failed, using original: %{public}@", error.localizedDescription)
                    await MainActor.run { [weak self] in
                        self?.debugStatusMessage = "Audio preprocessing failed, using original"
                    }
                    uploadURL = fileURL
                }
                await MainActor.run { [weak self] in
                    self?.debugStatusMessage = "Transcribing audio"
                }

                var rawResult: String
                do {
                    rawResult = try await transcriptionService.transcribe(fileURL: uploadURL, prompt: whisperPrompt)
                } catch let error where Self.isTransientNetworkError(error) {
                    os_log(.info, log: recordingLog, "transcription failed with transient error — retrying once: %{public}@", error.localizedDescription)
                    await MainActor.run { [weak self] in
                        self?.debugStatusMessage = "Connection issue, retrying…"
                    }
                    rawResult = try await transcriptionService.transcribe(fileURL: uploadURL, prompt: whisperPrompt)
                }

                // Smart retry: if transcript is empty but recording was long enough, retry once
                if rawResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimDuration > 1.5 {
                    os_log(.info, log: recordingLog, "empty transcript on %.1fs recording — retrying once", trimDuration)
                    rawResult = try await transcriptionService.transcribe(fileURL: uploadURL, prompt: whisperPrompt)
                }
                let rawTranscript = rawResult

                // Clean up preprocessed file if different from original
                if uploadURL != fileURL {
                    try? FileManager.default.removeItem(at: uploadURL)
                }
                let appContext: AppContext
                if let sessionContext {
                    appContext = sessionContext
                } else if let inFlightContext = await inFlightContextTask?.value {
                    appContext = inFlightContext
                } else {
                    appContext = fallbackContextAtStop()
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
                            transcript: rawTranscript,
                            context: appContext,
                            customVocabulary: customVocabulary,
                            smartFormatting: smartFormattingEnabled,
                            smartCorrections: smartCorrectionsEnabled,
                            developerMode: developerModeEnabled,
                            customPrompt: customPostProcessingPrompt
                        )
                        finalTranscript = postProcessingResult.transcript
                        processingStatus = "Post-processing succeeded"
                        postProcessingPrompt = postProcessingResult.prompt
                    } catch {
                        finalTranscript = rawTranscript
                        processingStatus = "Post-processing failed, using raw transcript"
                        postProcessingPrompt = ""
                    }
                } else {
                    finalTranscript = rawTranscript
                    processingStatus = "Post-processing disabled"
                    postProcessingPrompt = ""
                }
                await MainActor.run {
                    self.lastContextSummary = appContext.contextSummary
                    self.lastContextScreenshotDataURL = appContext.screenshotDataURL
                    self.lastContextScreenshotStatus = appContext.screenshotError
                        ?? "available (\(appContext.screenshotMimeType ?? "image"))"
                    let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        audioFileName: savedAudioFileName,
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
                    resolvedContext = fallbackContextAtStop()
                }
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
                        audioFileName: savedAudioFileName,
                        recordingDurationSeconds: trimDuration > 0 ? trimDuration : nil
                    )
                }
            }
        }
    }

    // MARK: - Network error classification

    /// Returns true for transient network errors that are worth retrying once
    /// (connection lost, timeout, DNS failure, etc.)
    private static func isTransientNetworkError(_ error: Error) -> Bool {
        if let transcriptionError = error as? TranscriptionError, transcriptionError.isTimeout {
            return true
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return [-1001, -1005, -1009, -1003, -1004, -1200].contains(nsError.code)
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
