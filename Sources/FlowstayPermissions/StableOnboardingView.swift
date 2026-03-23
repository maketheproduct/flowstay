import AppKit
import FlowstayCore
import KeyboardShortcuts
import SwiftUI

/// A simplified onboarding flow that keeps ownership local to the view tree,
/// but reuses the current onboarding visual language so the shipped experience
/// still matches the modern product.
public struct StableOnboardingView: View {
    private enum Step: Int, CaseIterable, Hashable {
        case welcome
        case readiness
        case shortcuts
        case setup
        case completion

        var maxWidth: CGFloat {
            switch self {
            case .welcome:
                560
            case .readiness:
                560
            case .shortcuts:
                620
            case .setup:
                560
            case .completion:
                500
            }
        }
    }

    @ObservedObject private var permissionManager: PermissionManager
    @ObservedObject private var engineCoordinator: EngineCoordinatorViewModel

    private let appState: AppState
    private let onComplete: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    @State private var currentStep: Step = .welcome
    @State private var isDownloadingModel = false
    @State private var modelDownloadComplete = false
    @State private var modelError: String?
    @State private var notificationPermissionGranted = false
    @State private var hasStartedBackgroundPreparation = false

    public init(
        permissionManager: PermissionManager,
        engineCoordinator: EngineCoordinatorViewModel,
        appState: AppState,
        onComplete: (() -> Void)? = nil
    ) {
        _permissionManager = ObservedObject(wrappedValue: permissionManager)
        _engineCoordinator = ObservedObject(wrappedValue: engineCoordinator)
        self.appState = appState
        self.onComplete = onComplete
    }

    private var theme: OnboardingTheme {
        OnboardingTheme.resolve(for: colorScheme)
    }

    private var canExit: Bool {
        permissionManager.criticalPermissionsGranted && modelDownloadComplete
    }

    private var toggleShortcutDescription: String {
        let fallback = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        return safeShortcutDescription(
            KeyboardShortcuts.getShortcut(for: .toggleDictation) ?? fallback
        )
    }

