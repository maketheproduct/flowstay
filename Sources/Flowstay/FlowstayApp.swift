import AppKit
import Combine
import FlowstayCore
import FlowstayPermissions
import FlowstayUI
import os
import SwiftUI

// MARK: - Pure AppKit Entry Point

// Using NSApplicationMain instead of SwiftUI @main to avoid Swift 6 actor isolation crashes
// The crash occurs when SwiftUI Scene body closures capture @MainActor isolated objects

/// App delegate that manages the status bar item, popover, and all windows
/// This is the main controller for the entire app - no SwiftUI App struct is used
class FlowstayAppDelegate: NSObject, NSApplicationDelegate, MenuBarPopoverController {
    // MARK: - Logging

    private let logger = Logger(subsystem: "com.flowstay.app", category: "AppDelegate")

    // MARK: - Status Bar

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Windows

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var onboardingWindowDelegate: OnboardingWindowDelegate?
    private var recoveryWindowDelegate: RecoveryWindowDelegate?
    private var onboardingOverlayMode: OnboardingOverlayMode = .suppressed
    private var shouldRestoreOnboardingWindowAfterAccessibilityPrompt = false
    private var onboardingWindowLevelBeforeAccessibilityPrompt: NSWindow.Level?

    // MARK: - State (owned by delegate, not SwiftUI)

    private var appState: AppState!
    private var engineCoordinator: EngineCoordinatorViewModel!
    private var permissionManager: PermissionManager!
    private var initService: AppInitializationService!
    private var personasEngine: PersonasEngine!
    private var overlayWindowController: OverlayWindowController?
    private var recordingTargetApp: DetectedApp?
    private var previousRecordingState = false
    private var isAwaitingTranscriptionCompletion = false
    private var overlayProcessingTimeoutTask: Task<Void, Never>?
    private var isHotkeyStartPending = false
    private var queuedStartRequest = false
    private var isHoldToTalkHotkeyPressed = false
    private var holdToTalkSessionActive = false
    private var stopHoldToTalkAfterTransition = false
    private var hotkeyWarmupTask: Task<Void, Never>?
    private var hotkeyStartupFeedbackTask: Task<Void, Never>?
    private var overlayOutcomeVisibleUntil: Date?
    private var overlayOutcomeState: OverlayOutcomeState?
    private var lastResolvedOverlayPhase: OverlayVisibilityPhase = .hidden
    private let launchTimestamp = Date()
    private var firstHotkeyKeydownAt: Date?
    private var firstHotkeyFeedbackAt: Date?
    private var firstRecordingStartAt: Date?
    private var hotkeyListenerReadyAt: Date?
    private var lastPopoverGuidanceAt: Date?

    private struct PersonaProcessingOutcome {
        let processedText: String
        let usedPersonaId: String?
        let overlayOutcomeSuccess: Bool
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("[AppDelegate] applicationDidFinishLaunching - initializing app")
        logStartupMetric("app launch", at: launchTimestamp)
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let startupContext = StartupRecoveryManager.shared.beginLaunch(version: shortVersion, build: buildVersion)
        if startupContext.recoveryMode {
            let stage = startupContext.previousIncompleteStage?.rawValue ?? "unknown"
            let build = startupContext.buildIdentifier
            logger.fault(
                "[AppDelegate] Startup recovery enabled for build \(build, privacy: .public) after incomplete stage \(stage, privacy: .public)"
            )
        }

        // Register custom fonts
        FontLoader.registerFonts()
        StartupRecoveryManager.shared.markStage(.fontsRegistered)

        // Initialize all state objects (previously in SwiftUI App.init)
        initializeState()
        StartupRecoveryManager.shared.markStage(.stateInitialized)

        // Setup UI
        setupStatusItem()
        setupRecordingObserver()
        setupOverlayObserver()
        setupModelReadinessObserver()
        setupHoldInputSourceObserver()
        MenuBarHelper.delegate = self
        StartupRecoveryManager.shared.markStage(.uiReady)

        // Register for URL events (OAuth callbacks)
        registerForURLEvents()

        // Set up onboarding callback
        initService.setOnboardingCallback { [weak self] in
            self?.logger.info("[AppDelegate] Opening onboarding window")
            self?.openOnboardingWindow()
        }

        // Set up transcription completion callback
        setupTranscriptionCallback()

        initService.setShortcutHandlers(
            onHotkeyEvent: { [weak self] event in
                self?.handleHotkeyEvent(event)
            },
            onFeedback: { [weak self] event in
                self?.handleHotkeyFeedback(event)
            },
            onListenerReady: { [weak self] in
                self?.recordHotkeyListenerReady()
            }
        )

