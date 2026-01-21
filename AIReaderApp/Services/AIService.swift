// AIService.swift
// Service for AI-powered text analysis using OpenAI API
//
// Implements all analysis types from the web app: fact_check, discussion, key_points,
// argument_map, counterpoints, custom_question, and comment

import Foundation

/// Configuration for OpenAI API
struct AIConfiguration {
    var apiKey: String
    var baseURL: String
    var model: String
    var reasoningEffort: String
    var temperature: Double?
    var maxOutputTokens: Int
    var timeoutSeconds: TimeInterval
    var maxInputChars: Int
    var contextMaxChars: Int
    var chapterContextMaxChars: Int

    static var `default`: AIConfiguration {
        // Read API key from UserDefaults (where SettingsManager stores it)
        // This works on physical iOS devices, unlike environment variables
        let defaults = UserDefaults.standard
        let apiKey = defaults.string(forKey: "settings.apiKey") ?? ""

        return AIConfiguration(
            apiKey: apiKey,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o",
            reasoningEffort: "high",
            temperature: nil,
            maxOutputTokens: 16000,
            timeoutSeconds: 180,
            maxInputChars: 400000,
            contextMaxChars: 8000,
            chapterContextMaxChars: 100000
        )
    }
}

/// Service for performing AI analysis on text selections
@Observable
final class AIService {
    // MARK: - Properties
    private let config: AIConfiguration
    private let session: URLSession

