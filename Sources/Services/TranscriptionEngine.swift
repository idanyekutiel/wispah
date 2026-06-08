import Foundation
import os.log

/// Outcome of a single engine transcription attempt.
struct EngineResult {
    let rawTranscript: String
    let coveredAudioDuration: Double?
    /// True when the result passed validation (non-empty, not a known hallucination,
    /// no obvious repeat-loop, and — for long audio — adequate coverage).
    let isHighConfidence: Bool
    /// How many times a request was retried due to a transient network error.
    let networkRetryCount: Int
    /// Whether the engine re-rolled (one extra attempt) due to a weak first result.
    let didReroll: Bool
    /// Why the re-roll happened (e.g. "empty result", "repeat loop") — nil if none.
    let rerollReason: String?

    var trimmedTranscript: String {
        rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool {
        trimmedTranscript.isEmpty
    }
}

/// The single, canonical transcription path. Both live recording and
/// "retranscribe from history" call `transcribe` so the highest-quality path is
/// guaranteed identical no matter how it was triggered.
///
/// Responsibilities: send one request with `temperature=0`, validate the result,
/// and re-roll once on a suspicious/empty/incomplete result (Whisper's server-side
/// temperature fallback is nondeterministic, so a second attempt often comes back
/// clean — this is what a manual "redo" did before, now built in).
///
/// Audio preprocessing and saved-file bookkeeping stay in the orchestration layer
/// (they are deterministic and shared by both callers, so they don't affect path
/// parity); the engine receives an upload-ready file.
final class TranscriptionEngine {
    private let service: TranscriptionService

    /// Long-audio coverage below this fraction of the expected speech duration is
    /// treated as incomplete and worth one re-roll. Kept conservative (0.6) so normal
    /// leading/trailing silence doesn't masquerade as a truncated transcript.
    private let minimumCoverageFraction = 0.6
    /// Recordings at or above this length are eligible for the coverage check.
    private let longRecordingThresholdSeconds: Double = 30

    init(service: TranscriptionService) {
        self.service = service
    }

    /// Transcribe an already-preprocessed, upload-ready file.
    /// - Parameters:
    ///   - uploadURL: 16kHz mono file ready to POST.
    ///   - prompt: optional vocabulary prompt.
    ///   - expectedDurationSeconds: best-known recording length, for the coverage check.
    func transcribe(
        uploadURL: URL,
        prompt: String?,
        expectedDurationSeconds: Double
    ) async throws -> EngineResult {
        var (result, networkRetryCount) = try await requestCountingNetworkRetries(uploadURL, prompt: prompt)

        // The empty/suspicious/incomplete re-roll lives here only — exactly one extra
        // attempt — so a weak result never balloons into many requests.
        var didReroll = false
        let rerollReason = rerollReason(result, expected: expectedDurationSeconds)
        if let rerollReason {
            didReroll = true
            os_log(.info, log: recordingLog, "engine: %{public}@ — one smart re-roll", rerollReason)
            let (reroll, rerollNetworkRetries) = try await requestCountingNetworkRetries(uploadURL, prompt: prompt)
            networkRetryCount += rerollNetworkRetries
            result = preferBetter(result, reroll, expected: expectedDurationSeconds)
        }

        return EngineResult(
            rawTranscript: result.transcript,
            coveredAudioDuration: result.coveredAudioDuration,
            isHighConfidence: isHighConfidence(result, expected: expectedDurationSeconds),
            networkRetryCount: networkRetryCount,
            didReroll: didReroll,
            rerollReason: rerollReason
        )
    }

    // MARK: - Request (with transient + empty re-tries)

    /// One transcription request, retried once on a transient network error. Returns the
    /// result plus how many network retries were spent (0 or 1).
    /// (Empty/weak-result re-rolls are owned solely by `transcribe` so they can't stack.)
    private func requestCountingNetworkRetries(
        _ uploadURL: URL,
        prompt: String?
    ) async throws -> (TranscriptionResult, Int) {
        do {
            return (try await service.transcribeDetailed(fileURL: uploadURL, prompt: prompt), 0)
        } catch let error where AppState.isTransientNetworkError(error) {
            os_log(.info, log: recordingLog, "engine: transient network error — retrying once: %{public}@", error.localizedDescription)
            return (try await service.transcribeDetailed(fileURL: uploadURL, prompt: prompt), 1)
        }
    }

    // MARK: - Validation

    private func isHighConfidence(_ result: TranscriptionResult, expected: Double) -> Bool {
        let text = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !result.hadSuspiciousOutro else { return false }
        guard !hasRepeatLoop(text) else { return false }
        guard !isCoverageIncomplete(result, expected: expected) else { return false }
        return true
    }

    /// The reason this result is weak enough to justify a single re-roll, or nil if it's fine.
    private func rerollReason(_ result: TranscriptionResult, expected: Double) -> String? {
        let text = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return expected > 1.5 ? "empty result" : nil }
        if result.hadSuspiciousOutro { return "suspicious outro" }
        if hasRepeatLoop(text) { return "repeat loop" }
        if isCoverageIncomplete(result, expected: expected) { return "incomplete coverage" }
        return nil
    }

    private func isCoverageIncomplete(_ result: TranscriptionResult, expected: Double) -> Bool {
        guard expected >= longRecordingThresholdSeconds,
              let covered = result.coveredAudioDuration else { return false }
        let incomplete = covered < expected * minimumCoverageFraction
        if incomplete {
            os_log(.info, log: recordingLog, "engine: coverage %.1fs below %.0f%% of expected %.1fs", covered, minimumCoverageFraction * 100, expected)
        }
        return incomplete
    }

    /// When two attempts disagree, keep the stronger one: prefer a confident result,
    /// then a non-empty one, then better coverage.
    private func preferBetter(
        _ first: TranscriptionResult,
        _ second: TranscriptionResult,
        expected: Double
    ) -> TranscriptionResult {
        let firstConfident = isHighConfidence(first, expected: expected)
        let secondConfident = isHighConfidence(second, expected: expected)
        if firstConfident != secondConfident {
            return firstConfident ? first : second
        }

        let firstEmpty = first.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let secondEmpty = second.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if firstEmpty != secondEmpty {
            return firstEmpty ? second : first
        }

        let firstCoverage = first.coveredAudioDuration ?? 0
        let secondCoverage = second.coveredAudioDuration ?? 0
        return secondCoverage > firstCoverage ? second : first
    }

    // MARK: - Repeat-loop detection

    /// Conservative detector for Whisper's classic repeat-loop hallucination. Only
    /// flags unmistakable loops (the same word repeated many times in a row, or a
    /// very low unique-word ratio over a long transcript) so we never re-roll good audio.
    private func hasRepeatLoop(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.count >= 16 else { return false }

        // A run of the SAME multi-character token repeated 10+ times is a loop, not
        // speech. Short tokens ("no", "ha", "uh") are excluded — emphatic real speech
        // ("no no no no no…") legitimately repeats them.
        var runLength = 1
        for index in 1..<words.count {
            if words[index] == words[index - 1] {
                runLength += 1
                if runLength >= 10 && words[index].count >= 3 { return true }
            } else {
                runLength = 1
            }
        }

        // Or an extremely low unique-word ratio over a long transcript.
        let uniqueRatio = Double(Set(words).count) / Double(words.count)
        return words.count >= 60 && uniqueRatio < 0.1
    }
}