        logger.info("[AppDelegate] Starting app initialization")
        Task { @MainActor in
            await initService.initializeApp()

            // Clean up old history based on retention setting
            let retentionDays = appState.historyRetentionDays
            if retentionDays > 0 {
                let deletedCount = await TranscriptionHistoryStore.shared.deleteOlderThan(days: retentionDays)
                if deletedCount > 0 {
                    logger.info("[AppDelegate] History cleanup: deleted \(deletedCount) records older than \(retentionDays) days")
                }
            }

            StartupRecoveryManager.shared.markStartupComplete()

            if startupContext.recoveryMode {
                openRecoveryWindow(autoPresented: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        restoreOnboardingWindowAfterAccessibilityPromptIfNeeded(reason: "app-became-active")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("[AppDelegate] applicationWillTerminate - cleaning up")
        overlayProcessingTimeoutTask?.cancel()
        overlayProcessingTimeoutTask = nil
        hotkeyWarmupTask?.cancel()
        hotkeyWarmupTask = nil
        hotkeyStartupFeedbackTask?.cancel()
        hotkeyStartupFeedbackTask = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        cancellables.removeAll()
    }

    // MARK: - State Initialization

    private func initializeState() {
        logger.info("[AppDelegate] Initializing state objects...")

        permissionManager = PermissionManager()
        appState = AppState()
        GlobalShortcutsManager.setHoldInputSource(appState.holdToTalkInputSource)
        engineCoordinator = EngineCoordinatorViewModel(appState: appState)
        personasEngine = PersonasEngine()
        overlayWindowController = OverlayWindowController(engineCoordinator: engineCoordinator)

        initService = AppInitializationService(
            permissionManager: permissionManager,
            appState: appState,
            engineCoordinator: engineCoordinator,
            onboardingCallback: nil
        )

        logger.info("[AppDelegate] ✅ State objects initialized")
    }

    private func setupTranscriptionCallback() {
        engineCoordinator.onTranscriptionComplete = { [weak self] finalText, duration in
            guard let self else { return }

            Task { @MainActor in
                await self.handleTranscriptionCompletion(finalText: finalText, duration: duration)
            }
        }
    }

    private func handleTranscriptionCompletion(finalText: String, duration: TimeInterval) async {
        // The callback fired — cancel the safety timeout immediately.
        // The overlay stays on .processing (isAwaitingTranscriptionCompletion remains true)
        // until we finish and call consumeAwaitingOverlayCompletion() at the end.
        cancelOverlayProcessingTimeout()

        // Safety net: always clear the processing overlay state, even if something
        // below crashes or hangs. The normal path clears it via consumeAwaitingOverlayCompletion().
        defer {
            if isAwaitingTranscriptionCompletion {
                logger.warning("[AppDelegate] Safety defer: clearing stuck isAwaitingTranscriptionCompletion")
                _ = consumeAwaitingOverlayCompletion()
                applyOverlayVisibility(reason: "transcription-callback-safety-cleanup")
            }
        }

        guard let appState, let permissionManager, let personasEngine else {
            logger.error("[AppDelegate] Missing required state objects in transcription callback")
            return
        }

        logger.info(
            "[AppDelegate] Transcription complete (\(finalText.count) chars, duration: \(String(format: "%.1f", duration))s)"
        )

        guard let finalTranscription = resolveFinalTranscriptionOrHandleNoSpeech(finalText) else {
            return
        }

        // Use app captured at recording start to keep routing stable even if focus changed.
        let detectedApp = recordingTargetApp ?? AppDetectionService.shared.currentApp
        let personaOutcome = await processPersonaIfNeeded(
            finalTranscription: finalTranscription,
            appState: appState,
            personasEngine: personasEngine,
            detectedApp: detectedApp
        )

        // Clear snapshot once this transcription is fully processed.
        recordingTargetApp = nil

        await persistTranscription(
            finalTranscription: finalTranscription,
            processedText: personaOutcome.processedText,
            usedPersonaId: personaOutcome.usedPersonaId,
            duration: duration,
            appState: appState,
            detectedApp: detectedApp
        )

        await performAutoPasteIfNeeded(
            processedText: personaOutcome.processedText,
            appState: appState,
            permissionManager: permissionManager
        )

        // Play completion sound AFTER paste (or if no paste, after processing)
        if appState.soundFeedbackEnabled {
            SoundManager.shared.playTranscriptionComplete()
        }

        if consumeAwaitingOverlayCompletion() {
            stageOverlayOutcome(success: personaOutcome.overlayOutcomeSuccess)
            applyOverlayVisibility(reason: "transcription-complete")
        }
    }

    private func resolveFinalTranscriptionOrHandleNoSpeech(_ finalText: String) -> String? {
        switch FinalTranscriptionPolicy.classify(finalText) {
        case .noSpeech:
            logger.warning("[AppDelegate] No transcription detected (trimmed empty). Showing overlay error state")
            recordingTargetApp = nil
            if consumeAwaitingOverlayCompletion() {
                stageOverlayOutcome(success: false)
                applyOverlayVisibility(reason: "transcription-empty-no-speech")
            } else {
                logger.debug("[AppDelegate] Empty transcription callback arrived with no awaiting overlay completion state")
            }
            return nil

        case let .transcript(trimmed):
            return trimmed
        }
    }

    private func processPersonaIfNeeded(
        finalTranscription: String,
        appState: AppState,
        personasEngine: PersonasEngine,
        detectedApp: DetectedApp?
    ) async -> PersonaProcessingOutcome {
        var processedText = finalTranscription
        var usedPersonaId: String?
        var overlayOutcomeSuccess = true

        guard appState.personasEnabled else {
            return PersonaProcessingOutcome(
                processedText: processedText,
                usedPersonaId: usedPersonaId,
                overlayOutcomeSuccess: overlayOutcomeSuccess
            )
        }

        var selectedPersonaId = appState.selectedPersonaId
        if appState.useSmartAppDetection,
           let app = detectedApp,
           let appPersonaId = appState.getPersonaForApp(app.bundleId)
        {
            selectedPersonaId = appPersonaId
            logger.info("[AppDelegate] Using app-specific persona for \(app.name): \(appPersonaId)")
        } else {
            logger.info("[AppDelegate] Using default persona: \(selectedPersonaId ?? "none")")
        }

        if selectedPersonaId == "none" {
            logger.info("[AppDelegate] Skipping persona per app rule")
        }

        guard let personaId = selectedPersonaId,
              let persona = appState.allPersonas.first(where: { $0.id == personaId })
        else {
            return PersonaProcessingOutcome(
                processedText: processedText,
                usedPersonaId: usedPersonaId,
                overlayOutcomeSuccess: overlayOutcomeSuccess
            )
        }

        logger.info("[AppDelegate] Processing with persona: \(persona.name)")

        let processingTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            NotificationManager.shared.sendNotification(
                title: "Processing transcription...",
                body: "AI is still working on your text",
                identifier: "processing-delay"
            )
        }

        let result = await personasEngine.processTranscriptionWithResult(
            finalTranscription,
            instruction: persona.instruction,
            appState: appState
        )
        processedText = result.text
        overlayOutcomeSuccess = result.isSuccess
        processingTimer.cancel()
        usedPersonaId = personaId

        logger.info("[AppDelegate] Personas processing complete (\(processedText.count) chars)")
        return PersonaProcessingOutcome(
            processedText: processedText,
            usedPersonaId: usedPersonaId,
            overlayOutcomeSuccess: overlayOutcomeSuccess
        )
    }

    private func persistTranscription(
        finalTranscription: String,
        processedText: String,
        usedPersonaId: String?,
        duration: TimeInterval,
        appState: AppState,
        detectedApp: DetectedApp?
    ) async {
        appState.recentTranscripts.insert(
            TranscriptItem(
                text: processedText,
                originalText: usedPersonaId != nil ? finalTranscription : nil,
                personaId: usedPersonaId,
                timestamp: Date(),
                duration: duration
            ),
            at: 0
        )

        let record = TranscriptionRecord(
            duration: duration,
            rawText: finalTranscription,
            processedText: processedText,
            personaId: usedPersonaId,
            personaName: usedPersonaId != nil ? appState.allPersonas.first(where: { $0.id == usedPersonaId })?.name : nil,
            appBundleId: detectedApp?.bundleId,
            appName: detectedApp?.name
        )
        await TranscriptionHistoryStore.shared.addIgnoringErrors(record)
    }

    private func performAutoPasteIfNeeded(
        processedText: String,
        appState: AppState,
        permissionManager: PermissionManager
    ) async {
        if appState.autoPasteEnabled, permissionManager.hasAccessibilityPermission {
            logger.info("[AppDelegate] Auto-pasting transcript...")
            await TextPaster.pasteText(processedText)
        } else if appState.autoPasteEnabled {
            logger.info("[AppDelegate] Auto-paste enabled but accessibility permission not granted")
        }
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        logger.info("[AppDelegate] Setting up status item...")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusIcon(isRecording: false)
            button.action = #selector(togglePopover)
            button.target = self

            // Pre-warm button window for first-show positioning
            // NSStatusItem.button.window may not be initialized immediately after creation
            // Accessing it asynchronously triggers the system to set it up
            DispatchQueue.main.async {
                _ = button.window
            }
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let popoverSize = preferredPopoverSize()

        // Set explicit content size for reliable positioning
        popover.contentSize = popoverSize

        installPopoverContent(size: popoverSize, appearance: statusItem?.button?.effectiveAppearance)

        logger.info("[AppDelegate] ✅ Status item and popover configured with MenuBarView")
    }

    private func makeMenuBarRootView() -> MenuBarView {
        MenuBarView(
            appState: appState,
            engineCoordinator: engineCoordinator,
            permissionManager: permissionManager
        )
    }

    private func installPopoverContent(size: CGSize, appearance: NSAppearance?) {
        let hostingController = NSHostingController(rootView: makeMenuBarRootView())
        hostingController.view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        hostingController.view.appearance = appearance

        popover.appearance = appearance
        popover.contentSize = size
        popover.contentViewController = hostingController
    }

    private func setupRecordingObserver() {
        engineCoordinator.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self else { return }

                if isRecording {
                    if firstRecordingStartAt == nil {
                        let now = Date()
                        firstRecordingStartAt = now
                        logStartupMetric("first recording start", at: now)
                    }
                    AppDetectionService.shared.detectFrontmostApp()
                    recordingTargetApp = AppDetectionService.shared.currentApp
                    if let app = recordingTargetApp {
                        logger.info("[AppDelegate] Captured recording target app: \(app.name) (\(app.bundleId))")
                    } else {
                        logger.info("[AppDelegate] Recording started with no detected target app")
                    }

                    if stopHoldToTalkAfterTransition, !isHoldToTalkHotkeyPressed {
                        stopHoldToTalkAfterTransition = false
                        holdToTalkSessionActive = false
                        applyHotkeyDecision(
                            HotkeyStartDecision(actions: [.stopRecording], queuedStartRequest: false)
                        )
                    }
                } else if !isHoldToTalkHotkeyPressed {
                    holdToTalkSessionActive = false
                    stopHoldToTalkAfterTransition = false
                }

                updateStatusIcon(isRecording: isRecording)
                handleOverlayRecordingTransition(isRecording: isRecording)
                previousRecordingState = isRecording
            }
            .store(in: &cancellables)

        engineCoordinator.$isTransitioningRecordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyOverlayVisibility(reason: "recording-transition-updated")
            }
            .store(in: &cancellables)
    }

