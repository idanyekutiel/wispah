import Foundation
import AVFoundation
import os.log

struct PreparedTranscriptionUpload {
    let uploadURL: URL
    let effectiveAudioFileName: String?
    let temporaryUploadURL: URL?
    let uploadDurationSeconds: Double?
}

/// An ordered fallback source of audio for transcription. The pipeline walks the
/// list, running the *same* `TranscriptionEngine` against each, until one yields a
/// high-confidence result. This is the entire redundancy layer — deliberately small
/// and out of the way of the linear main path.
struct AudioSource {
    let label: String
    /// Whether to downsample/encode this source before upload. Raw recordings need it;
    /// already-preprocessed saved audio should be uploaded as-is (no second lossy
    /// re-encode, no overwrite of the stored file).
    let applyPreprocessing: Bool
    /// Whether a successful upload should replace the saved history audio with the
    /// (preprocessed) file that was actually sent.
    let replaceSavedAudio: Bool
    /// Whether to trim to the detected speech window before upload. This is critical:
    /// Whisper hallucinates ("thank you for watching", etc.) on the non-speech padding
    /// around real speech, so a *live* recording must trim its leading/trailing silence.
    /// Already-processed saved audio (retry/retranscribe) was trimmed when first recorded,
    /// so it's sent as-is.
    let applySpeechTrimming: Bool
    /// Produces the source URL lazily (nil if unavailable — e.g. nothing to recover).
    let provide: () async -> URL?
}

struct UnifiedTranscriptionOutcome {
    let rawTranscript: String
    let effectiveAudioFileName: String?
    /// Which source produced the result (for debug status).
    let path: String
    /// True when a non-primary source or a best-effort (low-confidence) result was used.
    let usedFallback: Bool
    /// True when the returned result passed validation.
    let succeeded: Bool
    let networkRetryCount: Int
    let didRecoveryAttempt: Bool
    let recoveryReason: String?

    /// One-line, human-readable diagnostics for the run log.
    var diagnosticsSummary: String {
        var parts = ["Source: \(path)"]
        if networkRetryCount > 0 {
            parts.append("Network retries: \(networkRetryCount)")
        }
        if didRecoveryAttempt {
            parts.append("Independent recovery: \(recoveryReason ?? "weak result")")
        }
        let resultDesc: String
        if succeeded {
            resultDesc = "high confidence"
        } else if rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resultDesc = "empty"
        } else {
            resultDesc = "best effort"
        }
        parts.append("Result: \(resultDesc)")
        return parts.joined(separator: " · ")
    }
}

/// How a transcription was produced — shown as a tag in the run log detail view.
enum TranscriptionMethod: String {
    case standard
    case recovered
    case manualRetry
    case retranscribe
    case failed

    var displayLabel: String {
        switch self {
        case .standard: return "Standard"
        case .recovered: return "Recovered (fallback)"
        case .manualRetry: return "Manual retry"
        case .retranscribe: return "Retranscribe"
        case .failed: return "Failed"
        }
    }

    /// The method for a freshly-recorded transcription, given how it resolved.
    static func live(succeeded: Bool, usedFallback: Bool) -> TranscriptionMethod {
        if !succeeded && usedFallback { return .recovered }
        return .standard
    }
}

extension AppState {
    func makePrimaryTranscriptionService(customVocabulary: String) -> TranscriptionService {
        TranscriptionService(
            apiKey: activeAPIKey,
            baseURL: activeBaseURL,
            model: whisperModelId,
            language: transcriptionLanguage,
            keywords: sttVocabularyTerms(customVocabulary: customVocabulary)
        )
    }

    /// A weak result is only retried when the other provider is already configured.
    /// This makes the second opinion genuinely independent without requiring another
    /// key or silently routing ordinary successful dictation through two vendors.
    func makeRecoveryTranscriptionService(customVocabulary: String) -> TranscriptionService? {
        let recoveryProvider: APIProvider
        let recoveryKey: String
        switch apiProvider {
        case .groq:
            recoveryProvider = .openai
            recoveryKey = openaiAPIKey
        case .openai:
            recoveryProvider = .groq
            recoveryKey = apiKey
        }

        guard !recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return TranscriptionService(
            apiKey: recoveryKey,
            baseURL: recoveryProvider.baseURL,
            model: recoveryProvider.defaultWhisperModel,
            language: transcriptionLanguage,
            keywords: sttVocabularyTerms(customVocabulary: customVocabulary)
        )
    }

    func vocabularyOnlySTTPrompt(customVocabulary: String) -> String? {
        let terms = sttVocabularyTerms(customVocabulary: customVocabulary)
        guard !terms.isEmpty else { return nil }
        // Whisper accepts only a free-form prompt. GPT Transcribe receives the same
        // entries through its dedicated `keywords[]` fields in TranscriptionService.
        return "Glossary of terms that may appear: " + terms.joined(separator: ", ") + "."
    }

