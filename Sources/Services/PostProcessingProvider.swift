import Foundation

protocol PostProcessingProvider {
    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        smartFormatting: Bool,
        smartCorrections: Bool,
        developerMode: Bool,
        customPrompt: String
    ) async throws -> PostProcessingResult
}
