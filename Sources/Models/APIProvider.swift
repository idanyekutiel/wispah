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
        case .openai: return "gpt-4o-mini-transcribe"
        }
    }

    var defaultLLMModel: String {
        switch self {
        case .groq: return "meta-llama/llama-4-scout-17b-16e-instruct"
        case .openai: return "gpt-5-nano"
        }
    }

    var defaultVisionModel: String {
        switch self {
        case .groq: return "meta-llama/llama-4-scout-17b-16e-instruct"
        case .openai: return "gpt-5-mini"
        }
    }

    var whisperModels: [(id: String, name: String, description: String)] {
        switch self {
        case .groq:
            return [
                (id: "whisper-large-v3", name: "Large V3 (Most Accurate)", description: "Best accuracy across all languages."),
                (id: "whisper-large-v3-turbo", name: "Large V3 Turbo (Fast)", description: "Slightly faster with ~1% lower accuracy. Multilingual.")
            ]
        case .openai:
            return [
                (id: "gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe", description: "Better accuracy than Whisper. Low cost."),
                (id: "gpt-4o-transcribe", name: "GPT-4o Transcribe", description: "Best accuracy. Higher cost."),
                (id: "whisper-1", name: "Whisper 1", description: "Original model. Cheapest option.")
            ]
        }
    }

    var llmModels: [(id: String, name: String, description: String)] {
        switch self {
        case .groq:
            return [
                (id: "meta-llama/llama-4-scout-17b-16e-instruct", name: "Llama 4 Scout", description: "Fast and capable. Supports vision for screen context."),
                (id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B", description: "Larger model. Text only — no screen context support."),
                (id: "meta-llama/llama-4-maverick-17b-128e-instruct", name: "Llama 4 Maverick", description: "128 experts. Highest quality, slower.")
            ]
        case .openai:
            return [
                (id: "gpt-5-nano", name: "GPT-5 Nano (Recommended)", description: "Fastest and cheapest. Supports vision. $0.05/$0.40 per 1M tokens."),
                (id: "gpt-5-mini", name: "GPT-5 Mini", description: "Great balance of speed, cost, and quality. Supports vision. $0.25/$2 per 1M tokens."),
                (id: "gpt-5", name: "GPT-5", description: "Most capable. Supports vision. $1.25/$10 per 1M tokens."),
                (id: "gpt-4.1-nano", name: "GPT-4.1 Nano", description: "Previous gen. Fast and cheap. $0.10/$0.40 per 1M tokens."),
                (id: "gpt-4.1-mini", name: "GPT-4.1 Mini", description: "Previous gen. Good quality. $0.40/$1.60 per 1M tokens."),
                (id: "gpt-4.1", name: "GPT-4.1", description: "Previous gen. Most capable 4.1. $2/$8 per 1M tokens.")
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
