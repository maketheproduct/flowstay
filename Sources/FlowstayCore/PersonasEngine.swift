import Foundation
import os

// MARK: - Processing Result

/// Result type for persona processing that captures both success and fallback scenarios
public nonisolated enum ProcessingResult: Sendable {
    /// Processing succeeded with the transformed text
    case success(String)
    /// Processing failed but returned original text as fallback, with the error that occurred
    case fallback(originalText: String, error: PersonasError)

    /// The text to use (either processed or original)
    public var text: String {
        switch self {
        case let .success(text):
            text
        case let .fallback(originalText, _):
            originalText
        }
    }

    /// Whether processing succeeded
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// The error if processing failed, nil if successful
    public var error: PersonasError? {
        if case let .fallback(_, error) = self { return error }
        return nil
    }
}

/// Main engine for processing transcriptions with personas using AI providers
public class PersonasEngine: ObservableObject {
    @Published public var isProcessing: Bool = false
    @Published public var lastError: PersonasError?

    private let logger = Logger(subsystem: "com.flowstay.core", category: "PersonasEngine")
    private let openRouterProvider = OpenRouterProvider()
    private let claudeCodeProvider = ClaudeCodeProvider()

    public init() {
        logger.info("[PersonasEngine] Initialized (multi-provider backend)")
    }

    // MARK: - Structured Result Processing

    /// Process a transcription and return a structured result indicating success or fallback
    /// This is the preferred API for callers who need to distinguish between success and fallback
    public func processTranscriptionWithResult(
        _ text: String,
        appState: AppState
    ) async -> ProcessingResult {
        await processTranscriptionWithResult(
            text,
            instruction: appState.currentInstruction,
            appState: appState
        )
    }

