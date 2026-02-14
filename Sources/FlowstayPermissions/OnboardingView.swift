import AppKit
import FlowstayCore
import SwiftUI
import UserNotifications

public struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    let engineCoordinator: EngineCoordinatorViewModel
    let onComplete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 0
    @State private var isDownloadingModel = false
    @State private var modelDownloadComplete = false
    @State private var showExitWarning = false
    @State private var notificationPermissionGranted = false

    public init(
        permissionManager: PermissionManager,
        engineCoordinator: EngineCoordinatorViewModel,
        appState _: AppState,
        onComplete: (() -> Void)? = nil
    ) {
        self.permissionManager = permissionManager
        self.engineCoordinator = engineCoordinator
        self.onComplete = onComplete
    }

    private var canExit: Bool {
        // Can only exit if critical steps are complete
        permissionManager.criticalPermissionsGranted && modelDownloadComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Progress indicator (6 steps: 0, 1, 2, 3, 4, 5)
            ProgressView(value: Double(currentStep), total: 5)
                .progressViewStyle(.linear)
                .padding()

            // Content
            TabView(selection: $currentStep) {
                WelcomeCard()
                    .tag(0)

                MicrophonePermissionCard(permissionManager: permissionManager)
                    .tag(1)

                AccessibilityPermissionCard(
                    permissionManager: permissionManager,
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = 3
                        }
                    }
                )
                .tag(2)

                NotificationPermissionCard(
                    permissionGranted: $notificationPermissionGranted
                )
                .tag(3)

                ModelDownloadCard(
                    engineCoordinator: engineCoordinator,
                    isDownloading: $isDownloadingModel,
                    downloadComplete: $modelDownloadComplete,
                    onDownloadComplete: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = 5
                        }
                    }
                )
                .tag(4)

                CompletionCard(onComplete: {
                    print("[OnboardingView] Completion card - calling onComplete callback")
                    onComplete?()
                    print("[OnboardingView] Dismissing onboarding window")
                    dismiss()
                })
                .tag(5)
            }
            .tabViewStyle(.automatic)
            .animation(.easeInOut(duration: 0.3), value: currentStep)
            .onAppear {
                // Start downloading models in background as soon as onboarding appears
                startBackgroundModelDownload()
            }

            // Navigation buttons
            HStack {
                Button("Previous") {
                    withAnimation {
                        currentStep -= 1
                    }
                }
                .disabled(currentStep == 0)

                Spacer()

                if currentStep < 5 {
                    Button("Next") {
                        withAnimation {
                            if currentStep < 5 {
                                // Skip download step if models are already ready
                                if currentStep == 3, modelDownloadComplete {
                                    currentStep = 5
                                } else {
                                    currentStep += 1
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentStep == 4 && !modelDownloadComplete) // Can't proceed until model downloads
                }
            }
            .padding()
        }
        .frame(width: 600, height: 500)
        .interactiveDismissDisabled(!canExit)
        .alert("Exit onboarding?", isPresented: $showExitWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Exit app", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        } message: {
            Text("Completing onboarding is required for Flowstay to work. If you exit now, you'll need to complete onboarding the next time you launch the app.")
        }
    }

    private func startBackgroundModelDownload() {
        // Check if models are already downloaded AND initialized
        if engineCoordinator.isModelDownloaded(), engineCoordinator.isModelsReady {
            modelDownloadComplete = true
            return
        }

        // Start download/initialization in background
        isDownloadingModel = true
        Task {
            await engineCoordinator.preInitializeAllModels()
            await MainActor.run {
                isDownloadingModel = false
                if engineCoordinator.engineError == nil {
                    modelDownloadComplete = true

                    // GlobalShortcutsManager will be initialized in finalizeInitialization()
                    // after onboarding completes to avoid redundant initialization

                    // Send notification when download completes
                    sendModelReadyNotification()

                    // Auto-advance if user is on the download step
                    if currentStep == 4 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = 5
                        }
                    }
                }
            }
        }
    }

    private func sendModelReadyNotification() {
        Task { @MainActor in
            // Only send notification if user granted permission
            guard notificationPermissionGranted else {
                print("[OnboardingView] Skipping model ready notification - permissions not granted")
                return
            }

            NotificationManager.shared.sendNotification(
                title: "Model installed!",
                body: "Try transcribing with Option + Space",
                identifier: "model-ready"
            )
        }
    }
}

