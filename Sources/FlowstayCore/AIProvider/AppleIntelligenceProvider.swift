import Foundation

/// AI provider wrapper for Apple Intelligence (macOS 26+)
@available(macOS 26, *)
public struct AppleIntelligenceProvider: AIProviderProtocol {
    public let providerId = AIProviderIdentifier.appleIntelligence.rawValue
    public let displayName = AIProviderIdentifier.appleIntelligence.displayName

    public init() {}

    public func isAvailable() async -> Bool {
        AppleIntelligenceHelper.isAvailable()
    }

    public func getStatus() async -> AIProviderStatus {
        switch AppleIntelligenceHelper.getStatus() {
        case .available:
            .available
        case .notEnabled:
            .notConfigured(reason: "Enable Apple Intelligence in System Settings")
        case .deviceNotEligible:
            .unavailable(reason: "This Mac doesn't support Apple Intelligence")
        case .modelNotReady:
            .unavailable(reason: "Apple Intelligence model is downloading")
        case .unavailable:
            .unavailable(reason: "Apple Intelligence is unavailable")
        }
    }

    public func rewriteText(_ text: String, instruction: String, modelId: String?) async throws -> String {
        // modelId is ignored for Apple Intelligence - uses system default
        try await AppleIntelligenceHelper.rewriteText(text, instruction: instruction)
    }
}
