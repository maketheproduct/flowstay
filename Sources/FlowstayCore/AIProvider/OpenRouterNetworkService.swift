import Foundation
import os

/// Network service for OpenRouter API interactions
public final nonisolated class OpenRouterNetworkService: Sendable {
    // SAFETY: This URL is a compile-time constant that is guaranteed to be valid.
    // Using force-unwrap is safe here because the string literal will always parse successfully.
    // swiftlint:disable:next force_unwrapping
    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    private let session: URLSession
    private let logger = Logger(subsystem: "com.flowstay.core", category: "OpenRouterNetwork")

    public init() {
        // Use ephemeral sessions to avoid persisting auth-related artifacts
        // (cookies/cache) to disk for privacy and security.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Fetch available models from OpenRouter
    public func fetchModels() async throws -> [OpenRouterModel] {
        let url = Self.baseURL.appendingPathComponent("models")

        logger.info("[OpenRouter] Fetching models from \(url.absoluteString)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("[OpenRouter] Failed to fetch models: HTTP \(httpResponse.statusCode)")
            throw AIProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let modelsResponse = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)

        // Sort: free models first, then by name
        let sortedModels = modelsResponse.data.sorted { lhs, rhs in
            if lhs.isFree != rhs.isFree {
                return lhs.isFree
            }
            return lhs.name < rhs.name
        }

        logger.info("[OpenRouter] Fetched \(sortedModels.count) models (\(sortedModels.count(where: { $0.isFree })) free)")

        return sortedModels
    }

    /// Send chat completion request
    public func chatCompletion(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        let url = Self.baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://flowstay.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Flowstay macOS Dictation App", forHTTPHeaderField: "X-Title")

        // Build system prompt with explicit output instructions
        let fullSystemPrompt = """
        \(systemPrompt)

        Output ONLY the processed text itself, do not acknowledge the request, add quotation marks or anything else. Do not change the language or explain what you're doing.
        """

        let chatRequest = OpenRouterChatRequest(
            model: model,
            messages: [
                OpenRouterMessage(role: "system", content: fullSystemPrompt),
                OpenRouterMessage(role: "user", content: userMessage),
            ],
            maxTokens: 4096,
            temperature: 0.3
        )

        request.httpBody = try JSONEncoder().encode(chatRequest)

        logger.info("[OpenRouter] Sending chat completion request to model: \(model)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            logger.error("[OpenRouter] Invalid API key")
            throw AIProviderError.invalidAPIKey
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            logger.warning("[OpenRouter] Rate limited, retry after: \(retryAfter ?? 0)")
            throw AIProviderError.rateLimited(retryAfter: retryAfter)
        case 400 ... 499:
            // Try to parse error message
            if let errorResponse = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data),
               let message = errorResponse.error?.message
            {
                logger.error("[OpenRouter] Client error: \(message)")
                throw AIProviderError.networkError(message)
            }
            logger.error("[OpenRouter] Client error: HTTP \(httpResponse.statusCode)")
            throw AIProviderError.networkError("HTTP \(httpResponse.statusCode)")
        case 500 ... 599:
            logger.error("[OpenRouter] Server error: HTTP \(httpResponse.statusCode)")
            throw AIProviderError.providerUnavailable("OpenRouter server error")
        default:
            logger.error("[OpenRouter] Unexpected status: HTTP \(httpResponse.statusCode)")
            throw AIProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        let chatResponse = try JSONDecoder().decode(OpenRouterChatResponse.self, from: data)

        guard let content = chatResponse.choices.first?.message.content else {
            logger.error("[OpenRouter] No content in response")
            throw AIProviderError.invalidResponse
        }

        if let usage = chatResponse.usage {
            logger.info("[OpenRouter] Tokens used - prompt: \(usage.promptTokens ?? 0), completion: \(usage.completionTokens ?? 0)")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exchange OAuth code for API key
    public func exchangeCodeForKey(code: String, codeVerifier: String) async throws -> String {
        let url = Self.baseURL.appendingPathComponent("auth/keys")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "code": code,
            "code_verifier": codeVerifier,
            "code_challenge_method": "S256",
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("[OpenRouter] Exchanging OAuth code for API key")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("[OpenRouter] Failed to exchange code: HTTP \(httpResponse.statusCode)")

            // Try to parse error
            if let errorResponse = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data),
               let message = errorResponse.error?.message
            {
                throw AIProviderError.networkError(message)
            }

            throw AIProviderError.invalidAPIKey
        }

        let keyResponse = try JSONDecoder().decode(OpenRouterKeyResponse.self, from: data)

        logger.info("[OpenRouter] Successfully obtained API key")

        return keyResponse.key
    }
}
