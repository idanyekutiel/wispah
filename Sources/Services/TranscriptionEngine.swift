import Foundation
import os.log

/// Progress signals emitted by the engine while a transcription is in flight, so the UI
/// can surface retries and independent recovery instead of an opaque spinner.
/// Delivered from arbitrary task contexts — handlers must hop to the main actor.
enum TranscriptionProgress: Sendable {
    /// A transient network failure is being retried.
    case retryingNetwork
    /// A chunk hit a 429 and is waiting to retry. `attempt` is 1-based.
    case rateLimited(attempt: Int, maxAttempts: Int)
    /// A weak first result is being checked by an independent provider/model.
    case recovering(reason: String)
}

/// Outcome of a single engine transcription attempt.
struct EngineResult {
    let rawTranscript: String
    let coveredAudioDuration: Double?
    /// True when the result passed validation (non-empty, not a known hallucination,
    /// no obvious repeat-loop, and — for long audio — adequate coverage).
    let isHighConfidence: Bool
    /// How many times a request was retried due to a transient network error.
    let networkRetryCount: Int
    /// Whether an independent provider/model checked a weak first result.
    let didRecoveryAttempt: Bool
    /// Why recovery was attempted (e.g. "empty result", "repeat loop") — nil if none.
    let recoveryReason: String?

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
/// Responsibilities: send one deterministic request, validate the result, and ask an
/// independent provider/model to recover a suspicious/empty/incomplete result when one
/// is configured. Repeating the same weak audio at a higher temperature is deliberately
/// avoided because it trades a recognizable hallucination for a less predictable one.
///
/// Audio preprocessing and saved-file bookkeeping stay in the orchestration layer
/// (they are deterministic and shared by both callers, so they don't affect path
/// parity); the engine receives an upload-ready file.
final class TranscriptionEngine {
    private let service: TranscriptionService
    private let recoveryService: TranscriptionService?
    private let chunker: AudioChunker
    /// Optional progress sink. Called from concurrent task contexts, so it's `@Sendable`
    /// and implementations must marshal to the main actor before touching UI.
    private let onProgress: (@Sendable (TranscriptionProgress) -> Void)?

    /// Long-audio coverage below this fraction of the expected speech duration is
    /// treated as incomplete and worth an independent recovery check. Kept conservative
    /// (0.6) so normal
    /// leading/trailing silence doesn't masquerade as a truncated transcript.
    private let minimumCoverageFraction = 0.6
    /// Recordings at or above this length are eligible for the coverage check.
    private let longRecordingThresholdSeconds: Double = 30
    /// Bounded transient retry budget. Three total attempts handles brief provider/network
    /// faults without turning a held hotkey into an unbounded wait. A full request timeout
    /// gets only one retry because three consecutive timeout windows feel hung and rarely
    /// recover before a later manual retry would.
    private let maxTransientRetries = 2

    /// Recordings longer than this are split into overlapping chunks transcribed
    /// independently and stitched back together (see `transcribeChunked`). Below it, the
    /// single-shot path is faster and carries no stitching risk, so it's left untouched.
    private let chunkingThresholdSeconds: Double = 90
    /// Provider-specific concurrency / throttle / retry budget for the chunked path.
    private let rateLimitPolicy: ChunkRateLimitPolicy

