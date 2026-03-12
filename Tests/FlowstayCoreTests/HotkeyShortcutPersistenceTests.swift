import KeyboardShortcuts
@testable import FlowstayCore
import XCTest

@MainActor
final class HotkeyShortcutPersistenceTests: XCTestCase {
    private let toggleDefaultsKey = "KeyboardShortcuts_toggleDictation"
    private let holdDefaultsKey = "KeyboardShortcuts_holdToTalk"
    private var originalToggleValue: Any?
    private var originalHoldValue: Any?

    override func setUp() async throws {
        originalToggleValue = UserDefaults.standard.object(forKey: toggleDefaultsKey)
        originalHoldValue = UserDefaults.standard.object(forKey: holdDefaultsKey)

        UserDefaults.standard.removeObject(forKey: toggleDefaultsKey)
        UserDefaults.standard.removeObject(forKey: holdDefaultsKey)
    }

    override func tearDown() async throws {
        restoreUserDefaultsValue(originalToggleValue, forKey: toggleDefaultsKey)
        restoreUserDefaultsValue(originalHoldValue, forKey: holdDefaultsKey)
        originalToggleValue = nil
        originalHoldValue = nil
    }

    func testToggleAndHoldShortcutRoundTrip() {
        let toggleShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.option, .command])
        let holdShortcut = KeyboardShortcuts.Shortcut(.h, modifiers: [.control, .shift])

        KeyboardShortcuts.setShortcut(toggleShortcut, for: .toggleDictation)
        KeyboardShortcuts.setShortcut(holdShortcut, for: .holdToTalk)

        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .toggleDictation), toggleShortcut)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .holdToTalk), holdShortcut)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: toggleDefaultsKey))
        XCTAssertNotNil(UserDefaults.standard.object(forKey: holdDefaultsKey))
    }

    func testClearingHoldShortcutRemovesBinding() {
        let holdShortcut = KeyboardShortcuts.Shortcut(.h, modifiers: [.control, .shift])
        KeyboardShortcuts.setShortcut(holdShortcut, for: .holdToTalk)
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .holdToTalk), holdShortcut)

        KeyboardShortcuts.setShortcut(nil, for: .holdToTalk)
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .holdToTalk))
    }

    private func restoreUserDefaultsValue(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
