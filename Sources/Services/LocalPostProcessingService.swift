import Foundation
import MLXLLM
import MLXLMCommon
import os

final class LocalPostProcessingService: PostProcessingProvider {
    private let modelId: String
    private let postProcessingTimeoutSeconds: TimeInterval = 60

    private static func debugLog(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let path = "/tmp/wispah-llm-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    init(model: String) {
        self.modelId = model
    }

    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        smartFormatting: Bool,
        smartCorrections: Bool,
        developerMode: Bool,
        customPrompt: String
    ) async throws -> PostProcessingResult {
        let timeoutSeconds = postProcessingTimeoutSeconds
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            group.addTask { [self] in
                try await self.process(
                    transcript: transcript,
                    context: context,
                    customVocabulary: customVocabulary,
                    smartFormatting: smartFormatting,
                    smartCorrections: smartCorrections,
                    developerMode: developerMode,
                    customPrompt: customPrompt
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostProcessingError.requestTimedOut(timeoutSeconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw PostProcessingError.invalidResponse("No post-processing result")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func process(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        smartFormatting: Bool,
        smartCorrections: Bool,
        developerMode: Bool,
        customPrompt: String
    ) async throws -> PostProcessingResult {
        let appHint = PostProcessingService.appContextHints[context.bundleIdentifier ?? ""] ?? ""

        let built = PostProcessingPromptBuilder.build(
            transcript: transcript,
            contextSummary: context.contextSummary,
            model: modelId,
            customVocabulary: customVocabulary,
            smartFormatting: smartFormatting,
            smartCorrections: smartCorrections,
            developerMode: developerMode,
            customPrompt: customPrompt,
            appHint: appHint
        )

        let manager = await LocalModelManager.shared
        try await manager.loadLLMModel(modelId)

        guard let container = await manager.llmContainer else {
            throw PostProcessingError.invalidResponse("LLM model not available")
        }

        // For Qwen3: disable thinking mode to avoid endless <think> loops
        var userMessage = built.userMessage
        if modelId.lowercased().contains("qwen") {
            userMessage += "\n/no_think"
        }

        let input = try await container.prepare(
            input: .init(
                chat: [
                    .system(built.systemPrompt),
                    .user(userMessage)
                ]
            )
        )

        let maxTokens = max(256, min(1024, transcript.count * 2))
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.1
        )

        Self.debugLog("Generating: maxTokens=\(maxTokens), transcript=\(transcript.count) chars, model=\(modelId)")

        var generatedText = ""
        var shouldStop = false
        let stream = try await container.generate(input: input, parameters: parameters)
        for await generation in stream {
            if shouldStop { break }
            switch generation {
            case .chunk(let text):
                generatedText += text
                // Detect thinking spiral and bail early
                if generatedText.count > 2000,
                   generatedText.hasPrefix("<think>"),
                   !generatedText.contains("</think>") {
                    Self.debugLog("Thinking spiral at \(generatedText.count) chars, stopping")
                    shouldStop = true
                }
                if generatedText.count > 4096 {
                    shouldStop = true
                }
            default:
                break
            }
        }

        Self.debugLog("Raw output (\(generatedText.count) chars): \(String(generatedText.prefix(1000)))")

        await manager.resetIdleTimer()

        // Strip Qwen3 thinking tags if present
        var output = generatedText
        if let thinkEnd = output.range(of: "</think>") {
            output = String(output[thinkEnd.upperBound...])
        }

        let sanitized = PostProcessingPromptBuilder.sanitize(output.trimmingCharacters(in: .whitespacesAndNewlines))
        Self.debugLog("Cleaned output (\(sanitized.count) chars): \(String(sanitized.prefix(500)))")

        // If LLM returns empty (or EMPTY sentinel), fall back to raw transcript
        let finalTranscript = sanitized.isEmpty ? transcript : sanitized

        return PostProcessingResult(
            transcript: finalTranscript,
            prompt: built.displayPrompt
        )
    }
}
