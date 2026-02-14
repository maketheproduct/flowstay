import Foundation

/// Protocol defining the contract for AI text rewriting providers
public protocol AIProviderProtocol: Sendable {
    /// Unique identifier for this provider
    var providerId: String { get }

    /// Display name for UI
    var displayName: String { get }

    /// Check if provider is currently available and configured
    func isAvailable() async -> Bool

    /// Get detailed availability status for UI feedback
    func getStatus() async -> AIProviderStatus

    /// Rewrite text using the provider's AI model
    /// - Parameters:
    ///   - text: The input text to rewrite
    ///   - instruction: The persona instruction guiding the rewrite
    ///   - modelId: Optional specific model to use (provider-specific)
    /// - Returns: The rewritten text
    func rewriteText(_ text: String, instruction: String, modelId: String?) async throws -> String
}

/// Availability status for AI providers
public nonisolated enum AIProviderStatus: Sendable, Equatable {
    case available
    case notConfigured(reason: String)
    case unavailable(reason: String)
    case rateLimited(retryAfter: TimeInterval?)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var statusMessage: String {
        switch self {
        case .available:
            return "Ready"
        case let .notConfigured(reason):
            return reason
        case let .unavailable(reason):
            return reason
        case let .rateLimited(retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Try again in \(Int(seconds)) seconds."
            }
            return "Rate limited. Please try again later."
        }
    }
}

/// Errors that can occur with AI providers
public nonisolated enum AIProviderError: LocalizedError, Sendable {
    case notConfigured
    case invalidAPIKey
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case modelNotFound(String)
    case invalidResponse
    case providerUnavailable(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI provider not configured. Please add your API key."
        case .invalidAPIKey:
            return "Invalid API key. Please reconnect your account."
        case let .networkError(message):
            return "Network error: \(message)"
        case let .rateLimited(retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Try again in \(Int(seconds)) seconds."
            }
            return "Rate limited. Please try again later."
        case let .modelNotFound(model):
            return "Model '\(model)' not found."
        case .invalidResponse:
            return "Invalid response from AI provider."
        case let .providerUnavailable(reason):
            return "Provider unavailable: \(reason)"
        case .timeout:
            return "Request timed out. Please try again."
        }
    }
}

/// Known AI provider identifiers
public nonisolated enum AIProviderIdentifier: String, CaseIterable, Sendable {
    case appleIntelligence = "apple-intelligence"
    case openRouter = "openrouter"
    case claudeCode = "claude-code"

    public var displayName: String {
        switch self {
        case .appleIntelligence:
            "Apple Intelligence"
        case .openRouter:
            "OpenRouter"
        case .claudeCode:
            "Claude Code"
        }
    }

    /// Whether this provider is local by default (on-device)
    public var isLocalByDefault: Bool {
        switch self {
        case .appleIntelligence:
            true
        case .openRouter:
            false
        case .claudeCode:
            false
        }
    }
}

/// Processing behavior for Claude Code provider
public nonisolated enum ClaudeCodeProcessingMode: String, CaseIterable, Sendable {
    case rewriteOnly = "rewrite-only"
    case assistant

    public var displayName: String {
        switch self {
        case .rewriteOnly:
            "Rewrite only"
        case .assistant:
            "Assistant"
        }
    }
}