    // MARK: - Errors
    enum AIError: LocalizedError {
        case noAPIKey
        case networkError(Error)
        case invalidResponse
        case apiError(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "OpenAI API key not configured. Please add your API key in Settings."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from AI service"
            case .apiError(let message):
                return "AI API error: \(message)"
            case .timeout:
                return "Request timed out. Please try again."
            }
        }
    }

    // MARK: - Initialization
    init(configuration: AIConfiguration = .default) {
        self.config = configuration

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeoutSeconds
        sessionConfig.timeoutIntervalForResource = configuration.timeoutSeconds * 2
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Public API

    /// Perform fact check analysis
    func factCheck(text: String, context: String) async throws -> String {
        let prompt = """
        You are an expert fact-checker and knowledge assistant. The user has selected some text while reading and wants a quick explanation or verification.

        **Selected Text:**
        \(text)

        **Surrounding Context:**
        \(context)

        **Your Task:**
        Provide a concise, informative response that:
        1. If it's a term, person, event, or concept: Give a clear definition or explanation
        2. If it's a factual claim: Verify its accuracy with current knowledge
        3. If it's a quote or reference: Provide attribution and context
        4. Add any relevant historical or contemporary context

        Keep your response focused and educational. Use bullet points for multiple facts.
        """

        return try await callOpenAI(prompt: prompt)
    }

    /// Perform deep discussion analysis
    func discussion(text: String, context: String) async throws -> String {
        let prompt = """
        You are a thoughtful academic discussion partner. The user wants to engage deeply with this passage.

        **Selected Text:**
        \(text)

        **Surrounding Context:**
        \(context)

        **Your Task:**
        Provide a rich academic discussion that includes:

        1. **Core Thesis:** What is the central argument or idea being presented?

        2. **Theoretical Framework:** What philosophical, scientific, or cultural frameworks inform this passage?

        3. **Critical Evaluation:**
           - What are the strengths of this argument?
           - What are potential weaknesses or blind spots?
           - What assumptions are being made?

        4. **Connections:** How does this relate to:
           - Other thinkers or traditions
           - Contemporary debates
           - Practical applications

        5. **Questions for Reflection:**
           Pose 2-3 thought-provoking questions that could deepen understanding

        Write in an engaging, scholarly tone that invites further exploration.
        """

        return try await callOpenAI(prompt: prompt)
    }

    /// Extract key points
    func keyPoints(text: String, context: String) async throws -> String {
        let prompt = """
        You are a skilled summarizer who excels at identifying essential ideas.

        **Selected Text:**
        \(text)

        **Surrounding Context:**
        \(context)

        **Your Task:**
        Extract 3-8 key points from this passage:

        - Each point should capture a distinct, important idea
        - Use clear, concise language
        - Bold key terms or concepts
        - Order points by importance or logical flow
        - Include any crucial evidence or examples mentioned

        Format as a numbered list for easy reference.
        """

        return try await callOpenAI(prompt: prompt)
    }

    /// Create argument map
    func argumentMap(text: String, context: String) async throws -> String {
        let prompt = """
        You are an expert in logical analysis and critical thinking.

        **Selected Text:**
        \(text)

        **Surrounding Context:**
        \(context)

        **Your Task:**
        Create a structured argument map that includes:

        1. **Main Conclusion:**
           What is the author ultimately trying to convince us of?

        2. **Key Premises:**
           List the main supporting claims (label each: P1, P2, etc.)

        3. **Evidence:**
           What facts, examples, or data support each premise?

        4. **Reasoning Structure:**
           How do the premises connect to the conclusion?
           (deductive, inductive, analogical, etc.)

        5. **Hidden Assumptions:**
           What unstated beliefs must be true for the argument to work?

        6. **Potential Weak Points:**
           Where might the argument be challenged?

        Use clear formatting with headers and bullet points.
        """

        return try await callOpenAI(prompt: prompt)
    }

    /// Generate counterpoints
    func counterpoints(text: String, context: String) async throws -> String {
        let prompt = """
        You are a skilled devil's advocate and critical thinker.

        **Selected Text:**
        \(text)

        **Surrounding Context:**
        \(context)

        **Your Task:**
        Present 3-6 thoughtful counterpoints or alternative perspectives:

        For each counterpoint:
        1. **The Challenge:** State the objection or alternative view clearly
        2. **The Reasoning:** Explain why this is a valid concern
        3. **Possible Response:** How might the author defend their position?

        Consider:
        - Logical objections
        - Empirical counterevidence
        - Alternative interpretations
        - Different value frameworks
        - Historical or cultural perspectives

        Be fair and intellectually honest in your critiques.
        """

        return try await callOpenAI(prompt: prompt)
    }

    /// Answer custom question with conversation history
    func customQuestion(
        text: String,
        question: String,
        context: String,
        chapterContext: String? = nil,
        history: [(question: String, answer: String)] = []
    ) async throws -> String {
        var prompt = """
        You are a knowledgeable reading assistant helping with questions about a text.

        **Selected Text:**
        \(text)

        **Surrounding Context:**
        \(context)
        """

        if let chapter = chapterContext, !chapter.isEmpty {
            let trimmedChapter = String(chapter.prefix(config.chapterContextMaxChars))
            prompt += """

            **Full Chapter Context (for reference):**
            \(trimmedChapter)
            """
        }

        if !history.isEmpty {
            prompt += """

            **Previous Conversation:**
            """
            for turn in history {
                prompt += """

                User: \(turn.question)
                Assistant: \(turn.answer)
                """
            }
        }

        prompt += """

        **User's Question:**
        \(question)

        **Your Task:**
        Answer the question directly and helpfully, drawing on:
        - The selected text and its context
        - Your general knowledge
        - The conversation history (if any)

        Be thorough but concise. Use examples when helpful.
        """

        return try await callOpenAI(prompt: prompt)
    }

    /// Save a comment (no AI processing needed)
    func saveComment(text: String, comment: String) -> String {
        return comment  // Comments are just saved as-is
    }

    // MARK: - Private Implementation

    /// Call OpenAI with streaming, yielding partial responses as they arrive
    func callOpenAIStreaming(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard !config.apiKey.isEmpty else {
                    continuation.finish(throwing: AIError.noAPIKey)
                    return
                }

                // Trim prompt if too long
                let trimmedPrompt = String(prompt.prefix(config.maxInputChars))

                // Build request
                let endpoint = "\(config.baseURL)/chat/completions"
                guard let url = URL(string: endpoint) else {
                    continuation.finish(throwing: AIError.invalidResponse)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                // Build request body with streaming enabled
                var body: [String: Any] = [
                    "model": config.model,
                    "messages": [
                        ["role": "user", "content": trimmedPrompt]
                    ],
                    "max_tokens": config.maxOutputTokens,
                    "stream": true
                ]

                if let temp = config.temperature {
                    body["temperature"] = temp
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: AIError.invalidResponse)
                        return
                    }

                    // Parse SSE stream
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if jsonString == "[DONE]" {
                                break
                            }

                            if let data = jsonString.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let choices = json["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any],
                               let content = delta["content"] as? String {
                                continuation.yield(content)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.networkError(error))
                }
            }
        }
    }

    private func callOpenAI(prompt: String) async throws -> String {
        guard !config.apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        // Trim prompt if too long
        let trimmedPrompt = String(prompt.prefix(config.maxInputChars))

        // Build request
        let endpoint = "\(config.baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw AIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "user", "content": trimmedPrompt]
            ],
            "max_tokens": config.maxOutputTokens
        ]

        // Add temperature if specified
        if let temp = config.temperature {
            body["temperature"] = temp
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Make request with retry logic
        return try await performRequestWithRetry(request: request)
    }

    private func performRequestWithRetry(request: URLRequest, retries: Int = 3) async throws -> String {
        var lastError: Error?

        for attempt in 0..<retries {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    return try parseResponse(data: data)
                } else if httpResponse.statusCode == 429 {
                    // Rate limited - wait and retry
                    let delay = pow(2.0, Double(attempt)) * 1.0
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    // Try to parse error message
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        throw AIError.apiError(message)
                    }
                    throw AIError.apiError("HTTP \(httpResponse.statusCode)")
                }
            } catch let error as AIError {
                throw error
            } catch {
                lastError = error
                let delay = pow(2.0, Double(attempt)) * 0.5
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError.map { AIError.networkError($0) } ?? AIError.timeout
    }

    private func parseResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Analysis Job Manager
