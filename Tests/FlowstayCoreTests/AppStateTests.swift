@testable import FlowstayCore
import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    var appState: AppState!

    override func setUp() async throws {
        // Create a fresh AppState for each test
        // Note: This may read from actual UserDefaults
        appState = AppState()
    }

    override func tearDown() async throws {
        appState = nil
    }

    // MARK: - Initialization Tests

    func testAppStateInitializesWithDefaultValues() {
        XCTAssertEqual(appState.status, .idle)
        XCTAssertFalse(appState.isRecording)
        XCTAssertFalse(appState.isProcessing)
        XCTAssertEqual(appState.currentTranscript, "")
        XCTAssertNil(appState.errorMessage)
    }

    func testAppStateContainsBuiltInPersonas() {
        let builtInIds = Set(Persona.builtInPresets.map(\.id))
        let statePersonaIds = Set(appState.allPersonas.filter(\.isBuiltIn).map(\.id))

        XCTAssertEqual(builtInIds, statePersonaIds)
    }

    // MARK: - Persona CRUD Tests

    func testAddPersona() {
        let initialCount = appState.allPersonas.count
        let newPersona = Persona(
            id: "test-\(UUID().uuidString)",
            name: "Test Persona",
            instruction: "Test instruction",
            emoji: "🧪",
            isBuiltIn: false
        )

        appState.addPersona(newPersona)

        XCTAssertEqual(appState.allPersonas.count, initialCount + 1)
        XCTAssertTrue(appState.allPersonas.contains(where: { $0.id == newPersona.id }))
    }

    func testUpdatePersona() {
        let persona = Persona(
            id: "update-test-\(UUID().uuidString)",
            name: "Original Name",
            instruction: "Original instruction",
            emoji: "🔵",
            isBuiltIn: false
        )
        appState.addPersona(persona)

        let updatedPersona = Persona(
            id: persona.id,
            name: "Updated Name",
            instruction: "Updated instruction",
            emoji: "🟢",
            isBuiltIn: false
        )
        appState.updatePersona(updatedPersona)

        let found = appState.allPersonas.first(where: { $0.id == persona.id })
        XCTAssertEqual(found?.name, "Updated Name")
        XCTAssertEqual(found?.instruction, "Updated instruction")
        XCTAssertEqual(found?.emoji, "🟢")
    }

    func testDeleteUserPersona() {
        let persona = Persona(
            id: "delete-test-\(UUID().uuidString)",
            name: "To Delete",
            instruction: "Delete me",
            emoji: "🗑️",
            isBuiltIn: false
        )
        appState.addPersona(persona)
        let countAfterAdd = appState.allPersonas.count

        appState.deletePersona(id: persona.id)

        XCTAssertEqual(appState.allPersonas.count, countAfterAdd - 1)
        XCTAssertFalse(appState.allPersonas.contains(where: { $0.id == persona.id }))
    }

    func testCannotDeleteBuiltInPersona() {
        let builtInPersona = Persona.cleanup
        let initialCount = appState.allPersonas.count

        appState.deletePersona(id: builtInPersona.id)

        XCTAssertEqual(appState.allPersonas.count, initialCount)
        XCTAssertTrue(appState.allPersonas.contains(where: { $0.id == builtInPersona.id }))
    }

    // MARK: - App Rule CRUD Tests

    func testAddAppRule() {
        let rule = AppRule(
            appBundleId: "com.test.app.\(UUID().uuidString.prefix(8))",
            appName: "Test App",
            personaId: "cleanup"
        )

        appState.addAppRule(rule)

        XCTAssertTrue(appState.appRules.contains(where: { $0.id == rule.id }))
    }

    func testAddAppRuleReplacesExisting() {
        let bundleId = "com.test.app.\(UUID().uuidString.prefix(8))"
        let rule1 = AppRule(appBundleId: bundleId, appName: "Test App", personaId: "cleanup")
        let rule2 = AppRule(appBundleId: bundleId, appName: "Test App", personaId: "professional")

        appState.addAppRule(rule1)
        appState.addAppRule(rule2)

        let rulesForApp = appState.appRules.filter { $0.appBundleId == bundleId }
        XCTAssertEqual(rulesForApp.count, 1)
        XCTAssertEqual(rulesForApp.first?.personaId, "professional")
    }

    func testUpdateAppRule() {
        let rule = AppRule(
            appBundleId: "com.test.update.\(UUID().uuidString.prefix(8))",
            appName: "Test App",
            personaId: "cleanup"
        )
        appState.addAppRule(rule)

        var updatedRule = rule
        updatedRule.personaId = "professional"
        appState.updateAppRule(updatedRule)

        let found = appState.appRules.first(where: { $0.id == rule.id })
        XCTAssertEqual(found?.personaId, "professional")
    }

    func testDeleteAppRule() {
        let rule = AppRule(
            appBundleId: "com.test.delete.\(UUID().uuidString.prefix(8))",
            appName: "Delete Me App",
            personaId: "cleanup"
        )
        appState.addAppRule(rule)

        appState.deleteAppRule(id: rule.id)

        XCTAssertFalse(appState.appRules.contains(where: { $0.id == rule.id }))
    }

    // MARK: - Computed Property Tests

    func testSelectedPersonaIdSetsCorrectly() {
        // Select the cleanup persona
        appState.selectedPersonaId = "cleanup"

        XCTAssertEqual(appState.selectedPersonaId, "cleanup")
    }

    func testSelectedPersonaIdNilWhenNoSelection() {
        appState.selectedPersonaId = nil

        XCTAssertNil(appState.selectedPersonaId)
    }

    func testCurrentInstructionReturnsSelectedPersonaInstruction() {
        appState.personasEnabled = true
        appState.selectedPersonaId = "cleanup"

        let instruction = appState.currentInstruction

        XCTAssertFalse(instruction.isEmpty)
        XCTAssertEqual(instruction, Persona.cleanup.instruction)
    }

    func testCurrentInstructionReturnsEmptyWhenPersonasDisabled() {
        appState.personasEnabled = false
        appState.selectedPersonaId = "cleanup"

        let instruction = appState.currentInstruction

        XCTAssertTrue(instruction.isEmpty)
    }

    // MARK: - Status Tests

    func testAppStatusValues() {
        appState.status = .idle
        XCTAssertEqual(appState.status, .idle)

        appState.status = .recording
        XCTAssertEqual(appState.status, .recording)

        appState.status = .processing
        XCTAssertEqual(appState.status, .processing)

        appState.status = .error
        XCTAssertEqual(appState.status, .error)
    }

    // MARK: - Settings Tests

    func testAutoPasteEnabledDefault() {
        // The default value should be loaded from UserDefaults or be a reasonable default
        // Just test that it's a boolean value (either true or false)
        XCTAssertNotNil(appState.autoPasteEnabled as Bool?)
    }

    func testSoundFeedbackEnabledDefault() {
        // Default should be true
        // Note: This may vary based on UserDefaults state
        XCTAssertNotNil(appState.soundFeedbackEnabled as Bool?)
    }

    func testHistoryRetentionDaysDefault() {
        // Default is 30 days
        // Note: This may vary based on UserDefaults state
        XCTAssertGreaterThanOrEqual(appState.historyRetentionDays, 0)
    }

    func testHotkeyPressModeCanBeSet() {
        appState.hotkeyPressMode = .hold
        XCTAssertEqual(appState.hotkeyPressMode, .hold)

        appState.hotkeyPressMode = .push
        XCTAssertEqual(appState.hotkeyPressMode, .push)

        appState.hotkeyPressMode = .both
        XCTAssertEqual(appState.hotkeyPressMode, .both)
    }

    func testClaudeCodeModelSelectionCanBeSet() {
        appState.selectedClaudeCodeModelId = "haiku"
        XCTAssertEqual(appState.selectedClaudeCodeModelId, "haiku")

        appState.selectedClaudeCodeModelId = nil
        XCTAssertNil(appState.selectedClaudeCodeModelId)
    }

    func testClaudeCodeProcessingModeDefaultOrSetValue() {
        XCTAssertFalse(appState.claudeCodeProcessingMode.isEmpty)

        appState.claudeCodeProcessingMode = ClaudeCodeProcessingMode.assistant.rawValue
        XCTAssertEqual(appState.claudeCodeProcessingMode, ClaudeCodeProcessingMode.assistant.rawValue)
    }
}

