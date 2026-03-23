import AppKit
import Combine
import FlowstayCore
import KeyboardShortcuts
import SwiftUI

enum OnboardingTutorialMode: String {
    case toggle
    case hold

    var displayName: String {
        switch self {
        case .toggle:
            "Toggle"
        case .hold:
            "Hold"
        }
    }
}

enum OnboardingViewCommand: Equatable {
    case dismissAfterDeferral
    case completeOnboarding
}

enum HotkeyTutorialStep: Int, CaseIterable {
    case toggleStartPrompt
    case toggleRecording
    case toggleStopPrompt
    case togglePasteDemo
    case holdStartPrompt
    case holdRecording
    case holdReleasePrompt
    case holdPasteDemo
    case complete

    var requiresUserAction: Bool {
        switch self {
        case .toggleStartPrompt, .toggleRecording, .toggleStopPrompt,
             .holdStartPrompt, .holdRecording, .holdReleasePrompt:
            true
        case .togglePasteDemo, .holdPasteDemo, .complete:
            false
        }
    }
}

struct TutorialKeyVisual: Identifiable {
    let label: String
    let state: TutorialKeyVisualState

    var id: String {
        label
    }
}

enum ToggleShortcutHandlingPolicy {
    static let debounceInterval: TimeInterval = 0.15

    static func shouldAcceptPress(now: Date, lastHandledAt: Date?) -> Bool {
        guard let lastHandledAt else { return true }
        return now.timeIntervalSince(lastHandledAt) >= debounceInterval
    }

    static func shouldStopToggleRecording(
        tutorialStep: HotkeyTutorialStep,
        activeMode: OnboardingTutorialMode?,
        isRecording: Bool
    ) -> Bool {
        guard isRecording, activeMode == .toggle else { return false }
        return tutorialStep == .toggleRecording || tutorialStep == .toggleStopPrompt
    }
}

@MainActor
final class OnboardingAccessibilityPromptHandler {
    private let onWillPresent: (@MainActor () async -> Void)?
    private let onDidComplete: (@MainActor (Bool) -> Void)?

    private init(
        onWillPresent: (@MainActor () async -> Void)?,
        onDidComplete: (@MainActor (Bool) -> Void)?
    ) {
        self.onWillPresent = onWillPresent
        self.onDidComplete = onDidComplete
    }

    static func make(
        onWillPresent: (@MainActor () async -> Void)?,
        onDidComplete: (@MainActor (Bool) -> Void)?
    ) -> OnboardingAccessibilityPromptHandler? {
        guard onWillPresent != nil || onDidComplete != nil else {
            return nil
        }
        return OnboardingAccessibilityPromptHandler(
            onWillPresent: onWillPresent,
            onDidComplete: onDidComplete
        )
    }

    func notifyWillPresent() async {
        await onWillPresent?()
    }

    func notifyDidComplete(granted: Bool) {
        onDidComplete?(granted)
    }
}

// swiftlint:disable type_body_length
@MainActor
final class OnboardingCoordinator: ObservableObject {
    enum NavigationDirection {
        case forward
        case backward
    }

    @Published var currentScene: OnboardingScene = .welcome {
        didSet {
            handleSceneChange(from: oldValue, to: currentScene)
        }
    }

    @Published var navigationDirection: NavigationDirection = .forward

    @Published private(set) var microphoneStatus: PermissionStatus
    @Published private(set) var accessibilityStatus: PermissionStatus

    @Published var isRequestingMicrophone = false
    @Published var isPreparingModel = false
    @Published var modelReady = false
    @Published var modelError: String?

    @Published var firstWinTranscript = ""
    @Published var toggleModeCompleted = false
    @Published var holdModeCompleted = false
    @Published private(set) var activeTutorialMode: OnboardingTutorialMode?
    @Published var firstWinError: String?
    @Published var isRecordingFirstWin = false
    @Published private(set) var tutorialStep: HotkeyTutorialStep = .toggleStartPrompt
    @Published var latestTutorialTranscript = ""
    @Published var demoPasteText = ""
    @Published var isAnimatingPasteDemo = false
    @Published var showHotkeyFallbackHint = false
    @Published var isShortcutPickerPresented = false
    @Published var shortcutValidationMessage: String?
    @Published private(set) var tutorialToggleShortcutDescription = "⌥Space"
    @Published private(set) var tutorialHoldShortcutDescription = "Fn"
    @Published private(set) var isToggleKeyPressed = false
    @Published private(set) var isHoldKeyPressed = false

