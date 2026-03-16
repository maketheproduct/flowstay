import AppKit
import Foundation
import KeyboardShortcuts

/// Extension for KeyboardShortcuts names
public extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", default: .init(.space, modifiers: [.option]))
    static let holdToTalk = Self("holdToTalk")
}

/// Manages global keyboard shortcuts for Flowstay.
/// Dispatches user-intent events and feedback events to app-level policy handlers.
@MainActor
public class GlobalShortcutsManager {
    public static var holdInputSource: HoldToTalkInputSource = .functionKey
    private static var _isInitialized = false

    /// Task that listens for keyboard shortcut events.
    private static var toggleShortcutListenerTask: Task<Void, Never>?
    private static var holdShortcutListenerTask: Task<Void, Never>?
    private static var functionKeyGlobalMonitor: Any?
    private static var functionKeyLocalMonitor: Any?
    private static var isFunctionKeyPressed = false
    private static var isHoldShortcutPressed = false
    private static var isHoldInputPressed = false

    /// Debounce interval to prevent rapid double-triggers.
    private static let debounceInterval: TimeInterval = 0.3

    private static var hotkeyEventHandler: ((HotkeyInputEvent) -> Void)?
    private static var feedbackHandler: ((HotkeyFeedbackEvent) -> Void)?

    /// Check if global shortcuts have been initialized.
    public static var isInitialized: Bool {
        _isInitialized
    }

    public static func setHoldInputSource(_ source: HoldToTalkInputSource) {
        holdInputSource = source
        updateHoldInputState()
    }

    /// Initialize global shortcuts and dispatch callbacks.
    public static func initialize(
        onHotkeyEvent: @escaping (HotkeyInputEvent) -> Void,
        onFeedback: @escaping (HotkeyFeedbackEvent) -> Void
    ) {
        guard !_isInitialized else { return }

        hotkeyEventHandler = onHotkeyEvent
        feedbackHandler = onFeedback

        _ = KeyboardShortcuts.Name.toggleDictation
        _ = KeyboardShortcuts.Name.holdToTalk
        setupGlobalHotkey()
        _isInitialized = true
    }

    private static func setupGlobalHotkey() {
        // Cancel any existing listener task.
        toggleShortcutListenerTask?.cancel()
        toggleShortcutListenerTask = nil
        holdShortcutListenerTask?.cancel()
        holdShortcutListenerTask = nil
        removeFunctionKeyMonitors()
        isFunctionKeyPressed = false
        isHoldShortcutPressed = false
        isHoldInputPressed = false

        // Set default only when user has not customized a shortcut.
        if KeyboardShortcuts.getShortcut(for: .toggleDictation) == nil {
            let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
            KeyboardShortcuts.setShortcut(defaultShortcut, for: .toggleDictation)
        }

        let verifyShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        if verifyShortcut == nil {
            feedbackHandler?(.error)
        }

        startToggleShortcutListener()
        startHoldShortcutListener()

        let monitors = Self.makeFlagMonitors { flags in
            handleFunctionKeyFlagsChanged(flags)
        }
        functionKeyGlobalMonitor = monitors.global
        functionKeyLocalMonitor = monitors.local
    }

    private static func startToggleShortcutListener() {
        toggleShortcutListenerTask = Task { @MainActor in
            var lastHotkeyTime: Date?

            for await event in KeyboardShortcuts.events(for: .toggleDictation) {
                if Task.isCancelled { break }

                switch event {
                case .keyDown:
                    if let lastTime = lastHotkeyTime,
                       Date().timeIntervalSince(lastTime) < debounceInterval
                    {
                        feedbackHandler?(.blockedTransition)
                        continue
                    }
                    lastHotkeyTime = Date()
                    feedbackHandler?(.accepted)
                    hotkeyEventHandler?(.shortcutKeyDown)

                case .keyUp:
                    hotkeyEventHandler?(.shortcutKeyUp)
                }
            }
        }
    }

    private static func startHoldShortcutListener() {
        holdShortcutListenerTask = Task { @MainActor in
            for await event in KeyboardShortcuts.events(for: .holdToTalk) {
                if Task.isCancelled { break }

                if holdShortcutConflictsWithToggle() {
                    if isHoldShortcutPressed {
                        isHoldShortcutPressed = false
                        updateHoldInputState()
                    }
                    continue
                }

                switch event {
                case .keyDown:
                    guard !isHoldShortcutPressed else { continue }
                    isHoldShortcutPressed = true
                    updateHoldInputState()
                case .keyUp:
                    guard isHoldShortcutPressed else { continue }
                    isHoldShortcutPressed = false
                    updateHoldInputState()
                }
            }
        }
    }

    private static func holdShortcutConflictsWithToggle() -> Bool {
        guard let holdShortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk),
              let toggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        else {
            return false
        }
        return holdShortcut == toggleShortcut
    }

    /// Creates NSEvent flag-change monitors without inheriting @MainActor isolation.
    /// Extracts modifier flags (a Sendable value type) before crossing the isolation boundary.
    private nonisolated static func makeFlagMonitors(
        handler: @MainActor @escaping (NSEvent.ModifierFlags) -> Void
    ) -> (global: Any?, local: Any?) {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags
            DispatchQueue.main.async { handler(flags) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags
            DispatchQueue.main.async { handler(flags) }
            return event
        }
        return (global, local)
    }

    private static func handleFunctionKeyFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let functionPressedNow = flags.contains(.function)
        guard functionPressedNow != isFunctionKeyPressed else { return }

        isFunctionKeyPressed = functionPressedNow
        updateHoldInputState()
    }

    private static func updateHoldInputState() {
        let holdPressedNow: Bool = switch holdInputSource {
        case .functionKey:
            isFunctionKeyPressed
        case .alternativeShortcut:
            isHoldShortcutPressed
        }
        guard holdPressedNow != isHoldInputPressed else { return }

        isHoldInputPressed = holdPressedNow
        if holdPressedNow {
            hotkeyEventHandler?(.functionKeyDown)
        } else {
            hotkeyEventHandler?(.functionKeyUp)
        }
    }

    private static func removeFunctionKeyMonitors() {
        if let functionKeyGlobalMonitor {
            NSEvent.removeMonitor(functionKeyGlobalMonitor)
            self.functionKeyGlobalMonitor = nil
        }
        if let functionKeyLocalMonitor {
            NSEvent.removeMonitor(functionKeyLocalMonitor)
            self.functionKeyLocalMonitor = nil
        }
    }

    /// Stop listening for keyboard shortcuts (cleanup).
    public static func deinitialize() {
        toggleShortcutListenerTask?.cancel()
        toggleShortcutListenerTask = nil
        holdShortcutListenerTask?.cancel()
        holdShortcutListenerTask = nil
        removeFunctionKeyMonitors()
        isFunctionKeyPressed = false
        isHoldShortcutPressed = false
        isHoldInputPressed = false
        hotkeyEventHandler = nil
        feedbackHandler = nil
        _isInitialized = false
    }
}
