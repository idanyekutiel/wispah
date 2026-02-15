import Foundation

class TranscriptionService {
    private let apiKey: String
    private let baseURL = "https://api.assemblyai.com/v2"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // Validate API key by hitting a lightweight endpoint
    static func validateAPIKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
        request.setValue(trimmed, forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    // Upload audio file, submit for transcription, poll until done, return text
    func transcribe(fileURL: URL) async throws -> String {
        let uploadURL = try await uploadAudio(fileURL: fileURL)
        let transcriptID = try await submitTranscription(audioURL: uploadURL)
        let text = try await pollForResult(transcriptID: transcriptID)
        return text
    }

    // Step 1: Upload audio file
    private func uploadAudio(fileURL: URL) async throws -> String {
        let url = URL(string: "\(baseURL)/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let (data, response) = try await URLSession.shared.upload(for: request, from: audioData)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.uploadFailed("Status \(statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadURL = json["upload_url"] as? String else {
            throw TranscriptionError.uploadFailed("Invalid response")
        }

        return uploadURL
    }

    // Step 2: Submit transcription request
    private func submitTranscription(audioURL: String) async throws -> String {
        let url = URL(string: "\(baseURL)/transcript")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "audio_url": audioURL,
            "speech_models": ["universal-3-pro"],
            "punctuate": true,
            "format_text": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.submissionFailed("Status \(statusCode): \(responseBody)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcriptID = json["id"] as? String else {
            throw TranscriptionError.submissionFailed("Invalid response")
        }

        return transcriptID
    }

    // Step 3: Poll for completion
    private func pollForResult(transcriptID: String) async throws -> String {
        let url = URL(string: "\(baseURL)/transcript/\(transcriptID)")!

        while true {
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "Authorization")

            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                throw TranscriptionError.pollFailed("Invalid response")
            }

            switch status {
            case "completed":
                guard let text = json["text"] as? String else {
                    throw TranscriptionError.pollFailed("No text in response")
                }
                return text

            case "error":
                let error = json["error"] as? String ?? "Unknown error"
                throw TranscriptionError.transcriptionFailed(error)

            case "queued", "processing":
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            default:
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

enum TranscriptionError: LocalizedError {
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        }
    }
}