    @Published var isRequestingAccessibility = false
    @Published var showAccessibilityFallbackHint = false
    @Published private(set) var viewCommand: OnboardingViewCommand?

    let appState: AppState

    private let permissionManager: PermissionManager
    private let engineCoordinator: EngineCoordinatorViewModel
    private let accessibilityPromptHandler: OnboardingAccessibilityPromptHandler?
    private let hotkeyMonitor = OnboardingHotkeyMonitor()
    private let defaultToggleShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])

    private var hotkeyToggleShortcut: KeyboardShortcuts.Shortcut
    private var hotkeyHoldShortcut: KeyboardShortcuts.Shortcut?

    private var cancellables = Set<AnyCancellable>()
    private var modelPreparationTask: Task<Void, Never>?
    private var firstWinCaptureTask: Task<Void, Never>?
    private var audioPrewarmTask: Task<Void, Never>?
    private var pasteDemoTask: Task<Void, Never>?
    private var inactivityFallbackTask: Task<Void, Never>?
    private var toggleKeyPulseTask: Task<Void, Never>?
    private var deferredModelPreparationTask: Task<Void, Never>?
    private var initialized = false
    private var holdModeSessionActive = false
    private var didDetectSpeechInCurrentAttempt = false
    private var toggleFailureCount = 0
    private var holdFailureCount = 0
    private var lastToggleShortcutHandledAt: Date?

    private let inactivityFallbackNanoseconds: UInt64 = 20_000_000_000
    private let fallbackFailureThreshold = 2

    init(
        permissionManager: PermissionManager,
        engineCoordinator: EngineCoordinatorViewModel,
        appState: AppState,
        accessibilityPromptHandler: OnboardingAccessibilityPromptHandler? = nil
    ) {
        self.permissionManager = permissionManager
        self.engineCoordinator = engineCoordinator
        self.appState = appState
        self.accessibilityPromptHandler = accessibilityPromptHandler
        microphoneStatus = permissionManager.microphoneStatus
        accessibilityStatus = permissionManager.accessibilityStatus
        modelReady = engineCoordinator.isModelsReady

        if KeyboardShortcuts.getShortcut(for: .toggleDictation) == nil {
            KeyboardShortcuts.setShortcut(defaultToggleShortcut, for: .toggleDictation)
        }

        hotkeyToggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) ?? defaultToggleShortcut
        hotkeyHoldShortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk)

        observeDependencies()
        configureHotkeyMonitor()
        refreshTutorialShortcutBindings()
    }

    var requiredSetupComplete: Bool {
        microphoneStatus == .authorized && modelReady
    }

    var accessibilityGranted: Bool {
        accessibilityStatus == .authorized
    }

    var accessibilityDescriptionText: String {
        if accessibilityGranted {
            return "Auto-paste is on. Flowstay can insert transcribed text into the app you're using."
        }

        if showAccessibilityFallbackHint {
            return "macOS shows this approval outside Flowstay. If you do not see it immediately, use Accessibility settings and enable Flowstay there."
        }

        return "Flowstay uses Accessibility only to paste the text it transcribes into the app you are using."
    }

    var accessibilityPrimaryActionTitle: String {
        showAccessibilityFallbackHint ? "Show prompt again" : "Enable auto-paste"
    }

    var accessibilityRecoverySteps: [String] {
        guard showAccessibilityFallbackHint else { return [] }

        return [
            "Look for the macOS permission alert or the System Settings window that just opened.",
            "In Privacy & Security > Accessibility, turn on Flowstay, then return here.",
        ]
    }

    var firstWinCompleted: Bool {
        toggleModeCompleted && holdModeCompleted && tutorialStep == .complete
    }

    var canGoBack: Bool {
        currentScene.previous != nil && currentScene != .done
    }

    var canAdvance: Bool {
        Self.canAdvance(
            scene: currentScene,
            requiredSetupComplete: requiredSetupComplete,
            firstWinCompleted: firstWinCompleted,
            isRecordingFirstWin: isRecordingFirstWin
        )
    }

    var canCompleteOnboarding: Bool {
        Self.canCompleteOnboarding(
            scene: currentScene,
            requiredSetupComplete: requiredSetupComplete,
            firstWinCompleted: firstWinCompleted
        )
    }

    var progressStep: Int {
        currentScene.rawValue + 1
    }

    var progressTotal: Int {
        OnboardingScene.allCases.count
    }

    var progressFraction: Double {
        guard progressTotal > 1 else { return 1.0 }
        return Double(progressStep) / Double(progressTotal)
    }

    var actionHint: String {
        "Option + Space or hold Fn."
    }

    var tutorialTitle: String {
        switch tutorialStep {
        case .toggleStartPrompt:
            "Press"
        case .toggleRecording:
            "Speak"
        case .toggleStopPrompt:
            "Press again"
        case .togglePasteDemo:
            "Captured"
        case .holdStartPrompt:
            "Hold"
        case .holdRecording:
            "Speak"
        case .holdReleasePrompt:
            "Release"
        case .holdPasteDemo:
            "Captured"
        case .complete:
            "Ready"
        }
    }

    var tutorialSubtitle: String {
        ""
    }

    var tutorialKeyVisuals: [TutorialKeyVisual] {
        let labels: [String]
        let state: TutorialKeyVisualState

        switch tutorialStep {
        case .toggleStartPrompt, .toggleRecording, .toggleStopPrompt, .togglePasteDemo:
            labels = keyLabels(for: hotkeyToggleShortcut)
        case .holdStartPrompt, .holdRecording, .holdReleasePrompt, .holdPasteDemo:
            labels = holdKeyLabels()
        case .complete:
            return []
        }

        state = TutorialKeyVisualStatePolicy.resolve(
            tutorialStep: tutorialStep,
            activeMode: activeTutorialMode,
            isRecording: isRecordingFirstWin || engineCoordinator.isRecording,
            isTogglePressFeedbackActive: isToggleKeyPressed,
            isHoldPressed: isHoldKeyPressed
        )

        return labels.map { TutorialKeyVisual(label: $0, state: state) }
    }

    var tutorialProgressText: String {
        if tutorialStep.rawValue <= HotkeyTutorialStep.togglePasteDemo.rawValue {
            return "Shortcut 1 of 2"
        }
        if tutorialStep == .complete {
            return "Shortcut tutorial complete"
        }
        return "Shortcut 2 of 2"
    }

    var canContinueFromTutorial: Bool {
        tutorialStep == .complete && !isRecordingFirstWin
    }

    /// Skip the tutorial entirely and advance to quickSetup
    func skipTutorial() {
        // Cancel any in-progress recording - stop BEFORE clearing state
        let wasRecording = isRecordingFirstWin || engineCoordinator.isRecording

        // Clear tutorial state
        toggleModeCompleted = true
        holdModeCompleted = true
        tutorialStep = .complete
        isRecordingFirstWin = false
        firstWinError = nil

        if wasRecording {
            // Keep activeTutorialMode temporarily so cleanup works properly
            Task {
                await engineCoordinator.stopRecording()
                await MainActor.run {
                    activeTutorialMode = nil
                }
            }
        } else {
            activeTutorialMode = nil
        }

        // Advance to quickSetup
        navigationDirection = .forward
        currentScene = .quickSetup
    }

    var canDeferModelDownload: Bool {
        currentScene == .readiness &&
            microphoneStatus == .authorized &&
            !modelReady &&
            isPreparingModel
    }

    var fallbackActionTitle: String {
        switch tutorialStep {
        case .toggleStartPrompt:
            "Start this step manually"
        case .toggleRecording, .toggleStopPrompt:
            "Stop this step manually"
        case .holdStartPrompt:
            "Start hold step manually"
        case .holdRecording, .holdReleasePrompt:
            "Stop hold step manually"
        case .togglePasteDemo, .holdPasteDemo, .complete:
            "Continue"
        }
    }

    var isUsingAlternativeHoldInput: Bool {
        appState.holdToTalkInputSource == .alternativeShortcut
    }

    var holdShortcutMissing: Bool {
        appState.holdToTalkInputSource == .alternativeShortcut && hotkeyHoldShortcut == nil
    }

    var overlayMode: OnboardingOverlayMode {
        currentScene == .firstWin ? .followRuntime : .suppressed
    }

    func onAppear() {
        guard !initialized else { return }
        initialized = true

        Task {
            await permissionManager.checkPermissions()
            beginModelPreparationIfNeeded(force: false)
            refreshTutorialShortcutBindings()
            handleSceneChange(from: .welcome, to: currentScene)
        }
    }

    func cleanup() {
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        firstWinCaptureTask?.cancel()
        firstWinCaptureTask = nil
        audioPrewarmTask?.cancel()
        audioPrewarmTask = nil
        pasteDemoTask?.cancel()
        pasteDemoTask = nil
        inactivityFallbackTask?.cancel()
        inactivityFallbackTask = nil
        toggleKeyPulseTask?.cancel()
        toggleKeyPulseTask = nil

        hotkeyMonitor.stop()
        holdModeSessionActive = false
        isHoldKeyPressed = false
        isToggleKeyPressed = false

        if isRecordingFirstWin || engineCoordinator.isRecording {
            Task {
                await engineCoordinator.stopRecording()
            }
        }
    }

    func requestMicrophonePermission() {
        guard !isRequestingMicrophone else { return }

        isRequestingMicrophone = true
        Task {
            await permissionManager.requestMicrophonePermission()
            await permissionManager.checkPermissions()

            if permissionManager.hasMicrophonePermission {
                scheduleAudioPrewarmIfPossible()
            }

            await MainActor.run {
                isRequestingMicrophone = false
            }
        }
    }

    func openMicrophoneSettings() {
        Task { @MainActor in
            _ = SystemPreferencesHelper.open(.microphonePrivacy)
        }
    }

    func requestAccessibilityPermission() {
        guard !isRequestingAccessibility else { return }

        isRequestingAccessibility = true
        showAccessibilityFallbackHint = true
        Task {
            await accessibilityPromptHandler?.notifyWillPresent()

            await permissionManager.requestAccessibilityPermission()

            for _ in 0 ..< 12 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await permissionManager.checkAccessibilityPermissionOnly()
                if permissionManager.hasAccessibilityPermission {
                    break
                }
            }

            await MainActor.run {
                isRequestingAccessibility = false
                showAccessibilityFallbackHint = !permissionManager.hasAccessibilityPermission
                applyAccessibilityAutoPastePolicy(isGranted: permissionManager.hasAccessibilityPermission)
                accessibilityPromptHandler?.notifyDidComplete(
                    granted: permissionManager.hasAccessibilityPermission
                )
            }
        }
    }

    func openAccessibilitySettings() {
        showAccessibilityFallbackHint = true
        Task {
            await accessibilityPromptHandler?.notifyWillPresent()

            permissionManager.openAccessibilitySettings()
        }
    }

    func beginModelPreparationIfNeeded(force: Bool) {
        if !force, modelReady || isPreparingModel {
            return
        }

        modelPreparationTask?.cancel()
        isPreparingModel = true
        modelError = nil

        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            await engineCoordinator.preInitializeAllModels(prewarmBehavior: .modelsOnly)

            await MainActor.run {
                isPreparingModel = false
                modelReady = engineCoordinator.isModelsReady
                if let error = engineCoordinator.engineError, !error.isEmpty {
                    modelError = error
                }
                scheduleAudioPrewarmIfPossible()
            }
        }
    }

    func retryModelPreparation() {
        beginModelPreparationIfNeeded(force: true)
    }

    func moveNext() {
        guard canAdvance else { return }
        guard let next = currentScene.next else { return }
        navigationDirection = .forward
        currentScene = next
    }

    func moveBack() {
        guard canGoBack else { return }
        guard let previous = currentScene.previous else { return }
        navigationDirection = .backward
        currentScene = previous
    }

    func handleToggleTutorialShortcut() {
        guard currentScene == .firstWin else { return }

        let now = Date()
        guard ToggleShortcutHandlingPolicy.shouldAcceptPress(
            now: now,
            lastHandledAt: lastToggleShortcutHandledAt
        ) else {
            return
        }
        lastToggleShortcutHandledAt = now

        pulseToggleKeyVisual()
        registerTutorialInteraction()

        switch tutorialStep {
        case .toggleStartPrompt:
            startFirstWinRecording(for: .toggle)
        case .toggleRecording:
            guard ToggleShortcutHandlingPolicy.shouldStopToggleRecording(
                tutorialStep: tutorialStep,
                activeMode: activeTutorialMode,
                isRecording: isRecordingFirstWin || engineCoordinator.isRecording
            )
            else { return }
            stopFirstWinRecording(mode: .toggle)
        case .toggleStopPrompt:
            guard ToggleShortcutHandlingPolicy.shouldStopToggleRecording(
                tutorialStep: tutorialStep,
                activeMode: activeTutorialMode,
                isRecording: isRecordingFirstWin || engineCoordinator.isRecording
            )
            else { return }
            stopFirstWinRecording(mode: .toggle)
        default:
            break
        }
    }

    func presentShortcutPicker() {
        isShortcutPickerPresented = true
        registerTutorialInteraction()
    }

    func deferOnboardingUntilModelReady() {
        UserDefaults.standard.onboardingDeferredForModelDownload = true
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        viewCommand = .dismissAfterDeferral

        Task {
            if !UserDefaults.standard.notificationPromptAttempted {
                UserDefaults.standard.notificationPromptAttempted = true
            }

            let granted = await NotificationManager.shared.requestPermissions()
            if granted {
                await MainActor.run {
                    NotificationManager.shared.sendNotification(
                        title: "Model download in progress",
                        body: "Flowstay will notify you when speech models are ready",
                        identifier: "model-download-deferred"
                    )
                }
            }
        }

        guard deferredModelPreparationTask == nil else { return }
        deferredModelPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await engineCoordinator.preInitializeAllModels(prewarmBehavior: .modelsOnly)
            let modelsReady = engineCoordinator.isModelsReady
            UserDefaults.standard.onboardingDeferredForModelDownload = false
            deferredModelPreparationTask = nil

            guard !UserDefaults.standard.hasCompletedOnboarding else { return }

            if modelsReady {
                NotificationManager.shared.sendNotification(
                    title: "Flowstay is ready",
                    body: "Finish setup to start dictating",
                    identifier: "model-download-ready"
                )
            }

            scheduleDeferredOnboardingReopen()
        }
    }

    func completeOnboarding() {
        guard canCompleteOnboarding else { return }
        UserDefaults.standard.hasCompletedOnboarding = true
        viewCommand = .completeOnboarding
    }

    func clearViewCommand() {
        viewCommand = nil
    }

    func dismissShortcutPicker() {
        isShortcutPickerPresented = false
        showHotkeyFallbackHint = false
        refreshTutorialShortcutBindings()
        scheduleInactivityFallbackIfNeeded()
    }

    func updateHoldInputSource(_ source: HoldToTalkInputSource) {
        appState.holdToTalkInputSource = source
        if source == .functionKey {
            isHoldKeyPressed = false
        }
        refreshTutorialShortcutBindings()
        registerTutorialInteraction()
    }

    func handleToggleShortcutChanged(_: KeyboardShortcuts.Shortcut?) {
        shortcutValidationMessage = nil

        if appState.holdToTalkInputSource == .alternativeShortcut,
           let toggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation),
           let holdShortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk),
           toggleShortcut == holdShortcut
        {
            KeyboardShortcuts.setShortcut(nil, for: .holdToTalk)
            shortcutValidationMessage = "Hold shortcut cannot match the toggle shortcut. Please choose a different hold key."
        }

        refreshTutorialShortcutBindings()
        registerTutorialInteraction()
    }

    func handleHoldShortcutChanged(_: KeyboardShortcuts.Shortcut?) {
        shortcutValidationMessage = nil

        if let holdShortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk),
           let toggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation),
           holdShortcut == toggleShortcut
        {
            KeyboardShortcuts.setShortcut(nil, for: .holdToTalk)
            shortcutValidationMessage = "Hold shortcut cannot match the toggle shortcut."
        }

        refreshTutorialShortcutBindings()
        registerTutorialInteraction()
    }

    func performFallbackActionForCurrentStep() {
        registerTutorialInteraction()
        firstWinError = nil

        switch tutorialStep {
        case .toggleStartPrompt:
            startFirstWinRecording(for: .toggle)
        case .toggleRecording, .toggleStopPrompt:
            guard isRecordingFirstWin || engineCoordinator.isRecording else { return }
            stopFirstWinRecording(mode: .toggle)
        case .holdStartPrompt:
            if appState.holdToTalkInputSource == .alternativeShortcut, hotkeyHoldShortcut == nil {
                isShortcutPickerPresented = true
                return
            }
            startFirstWinRecording(for: .hold)
        case .holdRecording, .holdReleasePrompt:
            guard isRecordingFirstWin || engineCoordinator.isRecording else { return }
            stopFirstWinRecording(mode: .hold)
        case .togglePasteDemo, .holdPasteDemo, .complete:
            break
        }
    }

    nonisolated static func canAdvance(
        scene: OnboardingScene,
        requiredSetupComplete: Bool,
        firstWinCompleted: Bool,
        isRecordingFirstWin: Bool
    ) -> Bool {
        switch scene {
        case .welcome:
            true
        case .readiness:
            requiredSetupComplete
        case .firstWin:
            firstWinCompleted && !isRecordingFirstWin
        case .quickSetup:
            true
        case .done:
            false
        }
    }

    nonisolated static func canCompleteOnboarding(
        scene: OnboardingScene,
        requiredSetupComplete: Bool,
        firstWinCompleted: Bool
    ) -> Bool {
        scene == .done && requiredSetupComplete && firstWinCompleted
    }

    private func configureHotkeyMonitor() {
        hotkeyMonitor.onToggleShortcut = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleToggleTutorialShortcut()
            }
        }

        hotkeyMonitor.onHoldPressedChanged = { [weak self] isPressed in
            Task { @MainActor [weak self] in
                self?.handleHoldTutorialPressChanged(isPressed)
            }
        }
    }

    private func handleSceneChange(from oldScene: OnboardingScene, to newScene: OnboardingScene) {
        guard oldScene != newScene else { return }

        if newScene == .firstWin {
            if oldScene != .firstWin {
                resetTutorialState()
            }
            refreshTutorialShortcutBindings()
            hotkeyMonitor.start()
            scheduleInactivityFallbackIfNeeded()
            return
        }

        inactivityFallbackTask?.cancel()
        inactivityFallbackTask = nil
        hotkeyMonitor.stop()
        holdModeSessionActive = false
        isHoldKeyPressed = false
        isToggleKeyPressed = false

        if oldScene == .firstWin, isRecordingFirstWin || engineCoordinator.isRecording {
            stopFirstWinRecording(mode: activeTutorialMode)
        }
    }

    private func handleHoldTutorialPressChanged(_ isPressed: Bool) {
        guard currentScene == .firstWin else { return }

        isHoldKeyPressed = isPressed

        if isPressed {
            registerTutorialInteraction()
            guard tutorialStep == .holdStartPrompt else { return }
            guard !isRecordingFirstWin, !engineCoordinator.isRecording else { return }
            holdModeSessionActive = true
            startFirstWinRecording(for: .hold)
            return
        }

        guard holdModeSessionActive else { return }
        holdModeSessionActive = false

        guard activeTutorialMode == .hold,
              isRecordingFirstWin || engineCoordinator.isRecording
        else {
            return
        }

        registerTutorialInteraction()
        stopFirstWinRecording(mode: .hold)
    }

    private func startFirstWinRecording(for mode: OnboardingTutorialMode) {
        guard requiredSetupComplete else {
            firstWinError = "Complete microphone and model setup first."
            return
        }

        guard !isRecordingFirstWin else { return }

        if mode == .hold, appState.holdToTalkInputSource == .alternativeShortcut, hotkeyHoldShortcut == nil {
            firstWinError = "Set a hold shortcut first, or switch hold input to Fn."
            showHotkeyFallbackHint = true
            return
        }

        firstWinError = nil
        firstWinTranscript = ""
        latestTutorialTranscript = ""
        engineCoordinator.currentTranscript = ""
        activeTutorialMode = mode
        didDetectSpeechInCurrentAttempt = false

        switch mode {
        case .toggle:
            setTutorialStep(.toggleRecording)
        case .hold:
            setTutorialStep(.holdRecording)
        }

        Task {
            do {
                try await engineCoordinator.startRecording()
                await MainActor.run {
                    isRecordingFirstWin = true
                }
            } catch {
                await MainActor.run {
                    activeTutorialMode = nil
                    isRecordingFirstWin = false
                    registerFailure(for: mode, message: error.localizedDescription)
                }
            }
        }
    }

    private func stopFirstWinRecording(mode: OnboardingTutorialMode?) {
        guard isRecordingFirstWin || engineCoordinator.isRecording else { return }
        guard let mode else { return }

        firstWinCaptureTask?.cancel()

        Task {
            await engineCoordinator.stopRecording()
            await MainActor.run {
                isRecordingFirstWin = false
                activeTutorialMode = nil
                if mode == .toggle {
                    setTutorialStep(.toggleStopPrompt)
                } else {
                    setTutorialStep(.holdReleasePrompt)
                }
            }

            firstWinCaptureTask = Task { [weak self] in
                await self?.captureFirstWinTranscript(for: mode)
            }
        }
    }

    private func captureFirstWinTranscript(for mode: OnboardingTutorialMode) async {
        let attempts = 40

        for _ in 0 ..< attempts {
            let trimmed = engineCoordinator.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                await MainActor.run {
                    markTutorialSuccess(mode: mode, transcript: trimmed)
                }
                return
            }

            if let error = engineCoordinator.engineError, !error.isEmpty {
                await MainActor.run {
                    registerFailure(for: mode, message: error)
                }
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        await MainActor.run {
            registerFailure(for: mode, message: "No transcription detected. Try that step again.")
        }
    }

    private func markTutorialSuccess(mode: OnboardingTutorialMode, transcript: String) {
        firstWinError = nil
        firstWinTranscript = transcript
        latestTutorialTranscript = transcript

        switch mode {
        case .toggle:
            toggleModeCompleted = true
            toggleFailureCount = 0
            setTutorialStep(.togglePasteDemo)
            animatePasteDemo(for: .toggle, transcript: transcript)
        case .hold:
            holdModeCompleted = true
            holdFailureCount = 0
            setTutorialStep(.holdPasteDemo)
            animatePasteDemo(for: .hold, transcript: transcript)
        }
    }

    private func registerFailure(for mode: OnboardingTutorialMode, message: String) {
        firstWinError = message
        isRecordingFirstWin = false
        activeTutorialMode = nil
        didDetectSpeechInCurrentAttempt = false

        switch mode {
        case .toggle:
            toggleFailureCount += 1
            setTutorialStep(.toggleStartPrompt)
            if toggleFailureCount >= fallbackFailureThreshold {
                showHotkeyFallbackHint = true
            }
        case .hold:
            holdFailureCount += 1
            setTutorialStep(.holdStartPrompt)
            if holdFailureCount >= fallbackFailureThreshold {
                showHotkeyFallbackHint = true
            }
        }
    }

    private func animatePasteDemo(for mode: OnboardingTutorialMode, transcript: String) {
        pasteDemoTask?.cancel()
        isAnimatingPasteDemo = true
        demoPasteText = ""

        pasteDemoTask = Task { [weak self] in
            guard let self else { return }

            for character in transcript {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 14_000_000)
                await MainActor.run {
                    demoPasteText.append(character)
                }
            }

            await MainActor.run {
                isAnimatingPasteDemo = false
            }

            try? await Task.sleep(nanoseconds: 420_000_000)
            await MainActor.run {
                if mode == .toggle {
                    setTutorialStep(.holdStartPrompt)
                } else {
                    setTutorialStep(.complete)
                }
            }
        }
    }

    private func setTutorialStep(_ step: HotkeyTutorialStep) {
        tutorialStep = step
        scheduleInactivityFallbackIfNeeded()
    }

    private func registerTutorialInteraction() {
        showHotkeyFallbackHint = false
        scheduleInactivityFallbackIfNeeded()
    }

    private func scheduleInactivityFallbackIfNeeded() {
        inactivityFallbackTask?.cancel()
        inactivityFallbackTask = nil

        guard currentScene == .firstWin else { return }
        guard tutorialStep.requiresUserAction else { return }

        let watchedStep = tutorialStep
        inactivityFallbackTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: inactivityFallbackNanoseconds)

            await MainActor.run {
                guard currentScene == .firstWin else { return }
                guard tutorialStep == watchedStep else { return }
                guard !isShortcutPickerPresented else { return }
                showHotkeyFallbackHint = true
            }
        }
    }

    private func pulseToggleKeyVisual() {
        toggleKeyPulseTask?.cancel()
        isToggleKeyPressed = true

        toggleKeyPulseTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            await MainActor.run {
                isToggleKeyPressed = false
            }
        }
    }

    private func resetTutorialState() {
        toggleModeCompleted = false
        holdModeCompleted = false
        toggleFailureCount = 0
        holdFailureCount = 0
        lastToggleShortcutHandledAt = nil
        firstWinTranscript = ""
        latestTutorialTranscript = ""
        demoPasteText = ""
        firstWinError = nil
        isRecordingFirstWin = false
        activeTutorialMode = nil
        holdModeSessionActive = false
        didDetectSpeechInCurrentAttempt = false
        showHotkeyFallbackHint = false
        isShortcutPickerPresented = false
        isAnimatingPasteDemo = false
        setTutorialStep(.toggleStartPrompt)
    }

    private func refreshTutorialShortcutBindings() {
        hotkeyToggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) ?? defaultToggleShortcut

        if appState.holdToTalkInputSource == .alternativeShortcut {
            let configuredHoldShortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk)
            if configuredHoldShortcut == hotkeyToggleShortcut {
                KeyboardShortcuts.setShortcut(nil, for: .holdToTalk)
                hotkeyHoldShortcut = nil
                shortcutValidationMessage = "Hold shortcut cannot match the toggle shortcut."
            } else {
                hotkeyHoldShortcut = configuredHoldShortcut
            }
        } else {
            hotkeyHoldShortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk)
        }

        hotkeyMonitor.updateBindings(
            toggleShortcut: hotkeyToggleShortcut,
            holdInputSource: appState.holdToTalkInputSource,
            holdShortcut: hotkeyHoldShortcut
        )

        tutorialToggleShortcutDescription = safeShortcutDescription(hotkeyToggleShortcut)

        switch appState.holdToTalkInputSource {
        case .functionKey:
            tutorialHoldShortcutDescription = "Fn"
        case .alternativeShortcut:
            tutorialHoldShortcutDescription = hotkeyHoldShortcut.map { safeShortcutDescription($0) } ?? "Set hold shortcut"
        }
    }

    private func applyAccessibilityAutoPastePolicy(isGranted: Bool) {
        if isGranted {
            appState.autoPasteEnabled = true
            UserDefaults.standard.set(true, forKey: "autoPasteConfigured")
        } else {
            appState.autoPasteEnabled = false
        }
    }

    private func scheduleDeferredOnboardingReopen() {
        let delays: [TimeInterval] = [0.35, 0.9, 1.6]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !UserDefaults.standard.hasCompletedOnboarding else { return }
                MenuBarHelper.openOnboarding()
            }
        }
    }

    private func scheduleAudioPrewarmIfPossible() {
        guard microphoneStatus == .authorized, modelReady else { return }
        guard audioPrewarmTask == nil else { return }

        audioPrewarmTask = Task { [weak self] in
            guard let self else { return }
            _ = await engineCoordinator.prewarmRecordingPipelineIfNeeded()

            await MainActor.run {
                audioPrewarmTask = nil
            }
        }
    }

    private func observeDependencies() {
        permissionManager.$microphoneStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                microphoneStatus = status
                scheduleAudioPrewarmIfPossible()
            }
            .store(in: &cancellables)

        permissionManager.$accessibilityStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                accessibilityStatus = status
                showAccessibilityFallbackHint = status != .authorized && showAccessibilityFallbackHint
                applyAccessibilityAutoPastePolicy(isGranted: status == .authorized)
            }
            .store(in: &cancellables)

        engineCoordinator.$isModelsReady
            .receive(on: RunLoop.main)
            .sink { [weak self] ready in
                guard let self else { return }
                modelReady = ready
                if ready {
                    isPreparingModel = false
                    modelError = nil
                    scheduleAudioPrewarmIfPossible()
                }
            }
            .store(in: &cancellables)

        engineCoordinator.$currentTranscript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                guard currentScene == .firstWin else { return }
                guard isRecordingFirstWin else { return }

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                firstWinTranscript = trimmed

                guard !trimmed.isEmpty else { return }
                if !didDetectSpeechInCurrentAttempt {
                    didDetectSpeechInCurrentAttempt = true
                    registerTutorialInteraction()

                    if tutorialStep == .toggleRecording {
                        setTutorialStep(.toggleStopPrompt)
                    } else if tutorialStep == .holdRecording {
                        setTutorialStep(.holdReleasePrompt)
                    }
                }
            }
            .store(in: &cancellables)

        engineCoordinator.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in
                guard let self else { return }
                if currentScene == .firstWin {
                    isRecordingFirstWin = recording
                }
            }
            .store(in: &cancellables)
    }
}

// swiftlint:enable type_body_length

// MARK: - Key Label Helpers

extension OnboardingCoordinator {
    func holdKeyLabels() -> [String] {
        switch appState.holdToTalkInputSource {
        case .functionKey:
            return ["Fn"]
        case .alternativeShortcut:
            if let hotkeyHoldShortcut {
                return keyLabels(for: hotkeyHoldShortcut)
            }
            return ["Set Shortcut"]
        }
    }

    func keyLabels(for shortcut: KeyboardShortcuts.Shortcut) -> [String] {
        var labels: [String] = []
        let modifiers = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.control) {
            labels.append("Control")
        }
        if modifiers.contains(.option) {
            labels.append("Option")
        }
        if modifiers.contains(.shift) {
            labels.append("Shift")
        }
        if modifiers.contains(.command) {
            labels.append("Command")
        }

        let rawKeyLabel = shortcut.nsMenuItemKeyEquivalent?.uppercased() ?? "Key"
        let keyLabel = rawKeyLabel == " " ? "Space" : rawKeyLabel
        labels.append(keyLabel.uppercased() == "SPACE" ? "Space" : keyLabel.uppercased())
        return labels
    }
}