    private var holdShortcutDescription: String {
        switch appState.holdToTalkInputSource {
        case .functionKey:
            return "Fn"
        case .alternativeShortcut:
            guard let shortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk) else {
                return "Set in Settings"
            }
            return safeShortcutDescription(shortcut)
        }
    }

    private var toggleShortcutVisuals: [TutorialKeyVisual] {
        [
            TutorialKeyVisual(label: "option", state: .target),
            TutorialKeyVisual(label: "space", state: .target),
        ]
    }

    public var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()

            Circle()
                .fill(theme.ambientGlow)
                .frame(width: 260, height: 260)
                .blur(radius: 48)
                .offset(x: -190, y: -210)
                .allowsHitTesting(false)

            paneContent
                .padding(4)
        }
        .frame(width: 860, height: 660)
        .animation(.easeInOut(duration: 0.22), value: currentStep)
        .interactiveDismissDisabled(!canExit)
        .onAppear {
            prepareInitialState()
        }
    }

    private var paneContent: some View {
        ZStack {
            paneBackground

            VStack(spacing: 16) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 28)

                sceneView
                    .id(currentStep.rawValue)
                    .frame(maxWidth: currentStep.maxWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
                            removal: .opacity
                        )
                    )
            }
        }
        .clipShape(StableOnboardingPaneShape())
        .contentShape(StableOnboardingPaneShape())
        .compositingGroup()
        .shadow(color: theme.cardShadow.opacity(0.16), radius: 14, y: 8)
    }

    private var paneBackground: some View {
        StableOnboardingPaneShape()
            .fill(.ultraThinMaterial)
            .overlay {
                StableOnboardingPaneShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.backgroundGradientStart.opacity(0.84),
                                theme.backgroundGradientEnd.opacity(0.78),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(theme.cardHighlight.opacity(0.08))
                    .frame(width: 220, height: 220)
                    .blur(radius: 38)
                    .offset(x: -34, y: -68)
                    .allowsHitTesting(false)
            }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                if currentStep.rawValue > Step.welcome.rawValue {
                    Button {
                        moveBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(theme.surface, in: Circle())
                            .overlay(
                                Circle()
                                    .stroke(theme.cardBorder, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 28, height: 28)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(
                            step.rawValue <= currentStep.rawValue
                                ? theme.accent.opacity(0.78)
                                : theme.cardBorder.opacity(0.72)
                        )
                        .frame(height: 4)
                }
            }
            .frame(maxWidth: 340)
        }
    }

    @ViewBuilder
    private var sceneView: some View {
        switch currentStep {
        case .welcome:
            StableOnboardingWelcomeScene(theme: theme) {
                move(to: .readiness)
            }
        case .readiness:
            StableOnboardingReadinessScene(
                theme: theme,
                permissionManager: permissionManager,
                isDownloadingModel: isDownloadingModel,
                modelReady: modelDownloadComplete,
                modelError: modelError,
                onRetryModelPreparation: restartModelPreparation,
                onContinue: {
                    move(to: .shortcuts)
                }
            )
        case .shortcuts:
            StableOnboardingShortcutScene(
                theme: theme,
                toggleShortcutDescription: toggleShortcutDescription,
                holdShortcutDescription: holdShortcutDescription,
                toggleShortcutVisuals: toggleShortcutVisuals,
                usesFunctionKey: appState.holdToTalkInputSource == .functionKey,
                onContinue: {
                    move(to: .setup)
                }
            )
        case .setup:
            StableOnboardingSetupScene(
                theme: theme,
                permissionManager: permissionManager,
                notificationPermissionGranted: $notificationPermissionGranted,
                onContinue: {
                    move(to: .completion)
                }
            )
        case .completion:
            StableOnboardingCompletionScene(
                theme: theme,
                actionHint: "Press \(toggleShortcutDescription) to start dictating.",
                onComplete: {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    onComplete?()
                }
            )
        }
    }

    private func move(to step: Step) {
        withAnimation(.easeInOut(duration: 0.22)) {
            currentStep = step
        }
    }

    private func moveBack() {
        guard let previous = Step(rawValue: currentStep.rawValue - 1) else { return }
        move(to: previous)
    }

    private func prepareInitialState() {
        guard !hasStartedBackgroundPreparation else { return }
        hasStartedBackgroundPreparation = true

        Task {
            await permissionManager.checkPermissions()
            let notificationStatus = await NotificationManager.shared.checkPermissionStatus()

            await MainActor.run {
                notificationPermissionGranted = notificationStatus
            }

            startBackgroundModelDownloadIfNeeded()
        }
    }

    private func restartModelPreparation() {
        startBackgroundModelDownloadIfNeeded(force: true)
    }

    private func startBackgroundModelDownloadIfNeeded(force: Bool = false) {
        if !force, engineCoordinator.isModelDownloaded(), engineCoordinator.isModelsReady {
            modelDownloadComplete = true
            isDownloadingModel = false
            modelError = nil
            return
        }

        isDownloadingModel = true
        modelError = nil

        Task {
            await engineCoordinator.preInitializeAllModels(prewarmBehavior: .modelsOnly)

            await MainActor.run {
                isDownloadingModel = false

                if let engineError = engineCoordinator.engineError, !engineError.isEmpty {
                    modelDownloadComplete = false
                    modelError = engineError
                    return
                }

                modelDownloadComplete = true
                modelError = nil

                if notificationPermissionGranted {
                    NotificationManager.shared.sendNotification(
                        title: "Flowstay is ready",
                        body: "Finish setup to start dictating with \(toggleShortcutDescription).",
                        identifier: "onboarding-model-ready"
                    )
                }
            }
        }
    }
}

private struct StableOnboardingWelcomeScene: View {
    let theme: OnboardingTheme
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            appIcon

