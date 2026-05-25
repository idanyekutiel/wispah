import Foundation
import os.log

struct PreparedTranscriptionUpload {
    let uploadURL: URL
    let effectiveAudioFileName: String?
    let temporaryUploadURL: URL?
}

struct SharedTranscriptionAttemptResult {
    let transcriptionResult: TranscriptionResult
    let effectiveAudioFileName: String?
    let temporaryUploadURL: URL?
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

    func transcribePreparedUpload(
        _ uploadURL: URL,
        using transcriptionService: TranscriptionService,
        prompt: String?,
        emptyRetryDuration: Double,
        debugStatusMessage message: String = "Transcribing audio"
    ) async throws -> TranscriptionResult {
        await MainActor.run { [weak self] in
            self?.debugStatusMessage = message
        }

        var result: TranscriptionResult
        do {
            result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: prompt)
        } catch let error where Self.isTransientNetworkError(error) {
            os_log(.info, log: recordingLog, "transcription failed with transient error — retrying once: %{public}@", error.localizedDescription)
            await MainActor.run { [weak self] in
                self?.debugStatusMessage = "Connection issue, retrying…"
            }
            result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: prompt)
        }

        if result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && emptyRetryDuration > 1.5 {
            os_log(.info, log: recordingLog, "empty transcript on %.1fs recording — retrying once", emptyRetryDuration)
            result = try await transcriptionService.transcribeDetailed(fileURL: uploadURL, prompt: prompt)
        }

        return result
    }

    func transcribeSavedAudioAttempt(
        sourceURL: URL,
        savedAudioFileName: String?,
        transcriptionService: TranscriptionService,
        customVocabulary: String,
        applySpeechTrimming: Bool,
        trimDuration: Double,
        speechStart: Double,
        replaceSavedAudio: Bool = true,
        useVocabularyPrompt: Bool,
        debugStatusMessage: String = "Transcribing audio"
    ) async throws -> SharedTranscriptionAttemptResult {
        let prepared = await prepareTranscriptionUpload(
            from: sourceURL,
            savedAudioFileName: savedAudioFileName,
            applySpeechTrimming: applySpeechTrimming,
            trimDuration: trimDuration,
            speechStart: speechStart,
            replaceSavedAudio: replaceSavedAudio
        )

        let prompt = useVocabularyPrompt ? vocabularyOnlySTTPrompt(customVocabulary: customVocabulary) : nil
        let result = try await transcribePreparedUpload(
            prepared.uploadURL,
            using: transcriptionService,
            prompt: prompt,
            emptyRetryDuration: trimDuration,
            debugStatusMessage: debugStatusMessage
        )

        return SharedTranscriptionAttemptResult(
            transcriptionResult: result,
            effectiveAudioFileName: prepared.effectiveAudioFileName,
            temporaryUploadURL: prepared.temporaryUploadURL
        )
    }
}