    private func setupModelReadinessObserver() {
        engineCoordinator.$isModelsReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                guard let self else { return }
                guard isReady else { return }
                guard queuedStartRequest else { return }
                let decision = HotkeyStartPolicy.onModelsReady(
                    queuedStartRequest: queuedStartRequest,
                    modelsReady: isReady
                )
                applyHotkeyDecision(decision)
            }
            .store(in: &cancellables)
    }

    private func setupOverlayObserver() {
        applyOverlayVisibility(reason: "overlay-observer-setup")

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyOverlayVisibility(reason: "user-defaults-changed")
            }
            .store(in: &cancellables)
    }

    private func setupHoldInputSourceObserver() {
        appState.$holdToTalkInputSource
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { source in
                GlobalShortcutsManager.setHoldInputSource(source)
            }
            .store(in: &cancellables)
    }

    private func applyOverlayVisibility(reason: String) {
        let now = Date()
        let nextPhase = OverlayVisibilityPolicy.resolve(
            OverlayVisibilityInput(
                overlayEnabled: overlayIsEnabled,
                isRecording: engineCoordinator.isRecording,
                isTransitioningToRecording: engineCoordinator.isTransitioningRecordingState
                    && !engineCoordinator.isRecording
                    && !isAwaitingTranscriptionCompletion,
                isHotkeyStartPending: isHotkeyStartPending,
                isQueuedWarmup: queuedStartRequest,
                isAwaitingCompletion: isAwaitingTranscriptionCompletion,
                outcomeState: overlayOutcomeState,
                outcomeVisibleUntil: overlayOutcomeVisibleUntil
            ),
            now: now
        )
        let previousPhase = lastResolvedOverlayPhase

        if previousPhase != nextPhase {
            logger.debug(
                "[OverlayPhase] \(previousPhase.rawValue, privacy: .public) -> \(nextPhase.rawValue, privacy: .public) (\(reason, privacy: .public))"
            )
            lastResolvedOverlayPhase = nextPhase
        }

        switch nextPhase {
        case .hidden:
            if !overlayIsEnabled {
                cancelOverlayProcessingTimeout()
                isAwaitingTranscriptionCompletion = false
                clearOverlayOutcome()
            } else if let overlayOutcomeVisibleUntil, overlayOutcomeVisibleUntil <= now {
                clearOverlayOutcome()
            }
            overlayWindowController?.forceHide()

        case .recording:
            clearOverlayOutcome()
            overlayWindowController?.showRecording(on: currentOverlayScreen())

        case .warming:
            clearOverlayOutcome()
            overlayWindowController?.showWarmup(on: currentOverlayScreen())

        case .processing:
            clearOverlayOutcome()
            overlayWindowController?.showProcessing(on: currentOverlayScreen())
            if overlayProcessingTimeoutTask == nil {
                startOverlayProcessingTimeout()
            }

        case .outcomeSuccess, .outcomeError:
            if nextPhase != previousPhase {
                overlayWindowController?.showOutcome(
                    success: nextPhase == .outcomeSuccess,
                    on: currentOverlayScreen()
                )
            }
        }
    }

    private func clearOverlayOutcome() {
        overlayOutcomeVisibleUntil = nil
        overlayOutcomeState = nil
    }

    private func stageOverlayOutcome(success: Bool) {
        overlayOutcomeVisibleUntil = Date().addingTimeInterval(1.1)
        overlayOutcomeState = success ? .success : .error
    }

    private var overlayIsEnabled: Bool {
        OverlayEnablementPolicy.resolve(
            OverlayEnablementInput(
                userPreferenceEnabled: UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true,
                onboardingVisible: onboardingWindow?.isVisible ?? false,
                onboardingOverlayMode: onboardingOverlayMode
            )
        )
    }

    private func currentOverlayScreen() -> NSScreen? {
        if onboardingOverlayMode == .followRuntime,
           onboardingWindow?.isVisible == true,
           let onboardingScreen = onboardingWindow?.screen
        {
            return onboardingScreen
        }

        return statusItem?.button?.window?.screen ?? NSScreen.main
    }

    private func setOnboardingOverlayMode(_ mode: OnboardingOverlayMode, reason: String) {
        guard onboardingOverlayMode != mode else { return }
        onboardingOverlayMode = mode
        applyOverlayVisibility(reason: reason)
    }

    private func handleOverlayRecordingTransition(isRecording: Bool) {
        let wasRecording = previousRecordingState

        if isRecording {
            clearOverlayOutcome()
            setHotkeyStartPending(false)
            setQueuedStartRequest(false)
            isAwaitingTranscriptionCompletion = false
            cancelOverlayProcessingTimeout()
            applyOverlayVisibility(reason: "recording-started")
            return
        }

        guard wasRecording else { return }

        if !isAwaitingTranscriptionCompletion {
            isAwaitingTranscriptionCompletion = true
            clearOverlayOutcome()
            startOverlayProcessingTimeout()
        }
        applyOverlayVisibility(reason: "recording-stopped-awaiting-transcription")
    }

    private func startOverlayProcessingTimeout() {
        cancelOverlayProcessingTimeout()
        overlayProcessingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard self.isAwaitingTranscriptionCompletion, !self.engineCoordinator.isRecording else {
                    return
                }

                self.logger.warning("[AppDelegate] Overlay processing timeout reached; showing error state")
                if self.consumeAwaitingOverlayCompletion() {
                    self.stageOverlayOutcome(success: false)
                }
                self.overlayProcessingTimeoutTask = nil
                self.applyOverlayVisibility(reason: "processing-timeout")
            }
        }
    }

    private func cancelOverlayProcessingTimeout() {
        overlayProcessingTimeoutTask?.cancel()
        overlayProcessingTimeoutTask = nil
    }

    private func consumeAwaitingOverlayCompletion() -> Bool {
        let shouldShowOutcome = isAwaitingTranscriptionCompletion
        isAwaitingTranscriptionCompletion = false
        cancelOverlayProcessingTimeout()
        return shouldShowOutcome
    }

    private func handleHotkeyToggleRequested() {
        let decision = HotkeyStartPolicy.onToggle(
            HotkeyStartInput(
                isRecording: engineCoordinator.isRecording,
                isTransitioning: engineCoordinator.isTransitioningRecordingState,
                isAwaitingCompletion: isAwaitingTranscriptionCompletion,
                permissionsGranted: permissionManager.criticalPermissionsGranted,
                modelsDownloaded: engineCoordinator.isModelDownloaded(),
                modelsReady: engineCoordinator.isModelsReady,
                queuedStartRequest: queuedStartRequest
            )
        )
        applyHotkeyDecision(decision)
    }

    private func handleHotkeyEvent(_ event: HotkeyInputEvent) {
        switch appState.hotkeyPressMode {
        case .toggle:
            resetHoldToTalkState()
            guard event == .shortcutKeyDown else { return }
            handleHotkeyToggleRequested()

        case .hold:
            handleHoldToTalkEvent(event)

        case .both:
            if event == .shortcutKeyDown {
                resetHoldToTalkState()
                handleHotkeyToggleRequested()
                return
            }
            handleHoldToTalkEvent(event)
        }
    }

    private func handleHoldToTalkEvent(_ event: HotkeyInputEvent) {
        switch event {
        case .functionKeyDown:
            guard !isHoldToTalkHotkeyPressed else { return }
            isHoldToTalkHotkeyPressed = true
            stopHoldToTalkAfterTransition = false
            registerHotkeyKeydownIfNeeded()

            // Hold-to-talk only takes over recordings started by this hold interaction.
            guard !engineCoordinator.isRecording else {
                holdToTalkSessionActive = false
                return
            }

            holdToTalkSessionActive = true
            handleHotkeyToggleRequested()

        case .functionKeyUp:
            guard isHoldToTalkHotkeyPressed else { return }
            isHoldToTalkHotkeyPressed = false
            stopHoldToTalkSessionIfNeeded()

        case .shortcutKeyDown, .shortcutKeyUp:
            return
        }
    }

    private func stopHoldToTalkSessionIfNeeded() {
        guard holdToTalkSessionActive else { return }

        if queuedStartRequest {
            holdToTalkSessionActive = false
            applyHotkeyDecision(
                HotkeyStartDecision(actions: [.cancelQueuedWarmup], queuedStartRequest: false)
            )
            return
        }

        if engineCoordinator.isTransitioningRecordingState {
            holdToTalkSessionActive = false
            stopHoldToTalkAfterTransition = true
            return
        }

        guard engineCoordinator.isRecording else {
            resetHoldToTalkState()
            return
        }

        holdToTalkSessionActive = false
        stopHoldToTalkAfterTransition = false
        applyHotkeyDecision(
            HotkeyStartDecision(actions: [.stopRecording], queuedStartRequest: false)
        )
    }

    private func resetHoldToTalkState() {
        isHoldToTalkHotkeyPressed = false
        holdToTalkSessionActive = false
        stopHoldToTalkAfterTransition = false
    }

    private func applyHotkeyDecision(_ decision: HotkeyStartDecision) {
        let shouldMaintainPendingWarmup = isHotkeyStartPending
            || decision.actions.contains(.queueWarmup)
            || decision.actions.contains(.startRecording)
            || decision.actions.contains(.blocked(.queued))

        if shouldMaintainPendingWarmup {
            setHotkeyStartPending(true)
        }

        setQueuedStartRequest(decision.queuedStartRequest)

        for action in decision.actions {
            switch action {
            case .startRecording:
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await engineCoordinator.startRecording()
                    } catch {
                        stopHoldToTalkAfterTransition = false
                        holdToTalkSessionActive = false
                        setHotkeyStartPending(false)
                        logger.error("[AppDelegate] Failed to start recording from hotkey: \(error.localizedDescription)")
                        handleHotkeyFeedback(.error)
                    }
                }

            case .stopRecording:
                setHotkeyStartPending(false)
                if engineCoordinator.isRecording {
                    isAwaitingTranscriptionCompletion = true
                    clearOverlayOutcome()
                    startOverlayProcessingTimeout()
                    applyOverlayVisibility(reason: "recording-stop-initiated")
                }
                Task { @MainActor [weak self] in
                    await self?.engineCoordinator.stopRecording()
                }

            case .queueWarmup:
                setHotkeyStartPending(true)
                startHotkeyWarmupTimeout()
                applyOverlayVisibility(reason: "hotkey-queue-warmup")

            case .cancelQueuedWarmup:
                setHotkeyStartPending(false)
                setQueuedStartRequest(false)
                handleHotkeyFeedback(.blockedTransition)

            case .showModelGuidance:
                setHotkeyStartPending(false)
                openOnboardingWindow()

            case let .blocked(event):
                handleHotkeyFeedback(event)
            }
        }
    }

    private func startHotkeyWarmupTimeout() {
        hotkeyWarmupTask?.cancel()
        hotkeyWarmupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }

            let timeoutDecision = HotkeyStartPolicy.onWarmupTimeout(queuedStartRequest: queuedStartRequest)
            applyHotkeyDecision(timeoutDecision)
        }
    }

    private func setQueuedStartRequest(_ queued: Bool) {
        guard queuedStartRequest != queued else { return }
        queuedStartRequest = queued

        if !queued {
            hotkeyWarmupTask?.cancel()
            hotkeyWarmupTask = nil
        }

        applyOverlayVisibility(reason: "queued-start-updated")
    }

    private func setHotkeyStartPending(_ pending: Bool) {
        guard isHotkeyStartPending != pending else { return }
        isHotkeyStartPending = pending
        applyOverlayVisibility(reason: "hotkey-pending-updated")
    }

    private func registerHotkeyKeydownIfNeeded() {
        if firstHotkeyKeydownAt == nil {
            let now = Date()
            firstHotkeyKeydownAt = now
            logStartupMetric("first hotkey keydown", at: now)
        }
        if HotkeyStartPolicy.shouldShowStartPendingOnAccepted(
            isRecording: engineCoordinator.isRecording,
            isAwaitingCompletion: isAwaitingTranscriptionCompletion,
            permissionsGranted: permissionManager.criticalPermissionsGranted,
            modelsDownloaded: engineCoordinator.isModelDownloaded()
        ) {
            setHotkeyStartPending(true)
        }
    }

    private func handleHotkeyFeedback(_ event: HotkeyFeedbackEvent) {
        let now = Date()
        if event == .accepted {
            // "accepted" feedback currently originates from the toggle shortcut path.
            if appState.hotkeyPressMode != .hold {
                registerHotkeyKeydownIfNeeded()
            }
            return
        }

        switch event {
        case .queued:
            setHotkeyStartPending(true)

        case .blockedTransition:
            if !engineCoordinator.isTransitioningRecordingState {
                setHotkeyStartPending(false)
            }

        case .blockedPermissions, .notReady, .error:
            setHotkeyStartPending(false)

        case .accepted:
            break
        }

        if firstHotkeyFeedbackAt == nil {
            firstHotkeyFeedbackAt = now
            logStartupMetric("first hotkey feedback", at: now)
        }

        if appState.soundFeedbackEnabled {
            switch event {
            case .queued:
                SoundManager.shared.playQueuedFeedback()
            case .blockedTransition, .blockedPermissions, .notReady, .error:
                SoundManager.shared.playBlockedFeedback()
            case .accepted:
                break
            }
        }

        if event == .blockedPermissions || event == .notReady {
            openOnboardingWindow()
        }

        showHotkeyVisualFeedback(event)
    }

    private func showHotkeyVisualFeedback(_ event: HotkeyFeedbackEvent) {
        switch event {
        case .queued:
            if overlayIsEnabled {
                applyOverlayVisibility(reason: "hotkey-feedback-queued")
            } else {
                flashStatusItemAcknowledgement()
            }

        case .blockedTransition, .blockedPermissions, .notReady, .error:
            if event == .blockedTransition, queuedStartRequest {
                flashStatusItemAcknowledgement()
                return
            }
            if overlayIsEnabled,
               !engineCoordinator.isRecording,
               !isAwaitingTranscriptionCompletion
            {
                stageOverlayOutcome(success: false)
                applyOverlayVisibility(reason: "hotkey-feedback-blocked")
            } else {
                flashStatusItemAcknowledgement()
            }

        case .accepted:
            break
        }
    }

    private func flashStatusItemAcknowledgement() {
        hotkeyStartupFeedbackTask?.cancel()
        guard let button = statusItem?.button else { return }

        if let customFeedbackIcon = MenuBarIcon.loadIcon(isRecording: true) {
            button.image = customFeedbackIcon
        } else {
            let fallbackFeedbackIcon = NSImage(
                systemSymbolName: MenuBarIcon.systemIconName(isRecording: true),
                accessibilityDescription: "Flowstay feedback"
            )
            button.image = fallbackFeedbackIcon
        }

        hotkeyStartupFeedbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                hotkeyStartupFeedbackTask = nil
                return
            }
            updateStatusIcon(isRecording: engineCoordinator.isRecording)
            hotkeyStartupFeedbackTask = nil
        }
    }

    private func recordHotkeyListenerReady() {
        guard hotkeyListenerReadyAt == nil else { return }
        let now = Date()
        hotkeyListenerReadyAt = now
        logStartupMetric("hotkey listener ready", at: now)
    }

    private func logStartupMetric(_ label: String, at timestamp: Date) {
        let delta = timestamp.timeIntervalSince(launchTimestamp)
        logger.info("[StartupTelemetry] \(label, privacy: .public) +\(delta, format: .fixed(precision: 3))s")
    }

    private func updateStatusIcon(isRecording: Bool) {
        guard let button = statusItem?.button else { return }

        if let customIcon = MenuBarIcon.loadIcon(isRecording: isRecording) {
            button.image = customIcon
        } else {
            let iconName = MenuBarIcon.systemIconName(isRecording: isRecording)
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Flowstay")
        }
    }

    // MARK: - URL Handling (OAuth Callbacks)

    private func registerForURLEvents() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        logger.info("[AppDelegate] Registered for URL events")
    }

    /// `nonisolated` so the Apple-Event dispatcher can invoke the selector
    /// without triggering a `_checkExpectedExecutor` crash.
    @objc private nonisolated func handleURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent _: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString)
        else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.logger.info("[AppDelegate] Invalid URL event received")
                }
            }
            return
        }

        let scheme = url.scheme ?? "unknown"
        let host = url.host ?? ""
        let path = url.path

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.logger.info("[AppDelegate] URL event received: \(scheme)://\(host)\(path)")
            }
        }

        // Note: OpenRouter OAuth now uses localhost:3000 callback server instead of URL scheme
        // This handler remains for potential future URL scheme integrations
    }
}

