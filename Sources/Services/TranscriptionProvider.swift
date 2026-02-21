import Foundation

protocol TranscriptionProvider {
    func transcribe(fileURL: URL, prompt: String?) async throws -> String
}
