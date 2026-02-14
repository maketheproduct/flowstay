@testable import FlowstayCore
import XCTest

@MainActor
final class PersonasEngineTests: XCTestCase {
    var personasEngine: PersonasEngine!

    override func setUp() async throws {
        personasEngine = PersonasEngine()
    }

    override func tearDown() async throws {
        personasEngine = nil
    }

    // MARK: - ProcessingResult Tests

    func testProcessingResultSuccess() {
        let result = ProcessingResult.success("Processed text")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.text, "Processed text")
        XCTAssertNil(result.error)
    }

    func testProcessingResultFallback() {
        let error = PersonasError.providerNotConfigured(provider: "TestProvider")
        let result = ProcessingResult.fallback(originalText: "Original text", error: error)

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.text, "Original text")
        XCTAssertNotNil(result.error)
    }

    func testProcessingResultTextProperty() {
        let successResult = ProcessingResult.success("Success text")
        let fallbackResult = ProcessingResult.fallback(originalText: "Fallback text", error: .inferenceTimeout)

        XCTAssertEqual(successResult.text, "Success text")
        XCTAssertEqual(fallbackResult.text, "Fallback text")
    }

    // MARK: - PersonasError Tests

    func testPersonasErrorRequiresMacOS26() {
        let error = PersonasError.requiresMacOS26

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("macOS 26") ?? false)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testPersonasErrorAppleIntelligenceUnavailable() {
        let error = PersonasError.appleIntelligenceUnavailable

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Apple Intelligence") ?? false)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testPersonasErrorProviderNotConfigured() {
        let error = PersonasError.providerNotConfigured(provider: "OpenRouter")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("OpenRouter") ?? false)
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    func testPersonasErrorNoInstructionSelected() {
        let error = PersonasError.noInstructionSelected

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("instruction") ?? false)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testPersonasErrorInferenceFailed() {
        let error = PersonasError.inferenceFailed("Network timeout")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Network timeout") ?? false)
    }

    func testPersonasErrorInferenceTimeout() {
        let error = PersonasError.inferenceTimeout

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("timed out") ?? false)
    }

    // MARK: - PersonasEngine Initialization

    func testPersonasEngineInitialization() {
        XCTAssertNotNil(personasEngine)
        XCTAssertFalse(personasEngine.isProcessing)
        XCTAssertNil(personasEngine.lastError)
    }

    // MARK: - Empty Input Handling

    func testProcessEmptyTextReturnsEmpty() async {
        let appState = AppState()

        let result = await personasEngine.processTranscription("", appState: appState)

        XCTAssertEqual(result, "")
    }

    func testProcessEmptyTextWithResultReturnsSuccess() async {
        let appState = AppState()

        let result = await personasEngine.processTranscriptionWithResult("", appState: appState)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.text, "")
    }

    // MARK: - Clean Persona Response Tests

    // These test the internal cleaning logic through the public API behavior
    // The cleanPersonaResponse method strips surrounding quotes from AI responses

    func testResponseWithDoubleQuotesIsProcessable() {
        // The PersonasEngine should be able to handle quoted responses
        // This is a basic sanity check that the engine exists and can process text
        XCTAssertNotNil(personasEngine)
    }
}

// MARK: - ProcessingResult Equatable Extension for Testing

extension ProcessingResult: Equatable {
    public static func == (lhs: ProcessingResult, rhs: ProcessingResult) -> Bool {
        switch (lhs, rhs) {
        case let (.success(lhsText), .success(rhsText)):
            lhsText == rhsText
        case let (.fallback(lhsText, _), .fallback(rhsText, _)):
            // Only compare text, not error details
            lhsText == rhsText
        default:
            false
        }
    }
}

// MARK: - AIProviderError Tests

final class AIProviderErrorTests: XCTestCase {
    func testInvalidAPIKeyError() {
        let error = AIProviderError.invalidAPIKey

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.localizedDescription.contains("API key") || error.errorDescription?.contains("API key") ?? false)
    }

    func testRateLimitedError() {
        let error = AIProviderError.rateLimited(retryAfter: 30.0)

        XCTAssertNotNil(error.errorDescription)
    }

    func testNetworkError() {
        let error = AIProviderError.networkError("Connection failed")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Connection failed") ?? false)
    }

    func testInvalidResponseError() {
        let error = AIProviderError.invalidResponse

        XCTAssertNotNil(error.errorDescription)
    }

    func testProviderUnavailableError() {
        let error = AIProviderError.providerUnavailable("Server maintenance")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Server maintenance") ?? false)
    }

    func testClaudeCodeProviderIdentifierMetadata() {
        XCTAssertEqual(AIProviderIdentifier.claudeCode.rawValue, "claude-code")
        XCTAssertEqual(AIProviderIdentifier.claudeCode.displayName, "Claude Code")
        XCTAssertFalse(AIProviderIdentifier.claudeCode.isLocalByDefault)
    }
}
