import AppKit
import Foundation
import KeyboardShortcuts

/// Extension for KeyboardShortcuts names
public extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", default: .init(.space, modifiers: [.option]))
}

/// Manages global keyboard shortcuts for Flowstay.
/// Dispatches user-intent events and feedback events to app-level policy handlers.
@MainActor
public class GlobalShortcutsManager {
    private static var _isInitialized = false

    /// Task that listens for keyboard shortcut events.
    private static var shortcutListenerTask: Task<Void, Never>?
    private static var functionKeyGlobalMonitor: Any?
    private static var functionKeyLocalMonitor: Any?
    private static var isFunctionKeyPressed = false

    /// Debounce interval to prevent rapid double-triggers.
    private static let debounceInterval: TimeInterval = 0.3

    private static var hotkeyEventHandler: ((HotkeyInputEvent) -> Void)?
    private static var feedbackHandler: ((HotkeyFeedbackEvent) -> Void)?

    /// Check if global shortcuts have been initialized.
    public static var isInitialized: Bool {
        _isInitialized
    }

    /// Initialize global shortcuts and dispatch callbacks.
    public static func initialize(
        onHotkeyEvent: @escaping (HotkeyInputEvent) -> Void,
        onFeedback: @escaping (HotkeyFeedbackEvent) -> Void
    ) {
        guard !_isInitialized else {
            print("[GlobalShortcutsManager] Already initialized, skipping")
            return
        }

        print("[GlobalShortcutsManager] Starting initialization...")
        print("[GlobalShortcutsManager] App bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        print("[GlobalShortcutsManager] Activation policy: \(NSApplication.shared.activationPolicy().rawValue)")

        hotkeyEventHandler = onHotkeyEvent
        feedbackHandler = onFeedback

        _ = KeyboardShortcuts.Name.toggleDictation
        setupGlobalHotkey()
        _isInitialized = true

        print("[GlobalShortcutsManager] Keyboard shortcuts initialized successfully")
    }

    private static func setupGlobalHotkey() {
        print("[GlobalShortcutsManager] Setting up global hotkey...")

        // Cancel any existing listener task.
        shortcutListenerTask?.cancel()
        shortcutListenerTask = nil
        removeFunctionKeyMonitors()
        isFunctionKeyPressed = false

        // Set default only when user has not customized a shortcut.
        if KeyboardShortcuts.getShortcut(for: .toggleDictation) == nil {
            let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
            print("[GlobalShortcutsManager] Applying default shortcut (Option+Space)")
            KeyboardShortcuts.setShortcut(defaultShortcut, for: .toggleDictation)
        } else {
            print("[GlobalShortcutsManager] Existing shortcut detected, preserving custom value")
        }

        let verifyShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        if verifyShortcut != nil {
            print("[GlobalShortcutsManager] Shortcut verified successfully")
        } else {
            print("[GlobalShortcutsManager] Shortcut verification failed")
            feedbackHandler?(.error)
        }

        print("[GlobalShortcutsManager] Starting async event listener...")

        shortcutListenerTask = Task { @MainActor in
            var lastHotkeyTime: Date?

            print("[GlobalShortcutsManager] Async listener task started")

            for await event in KeyboardShortcuts.events(for: .toggleDictation) {
                if Task.isCancelled {
                    print("[GlobalShortcutsManager] Listener task cancelled, exiting")
                    break
                }

                switch event {
                case .keyDown:
                    if let lastTime = lastHotkeyTime,
                       Date().timeIntervalSince(lastTime) < debounceInterval
                    {
                        print("[GlobalShortcutsManager] Debounced rapid keypress (within \(Int(debounceInterval * 1000))ms)")
                        feedbackHandler?(.blockedTransition)
                        continue
                    }
                    lastHotkeyTime = Date()
                    print("[GlobalShortcutsManager] SHORTCUT KEY DOWN")
                    feedbackHandler?(.accepted)
                    hotkeyEventHandler?(.shortcutKeyDown)

                case .keyUp:
                    print("[GlobalShortcutsManager] SHORTCUT KEY UP")
                    hotkeyEventHandler?(.shortcutKeyUp)
                }
            }

            print("[GlobalShortcutsManager] Async listener task ended")
        }

        functionKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in
                handleFunctionKeyFlagsChanged(event)
            }
        }

        functionKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in
                handleFunctionKeyFlagsChanged(event)
            }
            return event
        }

        print("[GlobalShortcutsManager] Global hotkey listener registered")
    }

    private static func handleFunctionKeyFlagsChanged(_ event: NSEvent) {
        let functionPressedNow = event.modifierFlags.contains(.function)
        guard functionPressedNow != isFunctionKeyPressed else { return }

        isFunctionKeyPressed = functionPressedNow
        if functionPressedNow {
            print("[GlobalShortcutsManager] FUNCTION KEY DOWN")
            hotkeyEventHandler?(.functionKeyDown)
        } else {
            print("[GlobalShortcutsManager] FUNCTION KEY UP")
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
        print("[GlobalShortcutsManager] Deinitializing...")
        shortcutListenerTask?.cancel()
        shortcutListenerTask = nil
        removeFunctionKeyMonitors()
        isFunctionKeyPressed = false
        hotkeyEventHandler = nil
        feedbackHandler = nil
        _isInitialized = false
        print("[GlobalShortcutsManager] Deinitialized")
    }
}
