import Foundation
import os

/// Caches OpenRouter models with automatic refresh
@MainActor
public class OpenRouterModelCache: ObservableObject {
    public static let shared = OpenRouterModelCache()

    @Published public private(set) var models: [OpenRouterModel] = []
    @Published public private(set) var lastFetched: Date?
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let cacheKey = "openRouterModelsCache"
    private let cacheDuration: TimeInterval = 3600 // 1 hour
    private let networkService = OpenRouterNetworkService()
    private let logger = Logger(subsystem: "com.flowstay.core", category: "OpenRouterModelCache")

    private init() {
        loadFromDisk()
    }

    /// All free text models, sorted by name
    public var freeModels: [OpenRouterModel] {
        models.filter { $0.isFree && $0.isTextModel }
    }

    /// All paid text models, sorted by name
    public var paidModels: [OpenRouterModel] {
        models.filter { !$0.isFree && $0.isTextModel }
    }

    /// Popular free models (curated list for better UX)
    public var recommendedFreeModels: [OpenRouterModel] {
        let recommendedIds = [
            "meta-llama/llama-3.3-8b-instruct:free",
            "meta-llama/llama-3.2-3b-instruct:free",
            "google/gemma-2-9b-it:free",
            "mistralai/mistral-7b-instruct:free",
            "qwen/qwen-2.5-7b-instruct:free",
        ]
        return recommendedIds.compactMap { id in
            models.first { $0.id == id }
        }
    }

    /// Popular paid models (curated list)
    public var recommendedPaidModels: [OpenRouterModel] {
        let recommendedIds = [
            "anthropic/claude-sonnet-4",
            "openai/gpt-4o",
            "openai/gpt-4o-mini",
            "google/gemini-2.0-flash-001",
            "anthropic/claude-3.5-haiku",
        ]
        return recommendedIds.compactMap { id in
            models.first { $0.id == id }
        }
    }

    /// Check if cache needs refresh
    public var needsRefresh: Bool {
        guard let lastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > cacheDuration
    }

    /// Refresh models if cache is stale
    public func refreshIfNeeded() async {
        guard needsRefresh, !isLoading else { return }
        await refresh()
    }

    /// Force refresh models from API
    public func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        lastError = nil

        logger.info("[ModelCache] Refreshing models...")

        do {
            let fetchedModels = try await networkService.fetchModels()
            models = fetchedModels
            lastFetched = Date()
            saveToDisk()
            let freeModelCount = freeModels.count
            logger.info("[ModelCache] Refreshed \(fetchedModels.count) models (\(freeModelCount) free)")
        } catch {
            logger.error("[ModelCache] Failed to refresh: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }

        isLoading = false
    }

    /// Get a specific model by ID
    public func model(for id: String) -> OpenRouterModel? {
        models.first { $0.id == id }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let cache = CachedModels(models: models, lastFetched: lastFetched ?? Date())
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            let savedModelCount = models.count
            logger.debug("[ModelCache] Saved \(savedModelCount) models to disk")
        }
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(CachedModels.self, from: data)
        else {
            logger.debug("[ModelCache] No cached models found")
            return
        }
        models = cache.models
        lastFetched = cache.lastFetched
        let loadedModelCount = models.count
        logger.info("[ModelCache] Loaded \(loadedModelCount) models from cache (fetched: \(cache.lastFetched))")
    }

    private struct CachedModels: Codable {
        let models: [OpenRouterModel]
        let lastFetched: Date
    }
}
