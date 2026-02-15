import Foundation

enum PostProcessingError: LocalizedError {
    case requestFailed(Int, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let details):
            "Post-processing failed with status \(statusCode): \(details)"
        case .invalidResponse(let details):
            "Invalid post-processing response: \(details)"
        }
    }
}

struct PostProcessingResult {
    let transcript: String
    let prompt: String
}

final class PostProcessingService {
    private let apiKey: String
    private let baseURL = "https://api.groq.com/openai/v1"
    private let defaultModel = "meta-llama/llama-4-scout-17b-16e-instruct"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func postProcess(
        transcript: String,
        context: AppContext,
        customVocabulary: String
    ) async throws -> PostProcessingResult {
        let vocabularyTerms = mergedVocabularyTerms(
            rawVocabulary: customVocabulary,
            contextSummary: context.contextSummary
        )
        return try await process(
            transcript: transcript,
            contextSummary: context.contextSummary,
            model: defaultModel,
            customVocabulary: vocabularyTerms
        )
    }

    private func process(
        transcript: String,
        contextSummary: String,
        model: String,
        customVocabulary: [String]
    ) async throws -> PostProcessingResult {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let normalizedVocabulary = normalizedVocabularyText(customVocabulary)
        let vocabularyPrompt = if !normalizedVocabulary.isEmpty {
            """
The following vocabulary must be treated as high-priority terms while rewriting.
Use these spellings exactly in the output when relevant:
\(normalizedVocabulary)
"""
        } else {
            ""
        }

        var systemPrompt = """
You are a context-aware dictation post-processor.
Your job is to rewrite the transcription into a polished, accurate final message.

Rules:
- Preserve the user's intent and tone.
- Use the provided context as your primary source for names, email participants, subject cues, project names, and other proper nouns.
- Correct obvious spelling and punctuation issues, especially for names and entities mentioned in context.
- The custom vocabulary list is authoritative for proper noun spellings. If a spoken token is a close misspelling of a vocabulary item, rewrite it using that exact vocabulary spelling.
- Remove spoken filler (for example: "um", "uh", "you know", "like") unless they are meaningful.
- If there is uncertainty about a proper noun, keep the original wording rather than inventing a correction.
- Convert rough list-like text into properly formatted Markdown bullet points when the content contains:
  - lines that begin with dashes, numbers, asterisks, or repeated phrases like "first/second/third";
  - sentence fragments intended as separate list items.
- If the context indicates email, output a sendable email structure:
  - include a clear subject line only when present in the transcription or explicit context;
  - use a greeting, concise body paragraphs, and a closing,
  - keep it ready to paste directly into an email composer.
- If no edits are needed for a token, phrase, or sentence, preserve it exactly as dictated.
- Do not change the meaning by inserting invented names, closures, clauses, or next steps.
- Keep the original intent and content scope; do not add, remove, summarize, or continue beyond what was spoken.
- Do not infer missing clauses, placeholders, or closing lines if they were not dictated.
- If the transcription is incomplete, return the rewritten partial content only.
- If no changes are required overall, return the transcription exactly as it should be inserted into the destination app.
- Do not wrap the entire response in quotation marks.
- Do not return the final output wrapped in quotes.
- Do not emit each sentence wrapped in quotes.
- If the raw model output is fully wrapped in quotation marks, treat that as invalid and return only the unwrapped transcript text.
- Never output explanatory preambles, scaffolding, disclaimers, assumptions, or analysis.
- Never include bracketed status notes (for example, "[No further text provided ...]") or templates like "possible complete email".
- Correct transcribed names and entities using the custom vocabulary whenever they are close variants of listed terms.
- Use context for names/terms only when the transcript references people/entities directly.
- Return only the rewritten transcript text.
"""
        if !vocabularyPrompt.isEmpty {
            systemPrompt += "\n\n" + vocabularyPrompt
        }

        let userMessage = """
Task: Rewrite the transcription for correctness using the context and vocab rules.

Transcription:
\(transcript)

Context:
\(contextSummary)
"""

        let promptForDisplay = """
SYSTEM:
\(systemPrompt)

USER:
\(userMessage)
"""

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userMessage
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
            throw PostProcessingError.requestFailed(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        return PostProcessingResult(
            transcript: sanitizePostProcessedTranscript(content),
            prompt: promptForDisplay
        )
    }

    private func sanitizePostProcessedTranscript(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let normalized = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return normalized }

        var dequoted = normalized
        if dequoted.hasPrefix("\"") && dequoted.hasSuffix("\"") && dequoted.count > 1 {
            dequoted.removeFirst()
            dequoted.removeLast()
        }
        dequoted = dequoted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dequoted.isEmpty else { return dequoted }

        let bannedPrefixes = [
            "here is",
            "here's",
            "here is the rewritten",
            "here is rewritten",
            "below is",
            "following is",
            "based on the context",
            "based on context",
            "assuming",
            "however, based on the context",
            "possible complete email",
            "i will",
            "if you'd like",
            "this is the rewritten",
            "rewritten transcription"
        ]

        var outputLines: [String] = []
        for rawLine in dequoted.components(separatedBy: .newlines) {
            var mutableLine = rawLine
            let line = mutableLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                outputLines.append("")
                continue
            }

            let lower = line.lowercased()
            let isBracketedNote = line.hasPrefix("[") && line.hasSuffix("]")
            let isBanned = bannedPrefixes.contains { prefix in
                lower.hasPrefix(prefix)
            }

            if isBracketedNote || isBanned {
                continue
            }

            outputLines.append(rawLine)
        }

