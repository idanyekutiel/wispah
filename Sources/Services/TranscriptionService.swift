import Foundation
import AVFoundation
import os

class TranscriptionService {
    private let apiKey: String
    private let baseURL = "https://api.groq.com/openai/v1"
    private let transcriptionModel: String
    private let transcriptionLanguage: String?
    private let minimumTimeoutSeconds: TimeInterval = 30

    init(apiKey: String, model: String = "whisper-large-v3", language: String? = nil) {
        self.apiKey = apiKey
        self.transcriptionModel = model
        self.transcriptionLanguage = language
    }

    /// Timeout: 30s base, plus 2s per second of audio beyond 10s
    private func timeoutForFile(_ fileURL: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        do {
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            if durationSeconds.isFinite && durationSeconds > 0 {
                let extraSeconds = max(0, durationSeconds - 10)
                let calculatedTimeout = max(minimumTimeoutSeconds, 30 + extraSeconds * 2)
                return min(calculatedTimeout, 600)
            }
        } catch {
            os_log(.error, "Failed to load audio duration for timeout calculation: %{public}@", error.localizedDescription)
        }
        return 120
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
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
    func transcribe(fileURL: URL, prompt: String? = nil) async throws -> String {
        let timeout = await timeoutForFile(fileURL)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw TranscriptionError.submissionFailed("Service deallocated")
                }
                return try await self.transcribeAudio(fileURL: fileURL, prompt: prompt)
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
    private func transcribeAudio(fileURL: URL, prompt: String? = nil) async throws -> String {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
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
            prompt: prompt
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
                throw TranscriptionError.submissionFailed("Rate limit exceeded. Please wait and try again.")
            case 500...:
                throw TranscriptionError.submissionFailed("Groq server error. Please try again later.")
            default:
                throw TranscriptionError.submissionFailed("Unexpected error (HTTP \(statusCode)): \(truncatedBody)")
            }
        }

        return try parseTranscript(from: data)
    }

    private func makeMultipartBody(audioData: Data, fileName: String, model: String, boundary: String, language: String? = nil, prompt: String? = nil) -> Data {
        var body = Data()

        func append(_ value: String) {
            body.append(Data(value.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("verbose_json\r\n")

        if let language, !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        if let prompt, !prompt.isEmpty {
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

    private func parseTranscript(from data: Data) throws -> String {
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = json["text"] as? String ?? ""

            // verbose_json returns segments with no_speech_prob — filter hallucinations
            // Client-side speech detection already filters truly silent recordings,
            // so this is a last-resort check with a high threshold (0.95)
            if let segments = json["segments"] as? [[String: Any]], !segments.isEmpty {
                let avgNoSpeech = segments
                    .compactMap { $0["no_speech_prob"] as? Double }
                    .reduce(0, +) / Double(segments.count)
                os_log(.info, "Whisper segments=%d, avg no_speech_prob=%.3f", segments.count, avgNoSpeech)
                if avgNoSpeech > 0.95 {
                    os_log(.info, "Very high no_speech_prob (%.3f) — treating as empty transcript", avgNoSpeech)
                    return ""
                }
            }

            if !text.isEmpty { return text }
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.pollFailed("Invalid response")
        }

        return text
    }
}

enum TranscriptionError: LocalizedError {
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        }
    }
}
