import Foundation
import WhisperKit
import os

final class LocalTranscriptionService: TranscriptionProvider {
    private let model: String
    private let language: String?

    init(model: String, language: String? = nil) {
        self.model = model
        self.language = language
    }

    func transcribe(fileURL: URL, prompt: String?) async throws -> String {
        let manager = await LocalModelManager.shared
        try await manager.loadWhisperModel(model)

        guard let pipeline = await manager.whisperPipeline else {
            throw TranscriptionError.transcriptionFailed("Whisper pipeline not available")
        }

        var options = DecodingOptions(
            verbose: false,
            temperature: 0,
            usePrefillPrompt: prompt != nil,
            usePrefillCache: prompt != nil
        )

        if let language, !language.isEmpty {
            options.language = language
        }

        if let prompt, !prompt.isEmpty {
            options.promptTokens = pipeline.tokenizer?.encode(text: "<|startofprev|>\(prompt)").filter { $0 < 51865 }
        }

        Self.debugLog("Transcribing: \(fileURL.lastPathComponent), model=\(model), language=\(language ?? "auto")")

        let results = try await pipeline.transcribe(audioPath: fileURL.path, decodeOptions: options)

        Self.debugLog("WhisperKit returned \(results.count) segments")
        for (i, r) in results.enumerated() {
            Self.debugLog("  Segment \(i): '\(r.text)' [\(r.segments.count) sub-segments]")
        }

        let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        Self.debugLog("Final transcript (\(text.count) chars): \(text)")

        await manager.resetIdleTimer()
        return text
    }

    private static func debugLog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [Whisper] \(message)\n"
        let path = "/tmp/wispah-llm-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }
}