struct WelcomeCard: View {
    var body: some View {
        VStack(spacing: 24) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
            } else {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.flowstayBlue)
            }

            Text("Welcome to Flowstay")
                .font(.albertSans(34, weight: .semibold))

            Text("Stay in your flow state")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "lock.fill", title: "Privacy first", subtitle: "Everything stays on your Mac")
                FeatureRow(icon: "mic.badge.plus", title: "Multilingual speech recognition", subtitle: "Supports 25 European languages")
                FeatureRow(icon: "keyboard", title: "Auto-paste", subtitle: "Seamlessly insert text into any app")
            }
            .padding(.top)
        }
        .padding()
    }
}

struct MicrophonePermissionCard: View {
    @ObservedObject var permissionManager: PermissionManager
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundStyle(permissionManager.hasMicrophonePermission ? .green : Color.flowstayBlue)
                .scaleEffect(permissionManager.hasMicrophonePermission ? 1.1 : 1.0)
                .animation(.spring(), value: permissionManager.hasMicrophonePermission)

            Text("Microphone access")
                .font(.albertSans(24, weight: .semibold))

            Text("Flowstay needs your microphone to transcribe your voice. Your data never leaves your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if permissionManager.hasMicrophonePermission {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: {
                    isRequesting = true
                    Task {
                        await permissionManager.requestMicrophonePermission()
                        // Poll for permission changes
                        for _ in 0 ..< 10 {
                            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                            await permissionManager.checkPermissions()
                            if permissionManager.hasMicrophonePermission {
                                break
                            }
                        }
                        isRequesting = false
                    }
                }) {
                    Text("Allow microphone access")
                        .frame(minHeight: 32)
                        .padding(.horizontal, 20)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)

                if isRequesting {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
        .padding()
        .animation(.spring(), value: permissionManager.hasMicrophonePermission)
    }
}

struct AccessibilityPermissionCard: View {
    @ObservedObject var permissionManager: PermissionManager
    let onSkip: () -> Void
    @State private var isRequesting = false
    @State private var checkingTimer: Timer?
    @State private var timeoutTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.right.doc.on.clipboard")
                .font(.system(size: 60))
                .foregroundStyle(permissionManager.hasAccessibilityPermission ? .green : Color.flowstayBlue)
                .scaleEffect(permissionManager.hasAccessibilityPermission ? 1.1 : 1.0)
                .animation(.spring(), value: permissionManager.hasAccessibilityPermission)

            Text("Auto-paste")
                .font(.albertSans(24, weight: .semibold))

