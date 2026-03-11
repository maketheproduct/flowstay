@testable import FlowstayCore
import XCTest

@MainActor
final class AppStateRecoveryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var appState: AppState!

    override func setUp() async throws {
        suiteName = "AppStateRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        appState = nil
        defaults = nil
        suiteName = nil
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