            VStack(spacing: 10) {
                Text("Speak where you work")
                    .font(.albertSans(42, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)

                Text("Set up local dictation, check the essentials, and get into Flowstay without leaving your workflow.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 14) {
                StableFeaturePill(
                    theme: theme,
                    icon: "lock.fill",
                    title: "Private",
                    subtitle: "On-device"
                )
                StableFeaturePill(
                    theme: theme,
                    icon: "waveform.badge.mic",
                    title: "Offline",
                    subtitle: "Speech model"
                )
                StableFeaturePill(
                    theme: theme,
                    icon: "square.and.arrow.down.on.square",
                    title: "Fast insert",
                    subtitle: "Auto-paste"
                )
            }

            Button("Start setup") {
                onStart()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var appIcon: some View {
        Group {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
            } else {
                Image(systemName: "waveform.badge.mic")
                    .resizable()
                    .scaledToFit()
                    .padding(18)
                    .foregroundStyle(theme.accent)
            }
        }
        .frame(width: 92, height: 92)
        .shadow(color: theme.ambientGlow, radius: 16)
    }
}

private struct StableOnboardingReadinessScene: View {
    let theme: OnboardingTheme
    @ObservedObject var permissionManager: PermissionManager
    let isDownloadingModel: Bool
    let modelReady: Bool
    let modelError: String?
    let onRetryModelPreparation: () -> Void
    let onContinue: () -> Void

    @State private var isRequestingMicrophone = false

    private var requiredSetupComplete: Bool {
        permissionManager.hasMicrophonePermission && modelReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Get ready")
                    .font(.albertSans(30, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text("Microphone access and the offline speech model are the only required pieces.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            VStack(spacing: 0) {
                readinessRow(
                    title: "Microphone",
                    subtitle: microphoneSubtitle,
                    icon: permissionManager.hasMicrophonePermission ? "checkmark.circle.fill" : "mic.fill",
                    iconColor: permissionManager.hasMicrophonePermission ? theme.success : theme.accent
                ) {
                    if permissionManager.hasMicrophonePermission {
                        StableStatusBadge(theme: theme, title: "Ready")
                    } else if isRequestingMicrophone {
                        ProgressView()
                            .controlSize(.small)
                    } else if permissionManager.microphoneStatus == .denied {
                        Button("Open settings") {
                            openMicrophoneSettings()
                        }
                        .buttonStyle(.bordered)
                        .tint(theme.accent)
                    } else {
                        Button("Allow") {
                            requestMicrophonePermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                    }
                }

                Divider()
                    .overlay(theme.cardBorder)
                    .padding(.horizontal, 18)

                readinessRow(
                    title: "Speech model",
                    subtitle: modelSubtitle,
                    icon: modelReady ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                    iconColor: modelReady ? theme.success : theme.accent
                ) {
                    if modelReady {
                        StableStatusBadge(theme: theme, title: "Ready")
                    } else if isDownloadingModel {
                        Text("Downloading")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.tertiaryText)
                    } else {
                        Button(modelError == nil ? "Prepare" : "Retry") {
                            onRetryModelPreparation()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                    }
                }

                if let modelError {
                    Divider()
                        .overlay(theme.cardBorder)
                        .padding(.horizontal, 18)

                    Text(modelError)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.warning)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                }

                Divider()
                    .overlay(theme.cardBorder)
                    .padding(.horizontal, 18)
                    .padding(.top, modelError == nil ? 0 : 14)

                HStack(spacing: 12) {
                    if !requiredSetupComplete {
                        Text(requiredSetupComplete ? "" : "Finish the required items to continue.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.tertiaryText)
                    } else {
                        StableStatusBadge(theme: theme, title: "Ready to continue")
                    }

                    Spacer()

                    Button("Continue") {
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(!requiredSetupComplete)
                }
                .padding(18)
            }
            .stablePrimarySurface(theme, padding: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var microphoneSubtitle: String {
        switch permissionManager.microphoneStatus {
        case .authorized:
            "Ready"
        case .denied:
            "Turn it on in System Settings."
        case .restricted:
            "Unavailable on this Mac."
        case .notDetermined:
            "Needed to dictate."
        }
    }

    private var modelSubtitle: String {
        if modelReady {
            return "Ready"
        }
        if isDownloadingModel {
            return "Downloading local speech."
        }
        return "Needed to dictate."
    }

    private func readinessRow(
        title: String,
        subtitle: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            accessory()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private func requestMicrophonePermission() {
        guard !isRequestingMicrophone else { return }
        isRequestingMicrophone = true

        Task {
            await permissionManager.requestMicrophonePermission()

            for _ in 0 ..< 10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await permissionManager.checkPermissions()
                if permissionManager.hasMicrophonePermission {
                    break
                }
            }

            await MainActor.run {
                isRequestingMicrophone = false
            }
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct StableOnboardingShortcutScene: View {
    let theme: OnboardingTheme
    let toggleShortcutDescription: String
    let holdShortcutDescription: String
    let toggleShortcutVisuals: [TutorialKeyVisual]
    let usesFunctionKey: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(spacing: 8) {
                Text("Shortcuts that stay out of your way")
                    .font(.albertSans(30, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)

                Text("Flowstay is ready with sensible defaults. You can change them later in Settings.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            OnboardingKeyboardVisual(
                visuals: toggleShortcutVisuals,
                theme: theme
            )
            .frame(height: 124)

            HStack(spacing: 14) {
                StableShortcutCard(
                    theme: theme,
                    title: "Toggle dictation",
                    shortcut: toggleShortcutDescription,
                    detail: "Start and stop dictation with a single shortcut."
                )

                StableShortcutCard(
                    theme: theme,
                    title: usesFunctionKey ? "Hold to talk" : "Hold shortcut",
                    shortcut: holdShortcutDescription,
                    detail: usesFunctionKey
                        ? "Keep the function key pressed while you speak."
                        : "Your alternate shortcut can be held for push-to-talk."
                )
            }

            HStack(spacing: 12) {
                Text("You can fine-tune these in Flowstay Settings later.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)

                Spacer()

                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct StableOnboardingSetupScene: View {
    let theme: OnboardingTheme
    @ObservedObject var permissionManager: PermissionManager
    @Binding var notificationPermissionGranted: Bool
    let onContinue: () -> Void

    @State private var isRequestingAccessibility = false
    @State private var isRequestingNotifications = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Optional finishing touches")
                    .font(.albertSans(30, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text("Turn on auto-paste and notifications if you want the full desktop workflow.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 14) {
                StableSetupCard(
                    theme: theme,
                    title: "Accessibility",
                    subtitle: permissionManager.hasAccessibilityPermission
                        ? "Auto-paste is ready."
                        : "Lets Flowstay paste text into the app you are using.",
                    systemImage: "square.and.arrow.down.on.square",
                    iconColor: permissionManager.hasAccessibilityPermission ? theme.success : theme.accent
                ) {
                    if permissionManager.hasAccessibilityPermission {
                        StableStatusBadge(theme: theme, title: "On")
                    } else if isRequestingAccessibility {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        HStack(spacing: 10) {
                            Button("Enable") {
                                requestAccessibilityPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accent)

                            Button("Skip") {
                                onContinue()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if isRequestingAccessibility, !permissionManager.hasAccessibilityPermission {
                    Text("Enable Flowstay in Privacy & Security > Accessibility, then return here.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                StableSetupCard(
                    theme: theme,
                    title: "Notifications",
                    subtitle: notificationPermissionGranted
                        ? "Model-ready alerts are enabled."
                        : "Optional alerts for model download completion and setup status.",
                    systemImage: "bell.badge.fill",
                    iconColor: notificationPermissionGranted ? theme.success : theme.accent
                ) {
                    if notificationPermissionGranted {
                        StableStatusBadge(theme: theme, title: "On")
                    } else if isRequestingNotifications {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Allow") {
                            requestNotificationPermission()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .stablePrimarySurface(theme, padding: 18)

            HStack(spacing: 12) {
                if !permissionManager.hasAccessibilityPermission {
                    Text("You can enable auto-paste later in Settings.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.tertiaryText)
                } else {
                    StableStatusBadge(theme: theme, title: "Setup complete")
                }

                Spacer()

                Button(permissionManager.hasAccessibilityPermission ? "Continue" : "Continue without auto-paste") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func requestAccessibilityPermission() {
        guard !isRequestingAccessibility else { return }
        isRequestingAccessibility = true

        Task {
            await permissionManager.requestAccessibilityPermission()

            for _ in 0 ..< 24 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await permissionManager.checkAccessibilityPermissionOnly()
                if permissionManager.hasAccessibilityPermission {
                    break
                }
            }

            await MainActor.run {
                isRequestingAccessibility = false
            }
        }
    }

    private func requestNotificationPermission() {
        guard !isRequestingNotifications else { return }
        isRequestingNotifications = true

        Task {
            let granted = await NotificationManager.shared.requestPermissions()
            var resolved = granted

            if !granted {
                for _ in 0 ..< 15 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let status = await NotificationManager.shared.checkPermissionStatus()
                    if status {
                        resolved = true
                        break
                    }
                }
            }

            await MainActor.run {
                notificationPermissionGranted = resolved
                isRequestingNotifications = false
            }
        }
    }
}

private struct StableOnboardingCompletionScene: View {
    let theme: OnboardingTheme
    let actionHint: String
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 58))
                .foregroundStyle(theme.success)

            VStack(spacing: 8) {
                Text("You're ready")
                    .font(.albertSans(34, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text(actionHint)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button("Open Flowstay") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct StableFeaturePill: View {
    let theme: OnboardingTheme
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stableSecondarySurface(theme, padding: 16)
    }
}

private struct StableShortcutCard: View {
    let theme: OnboardingTheme
    let title: String
    let shortcut: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            Text(shortcut)
                .font(.albertSans(28, weight: .semibold))
                .foregroundStyle(theme.accent)

            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 146, alignment: .topLeading)
        .stableSecondarySurface(theme, padding: 18)
    }
}

private struct StableSetupCard<Accessory: View>: View {
    let theme: OnboardingTheme
    let title: String
    let subtitle: String
    let systemImage: String
    let iconColor: Color
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .stableSecondarySurface(theme, padding: 0)
    }
}

private struct StableStatusBadge: View {
    let theme: OnboardingTheme
    let title: String

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.success)
    }
}

private struct StableOnboardingPaneShape: InsettableShape {
    private let cornerRadius: CGFloat
    private let insetAmount: CGFloat

    init(cornerRadius: CGFloat = 34, insetAmount: CGFloat = 0) {
        self.cornerRadius = cornerRadius
        self.insetAmount = insetAmount
    }

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: cornerRadius - insetAmount, style: .continuous)
            .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        StableOnboardingPaneShape(
            cornerRadius: cornerRadius,
            insetAmount: insetAmount + amount
        )
    }
}

private extension View {
    func stablePrimarySurface(_ theme: OnboardingTheme, padding: CGFloat) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: OnboardingTheme.cardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: OnboardingTheme.cardCornerRadius, style: .continuous)
                            .fill(theme.surface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingTheme.cardCornerRadius, style: .continuous)
                    .stroke(theme.cardBorder, lineWidth: 0.8)
            )
            .shadow(color: theme.cardShadow, radius: 18, y: 10)
    }

    func stableSecondarySurface(_ theme: OnboardingTheme, padding: CGFloat) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(theme.elevatedSurface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(theme.cardBorder, lineWidth: 0.8)
            )
    }
}
