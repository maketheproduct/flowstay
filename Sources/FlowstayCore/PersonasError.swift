import Foundation

/// Errors that can occur during persona processing
public nonisolated enum PersonasError: LocalizedError, Sendable {
    case requiresMacOS26
    case appleIntelligenceUnavailable
    case providerNotConfigured(provider: String)
    case noInstructionSelected
    case inferenceFailed(String)
    case inferenceTimeout

    public var errorDescription: String? {
        switch self {
        case .requiresMacOS26:
            "Personas require macOS 26 or later."
        case .appleIntelligenceUnavailable:
            "Apple Intelligence is not available on this system."
        case let .providerNotConfigured(provider):
            "\(provider) is not configured."
        case .noInstructionSelected:
            "No persona instruction selected."
        case let .inferenceFailed(message):
            "Persona processing failed: \(message)"
        case .inferenceTimeout:
            "Persona processing timed out."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .requiresMacOS26:
            "Update to macOS 26 to use AI-powered personas."
        case .appleIntelligenceUnavailable:
            "Enable Apple Intelligence in System Settings or upgrade your Mac."
        case let .providerNotConfigured(provider):
            "Configure \(provider) in Settings to use personas."
        case .noInstructionSelected:
            "Select a persona in Settings."
        case .inferenceFailed, .inferenceTimeout:
            "The original transcription will be used."
        }
    }
}