    /// Process a transcription with an explicit persona instruction.
    /// Use this when caller has already resolved persona context (e.g. app-specific routing).
    public func processTranscriptionWithResult(
        _ text: String,
        instruction: String,
        appState: AppState
    ) async -> ProcessingResult {
        logger.info("[PersonasEngine] Starting persona processing (structured result)")

        guard !text.isEmpty else {
            logger.warning("[PersonasEngine] Empty input text, returning as-is")
            return .success(text)
        }

        isProcessing = true
        lastError = nil
        let providerId = appState.selectedAIProviderId
        let openRouterModelId = appState.selectedOpenRouterModelId
        let claudeCodeModelId = appState.selectedClaudeCodeModelId
        let claudeCodeMode =
            ClaudeCodeProcessingMode(rawValue: appState.claudeCodeProcessingMode) ?? .rewriteOnly
        let soundFeedbackEnabled = appState.soundFeedbackEnabled

        guard !instruction.isEmpty else {
            logger.warning("[PersonasEngine] No instruction selected")
            isProcessing = false
            return .fallback(originalText: text, error: .noInstructionSelected)
        }

        let result: ProcessingResult = switch providerId {
        case AIProviderIdentifier.openRouter.rawValue:
            await processWithOpenRouterResult(
                text: text, instruction: instruction,
                modelId: openRouterModelId, soundFeedbackEnabled: soundFeedbackEnabled
            )
        case AIProviderIdentifier.claudeCode.rawValue:
            await processWithClaudeCodeResult(
                text: text,
                instruction: instruction,
                modelId: claudeCodeModelId,
                mode: claudeCodeMode,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        default:
            await processWithAppleIntelligenceResult(
                text: text, instruction: instruction,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        }

        isProcessing = false
        if let error = result.error {
            lastError = error
        }

        return result
    }

    /// Process a transcription with the selected persona from appState
    /// Returns the processed text, or the original text if processing fails
    public func processTranscription(
        _ text: String,
        appState: AppState
    ) async -> String {
        await processTranscription(
            text,
            instruction: appState.currentInstruction,
            appState: appState
        )
    }

    /// Process a transcription with an explicit persona instruction.
    /// Use this when caller has already resolved persona context (e.g. app-specific routing).
    public func processTranscription(
        _ text: String,
        instruction: String,
        appState: AppState
    ) async -> String {
        logger.info("[PersonasEngine] Starting persona processing")

        guard !text.isEmpty else {
            logger.warning("[PersonasEngine] Empty input text, returning as-is")
            return text
        }

        isProcessing = true
        lastError = nil
        let providerId = appState.selectedAIProviderId
        let openRouterModelId = appState.selectedOpenRouterModelId
        let claudeCodeModelId = appState.selectedClaudeCodeModelId
        let claudeCodeMode =
            ClaudeCodeProcessingMode(rawValue: appState.claudeCodeProcessingMode) ?? .rewriteOnly
        let soundFeedbackEnabled = appState.soundFeedbackEnabled

        guard !instruction.isEmpty else {
            logger.warning("[PersonasEngine] No instruction selected")
            isProcessing = false
            return text
        }

        switch providerId {
        case AIProviderIdentifier.openRouter.rawValue:
            return await processWithOpenRouter(
                text: text,
                instruction: instruction,
                modelId: openRouterModelId,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        case AIProviderIdentifier.claudeCode.rawValue:
            return await processWithClaudeCode(
                text: text,
                instruction: instruction,
                modelId: claudeCodeModelId,
                mode: claudeCodeMode,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        default:
            return await processWithAppleIntelligence(
                text: text,
                instruction: instruction,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        }
    }

    // MARK: - Provider-specific processing

    private func processWithAppleIntelligence(
        text: String,
        instruction: String,
        soundFeedbackEnabled: Bool
    ) async -> String {
        // Check if Apple Intelligence is available
        guard #available(macOS 26, *) else {
            logger.warning("[PersonasEngine] macOS 26+ required for Apple Intelligence")
            lastError = .requiresMacOS26
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            return text
        }

        guard AppleIntelligenceHelper.isAvailable() else {
            logger.warning("[PersonasEngine] Apple Intelligence not available")
            lastError = .appleIntelligenceUnavailable
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: PersonasError.appleIntelligenceUnavailable.errorDescription ?? "Persona failed. Used raw transcription.",
                identifier: "persona-fallback"
            )
            return text
        }

        do {
            let rawResult = try await AppleIntelligenceHelper.rewriteText(text, instruction: instruction)
            let result = cleanPersonaResponse(rawResult, originalText: text)
            logger.info("[PersonasEngine] Apple Intelligence processing successful")
            isProcessing = false
            return result
        } catch {
            logger.error("[PersonasEngine] Apple Intelligence failed: \(error.localizedDescription)")
            lastError = .inferenceFailed(error.localizedDescription)
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: "Persona processing failed: \(error.localizedDescription). Used raw transcription.",
                identifier: "persona-fallback"
            )
            return text
        }
    }

    private func processWithOpenRouter(
        text: String,
        instruction: String,
        modelId: String?,
        soundFeedbackEnabled: Bool
    ) async -> String {
        // Check if OpenRouter is configured
        guard await openRouterProvider.isAvailable() else {
            logger.warning("[PersonasEngine] OpenRouter not configured")
            lastError = .appleIntelligenceUnavailable // Reuse error for now
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: "OpenRouter not connected. Please connect in Settings.",
                identifier: "persona-fallback"
            )
            return text
        }

        do {
            let rawResult = try await openRouterProvider.rewriteText(text, instruction: instruction, modelId: modelId)
            let result = cleanPersonaResponse(rawResult, originalText: text)
            logger.info("[PersonasEngine] OpenRouter processing successful")
            isProcessing = false
            return result
        } catch let error as AIProviderError {
            logger.error("[PersonasEngine] OpenRouter failed: \(error.localizedDescription)")
            lastError = .inferenceFailed(error.errorDescription ?? error.localizedDescription)
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: error.errorDescription ?? "OpenRouter processing failed. Used raw transcription.",
                identifier: "persona-fallback"
            )
            return text
        } catch {
            logger.error("[PersonasEngine] OpenRouter failed: \(error.localizedDescription)")
            lastError = .inferenceFailed(error.localizedDescription)
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: "OpenRouter processing failed: \(error.localizedDescription). Used raw transcription.",
                identifier: "persona-fallback"
            )
            return text
        }
    }

    private func processWithClaudeCode(
        text: String,
        instruction: String,
        modelId: String?,
        mode: ClaudeCodeProcessingMode,
        soundFeedbackEnabled: Bool
    ) async -> String {
        guard await claudeCodeProvider.isAvailable() else {
            logger.warning("[PersonasEngine] Claude Code not configured")
            let message = "Install Claude Code and run `claude login` to use this provider."
            lastError = .providerNotConfigured(provider: "Claude Code")
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: message,
                identifier: "persona-fallback"
            )
            return text
        }

        do {
            let rawResult = try await claudeCodeProvider.rewriteText(
                text,
                instruction: instruction,
                modelId: modelId,
                mode: mode
            )
            let result = cleanPersonaResponse(rawResult, originalText: text)
            logger.info("[PersonasEngine] Claude Code processing successful")
            isProcessing = false
            return result
        } catch let error as AIProviderError {
            logger.error("[PersonasEngine] Claude Code failed: \(error.localizedDescription)")
            lastError = .inferenceFailed(error.errorDescription ?? error.localizedDescription)
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: error.errorDescription ?? "Claude Code processing failed. Used raw transcription.",
                identifier: "persona-fallback"
            )
            return text
        } catch {
            logger.error("[PersonasEngine] Claude Code failed: \(error.localizedDescription)")
            lastError = .inferenceFailed(error.localizedDescription)
            isProcessing = false
            if soundFeedbackEnabled {
                SoundManager.shared.playError()
            }
            NotificationManager.shared.sendNotification(
                title: "Persona not applied",
                body: "Claude Code processing failed: \(error.localizedDescription). Used raw transcription.",
                identifier: "persona-fallback"
            )
            return text
        }
    }

    // MARK: - Result-returning Provider Methods

    private func processWithAppleIntelligenceResult(
        text: String,
        instruction: String,
        soundFeedbackEnabled: Bool
    ) async -> ProcessingResult {
        guard #available(macOS 26, *) else {
            logger.warning("[PersonasEngine] macOS 26+ required for Apple Intelligence")
            handleFallback(error: .requiresMacOS26, message: nil, soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: .requiresMacOS26)
        }

        guard AppleIntelligenceHelper.isAvailable() else {
            logger.warning("[PersonasEngine] Apple Intelligence not available")
            handleFallback(error: .appleIntelligenceUnavailable, message: nil, soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: .appleIntelligenceUnavailable)
        }

        do {
            let rawResult = try await AppleIntelligenceHelper.rewriteText(text, instruction: instruction)
            let result = cleanPersonaResponse(rawResult, originalText: text)
            logger.info("[PersonasEngine] Apple Intelligence processing successful")
            return .success(result)
        } catch {
            let personaError = PersonasError.inferenceFailed(error.localizedDescription)
            logger.error("[PersonasEngine] Apple Intelligence failed: \(error.localizedDescription)")
            handleFallback(error: personaError, message: error.localizedDescription, soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: personaError)
        }
    }

    private func processWithOpenRouterResult(
        text: String,
        instruction: String,
        modelId: String?,
        soundFeedbackEnabled: Bool
    ) async -> ProcessingResult {
        guard await openRouterProvider.isAvailable() else {
            logger.warning("[PersonasEngine] OpenRouter not configured")
            let error = PersonasError.providerNotConfigured(provider: "OpenRouter")
            handleFallback(error: error, message: "Please connect in Settings.", soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: error)
        }

        do {
            let rawResult = try await openRouterProvider.rewriteText(text, instruction: instruction, modelId: modelId)
            let result = cleanPersonaResponse(rawResult, originalText: text)
            logger.info("[PersonasEngine] OpenRouter processing successful")
            return .success(result)
        } catch let error as AIProviderError {
            let personaError = PersonasError.inferenceFailed(error.errorDescription ?? error.localizedDescription)
            logger.error("[PersonasEngine] OpenRouter failed: \(error.localizedDescription)")
            handleFallback(error: personaError, message: error.errorDescription, soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: personaError)
        } catch {
            let personaError = PersonasError.inferenceFailed(error.localizedDescription)
            logger.error("[PersonasEngine] OpenRouter failed: \(error.localizedDescription)")
            handleFallback(error: personaError, message: error.localizedDescription, soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: personaError)
        }
    }

    private func processWithClaudeCodeResult(
        text: String,
        instruction: String,
        modelId: String?,
        mode: ClaudeCodeProcessingMode,
        soundFeedbackEnabled: Bool
    ) async -> ProcessingResult {
        guard await claudeCodeProvider.isAvailable() else {
            logger.warning("[PersonasEngine] Claude Code not configured")
            let error = PersonasError.providerNotConfigured(provider: "Claude Code")
            handleFallback(
                error: error,
                message: "Install Claude Code and run `claude login` to use this provider.",
                soundFeedbackEnabled: soundFeedbackEnabled
            )
            return .fallback(originalText: text, error: error)
        }

        do {
            let rawResult = try await claudeCodeProvider.rewriteText(
                text,
                instruction: instruction,
                modelId: modelId,
                mode: mode
            )
            let result = cleanPersonaResponse(rawResult, originalText: text)
            logger.info("[PersonasEngine] Claude Code processing successful")
            return .success(result)
        } catch let error as AIProviderError {
            let personaError = PersonasError.inferenceFailed(error.errorDescription ?? error.localizedDescription)
            logger.error("[PersonasEngine] Claude Code failed: \(error.localizedDescription)")
            handleFallback(error: personaError, message: error.errorDescription, soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: personaError)
        } catch {
            let personaError = PersonasError.inferenceFailed(error.localizedDescription)
            logger.error("[PersonasEngine] Claude Code failed: \(error.localizedDescription)")
            handleFallback(error: personaError, message: error.localizedDescription, soundFeedbackEnabled: soundFeedbackEnabled)
            return .fallback(originalText: text, error: personaError)
        }
    }

    /// Helper to handle fallback notifications and sounds consistently
    private func handleFallback(error: PersonasError, message: String?, soundFeedbackEnabled: Bool) {
        if soundFeedbackEnabled {
            SoundManager.shared.playError()
        }
        let body = message ?? error.errorDescription ?? "Persona processing failed. Used raw transcription."
        NotificationManager.shared.sendNotification(
            title: "Persona not applied",
            body: body,
            identifier: "persona-fallback"
        )
    }

    // MARK: - Response Cleaning

    /// Clean persona response - only strip surrounding quotes if present
    /// Trust the explicit prompt instructions and persona directives
    private func cleanPersonaResponse(_ response: String, originalText _: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // ONLY strip surrounding quotes if the entire response is wrapped
        let leftDoubleQuote = "\u{201C}" // "
        let rightDoubleQuote = "\u{201D}" // "
        let leftSingleQuote = "\u{2018}" // '
        let rightSingleQuote = "\u{2019}" // '

        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) ||
            (cleaned.hasPrefix(leftDoubleQuote) && cleaned.hasSuffix(rightDoubleQuote)) ||
            (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) ||
            (cleaned.hasPrefix(leftSingleQuote) && cleaned.hasSuffix(rightSingleQuote))
        {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }
}