            Text("Allow Flowstay to paste automatically into your current app. You can always copy manually if you prefer.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if permissionManager.hasAccessibilityPermission {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .onAppear {
                        cleanupTimers()
                    }
            } else {
                VStack(spacing: 16) {
                    Button(action: {
                        isRequesting = true
                        Task {
                            await permissionManager.requestAccessibilityPermission()

                            // Start polling for permission changes
                            checkingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                                let trusted = AXIsProcessTrusted()
                                if trusted {
                                    Task { @MainActor in
                                        permissionManager.accessibilityStatus = .authorized
                                        cleanupTimers()
                                        isRequesting = false
                                    }
                                }
                            }

                            // Stop checking after 30 seconds
                            timeoutTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 30_000_000_000)
                                cleanupTimers()
                                isRequesting = false
                            }
                        }
                    }) {
                        Text("Allow accessibility access")
                            .frame(minHeight: 32)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isRequesting)

                    if isRequesting {
                        VStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Please enable Flowstay in System Settings")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !isRequesting {
                        Button("Skip for now") {
                            onSkip()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .animation(.spring(), value: permissionManager.hasAccessibilityPermission)
        .onAppear {
            // Reset requesting state when returning to this page
            if !permissionManager.hasAccessibilityPermission {
                cleanupTimers()
                isRequesting = false
            }
        }
        .onDisappear {
            cleanupTimers()
        }
    }

    private func cleanupTimers() {
        checkingTimer?.invalidate()
        checkingTimer = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}

struct CompletionCard: View {
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .scaleEffect(1.0)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: true)

            Text("All set!")
                .font(.albertSans(32, weight: .semibold))

            Text("Flowstay is ready. Dictate from anywhere. Stay in flow.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Text("Press Option + Space to start dictating")
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: {
                    // Switch back to accessory mode (hide from Dock)
                    NSApplication.shared.setActivationPolicy(.accessory)

                    // Call completion callback FIRST, then mark as complete
                    // This ensures if initialization fails, onboarding can be re-run
                    onComplete()

                    // Only mark complete after successful initialization
                    // The callback should handle any errors and not crash
                    UserDefaults.standard.hasCompletedOnboarding = true
                }) {
                    Text("Open Flowstay")
                        .frame(minHeight: 32)
                        .padding(.horizontal, 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.top)
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color.flowstayBlue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ModelDownloadCard: View {
    @ObservedObject var engineCoordinator: EngineCoordinatorViewModel
    @Binding var isDownloading: Bool
    @Binding var downloadComplete: Bool
    @State private var downloadError: String?
    let onDownloadComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            if isDownloading {
                VStack(spacing: 20) {
                    // Elegant indeterminate spinner
                    ProgressView()
                        .scaleEffect(2.0)
                        .tint(Color.flowstayBlue)
                        .frame(height: 100)

                    VStack(spacing: 12) {
                        Text("Downloading speech recognition model")
                            .font(.albertSans(20, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("~600 MB • This may take a few minutes")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 4) {
                            Text("You can minimize this window and continue working")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Text("We'll notify you when it's ready")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 4)
                    }
                }
            } else if downloadError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.orange)
            } else if downloadComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.flowstayBlue)
            }

            if !isDownloading {
                Text(downloadError != nil ? "Download failed" : (downloadComplete ? "Ready!" : "Download model"))
                    .font(.albertSans(28, weight: .semibold))
            }

            if let error = downloadError {
                VStack(spacing: 16) {
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    Button("Retry") {
                        downloadError = nil
                        // Trigger will be handled by onAppear in parent
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else if !isDownloading, !downloadComplete {
                Text("Speech recognition models enable offline transcription")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .padding()
        .onChange(of: engineCoordinator.engineError) { _, error in
            if let error {
                downloadError = error
                downloadComplete = false
                isDownloading = false
            }
        }
        .onChange(of: downloadComplete) { _, isComplete in
            if isComplete {
                onDownloadComplete()
            }
        }
    }
}

struct NotificationPermissionCard: View {
    @Binding var permissionGranted: Bool
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 60))
                .foregroundStyle(permissionGranted ? .green : Color.flowstayBlue)
                .scaleEffect(permissionGranted ? 1.1 : 1.0)
                .animation(.spring(), value: permissionGranted)

            Text("Notifications")
                .font(.albertSans(24, weight: .semibold))

            Text("Get notified when transcription finishes or models download. You can skip this step if you prefer.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if isRequesting {
                VStack(spacing: 8) {
                    Text("👆 Look for a notification banner at the top of your screen")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Text("Click \"Options\" then \"Allow\" to enable notifications")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if permissionGranted {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                VStack(spacing: 12) {
                    Button(action: {
                        isRequesting = true
                        Task {
                            // Request with timeout
                            let granted = await NotificationManager.shared.requestPermissions()

                            // Keep checking for 15 seconds to see if user responds
                            var finalGranted = granted
                            if !granted {
                                for _ in 0 ..< 15 {
                                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                                    let status = await NotificationManager.shared.checkPermissionStatus()
                                    if status {
                                        finalGranted = true
                                        break
                                    }
                                }
                            }

                            await MainActor.run {
                                permissionGranted = finalGranted
                                isRequesting = false
                            }
                        }
                    }) {
                        Text("Allow notifications")
                            .frame(minHeight: 32)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isRequesting)

                    if isRequesting {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
        }
        .padding()
        .animation(.spring(), value: permissionGranted)
        .onAppear {
            // Check initial status
            Task {
                let status = await NotificationManager.shared.checkPermissionStatus()
                await MainActor.run {
                    permissionGranted = status
                }
            }
        }
    }
}