// MARK: - Popover Control

extension FlowstayAppDelegate {
    /// `nonisolated` so the Objective-C runtime can call the selector without
    /// triggering a `_checkExpectedExecutor` crash when it dispatches from a
    /// non-main thread.  We bounce back to the main thread explicitly.
    @objc nonisolated func togglePopover() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.popover != nil else { return }
                if self.popover.isShown {
                    self.closePopover()
                } else {
                    self.showPopover()
                }
            }
        }
    }

    func showPopover() {
        showPopover(retryCount: 0, forceOnFailure: false)
    }

    func showPopover(retryCount: Int, forceOnFailure: Bool) {
        guard let button = statusItem?.button else { return }

        guard button.window != nil else {
            guard retryCount < 3 else {
                if forceOnFailure {
                    forceShowPopover(button: button, reason: "status-button-window-unavailable")
                } else {
                    showMenuBarClickGuidance(reason: "status-button-window-unavailable")
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.showPopover(retryCount: retryCount + 1, forceOnFailure: forceOnFailure)
            }
            return
        }

        appState.objectWillChange.send()
        engineCoordinator.objectWillChange.send()

        let popoverSize = preferredPopoverSize()
        let appearance = button.window?.effectiveAppearance ?? button.effectiveAppearance
        installPopoverContent(size: popoverSize, appearance: appearance)
        popover.contentViewController?.view.layoutSubtreeIfNeeded()

        NSApp.activate(ignoringOtherApps: true)

        let anchorResolution = MenuBarPopoverAnchorPolicy.resolve(button: button)
        if anchorResolution.isValid {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            return
        }

        guard retryCount < 3 else {
            if forceOnFailure {
                forceShowPopover(button: button, reason: anchorResolution.reason)
            } else {
                showMenuBarClickGuidance(reason: anchorResolution.reason)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.showPopover(retryCount: retryCount + 1, forceOnFailure: forceOnFailure)
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func preferredPopoverSize() -> CGSize {
        MenuBarView.preferredPopoverSize(
            criticalPermissionsGranted: permissionManager.criticalPermissionsGranted,
            onboardingComplete: UserDefaults.standard.hasCompletedOnboarding,
            recoveryActive: StartupRecoveryManager.shared.snapshot.isDegradedLaunch,
            modelsReady: engineCoordinator.isModelsReady,
            isRecording: engineCoordinator.isRecording
        )
    }

    func showMenuBarClickGuidance(reason: String) {
        let now = Date()
        if let lastPopoverGuidanceAt, now.timeIntervalSince(lastPopoverGuidanceAt) < 5 {
            return
        }
        lastPopoverGuidanceAt = now

        logger.warning(
            "[AppDelegate] Popover anchor invalid after retries (reason: \(reason, privacy: .public))"
        )

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Flowstay is ready"
        alert.informativeText = "Click the Flowstay icon in the menu bar to open the panel."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func forceShowPopover(button: NSStatusBarButton, reason: String) {
        logger.warning(
            "[AppDelegate] Forcing popover presentation (reason: \(reason, privacy: .public))"
        )
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func toggleTranscriptionFromMenuBar() {
        resetHoldToTalkState()
        if HotkeyStartPolicy.shouldShowStartPendingOnAccepted(
            isRecording: engineCoordinator.isRecording,
            isAwaitingCompletion: isAwaitingTranscriptionCompletion,
            permissionsGranted: permissionManager.criticalPermissionsGranted,
            modelsDownloaded: engineCoordinator.isModelDownloaded()
        ) {
            setHotkeyStartPending(true)
        }

        handleHotkeyToggleRequested()
    }
}

// MARK: - Settings & Recovery Windows

extension FlowstayAppDelegate {
    func openSettingsWindow() {
        if popover.isShown {
            closePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.presentSettingsWindow()
            }
            return
        }

        presentSettingsWindow()
    }

    private func presentSettingsWindow() {
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            refreshWindowContentAfterPresentation(existingWindow)
            return
        }

        let settingsView = TabbedSettingsView(
            appState: appState,
            engineCoordinator: engineCoordinator,
            permissionManager: permissionManager
        )

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Flowstay Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 860, height: 620))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshWindowContentAfterPresentation(window)

        settingsWindow = window

        logger.info("[AppDelegate] Settings window opened")
    }

    func openRecoveryWindow() {
        openRecoveryWindow(autoPresented: false)
    }

    func openRecoveryWindow(autoPresented: Bool) {
        closePopover()

        if let existingWindow = recoveryWindow, existingWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            refreshWindowContentAfterPresentation(existingWindow)
            return
        }

        let recoveryView = RecoveryTroubleshootingView(
            appState: appState,
            autoPresented: autoPresented,
            onContinue: { [weak self] in
                self?.recoveryWindow?.close()
            }
        )

        let hostingController = NSHostingController(rootView: recoveryView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Flowstay Troubleshooting"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 760, height: 640))
        let delegate = RecoveryWindowDelegate { [weak self] in
            self?.recoveryWindow = nil
            self?.recoveryWindowDelegate = nil
        }
        recoveryWindowDelegate = delegate
        window.delegate = delegate
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshWindowContentAfterPresentation(window)

        recoveryWindow = window
        logger.info("[AppDelegate] Recovery troubleshooting window opened")
    }
}

// MARK: - Onboarding Window

extension FlowstayAppDelegate {
    func openOnboardingWindow() {
        closePopover()

        if let existingWindow = onboardingWindow, existingWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            refreshWindowContentAfterPresentation(existingWindow)
            applyOverlayVisibility(reason: "onboarding-window-reopened")
            return
        }

        setOnboardingOverlayMode(.suppressed, reason: "onboarding-window-open-requested")

        let onboardingView = OnboardingView(
            permissionManager: permissionManager,
            engineCoordinator: engineCoordinator,
            appState: appState,
            onComplete: { [weak self] in
                guard let self else { return }
                logger.info("[AppDelegate] Onboarding completed - finalizing initialization")
                Task { @MainActor in
                    await self.initService.finalizeInitialization()
                    self.onboardingWindow?.close()
                    await self.presentPrimarySurfaceAfterOnboardingCompletion()
                }
            },
            onOverlayModeChange: { [weak self] mode in
                self?.setOnboardingOverlayMode(mode, reason: "onboarding-scene-updated")
            },
            onAccessibilityPromptWillPresent: { [weak self] in
                await self?.prepareOnboardingWindowForAccessibilityPrompt()
            },
            onAccessibilityPromptDidComplete: { [weak self] granted in
                guard granted else { return }
                self?.restoreOnboardingWindowAfterAccessibilityPromptIfNeeded(
                    reason: "accessibility-request-granted"
                )
            }
        )
        .frame(width: 860, height: 660)

        let hostingController = NSHostingController(rootView: onboardingView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        let window = OnboardingPanel(contentViewController: hostingController)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.setContentSize(NSSize(width: 860, height: 660))

        let delegate = OnboardingWindowDelegate(
            permissionManager: permissionManager,
            engineCoordinator: engineCoordinator,
            onWindowWillClose: { [weak self] in
                guard let self else { return }
                onboardingWindow = nil
                onboardingWindowDelegate = nil
                clearOnboardingAccessibilityPromptState()
                setOnboardingOverlayMode(.suppressed, reason: "onboarding-window-closed")
                applyOverlayVisibility(reason: "onboarding-window-closed")
            }
        )
        onboardingWindowDelegate = delegate
        window.delegate = delegate

        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshWindowContentAfterPresentation(window)

        onboardingWindow = window
        applyOverlayVisibility(reason: "onboarding-window-opened")

        logger.info("[AppDelegate] Onboarding window opened")
    }

    func presentPrimarySurfaceAfterOnboardingCompletion() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(120))
        showPopover(retryCount: 0, forceOnFailure: true)
    }

    func refreshWindowContentAfterPresentation(_ window: NSWindow) {
        DispatchQueue.main.async {
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    func prepareOnboardingWindowForAccessibilityPrompt() async {
        guard let onboardingWindow, onboardingWindow.isVisible else { return }

        if !shouldRestoreOnboardingWindowAfterAccessibilityPrompt {
            onboardingWindowLevelBeforeAccessibilityPrompt = onboardingWindow.level
        }

        shouldRestoreOnboardingWindowAfterAccessibilityPrompt = true

        onboardingWindow.level = .normal
        onboardingWindow.orderBack(nil)

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(180))
    }

    func restoreOnboardingWindowAfterAccessibilityPromptIfNeeded(reason: String) {
        guard shouldRestoreOnboardingWindowAfterAccessibilityPrompt else { return }

        guard let onboardingWindow else {
            clearOnboardingAccessibilityPromptState()
            return
        }

        onboardingWindow.level = onboardingWindowLevelBeforeAccessibilityPrompt ?? .floating

        guard NSApp.isActive else { return }

        onboardingWindow.makeKeyAndOrderFront(nil)
        refreshWindowContentAfterPresentation(onboardingWindow)
        logger.debug(
            "[AppDelegate] Restored onboarding window after accessibility flow (\(reason, privacy: .public))"
        )
        clearOnboardingAccessibilityPromptState()
    }

    func clearOnboardingAccessibilityPromptState() {
        shouldRestoreOnboardingWindowAfterAccessibilityPrompt = false
        onboardingWindowLevelBeforeAccessibilityPrompt = nil
    }
}

