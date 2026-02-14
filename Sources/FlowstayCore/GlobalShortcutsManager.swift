import AppKit
import Foundation
import KeyboardShortcuts

/// Extension for KeyboardShortcuts names
public extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", default: .init(.space, modifiers: [.option]))
}

/// Holder to ensure strong references to dependencies aren't deallocated
private class DependencyHolder {
    let engineCoordinator: EngineCoordinatorViewModel
    let permissionManager: PermissionManager

    init(engineCoordinator: EngineCoordinatorViewModel, permissionManager: PermissionManager) {
        self.engineCoordinator = engineCoordinator
        self.permissionManager = permissionManager
    }
}

/// Manages global keyboard shortcuts for Flowstay
/// Uses the modern KeyboardShortcuts.events() AsyncStream API for Swift 6 compatibility
@MainActor
public class GlobalShortcutsManager {
    private static var _isInitialized = false
    private static var dependencyHolder: DependencyHolder?

    /// Task that listens for keyboard shortcut events
    /// Using AsyncStream API instead of onKeyDown callback for Swift 6 concurrency safety
    private static var shortcutListenerTask: Task<Void, Never>?

    /// Debounce interval to prevent rapid double-triggers
    private static let debounceInterval: TimeInterval = 0.3 // 300ms

    /// Check if global shortcuts have been initialized
    public static var isInitialized: Bool {
        _isInitialized
    }

    /// Initialize global shortcuts with the required dependencies
    public static func initialize(
        engineCoordinator: EngineCoordinatorViewModel,
        permissionManager: PermissionManager
    ) {
        guard !_isInitialized else {
            print("[GlobalShortcutsManager] Already initialized, skipping")
            return
        }

        print("[GlobalShortcutsManager] Starting initialization...")
        print("[GlobalShortcutsManager] App bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        print("[GlobalShortcutsManager] Activation policy: \(NSApplication.shared.activationPolicy().rawValue)")

        // Create holder with strong references to prevent deallocation
        dependencyHolder = DependencyHolder(
            engineCoordinator: engineCoordinator,
            permissionManager: permissionManager
        )

        // Test that the KeyboardShortcuts extension is accessible
        _ = KeyboardShortcuts.Name.toggleDictation
        print("[GlobalShortcutsManager] Shortcut name: toggleDictation")

        setupGlobalHotkey()
        _isInitialized = true

        print("[GlobalShortcutsManager] Keyboard shortcuts initialized successfully")
    }

    private static func setupGlobalHotkey() {
        print("[GlobalShortcutsManager] Setting up global hotkey...")

        // Cancel any existing listener task
        shortcutListenerTask?.cancel()
        shortcutListenerTask = nil

        // Ensure default shortcut is set BEFORE starting listener
        let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        print("[GlobalShortcutsManager] Setting default shortcut (Option+Space)")
        KeyboardShortcuts.setShortcut(defaultShortcut, for: .toggleDictation)

        // Verify it's set
        let verifyShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        if verifyShortcut != nil {
            print("[GlobalShortcutsManager] Shortcut verified successfully")
        } else {
            print("[GlobalShortcutsManager] Shortcut verification failed")
        }

        // Start async listener using modern AsyncStream API
        // This properly integrates with Swift 6 concurrency (no callback isolation issues)
        print("[GlobalShortcutsManager] Starting async event listener...")

        shortcutListenerTask = Task { @MainActor in
            // Local debounce state (avoids static property isolation issues)
            var lastHotkeyTime: Date?

            print("[GlobalShortcutsManager] Async listener task started")

            // for-await loop using KeyboardShortcuts.events() AsyncStream
            // This is the modern, Swift 6 concurrency-safe way to listen for shortcuts
            for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleDictation) {
                // Check if task was cancelled
                if Task.isCancelled {
                    print("[GlobalShortcutsManager] Listener task cancelled, exiting")
                    break
                }

                // Debounce rapid keypresses to prevent double-triggers
                if let lastTime = lastHotkeyTime,
                   Date().timeIntervalSince(lastTime) < debounceInterval
                {
                    print("[GlobalShortcutsManager] Debounced rapid keypress (within \(Int(debounceInterval * 1000))ms)")
                    continue
                }
                lastHotkeyTime = Date()

                print("[GlobalShortcutsManager] SHORTCUT TRIGGERED!")

                // Handle the shortcut
                await handleShortcutTriggered()
            }

            print("[GlobalShortcutsManager] Async listener task ended")
        }

        print("[GlobalShortcutsManager] Global hotkey listener registered")
    }

    /// Handle the keyboard shortcut being triggered
    /// Extracted to separate function for clarity
    private static func handleShortcutTriggered() async {
        // Get strong references from holder to prevent deallocation
        guard let holder = dependencyHolder else {
            print("[GlobalShortcutsManager] Dependencies not available")
            NSSound.beep()
            return
        }

        let coordinator = holder.engineCoordinator
        let permissions = holder.permissionManager

        print("[GlobalShortcutsManager] Keyboard shortcut triggered - isRecording: \(coordinator.isRecording), isTransitioning: \(coordinator.isTransitioningRecordingState)")

        if !permissions.criticalPermissionsGranted {
            print("[GlobalShortcutsManager] Critical permissions not granted")
            NSSound.beep()
            return
        }

        if coordinator.isTransitioningRecordingState {
            print("[GlobalShortcutsManager] Shortcut ignored - recording state transition in progress")
            return
        }

        if coordinator.isRecording {
            print("[GlobalShortcutsManager] Stopping recording...")
            await coordinator.stopRecording()
        } else {
            print("[GlobalShortcutsManager] Starting recording...")
            do {
                try await coordinator.startRecording()
            } catch {
                print("[GlobalShortcutsManager] Failed to start recording: \(error)")
            }
        }
    }

    /// Stop listening for keyboard shortcuts (cleanup)
    public static func deinitialize() {
        print("[GlobalShortcutsManager] Deinitializing...")
        shortcutListenerTask?.cancel()
        shortcutListenerTask = nil
        dependencyHolder = nil
        _isInitialized = false
        print("[GlobalShortcutsManager] Deinitialized")
    }
}
