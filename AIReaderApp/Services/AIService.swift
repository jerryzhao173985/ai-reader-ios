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
    var provider: SettingsManager.AIProvider
    var reasoningEffort: String  // For GPT-5.2: none|low|medium|high|xhigh
    var webSearchEnabled: Bool   // For GPT-5.2: enable web search tool
    var temperature: Double?
    var maxOutputTokens: Int
    var timeoutSeconds: TimeInterval
    var maxInputChars: Int
    var contextMaxChars: Int
    var chapterContextMaxChars: Int
    var autoFallback: Bool  // If true, fall back to GPT-4o on GPT-5.2 failure

    /// Model ID based on provider
    var model: String { provider.modelId }

    /// Full endpoint URL based on provider
    var endpoint: String { "\(baseURL)\(provider.apiEndpoint)" }

    static var `default`: AIConfiguration {
        // Read settings from UserDefaults (where SettingsManager stores them)
        let defaults = UserDefaults.standard
        let apiKey = defaults.string(forKey: "settings.apiKey") ?? ""

        // Load provider setting
        let providerValue = defaults.string(forKey: "settings.aiProvider") ?? "gpt-4o"
        let provider = SettingsManager.AIProvider(rawValue: providerValue) ?? .gpt4o

        // Load auto-fallback setting
        let autoFallback: Bool
        if defaults.object(forKey: "settings.aiAutoFallback") != nil {
            autoFallback = defaults.bool(forKey: "settings.aiAutoFallback")
        } else {
            autoFallback = true
        }

        // Load reasoning effort (default xhigh for best quality)
        let effortValue = defaults.string(forKey: "settings.reasoningEffort") ?? "xhigh"
        let reasoningEffort = SettingsManager.ReasoningEffort(rawValue: effortValue) ?? .xhigh

        // Load web search setting (default false)
        let webSearchEnabled: Bool
        if defaults.object(forKey: "settings.webSearchEnabled") != nil {
            webSearchEnabled = defaults.bool(forKey: "settings.webSearchEnabled")
        } else {
            webSearchEnabled = false
        }

        return AIConfiguration(
            apiKey: apiKey,
            baseURL: "https://api.openai.com/v1",
            provider: provider,
            reasoningEffort: reasoningEffort.rawValue,
            webSearchEnabled: webSearchEnabled,
            temperature: nil,
            maxOutputTokens: 16000,
            timeoutSeconds: 180,
            maxInputChars: 400000,
            contextMaxChars: 8000,
            chapterContextMaxChars: 100000,
            autoFallback: autoFallback
        )
    }

    /// Create a fallback configuration using GPT-4o
    /// Disables web search since Chat Completions API doesn't support tools
    func withFallback() -> AIConfiguration {
        var fallback = self
        fallback.provider = .gpt4o
        fallback.autoFallback = false  // Don't chain fallbacks
        fallback.webSearchEnabled = false  // GPT-4o doesn't support web search
        return fallback
    }
}

/// Events yielded during AI streaming
/// Used to communicate both content and metadata (like fallback notifications) through the stream
enum StreamEvent: Sendable {
    case content(String)
    case fallbackOccurred(modelId: String, webSearchEnabled: Bool)
}

/// Result from non-streaming AI calls, includes model tracking info
private struct NonStreamingResult {
    let content: String
    let modelId: String
    let usedWebSearch: Bool
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

    /// Whether web search is enabled for this session
    /// Requires both: (1) GPT-5.2 provider (web search uses Responses API) AND (2) setting enabled
    /// Since settings can only be changed by exiting the book, config is always fresh
    var isWebSearchEnabled: Bool {
        config.provider == .gpt5_2 && config.webSearchEnabled
    }

    /// The model ID used for this session (e.g., "gpt-5.2", "gpt-4o")
    var modelId: String {
        config.provider.modelId
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

        return try await callOpenAI(prompt: prompt).content
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

        return try await callOpenAI(prompt: prompt).content
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

        return try await callOpenAI(prompt: prompt).content
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

        return try await callOpenAI(prompt: prompt).content
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

        return try await callOpenAI(prompt: prompt).content
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

        return try await callOpenAI(prompt: prompt).content
    }

    /// Save a comment (no AI processing needed)
    func saveComment(text: String, comment: String) -> String {
        return comment  // Comments are just saved as-is
    }

    // MARK: - Private Implementation

