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

    private struct PersonaProcessingOutcome {
        let processedText: String
        let usedPersonaId: String?
        let overlayOutcomeSuccess: Bool
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("[AppDelegate] applicationDidFinishLaunching - initializing app")
        logStartupMetric("app launch", at: launchTimestamp)

        // Register custom fonts
        FontLoader.registerFonts()

        // Initialize all state objects (previously in SwiftUI App.init)
        initializeState()

        // Setup UI
        setupStatusItem()
        setupRecordingObserver()
        setupOverlayObserver()
        setupModelReadinessObserver()
        MenuBarHelper.delegate = self

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
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

        // Set explicit content size for reliable positioning
        popover.contentSize = NSSize(width: 340, height: 400)

        // Create MenuBarView ONCE at startup - maintains proper layout for correct positioning
        let menuBarView = MenuBarView(
            appState: appState,
            engineCoordinator: engineCoordinator,
            permissionManager: permissionManager
        )
        let hostingController = NSHostingController(rootView: menuBarView)

        // Set explicit frame to ensure size is known before first show
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 340, height: 400)

        popover.contentViewController = hostingController

        logger.info("[AppDelegate] ✅ Status item and popover configured with MenuBarView")
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

    private func applyOverlayVisibility(reason: String) {
        let now = Date()
        let nextPhase = OverlayVisibilityPolicy.resolve(
            OverlayVisibilityInput(
                overlayEnabled: overlayIsEnabled,
                isRecording: engineCoordinator.isRecording,
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
        UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
    }

    private func currentOverlayScreen() -> NSScreen? {
        statusItem?.button?.window?.screen ?? NSScreen.main
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

        isAwaitingTranscriptionCompletion = true
        clearOverlayOutcome()
        startOverlayProcessingTimeout()
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
                guard self.isAwaitingTranscriptionCompletion, !self.engineCoordinator.isRecording else { return }

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
        case .push:
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
            // "accepted" feedback currently originates from the push shortcut path.
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

    // MARK: - Popover Control

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }

        // Ensure button's window is ready for accurate positioning
        // On first show after launch, the button may not have its window set
        guard button.window != nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.showPopover()
            }
            return
        }

        // Trigger ObservableObject refresh to ensure view shows latest data
        appState.objectWillChange.send()
        engineCoordinator.objectWillChange.send()

        // Force layout to ensure size is calculated correctly
        popover.contentViewController?.view.layoutSubtreeIfNeeded()

        // Activate app BEFORE showing popover (better focus handling)
        NSApp.activate(ignoringOtherApps: true)

        // Show popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        popover.performClose(nil)
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

    // MARK: - Settings Window

    func openSettingsWindow() {
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        window.setContentSize(NSSize(width: 700, height: 550))
        window.center()
        window.makeKeyAndOrderFront(nil)

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)

        logger.info("[AppDelegate] Settings window opened")
    }

    // MARK: - Onboarding Window

    func openOnboardingWindow() {
        if let existingWindow = onboardingWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView(
            permissionManager: permissionManager,
            engineCoordinator: engineCoordinator,
            appState: appState,
            onComplete: { [weak self] in
                guard let self else { return }
                logger.info("[AppDelegate] Onboarding completed - finalizing initialization")
                Task { @MainActor in
                    await self.initService.finalizeInitialization()
                    try? await Task.sleep(for: .milliseconds(500))
                    self.onboardingWindow?.close()
                    self.showPopover()
                }
            }
        )
        .frame(width: 600, height: 500)

        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Flowstay"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 600, height: 500))
        window.center()
        window.makeKeyAndOrderFront(nil)

        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)

        logger.info("[AppDelegate] Onboarding window opened")
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

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString)
        else {
            logger.info("[AppDelegate] Invalid URL event received")
            return
        }

        logger.info("[AppDelegate] URL event received: \(url.scheme ?? "unknown")://\(url.host ?? "")\(url.path)")

        // Note: OpenRouter OAuth now uses localhost:3000 callback server instead of URL scheme
        // This handler remains for potential future URL scheme integrations
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
