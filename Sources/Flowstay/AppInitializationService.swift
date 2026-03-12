import AppKit
import FlowstayCore
import Foundation
import SwiftUI

enum OnboardingLaunchDecision {
    case showOnboarding
    case deferForModelDownload
    case skip

    static func resolve(
        onboardingCompleted: Bool,
        permissionsGranted: Bool,
        modelDownloaded: Bool,
        deferredForModelDownload: Bool
    ) -> OnboardingLaunchDecision {
        let needsPermissions = !permissionsGranted
        let needsModel = !modelDownloaded
        if deferredForModelDownload, needsModel, !needsPermissions {
            return .deferForModelDownload
        }
        if !onboardingCompleted || needsPermissions || needsModel {
            return .showOnboarding
        }
        return .skip
    }
}

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
    private var deferredOnboardingResumeTask: Task<Void, Never>?

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
            deferredOnboardingResumeTask?.cancel()
            deferredOnboardingResumeTask = nil
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
        await permissionManager.checkPermissions()

        let modelDownloaded = engineCoordinator.isModelDownloaded()
        if modelDownloaded {
            UserDefaults.standard.onboardingDeferredForModelDownload = false
        }

        let decision = OnboardingLaunchDecision.resolve(
            onboardingCompleted: UserDefaults.standard.hasCompletedOnboarding,
            permissionsGranted: permissionManager.criticalPermissionsGranted,
            modelDownloaded: modelDownloaded,
            deferredForModelDownload: UserDefaults.standard.onboardingDeferredForModelDownload
        )

        switch decision {
        case .deferForModelDownload:
            print("[AppInitializationService] Onboarding deferred while model downloads in background")
            startDeferredOnboardingResumeIfNeeded()
        case .showOnboarding:
            print("[AppInitializationService] Requirements incomplete - showing onboarding")
            await showOnboardingWindow()
        case .skip:
            break
        }
    }

    /// Initialize the app on first launch
    func initializeApp() async {
        print("[AppInitializationService] Starting app initialization...")
        StartupRecoveryManager.shared.markStage(.appInitializationStarted)

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
        if modelDownloaded {
            UserDefaults.standard.onboardingDeferredForModelDownload = false
        }

        let decision = OnboardingLaunchDecision.resolve(
            onboardingCompleted: onboardingCompleted,
            permissionsGranted: permissionManager.criticalPermissionsGranted,
            modelDownloaded: modelDownloaded,
            deferredForModelDownload: UserDefaults.standard.onboardingDeferredForModelDownload
        )

        print("[AppInitializationService] Launch decision: \(decision)")

        switch decision {
        case .deferForModelDownload:
            startDeferredOnboardingResumeIfNeeded()
        case .showOnboarding:
            print("[AppInitializationService] Triggering onboarding window...")
            await showOnboardingWindow()
        case .skip:
            break
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
                alert.informativeText = """
                Flowstay couldn't create required directories. \
                Transcripts may not be saved. Error: \(error.localizedDescription)
                """
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

        StartupRecoveryManager.shared.markStage(.appInitializationCompleted)
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

        if StartupRecoveryManager.shared.shouldSkipGlobalShortcuts {
            print("[AppInitializationService] Recovery mode active - skipping global shortcuts for this launch")
            StartupRecoveryManager.shared.markSubsystemSkipped(.globalShortcuts)
            StartupRecoveryManager.shared.appendDiagnostic("skipping global shortcuts during recovery launch")
            return
        }

        guard let onHotkeyEvent = hotkeyEventCallback,
              let onFeedback = shortcutFeedbackCallback
        else {
            print("[AppInitializationService] Hotkey callbacks not configured yet, skipping shortcut setup")
            return
        }

        if StartupRecoveryManager.shared.shouldSkipGlobalShortcuts {
            print("[AppInitializationService] Skipping global shortcuts - startup recovery active")
            StartupRecoveryManager.shared.markSubsystemSkipped(.globalShortcuts)
            return
        }

        if !GlobalShortcutsManager.isInitialized {
            print("[AppInitializationService] Initializing global shortcuts...")
            StartupRecoveryManager.shared.markStage(.shortcutsInitializing)
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

    private func startDeferredOnboardingResumeIfNeeded() {
        guard deferredOnboardingResumeTask == nil else {
            print("[AppInitializationService] Deferred onboarding resume task already running")
            return
        }

        print("[AppInitializationService] Starting deferred model preparation task...")
        deferredOnboardingResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await engineCoordinator.preInitializeAllModels(prewarmBehavior: .modelsOnly)

            let modelDownloaded = engineCoordinator.isModelDownloaded()
            UserDefaults.standard.onboardingDeferredForModelDownload = false
            deferredOnboardingResumeTask = nil

            guard !UserDefaults.standard.hasCompletedOnboarding else { return }

            print("[AppInitializationService] Deferred model task finished (downloaded: \(modelDownloaded)) - reopening onboarding")
            await showOnboardingWindow()
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
