import Foundation

enum PostProcessingError: LocalizedError {
    case requestFailed(Int, String)
    case invalidResponse(String)
    case requestTimedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let details):
            "Post-processing failed with status \(statusCode): \(details)"
        case .invalidResponse(let details):
            "Invalid post-processing response: \(details)"
        case .requestTimedOut(let seconds):
            "Post-processing timed out after \(Int(seconds))s"
        }
    }
}

struct PostProcessingResult {
    let transcript: String
    let prompt: String
}

final class PostProcessingService: PostProcessingProvider {
    private let apiKey: String
    private let baseURL: String
    private let defaultModel: String
    private let postProcessingTimeoutSeconds: TimeInterval = 20

    static let appContextHints: [String: String] = [
        // Terminals
        "com.mitchellh.ghostty": "User is in Ghostty, a modern GPU-accelerated terminal by Mitchell Hashimoto (creator of Vagrant, Terraform). They are likely running commands, writing scripts, or interacting with CLI tools. Expect technical/developer language.",
        "com.apple.Terminal": "User is in Terminal. Expect command-line language, file paths, technical terms.",
        "com.googlecode.iterm2": "User is in iTerm2 terminal. Expect developer/CLI language.",
        "net.kovidgoyal.kitty": "User is in Kitty, a GPU-accelerated terminal. Expect developer/CLI language.",
        "com.warp.terminal": "User is in Warp, an AI-powered terminal. Expect developer/CLI language.",
        "co.zeit.hyper": "User is in Hyper terminal. Expect developer/CLI language.",
        // Code editors & AI coding tools
        "com.todesktop.230313mzl4w4u92": "User is in Cursor, an AI code editor built on VS Code. They are likely writing or discussing code, or prompting an AI coding assistant. Expect programming terms, variable names, file paths.",
        "com.microsoft.VSCode": "User is in VS Code. They are likely coding. Expect programming language, variable names, function names.",
        "dev.zed.Zed": "User is in Zed, a fast code editor. They are likely coding.",
        "com.jetbrains.intellij": "User is in IntelliJ IDEA. They are likely writing Java/Kotlin code.",
        "com.sublimetext.4": "User is in Sublime Text. They are likely editing code or text files.",
        "com.codeium.windsurf": "User is in Windsurf, an AI code editor by Codeium. They are likely writing or discussing code, or prompting an AI coding assistant.",
        "dev.replit.Replit-Desktop": "User is in Replit, an online IDE. They are likely coding or prompting an AI coding agent.",
        "com.apple.dt.Xcode": "User is in Xcode, Apple's IDE for macOS/iOS development. Expect Swift, Objective-C, SwiftUI terms.",
        "com.jetbrains.pycharm": "User is in PyCharm. They are likely writing Python code.",
        "com.jetbrains.WebStorm": "User is in WebStorm. They are likely writing JavaScript/TypeScript code.",
        "com.jetbrains.goland": "User is in GoLand. They are likely writing Go code.",
        "com.jetbrains.rider": "User is in Rider. They are likely writing C#/.NET code.",
        "com.jetbrains.rustrover": "User is in RustRover. They are likely writing Rust code.",
        "com.anthropic.claudecode": "User is in Claude Code, Anthropic's AI coding CLI. They are likely prompting an AI assistant to write or edit code. Expect programming terms, file paths, git commands.",
        // Browsers
        "com.apple.Safari": "User is in Safari browser. They may be researching, writing web content, or filling forms.",
        "com.google.Chrome": "User is in Chrome browser. They may be researching, writing web content, or filling forms.",
        "org.mozilla.firefox": "User is in Firefox browser. They may be researching, writing, or filling forms.",
        "company.thebrowser.Browser": "User is in Arc browser. They may be researching, writing, or filling forms.",
        "com.brave.Browser": "User is in Brave browser. They may be researching, writing, or filling forms.",
        // Communication
        "com.apple.MobileSMS": "User is in Messages. They are writing a text message.",
        "com.tinyspeck.slackmacgap": "User is in Slack, a workplace messaging app. They are writing a message.",
        "com.hnc.Discord": "User is in Discord, a chat platform for communities. They are writing a message.",
        "WhatsApp": "User is in WhatsApp. They are writing a message.",
        "net.whatsapp.WhatsApp": "User is in WhatsApp. They are writing a message.",
        "com.readdle.smartemail.macos": "User is in Spark, an email client. They are composing an email.",
        "ru.keepcoder.Telegram": "User is in Telegram, a messaging app. They are writing a message.",
        "com.microsoft.teams2": "User is in Microsoft Teams, a workplace communication app. They are writing a message.",
        // Email
        "com.google.Gmail": "User is in Gmail. They are composing or reading an email.",
        "com.apple.mail": "User is in Apple Mail. They are composing or reading an email.",
        // Productivity
        "com.apple.Notes": "User is in Apple Notes. They are taking notes — preserve structure, lists, and quick thoughts.",
        "md.obsidian": "User is in Obsidian, a Markdown-based knowledge base and note-taking app. They are writing notes, likely in Markdown format. Preserve structure.",
        "com.notion.Notion": "User is in Notion, a collaborative workspace for docs, wikis, and project management. They are writing documents or notes. Preserve structure and formatting.",
        "com.linear": "User is in Linear, a project management tool for software teams. They are likely writing issue descriptions, comments, or project updates.",
        "com.loom.desktop": "User is in Loom. They may be writing a video title, description, or comment.",
        "com.apple.iWork.Pages": "User is in Pages. They are writing a document — proper prose formatting.",
        "com.microsoft.Word": "User is in Microsoft Word. They are writing a document.",
        // Design
        "com.figma.Desktop": "User is in Figma. They may be discussing design, UI elements, components, or leaving comments.",
        // Misc
        "com.apple.finder": "User is in Finder. They may be discussing files, folders, or file management.",
        "com.apple.systempreferences": "User is in System Settings. They may be describing settings or configurations.",
    ]

