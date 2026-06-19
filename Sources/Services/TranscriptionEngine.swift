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
    private let chunker: AudioChunker

    /// Long-audio coverage below this fraction of the expected speech duration is
    /// treated as incomplete and worth one re-roll. Kept conservative (0.6) so normal
    /// leading/trailing silence doesn't masquerade as a truncated transcript.
    private let minimumCoverageFraction = 0.6
    /// Recordings at or above this length are eligible for the coverage check.
    private let longRecordingThresholdSeconds: Double = 30
    /// Temperature for the single re-roll. The first attempt is deterministic (0); a stuck
    /// hallucination ("thank you for watching" on silence) reproduces verbatim at 0, so the
    /// re-roll must perturb the decoder to have any chance of escaping it.
    private let rerollTemperature: Double = 0.4

    /// Recordings longer than this are split into overlapping chunks transcribed
    /// independently and stitched back together (see `transcribeChunked`). Below it, the
    /// single-shot path is faster and carries no stitching risk, so it's left untouched.
    private let chunkingThresholdSeconds: Double = 90
    /// Max chunks uploaded at once. Bounded so a long take doesn't fan out into a burst
    /// that trips provider rate limits.
    private let maxConcurrentChunks = 4

    init(service: TranscriptionService, chunker: AudioChunker = AudioChunker()) {
        self.service = service
        self.chunker = chunker
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
        // Long audio degrades and times out as a single request; split it at silence and
        // transcribe the pieces independently. Any failure in the split path falls back to
        // the proven single-shot transcription of the whole file.
        if expectedDurationSeconds > chunkingThresholdSeconds {
            do {
                return try await transcribeChunked(uploadURL: uploadURL, prompt: prompt)
            } catch {
                os_log(.error, log: recordingLog, "engine: chunked transcription failed (%{public}@) — falling back to single-shot", error.localizedDescription)
            }
        }
        return try await transcribeSingleFile(uploadURL: uploadURL, prompt: prompt, expectedDurationSeconds: expectedDurationSeconds)
    }

    /// Transcribe one upload-ready file as a single request, with the smart re-roll.
    private func transcribeSingleFile(
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
            os_log(.info, log: recordingLog, "engine: %{public}@ — one smart re-roll at temp %.1f", rerollReason, rerollTemperature)
            let (reroll, rerollNetworkRetries) = try await requestCountingNetworkRetries(uploadURL, prompt: prompt, temperature: rerollTemperature)
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

    // MARK: - Chunked transcription (long audio)

    /// Split a long recording at silence into overlapping chunks, transcribe them
    /// concurrently (each conditioned only on the vocabulary prompt — never on a sibling
    /// chunk's text, which is what stops Whisper's hallucinations from propagating), then
    /// stitch the de-overlapped transcripts. Per-chunk re-roll and validation come for free
    /// because each chunk goes through `transcribeSingleFile`.
    private func transcribeChunked(uploadURL: URL, prompt: String?) async throws -> EngineResult {
        let chunks = try await chunker.split(uploadURL)
        defer {
            for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) }
        }

        // Nothing actually got split (short tail, or the splitter declined) — single-shot it.
        guard chunks.count > 1 else {
            let only = chunks.first?.url ?? uploadURL
            let duration = chunks.first?.durationSeconds ?? chunkingThresholdSeconds
            return try await transcribeSingleFile(uploadURL: only, prompt: prompt, expectedDurationSeconds: duration)
        }

        let results = try await transcribeChunksConcurrently(chunks, prompt: prompt)
        let merged = stitch(results)

        let networkRetryCount = results.reduce(0) { $0 + $1.networkRetryCount }
        let didReroll = results.contains { $0.didReroll }
        let rerollReason = results.compactMap { $0.rerollReason }.first
        let coveredAudioDuration = chunks.map { $0.endSeconds }.max()
        let mergedTrimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
        // Coverage is structurally complete (we transcribed every chunk), so confidence
        // hinges only on getting non-empty, non-looping text back.
        let highConfidence = !mergedTrimmed.isEmpty && !hasRepeatLoop(mergedTrimmed)

        os_log(.info, log: recordingLog, "engine: chunked %d pieces → %d chars, reroll=%{public}d, netRetries=%d",
               chunks.count, mergedTrimmed.count, didReroll, networkRetryCount)

        return EngineResult(
            rawTranscript: merged,
            coveredAudioDuration: coveredAudioDuration,
            isHighConfidence: highConfidence,
            networkRetryCount: networkRetryCount,
            didReroll: didReroll,
            rerollReason: didReroll ? (rerollReason ?? "chunk re-roll") : nil
        )
    }

    /// Run chunks through `transcribeSingleFile` with at most `maxConcurrentChunks` in
    /// flight, preserving original order in the returned array. A chunk that throws after
    /// its own retries aborts the whole split (caller falls back to single-shot).
    private func transcribeChunksConcurrently(_ chunks: [AudioChunk], prompt: String?) async throws -> [EngineResult] {
        var results = [EngineResult?](repeating: nil, count: chunks.count)

        try await withThrowingTaskGroup(of: (Int, EngineResult).self) { group in
            var nextIndex = 0
            let initialWave = min(maxConcurrentChunks, chunks.count)

            func addTask(_ index: Int) {
                let chunk = chunks[index]
                group.addTask {
                    let result = try await self.transcribeSingleFile(
                        uploadURL: chunk.url,
                        prompt: prompt,
                        expectedDurationSeconds: chunk.durationSeconds
                    )
                    return (index, result)
                }
            }

            for _ in 0..<initialWave {
                addTask(nextIndex)
                nextIndex += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if nextIndex < chunks.count {
                    addTask(nextIndex)
                    nextIndex += 1
                }
            }
        }

        return results.compactMap { $0 }
    }

    // MARK: - Stitching

    /// Concatenate chunk transcripts, removing the duplicated words created by the chunk
    /// overlap. Adjacent chunks are merged by finding the longest run of words shared
    /// between the tail of the accumulated text and the head of the next chunk.
    private func stitch(_ results: [EngineResult]) -> String {
        let pieces = results.map { $0.trimmedTranscript }.filter { !$0.isEmpty }
        guard let first = pieces.first else { return "" }
        return pieces.dropFirst().reduce(first) { mergeOverlapping($0, $1) }
    }

    /// Merge `b` onto `a`, dropping `b`'s leading words that repeat `a`'s trailing words.
    private func mergeOverlapping(_ a: String, _ b: String) -> String {
        let aWords = a.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let bWords = b.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !aWords.isEmpty, !bWords.isEmpty else {
            return aWords.isEmpty ? b : a
        }

        let maxOverlap = min(20, aWords.count, bWords.count)
        var overlap = 0
        // Prefer the longest match so a short coincidental repeat doesn't win over the
        // real overlap region.
        var k = maxOverlap
        while k >= 2 {
            let aTail = aWords.suffix(k).map(normalizedWord)
            let bHead = bWords.prefix(k).map(normalizedWord)
            if aTail == bHead {
                overlap = k
                break
            }
            k -= 1
        }

        let joinedTail = bWords.dropFirst(overlap)
        if joinedTail.isEmpty { return a }
        return (aWords + joinedTail).joined(separator: " ")
    }

    private func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
    }

    // MARK: - Request (with transient + empty re-tries)

    /// One transcription request, retried once on a transient network error. Returns the
    /// result plus how many network retries were spent (0 or 1).
    /// (Empty/weak-result re-rolls are owned solely by `transcribe` so they can't stack.)
    private func requestCountingNetworkRetries(
        _ uploadURL: URL,
        prompt: String?,
        temperature: Double = 0
    ) async throws -> (TranscriptionResult, Int) {
        do {
            return (try await service.transcribeDetailed(fileURL: uploadURL, prompt: prompt, temperature: temperature), 0)
        } catch let error where AppState.isTransientNetworkError(error) {
            os_log(.info, log: recordingLog, "engine: transient network error — retrying once: %{public}@", error.localizedDescription)
            return (try await service.transcribeDetailed(fileURL: uploadURL, prompt: prompt, temperature: temperature), 1)
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
