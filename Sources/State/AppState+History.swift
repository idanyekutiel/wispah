import Foundation
import AppKit

extension AppState {
    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    /// The most recent history entry whose audio file still exists on disk — the target
    /// for "re-transcribe last audio" from the menu bar.
    var lastRetranscribableItem: PipelineHistoryItem? {
        pipelineHistory.first { item in
            guard let name = item.audioFileName else { return false }
            return FileManager.default.fileExists(atPath: Self.audioStorageDirectory().appendingPathComponent(name).path)
        }
    }

    func retryHistoryEntry(item: PipelineHistoryItem) {
        guard let audioFileName = item.audioFileName else {
            errorMessage = "No audio file available to retry"
            return
        }
        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            errorMessage = "Audio file no longer exists"
            return
        }

        Task {
            do {
                let service = makePrimaryTranscriptionService(customVocabulary: item.customVocabulary)
                let recoveryService = makeRecoveryTranscriptionService(customVocabulary: item.customVocabulary)
                let savedSource = AudioSource(label: "saved_audio", applyPreprocessing: true, replaceSavedAudio: false, applySpeechTrimming: true) { audioURL }
                let outcome = try await runUnifiedTranscription(
                    sources: [savedSource],
                    savedAudioFileName: item.audioFileName,
                    expectedDurationSeconds: item.recordingDurationSeconds ?? 0,
                    vocabularyPrompt: vocabularyOnlySTTPrompt(customVocabulary: item.customVocabulary),
                    transcriptionService: service,
                    recoveryTranscriptionService: recoveryService
                )

                let trimmed = outcome.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw TranscriptionError.transcriptionFailed("No reliable speech was detected in the saved audio")
                }
                let updatedAudioFileName = outcome.effectiveAudioFileName ?? item.audioFileName

                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed, forType: .string)

                    if let index = pipelineHistory.firstIndex(where: { $0.id == item.id }) {
                        let updated = PipelineHistoryItem(
                            id: item.id,
                            timestamp: item.timestamp,
                            rawTranscript: trimmed,
                            postProcessedTranscript: trimmed,
                            postProcessingPrompt: item.postProcessingPrompt,
                            contextSummary: item.contextSummary,
                            contextPrompt: item.contextPrompt,
                            contextScreenshotDataURL: item.contextScreenshotDataURL,
                            contextScreenshotStatus: item.contextScreenshotStatus,
                            postProcessingStatus: "Retried successfully",
                            debugStatus: "Retry · STT: \(outcome.path)",
                            customVocabulary: item.customVocabulary,
                            audioFileName: updatedAudioFileName,
                            recordingDurationSeconds: item.recordingDurationSeconds,
                            transcriptionMethod: TranscriptionMethod.manualRetry.rawValue,
                            diagnostics: outcome.diagnosticsSummary
                        )
                        pipelineHistory[index] = updated
                        try? pipelineHistoryStore.update(updated)
                    }

                    lastTranscript = trimmed
                    statusText = "Copied to clipboard!"
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Retry failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func updateHistoryEntry(_ item: PipelineHistoryItem) throws {
        try pipelineHistoryStore.update(item)
    }

    func deleteHistoryEntry(id: UUID) {
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.removeAll(where: { $0.id == id })
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    func recordPipelineHistoryEntry(
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        context: AppContext,
        processingStatus: String,
        audioFileName: String? = nil,
        recordingDurationSeconds: Double? = nil,
        transcriptionMethod: String? = nil,
        diagnostics: String? = nil
    ) {
        let isError = processingStatus.hasPrefix("Error:")

        guard saveRunHistory else {
            if let audioFileName {
                Self.deleteAudioFile(audioFileName)
            }
            return
        }

        var effectiveAudioFileName = audioFileName
        if !saveAudioFiles, let audioFileName {
            if isError && keepAudioOnErrors {
                // Keep audio for retry on errors
            } else {
                Self.deleteAudioFile(audioFileName)
                effectiveAudioFileName = nil
            }
        }

        let newEntry = PipelineHistoryItem(
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            contextSummary: context.contextSummary,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: context.screenshotError
                ?? "available (\(context.screenshotMimeType ?? "image"))",
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: effectiveAudioFileName,
            recordingDurationSeconds: recordingDurationSeconds,
            transcriptionMethod: transcriptionMethod,
            diagnostics: diagnostics
        )
        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }

        // Accumulate persistent stats (survives history trimming)
        if collectStats && !isError && !postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let words = postProcessedTranscript.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            statsStore.record(wordCount: words, recordingDurationSeconds: recordingDurationSeconds, timestamp: Date())
        }
    }
}