private enum MenuBarPopoverAnchorPolicy {
    struct Resolution {
        let isValid: Bool
        let reason: String
    }

    static func resolve(button: NSStatusBarButton) -> Resolution {
        guard let window = button.window else {
            return Resolution(isValid: false, reason: "status-button-window-missing")
        }

        let frameInWindow = button.convert(button.bounds, to: nil)
        let frameInScreen = window.convertToScreen(frameInWindow)
        let screen = window.screen ?? NSScreen.main

        guard frameInScreen.hasFiniteValues else {
            return Resolution(isValid: false, reason: "anchor-frame-nonfinite")
        }

        guard frameInScreen.width > 2, frameInScreen.height > 2 else {
            return Resolution(isValid: false, reason: "anchor-frame-too-small")
        }

        guard let screen else {
            return Resolution(isValid: false, reason: "anchor-screen-missing")
        }

        let midpoint = NSPoint(x: frameInScreen.midX, y: frameInScreen.midY)
        guard screen.frame.contains(midpoint) else {
            return Resolution(isValid: false, reason: "anchor-outside-screen")
        }

        // Menu bar extras are on the right side. Frames resolving on the left
        // half are usually stale/invalid status-item geometry.
        guard frameInScreen.midX >= screen.frame.midX else {
            return Resolution(isValid: false, reason: "anchor-left-half")
        }

        return Resolution(isValid: true, reason: "ok")
    }
}

