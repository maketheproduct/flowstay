import Foundation
import os

/// AI provider implementation for OpenRouter
public final nonisolated class OpenRouterProvider: AIProviderProtocol, Sendable {
    public let providerId = AIProviderIdentifier.openRouter.rawValue
    public let displayName = AIProviderIdentifier.openRouter.displayName

    private let keychainService: KeychainServiceProtocol
    private let networkService: OpenRouterNetworkService
    private let logger = Logger(subsystem: "com.flowstay.core", category: "OpenRouterProvider")

    /// Last-resort model ID when the model list hasn't loaded.
    public static let defaultFreeModel = "google/gemma-4-31b-it:free"

    /// Providers whose free models are general-purpose chat models, in order of preference.
    /// Free models come and go often, so the newest one from these providers is picked at run time.
    private static let preferredFreeProviders = ["google/gemma", "meta-llama/", "mistralai/", "qwen/", "openai/"]

    /// Free models built for something other than rewriting text.
    private static let unsuitableModelMarkers = ["code", "coder", "safety", "guard", "embed", "vision", "reasoning"]

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

        return Self.preferredFreeModel(from: cache.freeModels)?.id ?? Self.defaultFreeModel
    }

    /// Picks the newest general-purpose free model, preferring well-known providers.
    static func preferredFreeModel(from freeModels: [OpenRouterModel]) -> OpenRouterModel? {
        let suitable = freeModels.filter { model in
            let id = model.id.lowercased()
            return !unsuitableModelMarkers.contains { id.contains($0) }
        }
        let newestFirst = suitable.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        for provider in preferredFreeProviders {
            if let model = newestFirst.first(where: { $0.id.hasPrefix(provider) }) {
                return model
            }
        }
        return newestFirst.first
    }
}
