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

    /// Debounce interval to prevent rapid double-triggers.
    private static let debounceInterval: TimeInterval = 0.3

    private static var toggleRequestedHandler: (() -> Void)?
    private static var feedbackHandler: ((HotkeyFeedbackEvent) -> Void)?

    /// Check if global shortcuts have been initialized.
    public static var isInitialized: Bool {
        _isInitialized
    }

    /// Initialize global shortcuts and dispatch callbacks.
    public static func initialize(
        onToggleRequested: @escaping () -> Void,
        onFeedback: @escaping (HotkeyFeedbackEvent) -> Void
    ) {
        guard !_isInitialized else {
            print("[GlobalShortcutsManager] Already initialized, skipping")
            return
        }

        print("[GlobalShortcutsManager] Starting initialization...")
        print("[GlobalShortcutsManager] App bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        print("[GlobalShortcutsManager] Activation policy: \(NSApplication.shared.activationPolicy().rawValue)")

        toggleRequestedHandler = onToggleRequested
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

            for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleDictation) {
                if Task.isCancelled {
                    print("[GlobalShortcutsManager] Listener task cancelled, exiting")
                    break
                }

                if let lastTime = lastHotkeyTime,
                   Date().timeIntervalSince(lastTime) < debounceInterval
                {
                    print("[GlobalShortcutsManager] Debounced rapid keypress (within \(Int(debounceInterval * 1000))ms)")
                    feedbackHandler?(.blockedTransition)
                    continue
                }
                lastHotkeyTime = Date()

                print("[GlobalShortcutsManager] SHORTCUT TRIGGERED")
                feedbackHandler?(.accepted)
                toggleRequestedHandler?()
            }

            print("[GlobalShortcutsManager] Async listener task ended")
        }

        print("[GlobalShortcutsManager] Global hotkey listener registered")
    }

    /// Stop listening for keyboard shortcuts (cleanup).
    public static func deinitialize() {
        print("[GlobalShortcutsManager] Deinitializing...")
        shortcutListenerTask?.cancel()
        shortcutListenerTask = nil
        toggleRequestedHandler = nil
        feedbackHandler = nil
        _isInitialized = false
        print("[GlobalShortcutsManager] Deinitialized")
    }
}
