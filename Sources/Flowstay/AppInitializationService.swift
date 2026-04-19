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

private final class AppInitializationCallbacks {
    var onboarding: (() -> Void)?
    var hotkeyEvent: ((HotkeyInputEvent) -> Void)?
    var shortcutFeedback: ((HotkeyFeedbackEvent) -> Void)?
    var hotkeyListenerReady: (() -> Void)?
}

/// Service responsible for handling app initialization tasks
/// including onboarding flow and first-time setup
@MainActor
class AppInitializationService: ObservableObject {
    private let permissionManager: PermissionManager
    private let appState: AppState
    private let engineCoordinator: EngineCoordinatorViewModel
    private let callbacks = AppInitializationCallbacks()
    /// SAFETY: task creation/cancellation remains main-actor owned.
    /// These references are `nonisolated(unsafe)` only so `deinit` can cancel them
    /// synchronously under strict concurrency without scheduling more work.
    private nonisolated(unsafe) var prewarmTask: Task<Void, Never>?
    /// SAFETY: same as `prewarmTask`.
    private nonisolated(unsafe) var deferredOnboardingResumeTask: Task<Void, Never>?

    @Published var hasInitialized = false

    /// SAFETY: observer registration/removal is still performed on the main actor.
    /// This is marked `nonisolated(unsafe)` only so deinit can clear the token
    /// synchronously without scheduling more work.
    private nonisolated(unsafe) var notificationObserver: NSObjectProtocol?

    init(
        permissionManager: PermissionManager,
        appState: AppState,
        engineCoordinator: EngineCoordinatorViewModel,
        onboardingCallback: (() -> Void)? = nil
    ) {
        self.permissionManager = permissionManager
        self.appState = appState
        self.engineCoordinator = engineCoordinator
        callbacks.onboarding = onboardingCallback

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
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        prewarmTask?.cancel()
        prewarmTask = nil
        deferredOnboardingResumeTask?.cancel()
        deferredOnboardingResumeTask = nil
    }

    /// Clean up resources when done
    func cleanup() {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        prewarmTask?.cancel()
        prewarmTask = nil
        deferredOnboardingResumeTask?.cancel()
        deferredOnboardingResumeTask = nil
    }

    /// Set the onboarding callback after initialization
    func setOnboardingCallback(_ callback: @escaping () -> Void) {
        callbacks.onboarding = callback
    }

    func setShortcutHandlers(
        onHotkeyEvent: @escaping (HotkeyInputEvent) -> Void,
        onFeedback: @escaping (HotkeyFeedbackEvent) -> Void,
        onListenerReady: (() -> Void)? = nil
    ) {
        callbacks.hotkeyEvent = onHotkeyEvent
        callbacks.shortcutFeedback = onFeedback
        callbacks.hotkeyListenerReady = onListenerReady
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
            startDeferredOnboardingResumeIfNeeded()
        case .showOnboarding:
            await showOnboardingWindow()
        case .skip:
            break
        }
    }

    /// Initialize the app on first launch
    func initializeApp() async {
        StartupRecoveryManager.shared.markStage(.appInitializationStarted)

        // Check permissions first before attempting directory creation
        await permissionManager.checkPermissions()

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

        switch decision {
        case .deferForModelDownload:
            startDeferredOnboardingResumeIfNeeded()
        case .showOnboarding:
            await showOnboardingWindow()
        case .skip:
            break
        }

        // Create app directories after onboarding (this may trigger document access permission)
        do {
            try FileManager.createAppDirectories()
        } catch {
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
        }

        // Prewarm asynchronously so initialization does not block hotkey readiness.
        if launchPlan.steps.contains(.startModelPrewarmInBackground) {
            startModelPrewarmIfNeeded()
        }

        // Initialize auto-update system
        UpdateManager.shared.initialize()

        StartupRecoveryManager.shared.markStage(.appInitializationCompleted)
        hasInitialized = true
    }

    /// Finalize initialization after onboarding completes
    /// This initializes components that should only run after the user completes setup
    func finalizeInitialization() async {
        initializeGlobalShortcutsIfNeeded()
        startModelPrewarmIfNeeded()
    }

    private func initializeGlobalShortcutsIfNeeded() {
        guard permissionManager.criticalPermissionsGranted, UserDefaults.standard.hasCompletedOnboarding else {
            return
        }

        if StartupRecoveryManager.shared.shouldSkipGlobalShortcuts {
            StartupRecoveryManager.shared.markSubsystemSkipped(.globalShortcuts)
            StartupRecoveryManager.shared.appendDiagnostic("skipping global shortcuts during recovery launch")
            return
        }

        guard let onHotkeyEvent = callbacks.hotkeyEvent,
              let onFeedback = callbacks.shortcutFeedback
        else {
            return
        }

        if StartupRecoveryManager.shared.shouldSkipGlobalShortcuts {
            StartupRecoveryManager.shared.markSubsystemSkipped(.globalShortcuts)
            return
        }

        if !GlobalShortcutsManager.isInitialized {
            StartupRecoveryManager.shared.markStage(.shortcutsInitializing)
            GlobalShortcutsManager.initialize(
                onHotkeyEvent: onHotkeyEvent,
                onFeedback: onFeedback
            )
            callbacks.hotkeyListenerReady?()
        }
    }

    private func startModelPrewarmIfNeeded() {
        guard permissionManager.criticalPermissionsGranted, UserDefaults.standard.hasCompletedOnboarding else {
            return
        }

        guard prewarmTask == nil else { return }

        prewarmTask = Task { [weak self] in
            guard let self else { return }
            await engineCoordinator.preInitializeAllModels()
            await MainActor.run {
                self.prewarmTask = nil
            }
        }
    }

    private func startDeferredOnboardingResumeIfNeeded() {
        guard deferredOnboardingResumeTask == nil else { return }

        deferredOnboardingResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await engineCoordinator.preInitializeAllModels(prewarmBehavior: .modelsOnly)

            UserDefaults.standard.onboardingDeferredForModelDownload = false
            deferredOnboardingResumeTask = nil

            guard !UserDefaults.standard.hasCompletedOnboarding else { return }

            await showOnboardingWindow()
        }
    }

    private func showOnboardingWindow() async {
        // Use main actor to ensure UI updates happen on main thread
        await MainActor.run {
            callbacks.onboarding?()

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
