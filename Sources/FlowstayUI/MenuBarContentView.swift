import AVFoundation
import FlowstayCore
import SwiftUI

/// Clean, minimal menu bar dropdown content
public struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engineCoordinator: EngineCoordinatorViewModel
    @ObservedObject var permissionManager: PermissionManager

    @State private var hoveredTranscript: UUID?
    @State private var pulseTimer: Timer?
    @State private var animationPhase = 0
    // NOTE: openWindow removed - now using MenuBarHelper.openSettings/openOnboarding via AppDelegate

    public init(
        appState: AppState,
        engineCoordinator: EngineCoordinatorViewModel,
        permissionManager: PermissionManager
    ) {
        self.appState = appState
        self.engineCoordinator = engineCoordinator
        self.permissionManager = permissionManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header with recording status
            headerSection
                .padding(.bottom, 12)

            Divider()
                .padding(.vertical, 4)

            // Recent transcripts / History (always show for consistent layout)
            recentTranscriptsSection
                .padding(.vertical, 8)
            Divider()
                .padding(.vertical, 4)

            // Actions
            actionsSection
                .padding(.top, 8)
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 16)
        .frame(height: 400)
        .onAppear {
            // NOTE: GlobalShortcutsManager.initialize is now called from AppInitializationService
            // (either during onboarding completion or in applicationDidFinishLaunching for returning users)

            // Initialize engine callbacks and auto-paste settings
            Task { @MainActor in
                await initializeAppState()
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: engineCoordinator.isRecording ? "mic.circle.fill" : "mic.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(engineCoordinator.isRecording ? .red : .secondary)
                    .scaleEffect(engineCoordinator.isRecording ? (animationPhase == 0 ? 1.0 : 1.1) : 1.0)
                    .onChange(of: engineCoordinator.isRecording) { _, newValue in
                        if newValue {
                            startPulseAnimation()
                        } else {
                            stopPulseAnimation()
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.system(size: 14, weight: .medium))
                }

                Spacer()

                // Audio level indicator
                if engineCoordinator.isRecording {
                    AudioLevelIndicator(level: engineCoordinator.audioLevel)
                        .frame(width: 60, height: 20)
                }
            }
            .padding(.horizontal, 16)

            // Permission warnings
            if !permissionManager.criticalPermissionsGranted {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)

                    Text("Permissions needed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Fix") {
                        openOnboardingWindow()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.flowstayBlue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 16)
            }

            // Model loading indicator (shown while pre-loading on launch)
            if permissionManager.criticalPermissionsGranted, !engineCoordinator.isModelsReady, !engineCoordinator.isRecording {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)

                    Text("Loading speech models...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Recent Transcripts Section

    private var recentTranscriptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if !appState.recentTranscripts.isEmpty {
                    Button("Clear") {
                        appState.recentTranscripts.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.flowstayBlue)
                }
            }
            .padding(.horizontal, 16)

            if appState.recentTranscripts.isEmpty {
                // Empty state placeholder
                VStack {
                    Spacer()
                    Text("Press ⌥Space to start transcribing in any app")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appState.recentTranscripts.prefix(10)) { transcript in
                            TranscriptRow(
                                transcript: transcript,
                                appState: appState,
                                isHovered: hoveredTranscript == transcript.id,
                                onHover: { hoveredTranscript = $0 ? transcript.id : nil },
                                onCopy: { copyToClipboard(transcript.text) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // Modern recording button
            ModernRecordingButton(
                isRecording: engineCoordinator.isRecording,
                action: {
                    MenuBarHelper.toggleTranscription()
                }
            )
            .padding(.horizontal, 16)

            // Bottom actions
            HStack(spacing: 12) {
                Button(action: openSettingsWindow) {
                    Label("Settings", systemImage: "gear")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Quit") {
                    // Post notification to allow modals to dismiss first
                    NotificationCenter.default.post(name: Notification.Name("FlowstayWillTerminate"), object: nil)

                    // Give modals time to dismiss before terminating
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Computed Properties

    private var statusText: String {
        if engineCoordinator.isRecording {
            "Transcribing..."
        } else if !engineCoordinator.isModelsReady, permissionManager.criticalPermissionsGranted {
            "Loading models..."
        } else {
            "Ready to transcribe"
        }
    }

    // MARK: - Helper Methods

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openSettingsWindow() {
        // Close menu bar popover first
        MenuBarHelper.closeMenuBar()

        // Open the settings window via delegate
        MenuBarHelper.openSettings()
    }

    private func openOnboardingWindow() {
        // Open the onboarding window via delegate
        MenuBarHelper.openOnboarding()
    }

    private func startPulseAnimation() {
        // Reset phase and invalidate any existing timer
        animationPhase = 0
        pulseTimer?.invalidate()

        // Create new timer that toggles the phase on main RunLoop
        let timer = Timer(timeInterval: 0.8, repeats: true) { _ in
            // Hop to the main actor for any state/object access to silence concurrency warnings
            Task { @MainActor in
                if !engineCoordinator.isRecording {
                    pulseTimer?.invalidate()
                    pulseTimer = nil
                    return
                }

                withAnimation(.easeInOut(duration: 0.8)) {
                    animationPhase = animationPhase == 0 ? 1 : 0
                }
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stopPulseAnimation() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        withAnimation(.default) {
            animationPhase = 0
        }
    }

    @MainActor
    private func initializeAppState() async {
        // Check permissions on launch
        await permissionManager.checkPermissions()
        print("[MenuBarView] Initial permission check:")
        print("  - Mic: \(permissionManager.microphoneStatus)")
        print("  - Accessibility: \(permissionManager.accessibilityStatus)")

        // Show onboarding automatically if permissions are missing
        if !permissionManager.criticalPermissionsGranted {
            print("[MenuBarView] Auto-showing onboarding: criticalPermissions=\(permissionManager.criticalPermissionsGranted)")
            openOnboardingWindow()
        }

        // Default auto-paste to ON if user has accessibility permission
        if permissionManager.hasAccessibilityPermission, !UserDefaults.standard.bool(forKey: "autoPasteConfigured") {
            appState.autoPasteEnabled = true
            UserDefaults.standard.set(true, forKey: "autoPasteConfigured")
        }
    }
}

// MARK: - Supporting Views

struct TranscriptRow: View {
    let transcript: TranscriptItem
    let appState: AppState
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onCopy: () -> Void

    @State private var isExpanded = false
    @State private var isHoveredOriginal = false

    /// Expand when either a persona was used (to show before/after)
    /// or when the text is long enough that the collapsed view truncates it
    private var isLong: Bool {
        transcript.text.count > 80 || transcript.text.contains("\n")
    }

    private var isExpandable: Bool {
        transcript.wasProcessed || isLong
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row (always visible)
            Button(action: {
                if isExpandable {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }) {
                HStack(alignment: .top, spacing: 8) {
                    // Disclosure indicator (always present for alignment, invisible if not processed)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .padding(.top, 2)
                        .opacity(isExpandable ? 1 : 0)

                    VStack(alignment: .leading, spacing: 4) {
                        // Persona badge
                        if transcript.wasProcessed,
                           let personaId = transcript.personaId,
                           let persona = appState.allPersonas.first(where: { $0.id == personaId })
                        {
                            HStack(spacing: 4) {
                                if let emoji = persona.emoji {
                                    Text(emoji)
                                        .font(.system(size: 9))
                                }
                                Text(persona.name)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundStyle(Color.flowstayBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.flowstayBlue.opacity(0.1))
                            .clipShape(Capsule())
                        }

                        // Main text (processed or unprocessed)
                        Text(transcript.text)
                            .font(.system(size: 12))
                            .lineLimit(isExpanded ? nil : 2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)

                        // Timestamp
                        Text(RelativeDateTimeFormatter().localizedString(for: transcript.timestamp, relativeTo: Date()))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(isHovered && !isExpanded ? Color.gray.opacity(0.1) : Color.clear)
            .overlay(alignment: .topTrailing) {
                // Copy button (on hover) - always available for both collapsed and expanded states
                if isHovered {
                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 16)
                    .padding(.top, 6)
                }
            }
            .onHover(perform: onHover)

            // Expanded view (before/after comparison)
            if isExpanded, transcript.wasProcessed {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.horizontal, 16)

                    // Original text
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Original")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                if let original = transcript.originalText {
                                    copyToClipboard(original)
                                }
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .opacity(isHoveredOriginal ? 1.0 : 0.4)
                        }

                        if let original = transcript.originalText {
                            Text(original)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(isHoveredOriginal ? Color.gray.opacity(0.12) : Color.gray.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 16)
                    .onHover { hovering in
                        isHoveredOriginal = hovering
                    }
                }
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Modern Recording Button

struct ModernRecordingButton: View {
    let isRecording: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Invisible placeholder to maintain consistent width
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .opacity(0)

                    Text("Start transcription")
                        .font(.system(size: 14, weight: .medium))
                        .opacity(0)
                }

                // Actual content
                HStack(spacing: 8) {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isRecording ? .white : .primary)

                    Text(isRecording ? "Stop transcription" : "Start transcription")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isRecording ? .white : .primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                if isRecording {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.red.gradient)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        }
                }
            }
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
            // Long press completed
        } onPressingChanged: { isPressing in
            isPressed = isPressing
        }
    }
}

struct AudioLevelIndicator: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))

                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: geometry.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private var levelColor: Color {
        if level > 0.8 {
            .red
        } else if level > 0.5 {
            .orange
        } else {
            .green
        }
    }
}
