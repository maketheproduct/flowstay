@testable import FlowstayCore
import XCTest

final class PersonaTests: XCTestCase {
    func testCleanupPersonaHasCorrectProperties() {
        let cleanup = Persona.cleanup

        XCTAssertEqual(cleanup.id, "cleanup")
        XCTAssertEqual(cleanup.name, "Cleanup")
        XCTAssertTrue(cleanup.isBuiltIn)
        XCTAssertNotNil(cleanup.instruction)
        XCTAssertFalse(cleanup.instruction.isEmpty)
    }

    func testProfessionalPersonaHasCorrectProperties() {
        let professional = Persona.professional

        XCTAssertEqual(professional.id, "professional")
        XCTAssertEqual(professional.name, "Professional")
        XCTAssertTrue(professional.isBuiltIn)
    }

    func testConcisePersonaHasCorrectProperties() {
        let concise = Persona.concise

        XCTAssertEqual(concise.id, "concise")
        XCTAssertEqual(concise.name, "Concise")
        XCTAssertTrue(concise.isBuiltIn)
    }

    func testBuiltInPresetsContainsAllPresets() {
        let presets = Persona.builtInPresets

        XCTAssertEqual(presets.count, 3)
        XCTAssertTrue(presets.contains(where: { $0.id == "cleanup" }))
        XCTAssertTrue(presets.contains(where: { $0.id == "professional" }))
        XCTAssertTrue(presets.contains(where: { $0.id == "concise" }))
    }

    func testCustomPersonaCreation() {
        let custom = Persona(
            id: "custom-test",
            name: "Test Persona",
            instruction: "Test instruction",
            emoji: "🧪",
            isBuiltIn: false
        )

        XCTAssertEqual(custom.id, "custom-test")
        XCTAssertEqual(custom.name, "Test Persona")
        XCTAssertEqual(custom.instruction, "Test instruction")
        XCTAssertEqual(custom.emoji, "🧪")
        XCTAssertFalse(custom.isBuiltIn)
    }

    func testPersonaHashableConformance() {
        let persona1 = Persona.cleanup
        let persona2 = Persona.cleanup

        XCTAssertEqual(persona1, persona2)
        XCTAssertEqual(persona1.hashValue, persona2.hashValue)
    }
}