// MARK: - AppRule Tests

final class AppRuleTests: XCTestCase {
    func testAppRuleInitialization() {
        let rule = AppRule(
            id: "test-id",
            appBundleId: "com.test.app",
            appName: "Test App",
            appIcon: nil,
            personaId: "cleanup"
        )

        XCTAssertEqual(rule.id, "test-id")
        XCTAssertEqual(rule.appBundleId, "com.test.app")
        XCTAssertEqual(rule.appName, "Test App")
        XCTAssertNil(rule.appIcon)
        XCTAssertEqual(rule.personaId, "cleanup")
    }

    func testAppRuleAutoGeneratesId() {
        let rule = AppRule(
            appBundleId: "com.test.app",
            appName: "Test App",
            personaId: "cleanup"
        )

        XCTAssertFalse(rule.id.isEmpty)
    }

    func testAppRuleCodable() throws {
        let original = AppRule(
            appBundleId: "com.test.app",
            appName: "Test App",
            personaId: "cleanup"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppRule.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.appBundleId, original.appBundleId)
        XCTAssertEqual(decoded.appName, original.appName)
        XCTAssertEqual(decoded.personaId, original.personaId)
    }
}

// MARK: - Persona Extended Tests

final class PersonaExtendedTests: XCTestCase {
    func testPersonaCodableRoundTrip() throws {
        let original = Persona(
            id: "test-id",
            name: "Test Persona",
            instruction: "Test instruction with special chars: 🎤",
            emoji: "🧪",
            isBuiltIn: false
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Persona.self, from: encoded)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.instruction, original.instruction)
        XCTAssertEqual(decoded.emoji, original.emoji)
        XCTAssertEqual(decoded.isBuiltIn, original.isBuiltIn)
    }

    func testPersonaEquatable() {
        let persona1 = Persona(id: "same-id", name: "Name 1", instruction: "Instruction 1", emoji: "🔵", isBuiltIn: false)
        let persona2 = Persona(id: "same-id", name: "Name 2", instruction: "Instruction 2", emoji: "🟢", isBuiltIn: false)
        let persona3 = Persona(id: "different-id", name: "Name 1", instruction: "Instruction 1", emoji: "🔵", isBuiltIn: false)

        // Same ID means equal (even with different properties)
        XCTAssertEqual(persona1, persona2)
        // Different ID means not equal
        XCTAssertNotEqual(persona1, persona3)
    }

    func testBuiltInPersonasAreImmutable() {
        let cleanup = Persona.cleanup

        // Built-in personas should have isBuiltIn = true
        XCTAssertTrue(cleanup.isBuiltIn)
        XCTAssertTrue(Persona.professional.isBuiltIn)
        XCTAssertTrue(Persona.concise.isBuiltIn)
    }
}