    /// Call OpenAI with streaming, yielding partial responses as they arrive
    /// Automatically selects the appropriate API based on provider configuration
    /// Returns StreamEvent to communicate both content and metadata (like fallback notifications)
    func callOpenAIStreaming(prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        switch config.provider {
        case .gpt5_2:
            return callResponsesAPIStreaming(prompt: prompt)
        case .gpt4o:
            return callChatCompletionsStreaming(prompt: prompt)
        }
    }

    // MARK: - Responses API (GPT-5.2)

    /// Stream using the new OpenAI Responses API for GPT-5.2
    private func callResponsesAPIStreaming(prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard !config.apiKey.isEmpty else {
                    continuation.finish(throwing: AIError.noAPIKey)
                    return
                }

                let trimmedPrompt = String(prompt.prefix(config.maxInputChars))

                guard let url = URL(string: config.endpoint) else {
                    continuation.finish(throwing: AIError.invalidResponse)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                // Build Responses API request body
                // See: https://platform.openai.com/docs/api-reference/responses
                var body: [String: Any] = [
                    "model": config.model,
                    "input": trimmedPrompt,
                    "max_output_tokens": config.maxOutputTokens,
                    "stream": true
                ]

                // Add reasoning configuration for GPT-5.2
                // Note: summary parameter requires organization verification, so we omit it
                body["reasoning"] = [
                    "effort": config.reasoningEffort
                ]

                // Add web search tool if enabled
                // Allows model to search for up-to-date information relevant to the selected text
                if config.webSearchEnabled {
                    body["tools"] = [
                        [
                            "type": "web_search",
                            "search_context_size": "high"  // Maximum context for best results
                        ]
                    ]
                    // Request source information to be included in streaming response
                    // SSE events will contain response.web_search_call.* for status
                    // and sources will be available in the output items
                    body["include"] = [
                        "web_search_call.action.sources",
                        "web_search_call.results"
                    ]
                    #if DEBUG
                    print("[AIService] Web search enabled with include[sources,results] for this request")
                    #endif
                }

                if let temp = config.temperature {
                    body["temperature"] = temp
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    #if DEBUG
                    print("[AIService] Responses API request to \(config.endpoint) with model \(config.model)")
                    #endif

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AIError.invalidResponse)
                        return
                    }

                    // Check for non-200 response
                    if httpResponse.statusCode != 200 {
                        // Try to read error body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        #if DEBUG
                        print("[AIService] Responses API error: HTTP \(httpResponse.statusCode) - \(errorBody)")
                        #endif

                        // Attempt fallback if enabled
                        if config.autoFallback {
                            #if DEBUG
                            print("[AIService] Falling back to GPT-4o...")
                            #endif
                            // Notify user of fallback with visible warning
                            continuation.yield(.content("⚠️ *GPT-5.2 is currently unavailable. Using GPT-4o (web search not available).*\n\n"))
                            // Notify job manager of fallback for accurate model tracking
                            let fallbackConfig = config.withFallback()
                            continuation.yield(.fallbackOccurred(modelId: fallbackConfig.model, webSearchEnabled: fallbackConfig.webSearchEnabled))

                            let fallbackService = AIService(configuration: fallbackConfig)
                            for try await event in fallbackService.callOpenAIStreaming(prompt: prompt) {
                                continuation.yield(event)
                            }
                            continuation.finish()
                            return
                        }

                        continuation.finish(throwing: AIError.apiError("HTTP \(httpResponse.statusCode): \(errorBody.prefix(200))"))
                        return
                    }

                    // Parse SSE stream for Responses API
                    // Events: response.output_text.delta, response.output_text.done,
                    // response.web_search_call.* (when web search is enabled), etc.
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if jsonString == "[DONE]" {
                                break
                            }

                            if let data = jsonString.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let eventType = json["type"] as? String {

                                // Handle text delta events
                                if eventType == "response.output_text.delta" {
                                    if let delta = json["delta"] as? String {
                                        continuation.yield(.content(delta))
                                    }
                                }
                                // Also check for content_part deltas (alternate format)
                                else if eventType == "response.content_part.delta" {
                                    if let delta = json["delta"] as? [String: Any],
                                       let text = delta["text"] as? String {
                                        continuation.yield(.content(text))
                                    }
                                }
                                #if DEBUG
                                // Log web search events for debugging and transparency
                                // SSE events: response.web_search_call.in_progress, .searching, .completed
                                // With include[] parameter, we also get sources and results data
                                if eventType.hasPrefix("response.web_search_call") {
                                    print("[AIService] 🔍 Web search event: \(eventType)")

                                    // Log search queries if available
                                    if let queries = json["queries"] as? [String] {
                                        print("[AIService] 🔍 Search queries: \(queries)")
                                    }

                                    // Log search status details if available
                                    if let status = json["status"] as? String {
                                        print("[AIService] 🔍 Search status: \(status)")
                                    }

                                    // Log sources if available (from action.sources)
                                    if let action = json["action"] as? [String: Any],
                                       let sources = action["sources"] as? [[String: Any]] {
                                        print("[AIService] 🔍 Sources: \(sources.count) consulted")
                                    }

                                    // Log results count if available (from results)
                                    if let results = json["results"] as? [[String: Any]] {
                                        print("[AIService] 🔍 Results: \(results.count) returned")
                                    }
                                }
                                #endif
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    #if DEBUG
                    print("[AIService] Responses API stream error: \(error)")
                    #endif

                    // Attempt fallback on error if enabled
                    if config.autoFallback {
                        #if DEBUG
                        print("[AIService] Falling back to GPT-4o after error...")
                        #endif
                        do {
                            // Notify user of fallback with visible warning
                            continuation.yield(.content("⚠️ *GPT-5.2 is currently unavailable. Using GPT-4o (web search not available).*\n\n"))
                            // Notify job manager of fallback for accurate model tracking
                            let fallbackConfig = config.withFallback()
                            continuation.yield(.fallbackOccurred(modelId: fallbackConfig.model, webSearchEnabled: fallbackConfig.webSearchEnabled))

                            let fallbackService = AIService(configuration: fallbackConfig)
                            for try await event in fallbackService.callOpenAIStreaming(prompt: prompt) {
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                        return
                    }

                    continuation.finish(throwing: AIError.networkError(error))
                }
            }
        }
    }

