import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// Formats a keyboard shortcut for display without using `KeyboardShortcuts`'
/// `Bundle.module`-based localization. This avoids a `fatalError` crash when SPM's
/// auto-generated resource bundle accessor cannot find the bundle inside the `.app`
/// (the accessor looks at the app root, but `build_app.sh` places bundles in
/// `Contents/Resources/`).
@MainActor
public func safeShortcutDescription(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
    let modifiers = shortcut.modifiers
    var desc = ""

    if modifiers.contains(.control) { desc += "⌃" }
    if modifiers.contains(.option) { desc += "⌥" }
    if modifiers.contains(.shift) { desc += "⇧" }
    if modifiers.contains(.command) { desc += "⌘" }

    if let key = shortcut.key {
        desc += safeKeyDescription(key, carbonKeyCode: shortcut.carbonKeyCode)
    }

    return desc
}

// MARK: - Key description without localization

/// Maps a `KeyboardShortcuts.Key` to a display string using only hardcoded symbols
/// and Carbon keyboard layout APIs — no `Bundle.module` / `NSLocalizedString`.
@MainActor
private func safeKeyDescription(_ key: KeyboardShortcuts.Key, carbonKeyCode: Int) -> String {
    // Special keys — mirrors KeyboardShortcuts' SpecialKey enum but without
    // the `.localized` call that triggers Bundle.module for the space key.
    if let special = specialKeyDescription(key) {
        return special
    }

    // Regular keys — use the same Carbon API that KeyboardShortcuts uses internally.
    if let char = characterForKeyCode(carbonKeyCode) {
        return String(char).capitalized
    }

    // Ultimate fallback — show the raw key code so it's at least identifiable.
    return "Key(\(carbonKeyCode))"
}

// swiftlint:disable:next cyclomatic_complexity
private func specialKeyDescription(_ key: KeyboardShortcuts.Key) -> String? {
    switch key {
    case .return: "↩"
    case .delete: "⌫"
    case .deleteForward: "⌦"
    case .end: "↘"
    case .escape: "⎋"
    case .help: "?⃝"
    case .home: "↖"
    case .space: "Space"
    case .tab: "⇥"
    case .pageUp: "⇞"
    case .pageDown: "⇟"
    case .upArrow: "↑"
    case .rightArrow: "→"
    case .downArrow: "↓"
    case .leftArrow: "←"
    case .f1: "F1"
    case .f2: "F2"
    case .f3: "F3"
    case .f4: "F4"
    case .f5: "F5"
    case .f6: "F6"
    case .f7: "F7"
    case .f8: "F8"
    case .f9: "F9"
    case .f10: "F10"
    case .f11: "F11"
    case .f12: "F12"
    case .f13: "F13"
    case .f14: "F14"
    case .f15: "F15"
    case .f16: "F16"
    case .f17: "F17"
    case .f18: "F18"
    case .f19: "F19"
    case .f20: "F20"
    case .keypad0: "0\u{20e3}"
    case .keypad1: "1\u{20e3}"
    case .keypad2: "2\u{20e3}"
    case .keypad3: "3\u{20e3}"
    case .keypad4: "4\u{20e3}"
    case .keypad5: "5\u{20e3}"
    case .keypad6: "6\u{20e3}"
    case .keypad7: "7\u{20e3}"
    case .keypad8: "8\u{20e3}"
    case .keypad9: "9\u{20e3}"
    case .keypadClear: "⌧"
    case .keypadDecimal: ".\u{20e3}"
    case .keypadDivide: "/\u{20e3}"
    case .keypadEnter: "⌅"
    case .keypadEquals: "=\u{20e3}"
    case .keypadMinus: "-\u{20e3}"
    case .keypadMultiply: "*\u{20e3}"
    case .keypadPlus: "+\u{20e3}"
    default: nil
    }
}

/// Translates a Carbon key code to a character using the current ASCII-capable
/// keyboard layout — the same approach `KeyboardShortcuts` uses internally.
@MainActor
private func characterForKeyCode(_ keyCode: Int) -> Character? {
    guard
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
        return nil
    }

    let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
    let keyLayout = unsafeBitCast(
        CFDataGetBytePtr(layoutData),
        to: UnsafePointer<CoreServices.UCKeyboardLayout>.self
    )

    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0

    let error = UCKeyTranslate(
        keyLayout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        UInt32(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        chars.count,
        &length,
        &chars
    )

    guard error == noErr, length > 0 else {
        return nil
    }

    guard let scalar = UnicodeScalar(chars[0]) else {
        return nil
    }
    return Character(scalar)
}
