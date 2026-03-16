import AppKit
import FlowstayCore
import KeyboardShortcuts
import SwiftUI

public struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    let engineCoordinator: EngineCoordinatorViewModel
    let onComplete: (() -> Void)?
    let onOverlayModeChange: ((OnboardingOverlayMode) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var coordinator: OnboardingCoordinator

    public init(
        permissionManager: PermissionManager,
        engineCoordinator: EngineCoordinatorViewModel,
        appState: AppState,
        onComplete: (() -> Void)? = nil,
        onOverlayModeChange: ((OnboardingOverlayMode) -> Void)? = nil,
        onAccessibilityPromptWillPresent: (@MainActor () async -> Void)? = nil,
        onAccessibilityPromptDidComplete: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.permissionManager = permissionManager
        self.engineCoordinator = engineCoordinator
        self.onComplete = onComplete
        self.onOverlayModeChange = onOverlayModeChange
        _coordinator = StateObject(
            wrappedValue: OnboardingCoordinator(
                permissionManager: permissionManager,
                engineCoordinator: engineCoordinator,
                appState: appState,
                onAccessibilityPromptWillPresent: onAccessibilityPromptWillPresent,
                onAccessibilityPromptDidComplete: onAccessibilityPromptDidComplete
            )
        )
    }

    public var body: some View {
        let theme = OnboardingTheme.resolve(for: colorScheme)
        let profile = OnboardingSceneLayoutProfile.resolve(for: coordinator.currentScene)

        ZStack {
            Color.clear
                .ignoresSafeArea()

            Circle()
                .fill(theme.ambientGlow)
                .frame(width: 260, height: 260)
                .blur(radius: 48)
                .offset(x: -190, y: -210)
                .allowsHitTesting(false)

            paneContent(theme: theme, profile: profile)
                .padding(4)
        }
        .frame(width: 860, height: 660)
        .onAppear {
            coordinator.onAppear()
            onOverlayModeChange?(coordinator.overlayMode)
        }
        .onChange(of: coordinator.overlayMode) { _, newMode in
            onOverlayModeChange?(newMode)
        }
        .onDisappear {
            onOverlayModeChange?(.suppressed)
            coordinator.cleanup()
        }
    }

    private func paneContent(theme: OnboardingTheme, profile: OnboardingSceneLayoutProfile) -> some View {
        ZStack {
            paneBackground(theme)

            VStack(spacing: 16) {
                header(theme)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)

                sceneView(theme)
                    .id(coordinator.currentScene.rawValue)
                    .frame(maxWidth: profile.maxWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: profile.containerAlignment)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .transition(sceneTransition)
            }
        }
        .clipShape(OnboardingPaneShape())
        .contentShape(OnboardingPaneShape())
        .compositingGroup()
        .shadow(color: theme.cardShadow.opacity(0.16), radius: 14, y: 8)
    }

    private func paneBackground(_ theme: OnboardingTheme) -> some View {
        OnboardingPaneShape()
            .fill(.ultraThinMaterial)
            .overlay {
                OnboardingPaneShape()
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

    private func header(_ theme: OnboardingTheme) -> some View {
        VStack(spacing: 10) {
            HStack {
                if coordinator.canGoBack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            coordinator.moveBack()
                        }
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
                ForEach(OnboardingScene.allCases, id: \.rawValue) { scene in
                    Capsule()
                        .fill(
                            scene.rawValue <= coordinator.currentScene.rawValue
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
    private func sceneView(_ theme: OnboardingTheme) -> some View {
        switch coordinator.currentScene {
        case .welcome:
            WelcomeSceneView(theme: theme) {
                advance()
            }
        case .readiness:
            ReadinessSceneView(theme: theme, coordinator: coordinator, onContinue: {
                advance()
            }, onDefer: {
                coordinator.deferOnboardingUntilModelReady()
                dismiss()
            })
        case .firstWin:
            LiveDictationSceneView(theme: theme, coordinator: coordinator) {
                advance()
            }
        case .quickSetup:
            QuickSetupSceneView(theme: theme, coordinator: coordinator) {
                advance()
            }
        case .done:
            DoneSceneView(theme: theme, coordinator: coordinator) {
                completeOnboarding()
            }
        }
    }

    private var sceneTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)),
            removal: .opacity
        )
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.2)) {
            coordinator.moveNext()
        }
    }

    private func completeOnboarding() {
        guard coordinator.canCompleteOnboarding else { return }

        UserDefaults.standard.hasCompletedOnboarding = true
        onComplete?()
    }
}

private struct WelcomeSceneView: View {
    let theme: OnboardingTheme
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            appIcon