    // MARK: - Chat Completions API (GPT-4o)

    /// Stream using the Chat Completions API for GPT-4o (proven stable fallback)
    private func callChatCompletionsStreaming(prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard !config.apiKey.isEmpty else {
                    continuation.finish(throwing: AIError.noAPIKey)
                    return
                }

                let trimmedPrompt = String(prompt.prefix(config.maxInputChars))

                guard let url = URL(string: config.endpoint) else {
                    continuation.finish(throwing: AIError.invalidResponse)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                // Build Chat Completions API request body
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

                    #if DEBUG
                    print("[AIService] Chat Completions request to \(config.endpoint) with model \(config.model)")
                    #endif

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: AIError.invalidResponse)
                        return
                    }

                    // Parse SSE stream for Chat Completions
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
                                continuation.yield(.content(content))
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

    private func callOpenAI(prompt: String) async throws -> NonStreamingResult {
        switch config.provider {
        case .gpt5_2:
            return try await callResponsesAPI(prompt: prompt)
        case .gpt4o:
            return try await callChatCompletionsAPI(prompt: prompt)
        }
    }

    /// Non-streaming Responses API call for GPT-5.2
    private func callResponsesAPI(prompt: String) async throws -> NonStreamingResult {
        guard !config.apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        let trimmedPrompt = String(prompt.prefix(config.maxInputChars))

        guard let url = URL(string: config.endpoint) else {
            throw AIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": config.model,
            "input": trimmedPrompt,
            "max_output_tokens": config.maxOutputTokens,
            "stream": false
        ]

        // Add reasoning configuration for GPT-5.2
        // Note: summary parameter requires organization verification, so we omit it
        body["reasoning"] = [
            "effort": config.reasoningEffort
        ]

        // Add web search tool if enabled
        // Using search_context_size "high" for maximum context from search results
        if config.webSearchEnabled {
            body["tools"] = [
                [
                    "type": "web_search",
                    "search_context_size": "high"
                ]
            ]
            // Request detailed search information in the response:
            // - action.sources: URLs of websites consulted for transparency
            // - results: Full search results data for richer context
            body["include"] = [
                "web_search_call.action.sources",
                "web_search_call.results"
            ]
        }

        if let temp = config.temperature {
            body["temperature"] = temp
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let content = try await performResponsesAPIRequest(request: request)
            return NonStreamingResult(
                content: content,
                modelId: config.model,
                usedWebSearch: config.webSearchEnabled
            )
        } catch {
            // Attempt fallback if enabled
            if config.autoFallback {
                #if DEBUG
                print("[AIService] Responses API failed, falling back to GPT-4o: \(error)")
                #endif
                // Fallback returns NonStreamingResult with correct fallback model info
                let fallbackService = AIService(configuration: config.withFallback())
                return try await fallbackService.callOpenAI(prompt: prompt)
            }
            throw error
        }
    }