    init(
        service: TranscriptionService,
        recoveryService: TranscriptionService? = nil,
        chunker: AudioChunker = AudioChunker(),
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) {
        self.service = service
        self.recoveryService = recoveryService
        self.chunker = chunker
        self.onProgress = onProgress
        self.rateLimitPolicy = service.provider.chunkRateLimitPolicy
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
            } catch let error as TranscriptionError where error.isRateLimited {
                // Resending the whole file as one request would hit the same limit (and on
                // OpenAI can exceed the 25-min/request cap), so surface the rate limit
                // instead of pretending a single-shot retry will help.
                os_log(.error, log: recordingLog, "engine: chunked transcription rate-limited — not falling back to single-shot")
                throw error
            } catch {
                os_log(.error, log: recordingLog, "engine: chunked transcription failed (%{public}@) — falling back to single-shot", error.localizedDescription)
            }
        }
        return try await transcribeSingleFile(uploadURL: uploadURL, prompt: prompt, expectedDurationSeconds: expectedDurationSeconds)
    }

    /// Transcribe one upload-ready file and independently verify only weak results.
    private func transcribeSingleFile(
        uploadURL: URL,
        prompt: String?,
        expectedDurationSeconds: Double,
        rateLimitRetryIsManagedExternally: Bool = false
    ) async throws -> EngineResult {
        var (result, networkRetryCount) = try await requestCountingNetworkRetries(
            using: service,
            uploadURL,
            prompt: prompt,
            retryRateLimits: !rateLimitRetryIsManagedExternally
        )

        var didRecoveryAttempt = false
        let recoveryReason = recoveryReason(result, expected: expectedDurationSeconds)
        if let recoveryReason, let recoveryService {
            didRecoveryAttempt = true
            onProgress?(.recovering(reason: recoveryReason))
            os_log(
                .info,
                log: recordingLog,
                "engine: %{public}@ — checking with independent %{public}@/%{public}@",
                recoveryReason,
                recoveryService.provider.displayName,
                recoveryService.model
            )
            do {
                let (recovery, recoveryNetworkRetries) = try await requestCountingNetworkRetries(
                    using: recoveryService,
                    uploadURL,
                    prompt: prompt,
                    retryRateLimits: !rateLimitRetryIsManagedExternally
                )
                networkRetryCount += recoveryNetworkRetries
                result = preferBetter(result, recovery, expected: expectedDurationSeconds)
            } catch {
                if Task.isCancelled || AppState.isCancellation(error) { throw error }
                os_log(
                    .error,
                    log: recordingLog,
                    "engine: independent recovery failed; preserving first result: %{public}@",
                    error.localizedDescription
                )
            }
        } else if let recoveryReason {
            os_log(
                .info,
                log: recordingLog,
                "engine: %{public}@ — no independent recovery provider configured",
                recoveryReason
            )
            // A stripped outro may leave a useful, grounded prefix. Empty, looping, or
            // incomplete text is unsafe to paste as best-effort when nobody independently
            // confirmed it.
            if recoveryReason != "suspicious outro" {
                result = TranscriptionResult(
                    transcript: "",
                    hadSuspiciousOutro: result.hadSuspiciousOutro,
                    coveredAudioDuration: result.coveredAudioDuration
                )
            }
        }

        return EngineResult(
            rawTranscript: result.transcript,
            coveredAudioDuration: result.coveredAudioDuration,
            isHighConfidence: isHighConfidence(result, expected: expectedDurationSeconds),
            networkRetryCount: networkRetryCount,
            didRecoveryAttempt: didRecoveryAttempt,
            recoveryReason: recoveryReason
        )
    }

    // MARK: - Chunked transcription (long audio)

    /// Split a long recording at silence into overlapping chunks, transcribe them
    /// concurrently (each conditioned only on the vocabulary prompt — never on a sibling
    /// chunk's text, which is what stops Whisper's hallucinations from propagating), then
    /// stitch the de-overlapped transcripts. Per-chunk recovery and validation come for free
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
        let didRecoveryAttempt = results.contains { $0.didRecoveryAttempt }
        let recoveryReason = results.compactMap { $0.recoveryReason }.first
        let coveredAudioDuration = chunks.map { $0.endSeconds }.max()
        let mergedTrimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
        // Coverage is structurally complete (we transcribed every chunk), so confidence
        // hinges only on getting non-empty, non-looping text back.
        let highConfidence = !mergedTrimmed.isEmpty
            && !hasRepeatLoop(mergedTrimmed)
            && results.allSatisfy(\.isHighConfidence)

        os_log(.info, log: recordingLog, "engine: chunked %d pieces → %d chars, recovery=%{public}d, netRetries=%d",
               chunks.count, mergedTrimmed.count, didRecoveryAttempt, networkRetryCount)

        return EngineResult(
            rawTranscript: merged,
            coveredAudioDuration: coveredAudioDuration,
            isHighConfidence: highConfidence,
            networkRetryCount: networkRetryCount,
            didRecoveryAttempt: didRecoveryAttempt,
            recoveryReason: didRecoveryAttempt ? (recoveryReason ?? "chunk recovery") : nil
        )
    }

    /// Run chunks through `transcribeSingleFile` with at most `maxConcurrentChunks` in
    /// flight, preserving original order in the returned array. A shared throttle paces
    /// requests once the provider starts returning 429s. A chunk that exhausts its 429
    /// retry budget aborts the whole split.
    private func transcribeChunksConcurrently(_ chunks: [AudioChunk], prompt: String?) async throws -> [EngineResult] {
        var results = [EngineResult?](repeating: nil, count: chunks.count)
        let throttle = ChunkThrottle(policy: rateLimitPolicy)

        try await withThrowingTaskGroup(of: (Int, EngineResult).self) { group in
            var nextIndex = 0
            let initialWave = min(rateLimitPolicy.maxConcurrentChunks, chunks.count)

            func addTask(_ index: Int) {
                let chunk = chunks[index]
                group.addTask {
                    let result = try await self.transcribeChunkWithRateLimitRetry(chunk, prompt: prompt, throttle: throttle)
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

    /// Transcribe one chunk, retrying on 429 up to the provider's budget. Each attempt
    /// waits its turn at the shared throttle (a no-op until the first 429, then serial-
    /// with-gaps), and a 429 is reported so the server's `Retry-After` paces all chunks.
    private func transcribeChunkWithRateLimitRetry(_ chunk: AudioChunk, prompt: String?, throttle: ChunkThrottle) async throws -> EngineResult {
        var attempt = 0
        while true {
            await throttle.awaitTurn()
            do {
                return try await transcribeSingleFile(
                    uploadURL: chunk.url,
                    prompt: prompt,
                    expectedDurationSeconds: chunk.durationSeconds,
                    rateLimitRetryIsManagedExternally: true
                )
            } catch let error as TranscriptionError where error.isRateLimited && attempt < rateLimitPolicy.maxRateLimitRetries {
                attempt += 1
                onProgress?(.rateLimited(attempt: attempt, maxAttempts: rateLimitPolicy.maxRateLimitRetries))
                let waited = await throttle.note429(retryAfter: error.retryAfterSeconds)
                os_log(.info, log: recordingLog, "engine: chunk rate-limited (attempt %d/%d) — waiting ~%.1fs", attempt, rateLimitPolicy.maxRateLimitRetries, waited)
            }
        }
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

    // MARK: - Request (bounded transient retries)

    /// Retry timeouts, connection failures, HTTP 408, and HTTP 5xx with exponential
    /// backoff + jitter. Weak text never enters this loop; semantic recovery uses the
    /// independent service above.
    private func requestCountingNetworkRetries(
        using requestService: TranscriptionService,
        _ uploadURL: URL,
        prompt: String?,
        retryRateLimits: Bool = true
    ) async throws -> (TranscriptionResult, Int) {
        var retryCount = 0
        while true {
            do {
                return (
                    try await requestService.transcribeDetailed(
                        fileURL: uploadURL,
                        prompt: prompt,
                        temperature: 0
                    ),
                    retryCount
                )
            } catch {
                let transient = AppState.isTransientNetworkError(error)
                    || (error as? TranscriptionError)?.isTimeout == true
                    || (error as? TranscriptionError)?.isServerUnavailable == true
                let rateLimited = retryRateLimits
                    && (error as? TranscriptionError)?.isRateLimited == true
                let retryLimit = (error as? TranscriptionError)?.isTimeout == true
                    ? 1
                    : maxTransientRetries
                guard (transient || rateLimited), retryCount < retryLimit else { throw error }

                retryCount += 1
                if rateLimited {
                    onProgress?(.rateLimited(attempt: retryCount, maxAttempts: retryLimit))
                } else {
                    onProgress?(.retryingNetwork)
                }
                let serverDelay = (error as? TranscriptionError)?.retryAfterSeconds
                // Groq recommends exponential backoff starting around one second.
                // The previous 350/700ms retries landed inside the same provider outage
                // or connection failure window, while a manual retry seconds later worked.
                let exponential = (rateLimited ? 2.0 : 1.0) * pow(2.0, Double(retryCount - 1))
                let jitter = Double.random(in: 0...0.20)
                let delay = serverDelay.map { min(max(0, $0), 30) }
                    ?? min(exponential + jitter, 5)
                os_log(
                    .info,
                    log: recordingLog,
                    "engine: transient failure — retry %d/%d in %.2fs: %{public}@",
                    retryCount,
                    retryLimit,
                    delay,
                    error.localizedDescription
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
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

    /// The reason this result needs an independent recovery check, or nil if it's fine.
    private func recoveryReason(_ result: TranscriptionResult, expected: Double) -> String? {
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
    /// very low unique-word ratio over a long transcript) so good audio is never retried.
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

/// Shared pacing for one chunked transcription. Free-running (a no-op) until the first
/// 429; after that, requests are released one at a time, spaced by the provider's
/// `spacingAfterThrottleSeconds`, and each 429's `Retry-After` pushes the next slot out.
/// This is the "back off, then send the chunks serially" behavior — applied only when the
/// provider actually signals overload, so unthrottled runs keep full concurrency.
actor ChunkThrottle {
    private let policy: ChunkRateLimitPolicy
    private var throttled = false
    private var nextSlot: Date = .distantPast

    init(policy: ChunkRateLimitPolicy) {
        self.policy = policy
    }

    /// Record a 429 and extend the next-slot time by the server's `Retry-After` (or the
    /// provider fallback). Returns the resulting delay from now, for logging.
    @discardableResult
    func note429(retryAfter: TimeInterval?) -> TimeInterval {
        throttled = true
        let wait = retryAfter ?? policy.fallbackRetryAfterSeconds
        let candidate = Date().addingTimeInterval(wait)
        if candidate > nextSlot { nextSlot = candidate }
        return max(0, nextSlot.timeIntervalSinceNow)
    }

    /// Block until this request's turn. Returns immediately while unthrottled; once
    /// throttled, reserves the next serial slot and sleeps until it. Reserving before the
    /// `await` (then suspending) is what serializes concurrent callers into spaced slots.
    func awaitTurn() async {
        guard throttled else { return }
        let now = Date()
        let start = max(now, nextSlot)
        nextSlot = start.addingTimeInterval(policy.spacingAfterThrottleSeconds)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