private extension NSRect {
    var hasFiniteValues: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}

private final class OnboardingPanel: NSPanel {
    convenience init(contentViewController: NSViewController) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        isFloatingPanel = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private weak var permissionManager: PermissionManager?
    private weak var engineCoordinator: EngineCoordinatorViewModel?
    private let onWindowWillClose: (() -> Void)?

    init(
        permissionManager: PermissionManager,
        engineCoordinator: EngineCoordinatorViewModel,
        onWindowWillClose: (() -> Void)? = nil
    ) {
        self.permissionManager = permissionManager
        self.engineCoordinator = engineCoordinator
        self.onWindowWillClose = onWindowWillClose
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        guard let permissionManager, let engineCoordinator else {
            return true
        }

        if UserDefaults.standard.onboardingDeferredForModelDownload,
           permissionManager.criticalPermissionsGranted,
           !engineCoordinator.isModelsReady
        {
            return true
        }

        if permissionManager.criticalPermissionsGranted, engineCoordinator.isModelsReady {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Finish setup before closing?"
        alert.informativeText = "Flowstay still needs required setup before it can transcribe reliably."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Setup")
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Quit App")

        let response = alert.runModal()
        switch response {
        case .alertSecondButtonReturn:
            return true
        case .alertThirdButtonReturn:
            NSApplication.shared.terminate(nil)
            return false
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        onWindowWillClose?()
    }
}

private final class RecoveryWindowDelegate: NSObject, NSWindowDelegate {
    private let onWindowWillClose: (() -> Void)?

    init(onWindowWillClose: (() -> Void)? = nil) {
        self.onWindowWillClose = onWindowWillClose
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        onWindowWillClose?()
    }
}

// MARK: - Main Entry Point

// Pure AppKit entry - no SwiftUI App struct to avoid Swift 6 actor isolation crashes

@main
struct FlowstayMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = FlowstayAppDelegate()
        app.delegate = delegate

        // Keep a strong reference to prevent deallocation
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