            VStack(spacing: 8) {
                Text("Speak where you work")
                    .font(.albertSans(42, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.center)
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

private struct ReadinessSceneView: View {
    let theme: OnboardingTheme
    @ObservedObject var coordinator: OnboardingCoordinator
    let onContinue: () -> Void
    let onDefer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Get ready")
                    .font(.albertSans(30, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text("Microphone and model download")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            VStack(spacing: 0) {
                readinessRow(
                    title: "Microphone",
                    subtitle: microphoneSubtitle,
                    icon: coordinator.microphoneStatus == .authorized ? "checkmark.circle.fill" : "mic.fill",
                    iconColor: coordinator.microphoneStatus == .authorized ? theme.success : theme.accent
                ) {
                    if coordinator.microphoneStatus == .authorized {
                        ReadyLabel(theme: theme, title: "Ready")
                    } else if coordinator.isRequestingMicrophone {
                        ProgressView()
                            .controlSize(.small)
                    } else if coordinator.microphoneStatus == .denied {
                        Button("Open settings") {
                            coordinator.openMicrophoneSettings()
                        }
                        .buttonStyle(.bordered)
                        .tint(theme.accent)
                    } else {
                        Button("Allow") {
                            coordinator.requestMicrophonePermission()
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
                    icon: coordinator.modelReady ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                    iconColor: coordinator.modelReady ? theme.success : theme.accent
                ) {
                    if coordinator.modelReady {
                        ReadyLabel(theme: theme, title: "Ready")
                    } else if coordinator.isPreparingModel {
                        Text("Downloading")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.tertiaryText)
                    } else {
                        Button(coordinator.modelError == nil ? "Prepare" : "Retry") {
                            coordinator.retryModelPreparation()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                    }
                }

                if let modelError = coordinator.modelError {
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
                    .padding(.top, coordinator.modelError == nil ? 0 : 14)

                HStack(spacing: 12) {
                    if coordinator.canDeferModelDownload {
                        Button("Notify me when ready") {
                            onDefer()
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if !coordinator.modelReady {
                        Text("Downloading model...")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.tertiaryText)
                    }

                    Button("Continue to the shortcuts") {
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .disabled(!coordinator.requiredSetupComplete)
                }
                .padding(18)
            }
            .primarySurface(theme, padding: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var microphoneSubtitle: String {
        switch coordinator.microphoneStatus {
        case .authorized:
            "Ready"
        case .denied:
            "Turn it on in Settings."
        case .restricted:
            "Unavailable on this Mac."
        case .notDetermined:
            "Needed to dictate."
        }
    }

    private var modelSubtitle: String {
        if coordinator.modelReady {
            return "Ready"
        }
        if coordinator.isPreparingModel {
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
}

private struct LiveDictationSceneView: View {
    let theme: OnboardingTheme
    @ObservedObject var coordinator: OnboardingCoordinator
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingFirstWinLayoutMetrics.make(availableHeight: proxy.size.height - 8)

            VStack(alignment: .center, spacing: metrics.stackSpacing) {
                VStack(spacing: 4) {
                    Text(coordinator.tutorialTitle)
                        .font(.albertSans(30, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)

                    if coordinator.canContinueFromTutorial {
                        Text("Both shortcuts are ready.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: metrics.titleBlockHeight)

                OnboardingKeyboardVisual(
                    visuals: coordinator.tutorialKeyVisuals,
                    theme: theme
                )
                .frame(height: metrics.keyboardHeight)

                tutorialTranscriptSurface
                    .frame(height: metrics.transcriptHeight)

                tutorialFooter
                    .frame(height: metrics.footerHeight, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $coordinator.isShortcutPickerPresented, onDismiss: {
            coordinator.dismissShortcutPicker()
        }) {
            ShortcutPickerSheetView(theme: theme, coordinator: coordinator)
                .frame(width: 520, height: 340)
        }
    }

    private var tutorialTranscriptSurface: some View {
        HStack(spacing: 12) {
            if coordinator.isRecordingFirstWin {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
            } else if !coordinator.demoPasteText.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.success)
            } else {
                Capsule()
                    .fill(theme.accent.opacity(0.32))
                    .frame(width: 3, height: 18)
            }

            transcriptText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .secondarySurface(theme, padding: 16)
    }

    @ViewBuilder
    private var transcriptText: some View {
        if !coordinator.demoPasteText.isEmpty {
            Text(coordinator.demoPasteText)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(3)
        } else if !coordinator.latestTutorialTranscript.isEmpty {
            Text(coordinator.latestTutorialTranscript)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
        } else if coordinator.isRecordingFirstWin {
            Text("Listening...")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        } else {
            Text(" ")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var tutorialFooter: some View {
        HStack(spacing: 12) {
            if let firstWinError = coordinator.firstWinError {
                Text(firstWinError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.warning)
                    .lineLimit(2)
            } else if coordinator.showHotkeyFallbackHint || coordinator.holdShortcutMissing {
                HStack(spacing: 6) {
                    Text("Not working?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.tertiaryText)
                    Button("Change shortcut") {
                        coordinator.presentShortcutPicker()
                    }
                    .buttonStyle(.link)
                }
            } else if coordinator.canContinueFromTutorial {
                ReadyLabel(theme: theme, title: "Ready")
            } else {
                Color.clear
            }

            Spacer()

            if coordinator.canContinueFromTutorial {
                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if !coordinator.isRecordingFirstWin {
                Button("Skip for now") {
                    coordinator.skipTutorial()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.tertiaryText)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: coordinator.canContinueFromTutorial)
    }
}

private struct ShortcutPickerSheetView: View {
    let theme: OnboardingTheme
    @ObservedObject var coordinator: OnboardingCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcut setup")
                .font(.albertSans(24, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            Text("Pick keys that feel right.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.secondaryText)

            KeyboardShortcuts.Recorder(
                "Toggle transcription",
                name: .toggleDictation,
                onChange: coordinator.handleToggleShortcutChanged
            )

            Picker("Hold input", selection: Binding(
                get: { coordinator.appState.holdToTalkInputSource },
                set: { coordinator.updateHoldInputSource($0) }
            )) {
                ForEach(HoldToTalkInputSource.allCases, id: \.rawValue) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)

            if coordinator.appState.holdToTalkInputSource == .alternativeShortcut {
                KeyboardShortcuts.Recorder(
                    "Hold-to-talk shortcut",
                    name: .holdToTalk,
                    onChange: coordinator.handleHoldShortcutChanged
                )
            }

            if let shortcutValidationMessage = coordinator.shortcutValidationMessage {
                Text(shortcutValidationMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.warning)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
            }
        }
        .padding(20)
        .background(theme.backgroundGradientStart)
    }
}

private struct QuickSetupSceneView: View {
    let theme: OnboardingTheme
    @ObservedObject var coordinator: OnboardingCoordinator
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Paste into other apps")
                    .font(.albertSans(30, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text("Turn on Accessibility so Flowstay can insert transcribed text where you're typing.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Accessibility", systemImage: "square.and.arrow.down.on.square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primaryText)

                    Spacer()

                    if coordinator.accessibilityGranted {
                        ReadyLabel(theme: theme, title: "On")
                    }
                }

                Text(
                    coordinator.accessibilityDescriptionText
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                if coordinator.showAccessibilityFallbackHint {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("If you do not see the macOS approval window:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.primaryText)

                        ForEach(Array(coordinator.accessibilityRecoverySteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.primaryText)
                                    .frame(width: 18, height: 18)
                                    .background(theme.cardBorder.opacity(0.55), in: Circle())

                                Text(step)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14)
                    .background(theme.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(theme.cardBorder.opacity(0.82), lineWidth: 0.8)
                    )
                }

                if !coordinator.accessibilityGranted {
                    HStack(spacing: 10) {
                        Button(coordinator.accessibilityPrimaryActionTitle) {
                            coordinator.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                        .disabled(coordinator.isRequestingAccessibility)

                        if coordinator.showAccessibilityFallbackHint {
                            Button("Open Accessibility Settings") {
                                coordinator.openAccessibilitySettings()
                            }
                            .buttonStyle(.bordered)
                            .disabled(coordinator.isRequestingAccessibility)
                        }

                        if coordinator.isRequestingAccessibility {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            .primarySurface(theme, padding: 18)

            Button("Continue") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct DoneSceneView: View {
    let theme: OnboardingTheme
    @ObservedObject var coordinator: OnboardingCoordinator
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 58))
                .foregroundStyle(theme.success)

            VStack(spacing: 8) {
                Text("You're ready")
                    .font(.albertSans(34, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text(coordinator.actionHint)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .multilineTextAlignment(.center)

            Button("Open Flowstay") {
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(theme.accent)
            .disabled(!coordinator.canCompleteOnboarding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct ReadyLabel: View {
    let theme: OnboardingTheme
    let title: String

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.success)
    }
}

private struct OnboardingPaneShape: InsettableShape {
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
        OnboardingPaneShape(cornerRadius: cornerRadius, insetAmount: insetAmount + amount)
    }
}

private extension View {
    func primarySurface(_ theme: OnboardingTheme, padding: CGFloat) -> some View {
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

    func secondarySurface(_ theme: OnboardingTheme, padding: CGFloat) -> some View {
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
