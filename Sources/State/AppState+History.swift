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
                let service = TranscriptionService(apiKey: apiKey)
                let transcript = try await service.transcribe(fileURL: audioURL)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

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
                            debugStatus: "Retry",
                            customVocabulary: item.customVocabulary,
                            audioFileName: item.audioFileName,
                            recordingDurationSeconds: item.recordingDurationSeconds
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
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
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
        recordingDurationSeconds: Double? = nil
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
            recordingDurationSeconds: recordingDurationSeconds
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