/// Manages async analysis jobs with status tracking and streaming support
@Observable
final class AnalysisJobManager {
    struct Job: Identifiable {
        let id: UUID
        var status: Status
        var result: String?
        var streamingResult: String = ""  // Accumulates streaming chunks
        var error: Error?

        enum Status {
            case queued
            case running
            case streaming  // New status for active streaming
            case completed
            case error
        }
    }

    private(set) var jobs: [UUID: Job] = [:]
    private let aiService: AIService

    init(aiService: AIService = AIService()) {
        self.aiService = aiService
    }

    @discardableResult
    func queueAnalysis(
        type: AnalysisType,
        text: String,
        context: String,
        chapterContext: String? = nil,
        question: String? = nil,
        history: [(question: String, answer: String)] = []
    ) -> UUID {
        let jobId = UUID()
        jobs[jobId] = Job(id: jobId, status: .queued)

        Task {
            await runJobStreaming(
                id: jobId,
                type: type,
                text: text,
                context: context,
                chapterContext: chapterContext,
                question: question,
                history: history
            )
        }

        return jobId
    }

    private func runJobStreaming(
        id: UUID,
        type: AnalysisType,
        text: String,
        context: String,
        chapterContext: String?,
        question: String?,
        history: [(question: String, answer: String)]
    ) async {
        jobs[id]?.status = .running

        // Handle comment type specially (no AI call needed)
        if type == .comment {
            jobs[id]?.status = .completed
            jobs[id]?.result = question ?? ""
            return
        }

        // Build the prompt based on analysis type
        let prompt = buildPrompt(type: type, text: text, context: context, chapterContext: chapterContext, question: question, history: history)

        jobs[id]?.status = .streaming

        do {
            // Use array of chunks for more efficient memory allocation
            // Joining at intervals reduces reallocation overhead
            var chunks: [String] = []
            chunks.reserveCapacity(100)  // Pre-allocate for typical response
            var updateCounter = 0

            for try await chunk in aiService.callOpenAIStreaming(prompt: prompt) {
                chunks.append(chunk)
                updateCounter += 1

                // Update UI every 3 chunks to reduce main thread overhead
                // This also reduces string concatenation frequency
                if updateCounter >= 3 {
                    updateCounter = 0
                    let currentResult = chunks.joined()
                    await MainActor.run {
                        jobs[id]?.streamingResult = currentResult
                    }
                }
            }

            // Final update with complete result
            let fullResult = chunks.joined()
            await MainActor.run {
                jobs[id]?.status = .completed
                jobs[id]?.result = fullResult
                jobs[id]?.streamingResult = fullResult
            }
        } catch {
            await MainActor.run {
                jobs[id]?.status = .error
                jobs[id]?.error = error
            }
        }
    }