    func sttVocabularyTerms(customVocabulary: String) -> [String] {
        customVocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func prepareTranscriptionUpload(
        from sourceURL: URL,
        savedAudioFileName: String?,
        applySpeechTrimming: Bool,
        trimDuration: Double,
        speechStart: Double,
        replaceSavedAudio: Bool
    ) async -> PreparedTranscriptionUpload? {
        do {
            let uploadURL = try await audioRecorder.preprocessAudio(
                inputURL: sourceURL,
                trimToSeconds: applySpeechTrimming && trimDuration > 0 ? trimDuration : nil,
                skipLeadingSeconds: applySpeechTrimming ? speechStart : 0,
                automaticallyTrimSpeech: applySpeechTrimming
            )
            let uploadAsset = AVURLAsset(url: uploadURL)
            let uploadDuration = try? await uploadAsset.load(.duration)
            let uploadDurationSeconds = uploadDuration.map(CMTimeGetSeconds)
            let effectiveAudioFileName: String?
            if replaceSavedAudio, let savedAudioFileName {
                effectiveAudioFileName = Self.replaceAudioFile(
                    named: savedAudioFileName,
                    with: uploadURL,
                    preferredExtension: uploadURL.pathExtension
                )
            } else {
                effectiveAudioFileName = savedAudioFileName
            }
            return PreparedTranscriptionUpload(
                uploadURL: uploadURL,
                effectiveAudioFileName: effectiveAudioFileName,
                temporaryUploadURL: uploadURL != sourceURL ? uploadURL : nil,
                uploadDurationSeconds: uploadDurationSeconds
            )
        } catch AudioRecorderError.noSpeechDetected {
            os_log(.info, log: recordingLog, "adaptive VAD rejected source %{public}@ before upload", sourceURL.lastPathComponent)
            await MainActor.run { [weak self] in
                self?.debugStatusMessage = "No reliable speech detected"
            }
            return nil
        } catch {
            os_log(.error, log: recordingLog, "audio preprocessing failed, using original: %{public}@", error.localizedDescription)
            await MainActor.run { [weak self] in
                self?.debugStatusMessage = "Audio preprocessing failed, using original"
            }
            return PreparedTranscriptionUpload(
                uploadURL: sourceURL,
                effectiveAudioFileName: savedAudioFileName,
                temporaryUploadURL: nil,
                uploadDurationSeconds: nil
            )
        }
    }

    /// The single transcription path shared by live recording and retranscribe.
    /// Walks `sources` in order, preprocessing each and running the one canonical
    /// `TranscriptionEngine`, and returns the first high-confidence result (falling
    /// back to the best non-empty attempt). Saved-audio bookkeeping and temp-file
    /// cleanup are handled here so the engine stays pure.
    func runUnifiedTranscription(
        sources: [AudioSource],
        savedAudioFileName: String?,
        expectedDurationSeconds: Double,
        vocabularyPrompt: String?,
        transcriptionService: TranscriptionService,
        recoveryTranscriptionService: TranscriptionService? = nil,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> UnifiedTranscriptionOutcome {
        let engine = TranscriptionEngine(
            service: transcriptionService,
            recoveryService: recoveryTranscriptionService,
            onProgress: onProgress
        )
        let prompt = vocabularyPrompt

        var effectiveAudioFileName = savedAudioFileName
        var temporaryUploadURLs: [URL] = []
        var bestTranscript = ""
        var bestPath = "empty"
        var bestResult: EngineResult?
        var lastError: Error?

        defer {
            for url in temporaryUploadURLs { try? FileManager.default.removeItem(at: url) }
        }

        for (sourceIndex, source) in sources.enumerated() {
            guard let sourceURL = await source.provide() else { continue }

            let uploadURL: URL
            var sourceExpectedDuration = expectedDurationSeconds
            if source.applyPreprocessing {
                guard let prepared = await prepareTranscriptionUpload(
                    from: sourceURL,
                    savedAudioFileName: effectiveAudioFileName,
                    applySpeechTrimming: source.applySpeechTrimming,
                    trimDuration: expectedDurationSeconds,
                    speechStart: 0,
                    replaceSavedAudio: source.replaceSavedAudio
                ) else {
                    continue
                }
                if let temporaryUploadURL = prepared.temporaryUploadURL {
                    temporaryUploadURLs.append(temporaryUploadURL)
                }
                effectiveAudioFileName = prepared.effectiveAudioFileName ?? effectiveAudioFileName
                uploadURL = prepared.uploadURL
                if let duration = prepared.uploadDurationSeconds,
                   duration.isFinite,
                   duration > 0 {
                    sourceExpectedDuration = duration
                }
            } else {
                // Already upload-ready (saved audio): send as-is, don't re-encode or replace.
                uploadURL = sourceURL
            }

            do {
                let result = try await engine.transcribe(
                    uploadURL: uploadURL,
                    prompt: prompt,
                    expectedDurationSeconds: sourceExpectedDuration
                )
                if result.isHighConfidence && !result.isEmpty {
                    return UnifiedTranscriptionOutcome(
                        rawTranscript: result.rawTranscript,
                        effectiveAudioFileName: effectiveAudioFileName,
                        path: source.label,
                        usedFallback: sourceIndex > 0,
                        succeeded: true,
                        networkRetryCount: result.networkRetryCount,
                        didRecoveryAttempt: result.didRecoveryAttempt,
                        recoveryReason: result.recoveryReason
                    )
                }
                if bestTranscript.isEmpty && !result.isEmpty {
                    bestTranscript = result.rawTranscript
                    bestPath = "\(source.label)_best_effort"
                    bestResult = result
                }
            } catch {
                lastError = error
                os_log(.error, log: recordingLog, "engine source %{public}@ failed: %{public}@", source.label, error.localizedDescription)
            }
        }

        if !bestTranscript.isEmpty {
            return UnifiedTranscriptionOutcome(
                rawTranscript: bestTranscript,
                effectiveAudioFileName: effectiveAudioFileName,
                path: bestPath,
                usedFallback: true,
                succeeded: false,
                networkRetryCount: bestResult?.networkRetryCount ?? 0,
                didRecoveryAttempt: bestResult?.didRecoveryAttempt ?? false,
                recoveryReason: bestResult?.recoveryReason
            )
        }
        if let lastError { throw lastError }
        return UnifiedTranscriptionOutcome(
            rawTranscript: "",
            effectiveAudioFileName: effectiveAudioFileName,
            path: "empty",
            usedFallback: false,
            succeeded: false,
            networkRetryCount: 0,
            didRecoveryAttempt: false,
            recoveryReason: nil
        )
    }
}
