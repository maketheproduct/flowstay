@testable import FlowstayCore
import XCTest

@MainActor
final class AppStateRecoveryTests: XCTestCase {
    private let trackedKeys = [
        "userPersonas",
        "appRules",
        "hotkeyPressMode",
        "hasCompletedOnboarding",
        "selectedPersonaId",
        "launchAtLogin",
    ]
    private var originalValues: [String: Any] = [:]
    private var defaults: UserDefaults!
    private var appState: AppState!

    override func setUp() async throws {
        defaults = .standard
        originalValues = trackedKeys.reduce(into: [:]) { partialResult, key in
            if let value = defaults.object(forKey: key) {
                partialResult[key] = value
            }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in trackedKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in originalValues {
            defaults.set(value, forKey: key)
        }
        appState = nil
        defaults = nil
        originalValues = [:]
    }

    func testCorruptUserPersonasPayloadIsRemovedDuringInitialization() {
        defaults.set(Data("not-json".utf8), forKey: "userPersonas")

        appState = AppState(defaults: defaults, launchAtLoginStatusProvider: { false })

        XCTAssertEqual(appState.allPersonas.count, Persona.builtInPresets.count)
        XCTAssertNil(defaults.object(forKey: "userPersonas"))
    }

    func testCorruptAppRulesPayloadIsRemovedDuringInitialization() {
        defaults.set("definitely-not-json", forKey: "appRules")

        appState = AppState(defaults: defaults, launchAtLoginStatusProvider: { false })

        XCTAssertTrue(appState.appRules.isEmpty)
        XCTAssertNil(defaults.object(forKey: "appRules"))
    }

    func testUnknownHotkeyModeIsNormalizedOnLaunch() {
        defaults.set("legacy-unknown-mode", forKey: "hotkeyPressMode")
        defaults.set(true, forKey: "hasCompletedOnboarding")

        appState = AppState(defaults: defaults, launchAtLoginStatusProvider: { false })

        XCTAssertEqual(appState.hotkeyPressMode, .both)
        XCTAssertEqual(defaults.string(forKey: "hotkeyPressMode"), HotkeyPressMode.both.rawValue)
    }

    func testMissingSelectedPersonaIsClearedOnLaunch() {
        defaults.set("persona-that-no-longer-exists", forKey: "selectedPersonaId")

        appState = AppState(defaults: defaults, launchAtLoginStatusProvider: { false })

        XCTAssertNil(appState.selectedPersonaId)
        XCTAssertNil(defaults.object(forKey: "selectedPersonaId"))
    }

    func testLaunchAtLoginFallsBackToStoredPreferenceWhenStatusReadFails() {
        enum TestError: Error {
            case statusUnavailable
        }

        defaults.set(true, forKey: "launchAtLogin")

        appState = AppState(
            defaults: defaults,
            launchAtLoginStatusProvider: { throw TestError.statusUnavailable }
        )

        XCTAssertTrue(appState.launchAtLogin)
    }
}