    /// Non-streaming Chat Completions API call for GPT-4o
    private func callChatCompletionsAPI(prompt: String) async throws -> NonStreamingResult {
        guard !config.apiKey.isEmpty else {
            throw AIError.noAPIKey
        }

        let trimmedPrompt = String(prompt.prefix(config.maxInputChars))

        guard let url = URL(string: config.endpoint) else {
            throw AIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "user", "content": trimmedPrompt]
            ],
            "max_tokens": config.maxOutputTokens
        ]

        if let temp = config.temperature {
            body["temperature"] = temp
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let content = try await performChatCompletionsRequest(request: request)
        return NonStreamingResult(
            content: content,
            modelId: config.model,
            usedWebSearch: config.webSearchEnabled
        )
    }

    // MARK: - Chat Completions Request Handling

    private func performChatCompletionsRequest(request: URLRequest, retries: Int = 3) async throws -> String {
        var lastError: Error?

        for attempt in 0..<retries {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    return try parseChatCompletionsResponse(data: data)
                } else if httpResponse.statusCode == 429 {
                    let delay = pow(2.0, Double(attempt)) * 1.0
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
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

    private func parseChatCompletionsResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Responses API Request Handling

    private func performResponsesAPIRequest(request: URLRequest, retries: Int = 3) async throws -> String {
        var lastError: Error?

        for attempt in 0..<retries {
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AIError.invalidResponse
                }

                #if DEBUG
                print("[AIService] Responses API HTTP \(httpResponse.statusCode)")
                #endif

                if httpResponse.statusCode == 200 {
                    return try parseResponsesAPIResponse(data: data)
                } else if httpResponse.statusCode == 429 {
                    let delay = pow(2.0, Double(attempt)) * 1.0
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        throw AIError.apiError(message)
                    }
                    #if DEBUG
                    if let bodyString = String(data: data, encoding: .utf8) {
                        print("[AIService] Responses API error body: \(bodyString.prefix(500))")
                    }
                    #endif
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

    /// Parse Responses API response
    /// Response structure: { output: [{ type: "message", content: [{ type: "output_text", text: "..." }] }] }
    /// When include: ["web_search_call.action.sources"] is set, web search sources are also included
    private func parseResponsesAPIResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        #if DEBUG
        print("[AIService] Parsing Responses API response...")
        #endif

        // Check for error in response
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AIError.apiError(message)
        }

        // Parse output array
        guard let output = json["output"] as? [[String: Any]] else {
            throw AIError.invalidResponse
        }

        // Collect all text from output items
        var resultText = ""
        for item in output {
            let itemType = item["type"] as? String

            #if DEBUG
            // Log web search calls if present (when include parameter was used)
            // With include: ["web_search_call.action.sources", "web_search_call.results"]
            // we get both source URLs and full search results
            if itemType == "web_search_call" {
                print("[AIService] 🔍 Web search was performed")

                // Log sources from action.sources
                if let action = item["action"] as? [String: Any],
                   let sources = action["sources"] as? [[String: Any]] {
                    print("[AIService] 🔍 Sources consulted: \(sources.count)")
                    for source in sources.prefix(3) {
                        if let url = source["url"] as? String,
                           let title = source["title"] as? String {
                            print("[AIService]    - \(title): \(url)")
                        }
                    }
                }

                // Log results from web_search_call.results if present
                if let results = item["results"] as? [[String: Any]] {
                    print("[AIService] 🔍 Search results returned: \(results.count)")
                    for result in results.prefix(3) {
                        if let title = result["title"] as? String {
                            let snippet = (result["snippet"] as? String)?.prefix(80) ?? ""
                            print("[AIService]    Result: \(title)")
                            if !snippet.isEmpty {
                                print("[AIService]      \(snippet)...")
                            }
                        }
                    }
                }
            }
            #endif

            // Each output item can have content array
            if let content = item["content"] as? [[String: Any]] {
                for part in content {
                    if part["type"] as? String == "output_text",
                       let text = part["text"] as? String {
                        resultText += text
                    }
                }
            }
            // Or it might be a direct text field
            else if let text = item["text"] as? String {
                resultText += text
            }
        }

        if resultText.isEmpty {
            // Try alternate response structure (SDK convenience field)
            if let outputText = json["output_text"] as? String {
                resultText = outputText
            }
        }

        guard !resultText.isEmpty else {
            #if DEBUG
            print("[AIService] Could not parse Responses API output: \(json)")
            #endif
            throw AIError.invalidResponse
        }

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Actual model used for this job (updated on fallback)
        var modelId: String
        var webSearchEnabled: Bool

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
        history: [(question: String, answer: String)] = [],
        priorAnalysisContext: (type: AnalysisType, result: String)? = nil
    ) -> UUID {
        let jobId = UUID()
        jobs[jobId] = Job(
            id: jobId,
            status: .queued,
            modelId: aiService.modelId,
            webSearchEnabled: aiService.isWebSearchEnabled
        )

        Task {
            await runJobStreaming(
                id: jobId,
                type: type,
                text: text,
                context: context,
                chapterContext: chapterContext,
                question: question,
                history: history,
                priorAnalysisContext: priorAnalysisContext
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
        history: [(question: String, answer: String)],
        priorAnalysisContext: (type: AnalysisType, result: String)? = nil
    ) async {
        jobs[id]?.status = .running

        // Handle comment type specially (no AI call needed)
        if type == .comment {
            jobs[id]?.status = .completed
            jobs[id]?.result = question ?? ""
            return
        }

        // Build the prompt based on analysis type
        let prompt = buildPrompt(type: type, text: text, context: context, chapterContext: chapterContext, question: question, history: history, priorAnalysisContext: priorAnalysisContext)

        jobs[id]?.status = .streaming

        do {
            // Use array of chunks for more efficient memory allocation
            // Joining at intervals reduces reallocation overhead
            var chunks: [String] = []
            chunks.reserveCapacity(100)  // Pre-allocate for typical response
            var updateCounter = 0

            for try await event in aiService.callOpenAIStreaming(prompt: prompt) {
                switch event {
                case .content(let chunk):
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

                case .fallbackOccurred(let modelId, let webSearchEnabled):
                    // Update job with actual model used after fallback
                    await MainActor.run {
                        jobs[id]?.modelId = modelId
                        jobs[id]?.webSearchEnabled = webSearchEnabled
                    }
                    #if DEBUG
                    print("[AnalysisJobManager] Job \(id.uuidString.prefix(8)) fallback to \(modelId)")
                    #endif
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

    /// Get web search guidance specific to each analysis type
    /// These instructions ensure searches target SPECIFIC content from the selected text,
    /// focusing on exact phrases, terminology, and deeper meanings - NOT general book info
    private func webSearchGuidance(for type: AnalysisType) -> String {
        switch type {
        case .factCheck:
            return """

            **Web Search Available - Use Strategically:**
            Search for EXACT PHRASES and specific terms from the selected text:
            - Use quotation marks: "exact phrase from text" + definition OR meaning OR context
            - Search verbatim: specific names, dates, statistics, technical terms as they appear
            - Verify claims: historical events, scientific findings, data points mentioned
            - Find original sources: if a study or reference is cited, search for the primary source

            Search Query Examples:
            - Good: "adaptive unconscious" psychology definition
            - Good: "availability heuristic" Kahneman research
            - Bad: Thinking Fast and Slow book summary
            - Bad: Daniel Kahneman biography

            Focus on the SPECIFIC CONTENT in the selection - what terms mean, whether claims are accurate.
            """

        case .discussion:
            return """

            **Web Search Available - Use Strategically:**
            Search for DEEPER MEANING of specific phrases, concepts, and ideas in the selection:
            - Use quotation marks: "exact phrase" + philosophical analysis OR academic interpretation
            - Search etymology: origin and evolution of specific terms used
            - Find scholarly perspectives: how academics discuss these exact concepts
            - Explore intellectual history: where these ideas originated and developed

            Search Query Examples:
            - Good: "system 1 and system 2" cognitive psychology theory
            - Good: "bounded rationality" Herbert Simon original meaning
            - Good: "the map is not the territory" Korzybski philosophy
            - Bad: best books about decision making
            - Bad: what is behavioral economics about

            Search for what the EXACT WORDS mean and their intellectual context, not general book themes.
            If the passage uses specialized vocabulary, include the relevant domain (psychology, philosophy, etc.).
            """

        case .keyPoints:
            return """

            **Web Search Available - Use Strategically:**
            Search only when a key point contains terms or concepts needing clarification:
            - Define technical terms: "term from text" + definition in context
            - Clarify references: specific studies, experiments, or examples mentioned
            - Verify findings: particular claims, statistics, or research results cited
            - Explain jargon: specialized vocabulary in its proper domain context

            Search Query Examples:
            - Good: "priming effect" psychology experiments
            - Good: "anchoring bias" Tversky Kahneman 1974 study
            - Bad: cognitive bias overview
            - Bad: psychology research methods

            Search for definitions and context of SPECIFIC terms used in key points, not general topics.
            """

        case .argumentMap:
            return """

            **Web Search Available - Use Strategically:**
            Search to validate and trace SPECIFIC evidence and claims in the argument:
            - Find original sources: if studies or data are cited, locate the primary research
            - Verify premises: check whether specific factual claims are accurate and current
            - Check for updates: has the cited evidence been replicated, revised, or contested?
            - Clarify logic: definitions of reasoning patterns or logical frameworks mentioned

            Search Query Examples:
            - Good: "Linda problem" conjunction fallacy Tversky Kahneman 1983
            - Good: "prospect theory" Nobel Prize research findings
            - Good: "replication crisis" psychology specific study mentioned
            - Bad: logical fallacies list
            - Bad: how to analyze arguments

            Search for the SPECIFIC evidence, studies, and citations in the argument - not general critiques.
            """

        case .counterpoints:
            return """

            **Web Search Available - Use Strategically:**
            Search for intellectual challenges to the SPECIFIC claims in the selection:
            - Find counterarguments: "exact claim from text" + criticism OR counterargument
            - Search for rebuttals: specific studies or evidence that contradict the claims
            - Alternative interpretations: how other scholars interpret the same concepts
            - Updated findings: research that challenges or refines the original claims

            Search Query Examples:
            - Good: "heuristics and biases" Gigerenzer criticism
            - Good: "dual process theory" alternative models challenges
            - Good: "loss aversion" replication failures recent research
            - Bad: is Kahneman right or wrong
            - Bad: problems with behavioral economics

            Search for SUBSTANTIVE challenges to what's IN the selection, using the exact phrasing.
            """

        case .customQuestion:
            return """

            **Web Search Available - Use Strategically:**
            Search based on the user's question combined with SPECIFIC content from the selection:
            - Answer factual questions: search for exact terms or claims the user asks about
            - Clarify meaning: if the question asks "what does X mean," search for that exact phrase
            - Find connections: relate specific phrases from the text to the user's question
            - Get current info: if the question requires up-to-date data, search for recent sources

            Search Query Examples:
            - Good: [key phrase from selection] + [term from user's question]
            - Good: "exact quote user asks about" + explanation
            - Bad: general search unrelated to the selected text
            - Bad: book summary or author information (unless explicitly asked)

            Combine the user's question with EXACT phrases from the selected text in your searches.
            """

        case .comment:
            return ""  // Comments don't use AI
        }
    }

    private func buildPrompt(
        type: AnalysisType,
        text: String,
        context: String,
        chapterContext: String?,
        question: String?,
        history: [(question: String, answer: String)],
        priorAnalysisContext: (type: AnalysisType, result: String)? = nil
    ) -> String {
        let webGuidance = aiService.isWebSearchEnabled ? webSearchGuidance(for: type) : ""

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
            \(webGuidance)
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
            \(webGuidance)
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
            \(webGuidance)
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
            \(webGuidance)
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
            \(webGuidance)
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

            // Include prior analysis context if user is asking a follow-up about a previous analysis
            // This enables context-aware follow-ups like: "The fact check mentioned X - tell me more about Y"
            // For comments: the "result" is actually the user's comment text (not AI-generated)
            if let prior = priorAnalysisContext {
                if prior.type == AnalysisType.comment {
                    prompt += """

                **User's Previous Comment:**
                The user added this personal note about the selected text:
                \(prior.result)
                """
                } else {
                    prompt += """

                **Previous AI Analysis (\(prior.type.displayName)):**
                The user was viewing this analysis when they asked their question:
                \(prior.result)
                """
                }
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
            - The previous AI analysis (if provided)
            - The conversation history (if any)

            Be thorough but concise. Use examples when helpful.
            \(webGuidance)
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
