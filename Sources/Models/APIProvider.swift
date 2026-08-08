import Foundation

/// How the chunked-transcription engine paces and retries requests for a provider.
/// Groq's free tier is request-per-minute constrained (so we stay gentle and lean on
/// `Retry-After`); OpenAI tolerates more concurrency but caps single requests at 25
/// minutes — a limit chunking already keeps us under.
struct ChunkRateLimitPolicy {
    /// How many chunk uploads run at once before any throttling kicks in.
    let maxConcurrentChunks: Int
    /// Minimum spacing between request starts after a 429 has been seen (requests go
    /// serial-with-gaps so we settle just under the provider's per-minute ceiling).
    let spacingAfterThrottleSeconds: Double
    /// Per-chunk retry budget for 429s before the chunk gives up.
    let maxRateLimitRetries: Int
    /// Wait used when a 429 arrives without a usable `Retry-After` header.
    let fallbackRetryAfterSeconds: Double
}

enum APIProvider: String, CaseIterable, Identifiable {
    case groq
    case openai

    var id: String { rawValue }

    /// Provider-specific pacing for chunked long-audio transcription.
    var chunkRateLimitPolicy: ChunkRateLimitPolicy {
        switch self {
        case .groq:
            // Free tier ~30 requests/min. Keep concurrency low and, once throttled,
            // space requests ~2.1s apart (~28/min) so we hug the limit without tripping it.
            return ChunkRateLimitPolicy(
                maxConcurrentChunks: 3,
                spacingAfterThrottleSeconds: 2.1,
                maxRateLimitRetries: 6,
                fallbackRetryAfterSeconds: 5
            )
        case .openai:
            // Higher request ceilings; the real constraint (25-min/request) is handled by
            // chunk sizing, so we can fan out wider and recover from the rare 429 quickly.
            return ChunkRateLimitPolicy(
                maxConcurrentChunks: 6,
                spacingAfterThrottleSeconds: 1.0,
                maxRateLimitRetries: 4,
                fallbackRetryAfterSeconds: 3
            )
        }
    }

    /// Resolve a provider from a base URL (the engine only carries the URL).
    static func from(baseURL: String) -> APIProvider {
        APIProvider.allCases.first { baseURL.hasPrefix($0.baseURL) } ?? .groq
    }

    var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    var baseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .openai: return "https://api.openai.com/v1"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .groq: return "Paste your Groq API key"
        case .openai: return "Paste your OpenAI API key"
        }
    }

    var keyHelpURL: String {
        switch self {
        case .groq: return "https://console.groq.com/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        }
    }

    var keyHelpLabel: String {
        switch self {
        case .groq: return "console.groq.com/keys"
        case .openai: return "platform.openai.com/api-keys"
        }
    }

    var defaultWhisperModel: String {
        switch self {
        case .groq: return "whisper-large-v3"
        case .openai: return "gpt-transcribe"
        }
    }

    var defaultLLMModel: String {
        switch self {
        case .groq: return "openai/gpt-oss-120b"
        case .openai: return "gpt-5.6-luna"
        }
    }

    var defaultVisionModel: String {
        switch self {
        // GPT-OSS is text-only. Use Groq's current multimodal model solely for the
        // optional screenshot summary, with the production GPT-OSS model as the
        // text fallback. Keeping this separate prevents a preview vision model from
        // becoming the reliability-critical post-processing default.
        case .groq: return "qwen/qwen3.6-27b"
        case .openai: return "gpt-5.6-luna"
        }
    }

    var whisperModels: [(id: String, name: String, description: String)] {
        switch self {
        case .groq:
            return [
                (id: "whisper-large-v3", name: "Whisper Large V3", description: "Groq's most accurate production transcription model.")
            ]
        case .openai:
            return [
                (id: "gpt-transcribe", name: "GPT Transcribe", description: "OpenAI's current high-accuracy model for completed recordings.")
            ]
        }
    }

    var llmModels: [(id: String, name: String, description: String)] {
        switch self {
        case .groq:
            return [
                (id: "openai/gpt-oss-120b", name: "GPT-OSS 120B", description: "Groq's production quality model; fast and available on the free tier.")
            ]
        case .openai:
            return [
                (id: "gpt-5.6-luna", name: "GPT-5.6 Luna", description: "Current low-latency, cost-sensitive model for focused cleanup.")
            ]
        }
    }

    var freeInfo: String? {
        switch self {
        case .groq: return "Free API — no credit card needed"
        case .openai: return nil
        }
    }

    var storageKey: String {
        switch self {
        case .groq: return "groq_api_key"
        case .openai: return "openai_api_key"
        }
    }
}
