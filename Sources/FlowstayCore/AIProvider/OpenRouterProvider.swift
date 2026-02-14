import Foundation
import os

/// AI provider implementation for OpenRouter
public final nonisolated class OpenRouterProvider: AIProviderProtocol, Sendable {
    public let providerId = AIProviderIdentifier.openRouter.rawValue
    public let displayName = AIProviderIdentifier.openRouter.displayName

    private let keychainService: KeychainServiceProtocol
    private let networkService: OpenRouterNetworkService
    private let logger = Logger(subsystem: "com.flowstay.core", category: "OpenRouterProvider")

    /// Default free model to use if none selected (updated to current available model)
    public static let defaultFreeModel = "meta-llama/llama-3.2-3b-instruct:free"

    /// Fallback models in order of preference (in case default is unavailable)
    private static let fallbackModels = [
        "meta-llama/llama-3.2-3b-instruct:free",
        "meta-llama/llama-3.3-8b-instruct:free",
        "google/gemma-2-9b-it:free",
        "qwen/qwen-2.5-7b-instruct:free",
        "mistralai/mistral-7b-instruct:free",
    ]

    public init(keychainService: KeychainServiceProtocol = KeychainService.shared) {
        self.keychainService = keychainService
        networkService = OpenRouterNetworkService()
    }

    public func isAvailable() async -> Bool {
        await keychainService.hasAPIKey(for: providerId)
    }

    public func getStatus() async -> AIProviderStatus {
        if await keychainService.hasAPIKey(for: providerId) {
            .available
        } else {
            .notConfigured(reason: "Connect your OpenRouter account")
        }
    }

    public func rewriteText(_ text: String, instruction: String, modelId: String?) async throws -> String {
        guard let apiKey = await keychainService.getAPIKey(for: providerId) else {
            logger.warning("[OpenRouterProvider] No API key configured")
            throw AIProviderError.notConfigured
        }

        // Get valid model ID - try selected, then validate against cache, then use fallback
        let model = await resolveModelId(modelId)

        logger.info("[OpenRouterProvider] Processing text with model: \(model)")

        return try await networkService.chatCompletion(
            apiKey: apiKey,
            model: model,
            systemPrompt: instruction,
            userMessage: text
        )
    }

    /// Resolve model ID to a valid available model
    @MainActor
    private func resolveModelId(_ requestedId: String?) async -> String {
        let cache = OpenRouterModelCache.shared

        // If we have a requested ID, check if it exists in cache
        if let requestedId {
            if cache.model(for: requestedId) != nil {
                return requestedId
            }
            // Model doesn't exist in cache - might be stale, try refresh
            if cache.needsRefresh {
                await cache.refresh()
                if cache.model(for: requestedId) != nil {
                    return requestedId
                }
            }
            logger.warning("[OpenRouterProvider] Requested model '\(requestedId)' not found, falling back")
        }

        // Try fallback models
        for fallback in Self.fallbackModels {
            if cache.model(for: fallback) != nil {
                return fallback
            }
        }

        // If we have any free models, use the first one
        if let firstFree = cache.freeModels.first {
            return firstFree.id
        }

        // Last resort: return default (API will error if invalid, but that's better than nothing)
        return Self.defaultFreeModel
    }
}
