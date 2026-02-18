import Foundation

enum WhisperModel: String, CaseIterable, Identifiable {
    case largeV3 = "whisper-large-v3"
    case largeV3Turbo = "whisper-large-v3-turbo"
    case distilWhisper = "distil-whisper-large-v3-en"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .largeV3: return "Large V3 (Most Accurate)"
        case .largeV3Turbo: return "Large V3 Turbo (Fast)"
        case .distilWhisper: return "Distil-Whisper (Fastest, English Only)"
        }
    }
    var description: String {
        switch self {
        case .largeV3: return "Best accuracy across all languages."
        case .largeV3Turbo: return "Slightly faster with ~1% lower accuracy. Multilingual."
        case .distilWhisper: return "Fastest option. English only."
        }
    }
}
