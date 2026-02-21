import Foundation

enum APIProvider: String, CaseIterable, Identifiable {
    case groq
    case openai
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .local: return "Local"
        }
    }

    var baseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .openai: return "https://api.openai.com/v1"
        case .local: return ""
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .groq, .openai: return true
        case .local: return false
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .groq: return "Paste your Groq API key"
        case .openai: return "Paste your OpenAI API key"
        case .local: return ""
        }
    }

    var keyHelpURL: String {
        switch self {
        case .groq: return "https://console.groq.com/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .local: return ""
        }
    }

    var keyHelpLabel: String {
        switch self {
        case .groq: return "console.groq.com/keys"
        case .openai: return "platform.openai.com/api-keys"
        case .local: return ""
        }
    }

    var defaultWhisperModel: String {
        switch self {
        case .groq: return "whisper-large-v3"
        case .openai: return "gpt-4o-mini-transcribe"
        case .local: return "base"
        }
    }

    var defaultLLMModel: String {
        switch self {
        case .groq: return "meta-llama/llama-4-scout-17b-16e-instruct"
        case .openai: return "gpt-5-nano"
        case .local: return "mlx-community/Qwen3-1.7B-4bit"
        }
    }

    var defaultVisionModel: String {
        switch self {
        case .groq: return "meta-llama/llama-4-scout-17b-16e-instruct"
        case .openai: return "gpt-5-mini"
        case .local: return ""
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
        case .local:
            return [
                (id: "tiny", name: "Tiny (~40 MB)", description: "Fastest, lowest quality. Good for quick tests."),
                (id: "tiny.en", name: "Tiny English (~40 MB)", description: "English-only. Slightly better accuracy."),
                (id: "base", name: "Base (~74 MB)", description: "Good starting point. Decent quality."),
                (id: "base.en", name: "Base English (~74 MB)", description: "English-only. Better accuracy for English."),
                (id: "small", name: "Small (~244 MB)", description: "Solid general-purpose model."),
                (id: "small.en", name: "Small English (~244 MB)", description: "English-only. Best accuracy for its size."),
                (id: "medium", name: "Medium (~489 MB)", description: "High quality. Noticeably better on complex audio."),
                (id: "medium.en", name: "Medium English (~489 MB)", description: "English-only. Near-large quality."),
                (id: "large-v3", name: "Large V3 (~947 MB)", description: "Best quality. Multilingual."),
                (id: "large-v3-turbo", name: "Large V3 Turbo (~547 MB)", description: "Faster than large-v3 with similar quality."),
                (id: "distil-large-v3", name: "Distil Large V3 (~594 MB)", description: "Distilled. Fast with near-large quality.")
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
        case .local:
            return [
                (id: "mlx-community/Qwen3-0.6B-4bit", name: "Qwen3 0.6B (Fastest)", description: "Very fast, basic quality. ~400 MB."),
                (id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B (Recommended)", description: "Good balance of speed and quality. ~1 GB."),
                (id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B (Best Quality)", description: "Best local quality. ~2.5 GB."),
                (id: "mlx-community/gemma-3-4b-it-4bit", name: "Gemma 3 4B", description: "Google's model. Good quality. ~2.5 GB."),
                (id: "mlx-community/Phi-4-mini-instruct-4bit", name: "Phi-4 Mini 3.8B", description: "Strong reasoning. ~2.3 GB.")
            ]
        }
    }

    var freeInfo: String? {
        switch self {
        case .groq: return "Free API — no credit card needed"
        case .openai: return nil
        case .local: return "Fully offline — no API key needed"
        }
    }

    var storageKey: String {
        switch self {
        case .groq: return "groq_api_key"
        case .openai: return "openai_api_key"
        case .local: return ""
        }
    }
}
