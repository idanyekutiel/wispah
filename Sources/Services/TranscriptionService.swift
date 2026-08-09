import Foundation
import AVFoundation
import os

struct TranscriptionResult {
    let transcript: String
    let hadSuspiciousOutro: Bool
    let coveredAudioDuration: Double?
}

class TranscriptionService {
    private let apiKey: String
    private let baseURL: String
    private let transcriptionModel: String
    private let transcriptionLanguage: String?
    private let vocabularyKeywords: [String]
    private let minimumTimeoutSeconds: TimeInterval = 15
    private let maximumTimeoutSeconds: TimeInterval = 120

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        model: String = "whisper-large-v3",
        language: String? = nil,
        keywords: [String] = []
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transcriptionModel = model
        self.transcriptionLanguage = language
        self.vocabularyKeywords = keywords
    }

    /// Provider inferred from the base URL — drives provider-specific rate-limit pacing.
    var provider: APIProvider { APIProvider.from(baseURL: baseURL) }
    var model: String { transcriptionModel }

    /// Parse a 429 `Retry-After` header. Both providers send integer seconds; an HTTP-date
    /// form is tolerated as a fallback. Returns nil when absent or unparseable.
    static func parseRetryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = (response.value(forHTTPHeaderField: "Retry-After")
            ?? response.value(forHTTPHeaderField: "retry-after"))?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    /// Timeout budget is intentionally aggressive because these providers are expected
    /// to respond quickly; hung requests should fail fast instead of stalling the UX.
    private func timeoutForFile(_ fileURL: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            if durationSeconds.isFinite && durationSeconds > 0 {
                // Budget = floor + ~0.5s per second of audio. This comfortably covers
                // upload + (fast) provider processing for multi-minute recordings, so a
                // long take no longer trips the timeout and forces an unnecessary retry.
                let calculatedTimeout = minimumTimeoutSeconds + durationSeconds * 0.5
                return min(max(calculatedTimeout, minimumTimeoutSeconds), maximumTimeoutSeconds)
            }
        } catch {
            os_log(.error, "Failed to load audio duration for timeout calculation: %{public}@", error.localizedDescription)
        }
        return 15
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // Upload audio file, submit for transcription, poll until done, return text
    func transcribe(fileURL: URL, prompt: String? = nil, temperature: Double = 0) async throws -> String {
        try await transcribeDetailed(fileURL: fileURL, prompt: prompt, temperature: temperature).transcript
    }

    /// - Parameter temperature: legacy Whisper decoder temperature. The engine always
    ///   uses zero; `gpt-transcribe` omits this field entirely.
    func transcribeDetailed(fileURL: URL, prompt: String? = nil, temperature: Double = 0) async throws -> TranscriptionResult {
        let timeout = await timeoutForFile(fileURL)
        return try await withThrowingTaskGroup(of: TranscriptionResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw TranscriptionError.submissionFailed("Service deallocated")
                }
                return try await self.transcribeAudio(fileURL: fileURL, prompt: prompt, temperature: temperature, timeout: timeout)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TranscriptionError.transcriptionTimedOut(timeout)
            }

            guard let result = try await group.next() else {
                throw TranscriptionError.submissionFailed("No transcription result")
            }
            group.cancelAll()
            return result
        }
    }

    // Send audio file for transcription and return text
    private func transcribeAudio(fileURL: URL, prompt: String? = nil, temperature: Double = 0, timeout: TimeInterval) async throws -> TranscriptionResult {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = UUID().uuidString
        let contentType = "multipart/form-data; boundary=\(boundary)"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let body = makeMultipartBody(
            audioData: audioData,
            fileName: fileURL.lastPathComponent,
            model: transcriptionModel,
            boundary: boundary,
            language: transcriptionLanguage,
            prompt: prompt,
            temperature: temperature
        )
        request.httpBody = body

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            let truncatedBody = String(responseBody.prefix(500))
            let statusCode = httpResponse.statusCode
            switch statusCode {
            case 401, 403:
                throw TranscriptionError.submissionFailed("Invalid or expired API key")
            case 429:
                // Both Groq and OpenAI return a `Retry-After` header (seconds) on 429.
                // Surfacing it lets the engine wait exactly as long as the server asks
                // before retrying the chunk, instead of guessing or giving up.
                throw TranscriptionError.rateLimited(Self.parseRetryAfterSeconds(from: httpResponse))
            case 408:
                throw TranscriptionError.serverUnavailable(statusCode, Self.parseRetryAfterSeconds(from: httpResponse))
            case 500...:
                throw TranscriptionError.serverUnavailable(statusCode, Self.parseRetryAfterSeconds(from: httpResponse))
            default:
                throw TranscriptionError.submissionFailed("Unexpected error (HTTP \(statusCode)): \(truncatedBody)")
            }
        }

        return try parseTranscript(from: data)
    }

    private func makeMultipartBody(audioData: Data, fileName: String, model: String, boundary: String, language: String? = nil, prompt: String? = nil, temperature: Double = 0) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        // GPT transcription models return the compact JSON contract. Whisper's
        // verbose response is still useful for segment coverage/no-speech metadata.
        let usesGPTTranscribeContract = model == "gpt-transcribe"
        let responseFormat = model.contains("transcribe") ? "json" : "verbose_json"
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("\(responseFormat)\r\n")

        // `gpt-transcribe` does not use Whisper's decoder-temperature contract.
        // Omitting it also prevents the old high-temperature retry behavior from
        // leaking into the new model path.
        if !usesGPTTranscribeContract {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n")
            append("\(temperature)\r\n")
        }

        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            let fieldName = usesGPTTranscribeContract ? "languages[]" : "language"
            append("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n")
            append("\(language)\r\n")
        }

        if usesGPTTranscribeContract {
            for keyword in sanitizedKeywords(vocabularyKeywords) {
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"keywords[]\"\r\n\r\n")
                append("\(keyword)\r\n")
            }
        } else if let prompt, !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(prompt)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(audioContentType(for: fileName))\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return body
    }

    /// GPT Transcribe rejects the entire request when a keyword contains XML brackets
    /// or a line break. Drop only invalid entries; never let one dictionary typo take
    /// transcription offline.
    private func sanitizedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !value.contains("<"),
                  !value.contains(">"),
                  !value.contains("\r"),
                  !value.contains("\n"),
                  seen.insert(value.lowercased()).inserted else {
                return nil
            }
            return value
        }
    }

    private func audioContentType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        }
        if fileName.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if fileName.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        }
        return "audio/mp4"
    }

    private func parseTranscript(from data: Data) throws -> TranscriptionResult {
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = json["text"] as? String ?? ""
            var coveredAudioDuration: Double?

            // verbose_json returns segments with no_speech_prob — filter hallucinations
            // Client-side speech detection already filters truly silent recordings,
            // so this is a last-resort check with a high threshold (0.95)
            if let segments = json["segments"] as? [[String: Any]], !segments.isEmpty {
                coveredAudioDuration = segments
                    .compactMap { $0["end"] as? Double }
                    .max()

                let noSpeechProbabilities = segments.compactMap { $0["no_speech_prob"] as? Double }
                if !noSpeechProbabilities.isEmpty {
                    let avgNoSpeech = noSpeechProbabilities.reduce(0, +) / Double(noSpeechProbabilities.count)
                    os_log(.info, "Whisper segments=%d, avg no_speech_prob=%.3f", segments.count, avgNoSpeech)
                    if avgNoSpeech > 0.95 {
                        os_log(.info, "Very high no_speech_prob (%.3f) — treating as empty transcript", avgNoSpeech)
                        return TranscriptionResult(transcript: "", hadSuspiciousOutro: false, coveredAudioDuration: coveredAudioDuration)
                    }
                }
            }

            // Always return within the JSON block — don't fall through to plain text,
            // which would return the raw JSON string as the transcript
            return sanitizeTranscript(text, coveredAudioDuration: coveredAudioDuration)
        }

        // Non-JSON fallback (plain text response)
        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.pollFailed("Invalid response")
        }

        return sanitizeTranscript(text)
    }

    private func sanitizeTranscript(_ transcript: String, coveredAudioDuration: Double? = nil) -> TranscriptionResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TranscriptionResult(transcript: "", hadSuspiciousOutro: false, coveredAudioDuration: coveredAudioDuration)
        }

        if isKnownHallucinatedOutro(trimmed) {
            os_log(.info, "Dropping known transcription hallucination: %{public}@", trimmed)
            return TranscriptionResult(transcript: "", hadSuspiciousOutro: true, coveredAudioDuration: coveredAudioDuration)
        }

        var strippedTranscript = trimmed
        var removedOutro = false
        // Remove every repeated suffix, not only the final copy. Whisper sometimes emits
        // "Thank you for watching" two or more times; a one-pass sanitizer accidentally
        // accepted the earlier copies as real speech.
        while let stripped = strippingKnownHallucinatedOutroSuffix(from: strippedTranscript) {
            strippedTranscript = stripped
            removedOutro = true
            if strippedTranscript.isEmpty { break }
        }
        if removedOutro {
            if isKnownHallucinatedOutro(strippedTranscript) {
                strippedTranscript = ""
            }
            os_log(.info, "Removed known hallucinated transcript suffix(es)")
            return TranscriptionResult(transcript: strippedTranscript, hadSuspiciousOutro: true, coveredAudioDuration: coveredAudioDuration)
        }

        return TranscriptionResult(transcript: trimmed, hadSuspiciousOutro: false, coveredAudioDuration: coveredAudioDuration)
    }

    private func isKnownHallucinatedOutro(_ transcript: String) -> Bool {
        let normalized = normalizeHallucinationCandidate(transcript)
        if suspiciousHallucinationPhrases.contains(normalized) {
            return true
        }

        // Caption artifacts are often emitted more than once without punctuation,
        // e.g. "Subtitles by ... community Subtitles by ... community". Recognize a
        // transcript made entirely from any sequence of known hallucination phrases.
        var remainder = normalized
        var matchedPhrase = false
        let separators = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        while !remainder.isEmpty {
            guard let phrase = suffixHallucinationPhrases.first(where: { candidate in
                guard remainder.hasPrefix(candidate) else { return false }
                guard remainder.count > candidate.count else { return true }
                let boundary = remainder.index(remainder.startIndex, offsetBy: candidate.count)
                let next = remainder[boundary]
                return !next.isLetter && !next.isNumber
            }) else {
                return false
            }
            remainder = String(remainder.dropFirst(phrase.count))
                .trimmingCharacters(in: separators)
            matchedPhrase = true
        }
        return matchedPhrase
    }

    private func strippingKnownHallucinatedOutroSuffix(from transcript: String) -> String? {
        let coreEnd = trimmedHallucinationBoundary(in: transcript)
        let coreTranscript = transcript[..<coreEnd]
        let lowercased = coreTranscript.lowercased()

        for phrase in suffixHallucinationPhrases {
            guard lowercased.hasSuffix(phrase) else { continue }

            let suffixStart = coreTranscript.index(coreTranscript.endIndex, offsetBy: -phrase.count)
            let prefix = coreTranscript[..<suffixStart]
            guard shouldRemoveHallucinatedSuffix(in: prefix, phrase: phrase) else { continue }

            return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func trimmedHallucinationBoundary(in transcript: String) -> String.Index {
        var end = transcript.endIndex

        while end > transcript.startIndex {
            let previous = transcript.index(before: end)
            let character = transcript[previous]
            if character.isWhitespace || ".!?,;:)]}\"'".contains(character) {
                end = previous
                continue
            }
            break
        }

        return end
    }

    private func shouldRemoveHallucinatedSuffix(in prefix: Substring, phrase: String) -> Bool {
        guard !prefix.isEmpty else { return false }

        // Allows repeated boilerplate with no punctuation between copies. The final
        // remaining copy is removed by `isKnownHallucinatedOutro` after this loop.
        if isKnownHallucinatedOutro(String(prefix)) {
            return true
        }

        var sawLineBreak = false
        var lastSignificantCharacter: Character?

        for character in prefix.reversed() {
            if character == "\n" || character == "\r" {
                sawLineBreak = true
                break
            }
            if character.isWhitespace {
                continue
            }
            lastSignificantCharacter = character
            break
        }

        if sawLineBreak {
            return true
        }

        guard let lastSignificantCharacter else {
            return false
        }

        if shortHallucinationSuffixPhrases.contains(phrase) {
            let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPrefix.count >= 24 else { return false }
            // Short sign-offs ("thanks") are often legitimate, so only strip them after a
            // hard sentence boundary — never a comma ("…I appreciate it, thanks").
            return ".!?:;)]}\"'".contains(lastSignificantCharacter)
        }

        // Longer outro phrases ("thank you for watching") are essentially never real
        // speech, so also strip them when Whisper ran the outro into the sentence with a
        // comma ("…some others that I said I have questions, Thank you for watching!").
        return ".!?,:;)]}\"'".contains(lastSignificantCharacter)
    }

    private let suspiciousHallucinationPhrases: Set<String> = [
        "thanks",
        "thank you",
        "thanks for watching",
        "thank you for watching",
        "subtitles by amara.org community",
        "subtitles by the amara.org community",
    ]

    private let suffixHallucinationPhrases: [String] = [
        "subtitles by the amara.org community",
        "subtitles by amara.org community",
        "thank you for watching",
        "thanks for watching",
        "thank you",
        "thanks",
    ]

    private let shortHallucinationSuffixPhrases: Set<String> = [
        "thank you",
        "thanks",
    ]

    private func normalizeHallucinationCandidate(_ transcript: String) -> String {
        transcript
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }
}

enum TranscriptionError: LocalizedError {
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case rateLimited(TimeInterval?)
    case serverUnavailable(Int, TimeInterval?)
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .rateLimited: return "Rate limit exceeded. Please wait and try again."
        case .serverUnavailable(let statusCode, _): return "Transcription service unavailable (HTTP \(statusCode)). Please try again."
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        }
    }

    var isTimeout: Bool {
        if case .transcriptionTimedOut = self { return true }
        return false
    }

    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    var isServerUnavailable: Bool {
        if case .serverUnavailable = self { return true }
        return false
    }

    /// Server-requested wait (seconds) for a 429, if one was provided.
    var retryAfterSeconds: TimeInterval? {
        if case .rateLimited(let seconds) = self { return seconds }
        if case .serverUnavailable(_, let seconds) = self { return seconds }
        return nil
    }
}
