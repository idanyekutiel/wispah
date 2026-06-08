import Foundation
import os.log

struct PreparedTranscriptionUpload {
    let uploadURL: URL
    let effectiveAudioFileName: String?
    let temporaryUploadURL: URL?
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
    let didReroll: Bool
    let rerollReason: String?

    /// One-line, human-readable diagnostics for the run log (network retries, re-rolls, outcome).
    var diagnosticsSummary: String {
        var parts = ["Source: \(path)"]
        if networkRetryCount > 0 {
            parts.append("Network retries: \(networkRetryCount)")
        }
        if didReroll {
            parts.append("Re-roll: \(rerollReason ?? "weak result")")
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
    func vocabularyOnlySTTPrompt(customVocabulary: String) -> String? {
        let vocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vocab.isEmpty else { return nil }
        let terms = vocab
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }

    func prepareTranscriptionUpload(
        from sourceURL: URL,
        savedAudioFileName: String?,
        applySpeechTrimming: Bool,
        trimDuration: Double,
        speechStart: Double,
        replaceSavedAudio: Bool
    ) async -> PreparedTranscriptionUpload {
        do {
            let uploadURL = try await audioRecorder.preprocessAudio(
                inputURL: sourceURL,
                trimToSeconds: applySpeechTrimming && trimDuration > 0 ? trimDuration : nil,
                skipLeadingSeconds: applySpeechTrimming ? speechStart : 0
            )
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
                temporaryUploadURL: uploadURL != sourceURL ? uploadURL : nil
            )
        } catch {
            os_log(.error, log: recordingLog, "audio preprocessing failed, using original: %{public}@", error.localizedDescription)
            await MainActor.run { [weak self] in
                self?.debugStatusMessage = "Audio preprocessing failed, using original"
            }
            return PreparedTranscriptionUpload(
                uploadURL: sourceURL,
                effectiveAudioFileName: savedAudioFileName,
                temporaryUploadURL: nil
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
        transcriptionService: TranscriptionService
    ) async throws -> UnifiedTranscriptionOutcome {
        let engine = TranscriptionEngine(service: transcriptionService)
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
            if source.applyPreprocessing {
                let prepared = await prepareTranscriptionUpload(
                    from: sourceURL,
                    savedAudioFileName: effectiveAudioFileName,
                    applySpeechTrimming: false,
                    trimDuration: expectedDurationSeconds,
                    speechStart: 0,
                    replaceSavedAudio: source.replaceSavedAudio
                )
                if let temporaryUploadURL = prepared.temporaryUploadURL {
                    temporaryUploadURLs.append(temporaryUploadURL)
                }
                effectiveAudioFileName = prepared.effectiveAudioFileName ?? effectiveAudioFileName
                uploadURL = prepared.uploadURL
            } else {
                // Already upload-ready (saved audio): send as-is, don't re-encode or replace.
                uploadURL = sourceURL
            }

            do {
                let result = try await engine.transcribe(
                    uploadURL: uploadURL,
                    prompt: prompt,
                    expectedDurationSeconds: expectedDurationSeconds
                )
                if result.isHighConfidence && !result.isEmpty {
                    return UnifiedTranscriptionOutcome(
                        rawTranscript: result.rawTranscript,
                        effectiveAudioFileName: effectiveAudioFileName,
                        path: source.label,
                        usedFallback: sourceIndex > 0,
                        succeeded: true,
                        networkRetryCount: result.networkRetryCount,
                        didReroll: result.didReroll,
                        rerollReason: result.rerollReason
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
                didReroll: bestResult?.didReroll ?? false,
                rerollReason: bestResult?.rerollReason
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
            didReroll: false,
            rerollReason: nil
        )
    }
}