    private func buildPrompt(
        type: AnalysisType,
        text: String,
        context: String,
        chapterContext: String?,
        question: String?,
        history: [(question: String, answer: String)]
    ) -> String {
        switch type {
        case .factCheck:
            return """
            You are an expert fact-checker and knowledge assistant. The user has selected some text while reading and wants a quick explanation or verification.

            **Selected Text:**
            \(text)

            **Surrounding Context:**
            \(context)

            **Your Task:**
            Provide a concise, informative response that:
            1. If it's a term, person, event, or concept: Give a clear definition or explanation
            2. If it's a factual claim: Verify its accuracy with current knowledge
            3. If it's a quote or reference: Provide attribution and context
            4. Add any relevant historical or contemporary context

            Keep your response focused and educational. Use bullet points for multiple facts.
            """

        case .discussion:
            return """
            You are a thoughtful academic discussion partner. The user wants to engage deeply with this passage.

            **Selected Text:**
            \(text)

            **Surrounding Context:**
            \(context)

            **Your Task:**
            Provide a rich academic discussion that includes:

            1. **Core Thesis:** What is the central argument or idea being presented?

            2. **Theoretical Framework:** What philosophical, scientific, or cultural frameworks inform this passage?

            3. **Critical Evaluation:**
               - What are the strengths of this argument?
               - What are potential weaknesses or blind spots?
               - What assumptions are being made?

            4. **Connections:** How does this relate to:
               - Other thinkers or traditions
               - Contemporary debates
               - Practical applications

            5. **Questions for Reflection:**
               Pose 2-3 thought-provoking questions that could deepen understanding

            Write in an engaging, scholarly tone that invites further exploration.
            """

        case .keyPoints:
            return """
            You are a skilled summarizer who excels at identifying essential ideas.

            **Selected Text:**
            \(text)

            **Surrounding Context:**
            \(context)

            **Your Task:**
            Extract 3-8 key points from this passage:

            - Each point should capture a distinct, important idea
            - Use clear, concise language
            - Bold key terms or concepts
            - Order points by importance or logical flow
            - Include any crucial evidence or examples mentioned

            Format as a numbered list for easy reference.
            """

        case .argumentMap:
            return """
            You are an expert in logical analysis and critical thinking.

            **Selected Text:**
            \(text)

            **Surrounding Context:**
            \(context)

            **Your Task:**
            Create a structured argument map that includes:

            1. **Main Conclusion:**
               What is the author ultimately trying to convince us of?

            2. **Key Premises:**
               List the main supporting claims (label each: P1, P2, etc.)

            3. **Evidence:**
               What facts, examples, or data support each premise?

            4. **Reasoning Structure:**
               How do the premises connect to the conclusion?
               (deductive, inductive, analogical, etc.)

            5. **Hidden Assumptions:**
               What unstated beliefs must be true for the argument to work?

            6. **Potential Weak Points:**
               Where might the argument be challenged?

            Use clear formatting with headers and bullet points.
            """

        case .counterpoints:
            return """
            You are a skilled devil's advocate and critical thinker.

            **Selected Text:**
            \(text)

            **Surrounding Context:**
            \(context)

            **Your Task:**
            Present 3-6 thoughtful counterpoints or alternative perspectives:

            For each counterpoint:
            1. **The Challenge:** State the objection or alternative view clearly
            2. **The Reasoning:** Explain why this is a valid concern
            3. **Possible Response:** How might the author defend their position?

            Consider:
            - Logical objections
            - Empirical counterevidence
            - Alternative interpretations
            - Different value frameworks
            - Historical or cultural perspectives

            Be fair and intellectually honest in your critiques.
            """

        case .customQuestion:
            var prompt = """
            You are a knowledgeable reading assistant helping with questions about a text.

            **Selected Text:**
            \(text)

            **Surrounding Context:**
            \(context)
            """

            if let chapter = chapterContext, !chapter.isEmpty {
                let trimmedChapter = String(chapter.prefix(100000))
                prompt += """

                **Full Chapter Context (for reference):**
                \(trimmedChapter)
                """
            }

            if !history.isEmpty {
                prompt += """

                **Previous Conversation:**
                """
                for turn in history {
                    prompt += """

                    User: \(turn.question)
                    Assistant: \(turn.answer)
                    """
                }
            }

            prompt += """

            **User's Question:**
            \(question ?? "")

            **Your Task:**
            Answer the question directly and helpfully, drawing on:
            - The selected text and its context
            - Your general knowledge
            - The conversation history (if any)

            Be thorough but concise. Use examples when helpful.
            """

            return prompt

        case .comment:
            return ""  // Comments don't need AI processing
        }
    }

    func getJob(_ id: UUID) -> Job? {
        jobs[id]
    }

    func clearJob(_ id: UUID) {
        jobs.removeValue(forKey: id)
    }
}
