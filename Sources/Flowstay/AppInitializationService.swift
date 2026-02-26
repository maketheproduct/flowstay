import AppKit
import FlowstayCore
import Foundation
import SwiftUI
import UserNotifications

/// Service responsible for handling app initialization tasks
/// including onboarding flow and first-time setup
@MainActor
class AppInitializationService: ObservableObject {
    private let permissionManager: PermissionManager
    private let appState: AppState
    private let engineCoordinator: EngineCoordinatorViewModel
    private var onboardingCallback: (() -> Void)?
    private var hotkeyEventCallback: ((HotkeyInputEvent) -> Void)?
    private var shortcutFeedbackCallback: ((HotkeyFeedbackEvent) -> Void)?
    private var hotkeyListenerReadyCallback: (() -> Void)?
    private var prewarmTask: Task<Void, Never>?

    @Published var hasInitialized = false

    private var notificationObserver: NSObjectProtocol?

    init(
        permissionManager: PermissionManager,
        appState: AppState,
        engineCoordinator: EngineCoordinatorViewModel,
        onboardingCallback: (() -> Void)? = nil
    ) {
        self.permissionManager = permissionManager
        self.appState = appState
        self.engineCoordinator = engineCoordinator
        self.onboardingCallback = onboardingCallback

        // Re-check requirements when app becomes active
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkRequirements()
            }
        }
    }

    deinit {
        cleanup()
    }

    /// Clean up resources when done
    nonisolated func cleanup() {
        Task { @MainActor in
            // Clean up notification observer
            if let observer = notificationObserver {
                NotificationCenter.default.removeObserver(observer)
                notificationObserver = nil
            }
            prewarmTask?.cancel()
            prewarmTask = nil
            print("[AppInitializationService] Cleaned up resources")
        }
    }

    /// Set the onboarding callback after initialization
    func setOnboardingCallback(_ callback: @escaping () -> Void) {
        onboardingCallback = callback
    }

    func setShortcutHandlers(
        onHotkeyEvent: @escaping (HotkeyInputEvent) -> Void,
        onFeedback: @escaping (HotkeyFeedbackEvent) -> Void,
        onListenerReady: (() -> Void)? = nil
    ) {
        hotkeyEventCallback = onHotkeyEvent
        shortcutFeedbackCallback = onFeedback
        hotkeyListenerReadyCallback = onListenerReady
    }

    /// Check if critical requirements are met (permissions and model)
    /// If not, show onboarding automatically
    private func checkRequirements() async {
        // Check permissions
        await permissionManager.checkPermissions()

        // Check if model is downloaded
        let modelDownloaded = engineCoordinator.isModelDownloaded()
        let needsPermissions = !permissionManager.criticalPermissionsGranted
        let needsModel = !modelDownloaded

        // If requirements are missing, trigger onboarding
        if needsPermissions || needsModel {
            print("[AppInitializationService] Missing requirements - showing onboarding")
            print("  - Needs permissions: \(needsPermissions)")
            print("  - Needs model: \(needsModel)")
            await showOnboardingWindow()
        }
    }

    /// Initialize the app on first launch
    func initializeApp() async {
        print("[AppInitializationService] Starting app initialization...")

        // Only check notification permission status (don't request - that happens in onboarding)
        _ = await NotificationManager.shared.checkPermissionStatus()

        // Check permissions first before attempting directory creation
        await permissionManager.checkPermissions()
        print("[AppInitializationService] Permission check complete:")
        print("  - Mic: \(permissionManager.microphoneStatus)")
        print("  - Accessibility: \(permissionManager.accessibilityStatus)")
        print("  - Critical permissions granted: \(permissionManager.criticalPermissionsGranted)")

        // Make the hotkey listener available as early as possible for returning users.
        let onboardingCompleted = UserDefaults.standard.hasCompletedOnboarding
        let launchPlan = InitializationOrderingPolicy.makePlan(
            permissionsGranted: permissionManager.criticalPermissionsGranted,
            onboardingCompleted: onboardingCompleted
        )
        if launchPlan.steps.contains(.initializeShortcuts) {
            initializeGlobalShortcutsIfNeeded()
        }

        // Check if model is downloaded
        let modelDownloaded = engineCoordinator.isModelDownloaded()

        // Check if this is first launch or permissions are missing
        let isFirstLaunch = !UserDefaults.standard.hasCompletedOnboarding
        let needsPermissions = !permissionManager.criticalPermissionsGranted
        let needsModel = !modelDownloaded

        print("[AppInitializationService] Launch status:")
        print("  - First launch: \(isFirstLaunch)")
        print("  - Needs permissions: \(needsPermissions)")
        print("  - Needs model: \(needsModel)")

        // Show onboarding if it's first launch, permissions are missing, or model isn't downloaded
        if isFirstLaunch || needsPermissions || needsModel {
            print("[AppInitializationService] Triggering onboarding window...")
            await showOnboardingWindow()
        }

        // Create app directories after onboarding (this may trigger document access permission)
        do {
            try FileManager.createAppDirectories()
            print("[AppInitializationService] App directories created successfully")
        } catch {
            print("[AppInitializationService] ❌ CRITICAL: Failed to create app directories: \(error)")

            // Show user-facing error since transcripts won't be saved
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Directory Creation Failed"
                alert.informativeText = "Flowstay couldn't create required directories in ~/Library/Application Support/. Transcripts may not be saved. Error: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Continue Anyway")
                alert.addButton(withTitle: "Quit")

                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    NSApplication.shared.terminate(nil)
                }
            }
        }

        // Configure auto-paste default if user has accessibility permission
        if permissionManager.hasAccessibilityPermission, !UserDefaults.standard.bool(forKey: "autoPasteConfigured") {
            appState.autoPasteEnabled = true
            UserDefaults.standard.set(true, forKey: "autoPasteConfigured")
            print("[AppInitializationService] Auto-paste enabled by default")
        }

        // Prewarm asynchronously so initialization does not block hotkey readiness.
        if launchPlan.steps.contains(.startModelPrewarmInBackground) {
            startModelPrewarmIfNeeded()
        }

        // Initialize auto-update system
        print("[AppInitializationService] Initializing auto-update system...")
        UpdateManager.shared.initialize()
        print("[AppInitializationService] Auto-update system initialized")

        hasInitialized = true
        print("[AppInitializationService] App initialization complete")
    }

    /// Finalize initialization after onboarding completes
    /// This initializes components that should only run after the user completes setup
    func finalizeInitialization() async {
        print("[AppInitializationService] Finalizing initialization post-onboarding...")

        initializeGlobalShortcutsIfNeeded()
        startModelPrewarmIfNeeded()

        print("[AppInitializationService] Finalization complete")
    }

    private func initializeGlobalShortcutsIfNeeded() {
        guard permissionManager.criticalPermissionsGranted, UserDefaults.standard.hasCompletedOnboarding else {
            print("[AppInitializationService] Skipping global shortcuts - requirements not met")
            return
        }

        guard let onHotkeyEvent = hotkeyEventCallback,
              let onFeedback = shortcutFeedbackCallback
        else {
            print("[AppInitializationService] Hotkey callbacks not configured yet, skipping shortcut setup")
            return
        }

        if !GlobalShortcutsManager.isInitialized {
            print("[AppInitializationService] Initializing global shortcuts...")
            GlobalShortcutsManager.initialize(
                onHotkeyEvent: onHotkeyEvent,
                onFeedback: onFeedback
            )
            hotkeyListenerReadyCallback?()
            print("[AppInitializationService] ✅ Global shortcuts initialized")
        } else {
            print("[AppInitializationService] Global shortcuts already initialized, skipping")
        }
    }

    private func startModelPrewarmIfNeeded() {
        guard permissionManager.criticalPermissionsGranted, UserDefaults.standard.hasCompletedOnboarding else {
            print("[AppInitializationService] Skipping model prewarm - requirements not met")
            return
        }

        guard prewarmTask == nil else {
            print("[AppInitializationService] Model prewarm already in progress")
            return
        }

        print("[AppInitializationService] Starting model prewarm task in background...")
        prewarmTask = Task { [weak self] in
            guard let self else { return }
            await engineCoordinator.preInitializeAllModels()
            print("[AppInitializationService] ✅ Models prewarm task finished")
            await MainActor.run {
                self.prewarmTask = nil
            }
        }
    }

    private func showOnboardingWindow() async {
        print("[AppInitializationService] Calling onboarding callback...")

        // Use main actor to ensure UI updates happen on main thread
        await MainActor.run {
            onboardingCallback?()

            // Direct approach: try to open window using NSApplication
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                // Force show a test window to verify window creation works
                if let window = NSApplication.shared.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        // Also post notification as backup
        NotificationCenter.default.post(name: Notification.Name("ShowOnboardingWindow"), object: nil)
    }
}
