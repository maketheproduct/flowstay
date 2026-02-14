import Foundation
import FoundationModels

@available(macOS 26, *)
public enum AppleIntelligenceStatus {
    case available
    case notEnabled
    case deviceNotEligible
    case modelNotReady
    case unavailable
}

@available(macOS 26, *)
public struct AppleIntelligenceHelper {
    /// Check if Apple Intelligence is available on this system
    public static func isAvailable() -> Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Get detailed status of Apple Intelligence availability
    public static func getStatus() -> AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.appleIntelligenceNotEnabled):
            .notEnabled
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.modelNotReady):
            .modelNotReady
        case .unavailable:
            .unavailable
        }
    }

    /// Rewrite text using Apple Intelligence Foundation Models
    public static func rewriteText(_ text: String, instruction: String) async throws -> String {
        let session = LanguageModelSession()

        let prompt = """
        \(instruction)

        <instructions>
        Output ONLY the processed text itself, do not acknowledge the request, add quotation marks or anything else. Do not change the language or explain what you're doing
        </instructions>

        Text to process:
        \(text)
        """

        let response = try await session.respond(to: prompt)
        return response.content
    }
}