    init(apiKey: String, baseURL: String = "https://api.groq.com/openai/v1", model: String = "meta-llama/llama-4-scout-17b-16e-instruct") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.defaultModel = model
    }

    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String,
        smartFormatting: Bool = true,
        smartCorrections: Bool = false,
        developerMode: Bool = false,
        customPrompt: String = ""
    ) async throws -> PostProcessingResult {
        let vocabularyTerms = mergedVocabularyTerms(rawVocabulary: customVocabulary)
        let appHint = Self.appContextHints[context.bundleIdentifier ?? ""] ?? ""

        let timeoutSeconds = postProcessingTimeoutSeconds
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw PostProcessingError.invalidResponse("Post-processing service deallocated")
                }
                return try await self.process(
                    transcript: transcript,
                    contextSummary: context.contextSummary,
                    model: defaultModel,
                    customVocabulary: vocabularyTerms,
                    smartFormatting: smartFormatting,
                    smartCorrections: smartCorrections,
                    developerMode: developerMode,
                    customPrompt: customPrompt,
                    appHint: appHint
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
        contextSummary: String,
        model: String,
        customVocabulary: [String],
        smartFormatting: Bool,
        smartCorrections: Bool,
        developerMode: Bool,
        customPrompt: String,
        appHint: String
    ) async throws -> PostProcessingResult {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = postProcessingTimeoutSeconds

        let built = PostProcessingPromptBuilder.build(
            transcript: transcript,
            contextSummary: contextSummary,
            model: model,
            customVocabulary: customVocabulary.joined(separator: ", "),
            smartFormatting: smartFormatting,
            smartCorrections: smartCorrections,
            developerMode: developerMode,
            customPrompt: customPrompt,
            appHint: appHint
        )

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "messages": [
                [
                    "role": "system",
                    "content": built.systemPrompt
                ],
                [
                    "role": "user",
                    "content": built.userMessage
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            let truncatedMessage = String(message.prefix(500))
            let statusCode = httpResponse.statusCode
            switch statusCode {
            case 401, 403:
                throw PostProcessingError.requestFailed(statusCode, "Invalid or expired API key")
            case 429:
                throw PostProcessingError.requestFailed(statusCode, "Rate limit exceeded. Please wait and try again.")
            case 500...:
                throw PostProcessingError.requestFailed(statusCode, "Server error. Please try again later.")
            default:
                throw PostProcessingError.requestFailed(statusCode, truncatedMessage)
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        return PostProcessingResult(
            transcript: PostProcessingPromptBuilder.sanitize(content),
            prompt: built.displayPrompt
        )
    }

    private func mergedVocabularyTerms(rawVocabulary: String) -> [String] {
        PostProcessingPromptBuilder.mergedVocabularyTerms(rawVocabulary: rawVocabulary)
    }
}