        // Collapse leading/trailing blank lines and ensure no excessive vertical spacing.
        while outputLines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            outputLines.removeFirst()
        }
        while outputLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            outputLines.removeLast()
        }

        var compressed: [String] = []
        var previousWasEmpty = false
        for line in outputLines {
            let isEmptyLine = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmptyLine {
                if previousWasEmpty {
                    continue
                }
                previousWasEmpty = true
                compressed.append("")
            } else {
                previousWasEmpty = false
                compressed.append(line)
            }
        }

        return compressed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func correctedTranscript(_ value: String, vocabulary: [String]) -> String {
        var result = value
        let punctuationCharacters = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.controlCharacters)

        for entry in vocabulary {
            let cleanEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanEntry.contains(" ") {
                result = correctPhraseResult(result, phrase: cleanEntry)
            }
        }

        let tokenPattern = "\\p{L}+"
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern, options: []) else {
            return result
        }

        let mutableResult = NSMutableString(string: result)
        let nsValue = result as NSString
        let matches = tokenRegex.matches(in: result, range: NSRange(location: 0, length: nsValue.length))

        let singleWordVocabulary = vocabulary.filter { !$0.contains(" ") }
        if !singleWordVocabulary.isEmpty {
            for match in matches.reversed() {
                let token = nsValue.substring(with: match.range)
                let cleanedToken = token.trimmingCharacters(in: punctuationCharacters)
                guard let replacement = replacement(for: cleanedToken, from: singleWordVocabulary) else { continue }

                mutableResult.replaceCharacters(in: match.range, with: replacement)
            }
        }

        result = mutableResult as String
        return result
    }

    private func mergedVocabularyTerms(rawVocabulary: String, contextSummary: String) -> [String] {
        let userTerms = normalizedVocabularyTerms(rawVocabulary)
        let contextTerms = contextDerivedTerms(contextSummary)
        let expanded = (userTerms + contextTerms).flatMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] as [String] }

            var terms: [String] = [trimmed]
            if trimmed.contains(" ") {
                let parts = trimmed
                    .split(separator: " ")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count > 1 }
                terms.append(contentsOf: parts)
            }

            return terms
        }

        var seen = Set<String>()
        var deduped: [String] = []
        for term in expanded {
            let canonical = term.lowercased()
            if seen.insert(canonical).inserted {
                deduped.append(term)
            }
        }

        return deduped
            .sorted {
                $0.count == $1.count ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : $0.count > $1.count
            }
    }

    private func correctPhraseResult(_ text: String, phrase: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "(?i)\\b\(escaped)\\b"
        guard let phraseRegex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        return phraseRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: phrase)
    }

    private func replacement(for token: String, from vocabulary: [String]) -> String? {
        let lowered = token.lowercased()
        guard lowered.count >= 2 else { return nil }
        let firstLetter = lowered.first

        for candidate in vocabulary {
            let cleanCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredCandidate = cleanCandidate.lowercased()
            if loweredCandidate == lowered { return nil }
            guard let candidateFirstLetter = loweredCandidate.first,
                  candidateFirstLetter == firstLetter,
                  abs(loweredCandidate.count - lowered.count) <= 2 else { continue }

            let distance = levenshtein(lowered, loweredCandidate)
            if lowered.count <= 5 {
                if distance <= 1 { return cleanCandidate }
            } else if distance <= 2 {
                return cleanCandidate
            }
        }

        return nil
    }

    private func levenshtein(_ left: String, _ right: String) -> Int {
        let lhs = Array(left)
        let rhs = Array(right)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                if lhs[i - 1] == rhs[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = min(
                        previous[j] + 1,
                        current[j - 1] + 1,
                        previous[j - 1] + 1
                    )
                }
            }
            previous = current
            current = Array(repeating: 0, count: rhs.count + 1)
        }

        return previous[rhs.count]
    }

    private func normalizedVocabularyText(_ vocabularyTerms: [String]) -> String {
        let terms = vocabularyTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ")
    }

    private func contextDerivedTerms(_ contextSummary: String) -> [String] {
        guard let contextRegex = try? NSRegularExpression(
            pattern: "(?i)\\b(?:addressing|recipient|recipients|to|cc|bcc)\\b\\s*[:\\-]?\\s*(.+)",
            options: []
        ) else {
            return []
        }

        let nsContext = contextSummary as NSString
        let contextRange = NSRange(location: 0, length: nsContext.length)
        let contextMatches = contextRegex.matches(in: contextSummary, range: contextRange)
        guard !contextMatches.isEmpty else { return [] }

        var candidateTerms: [String] = []
        for match in contextMatches {
            guard match.numberOfRanges >= 2 else { continue }
            let capture = nsContext.substring(with: match.range(at: 1))
            if let end = capture.firstIndex(where: { $0 == "." || $0 == ";" }) {
                let fragment = String(capture[..<end])
                candidateTerms.append(contentsOf: parseNameList(fromContext: fragment))
            } else {
                candidateTerms.append(contentsOf: parseNameList(fromContext: capture))
            }
        }

        var seen = Set<String>()
        return candidateTerms
            .compactMap { candidate in
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return nil }
                let key = trimmed.lowercased()
                guard seen.insert(key).inserted else { return nil }
                return trimmed
            }
    }

    private func parseNameList(fromContext text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " or ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " cc ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " bcc ", with: ",", options: .caseInsensitive)

        return normalized
            .split(separator: ",")
            .compactMap { piece in
                var cleaned = String(piece)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
                if cleaned.isEmpty { return nil }
                if cleaned.range(of: ":") != nil {
                    cleaned = cleaned.replacingOccurrences(of: ":", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return looksLikePersonName(cleaned) ? cleaned : nil
            }
    }

    private func looksLikePersonName(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: " ", with: " ")
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalized.isEmpty && normalized.count <= 3 else { return false }
        return normalized.allSatisfy { token in
            guard let first = token.first else { return false }
            return first.isUppercase
        }
    }

    private func normalizedVocabularyTerms(_ rawVocabulary: String) -> [String] {
        rawVocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
