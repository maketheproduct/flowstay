import AppKit
import FlowstayCore
import KeyboardShortcuts
import SwiftUI

// Language support for FluidAudio Parakeet V3

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, personas, history, permissions
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .general: "General"
        case .personas: "Personas"
        case .history: "History"
        case .permissions: "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .personas: "wand.and.stars"
        case .history: "clock.arrow.circlepath"
        case .permissions: "lock.shield"
        }
    }
}

/// Enhanced settings view with sidebar navigation (System Settings style)
public struct TabbedSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var engineCoordinator: EngineCoordinatorViewModel
    @ObservedObject var permissionManager: PermissionManager
    @StateObject private var settingsViewModel: SettingsViewModel
    @State private var selectedTab: SettingsTab = .general

    public init(
        appState: AppState,
        engineCoordinator: EngineCoordinatorViewModel,
        permissionManager: PermissionManager
    ) {
        self.appState = appState
        self.engineCoordinator = engineCoordinator
        self.permissionManager = permissionManager
        _settingsViewModel = StateObject(wrappedValue: SettingsViewModel(
            engineCoordinator: engineCoordinator,
            appState: appState
        ))
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selectedTab {
            case .general:
                GeneralSettingsTab(
                    appState: appState,
                    settingsViewModel: settingsViewModel,
                    engineCoordinator: engineCoordinator,
                    permissionManager: permissionManager
                )
            case .personas:
                PersonasTab(appState: appState)
            case .history:
                HistoryTab(appState: appState)
            case .permissions:
                PermissionsTab(permissionManager: permissionManager)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 580)
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settingsViewModel: SettingsViewModel
    let engineCoordinator: EngineCoordinatorViewModel // Keep reference for actions, but don't observe
    @ObservedObject var permissionManager: PermissionManager
    @StateObject private var updateManager = UpdateManager.shared
    @State private var hotkeyValidationMessage: String?
    @State private var lastValidToggleShortcut: KeyboardShortcuts.Shortcut?
    @State private var lastValidHoldShortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("General")
                        .font(.albertSans(28, weight: .bold))
                    Text("Configure your dictation preferences")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSectionCard("Speech Engine") {
                        SettingsCardRow {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "waveform.badge.mic")
                                            .foregroundStyle(Color.flowstayBlue)
                                        Text("NVIDIA Parakeet V3")
                                            .font(.headline)
                                    }
                                    Text("High-performance multilingual speech recognition")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack {
                                        Circle()
                                            .fill(settingsViewModel.isModelsReady ? Color.green : Color.orange)
                                            .frame(width: 8, height: 8)
                                        Text(settingsViewModel.isModelsReady ? "Ready" : "Not ready")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(settingsViewModel.isModelsReady ? .green : .orange)
                                    }
                                    Text("Private and local")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let error = settingsViewModel.engineError {
                            SettingsCardRow(showsDivider: false) {
                                HStack {
                                    Label(error, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)

                                    Spacer()

                                    Button("Download model") {
                                        Task {
                                            await engineCoordinator.preInitializeAllModels()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }

                    SettingsSectionCard("Audio Input") {
                        SettingsCardRow(showsDivider: false) {
                            SettingsControlRow(
                                title: "Microphone",
                                systemImage: "mic",
                                description: "The app uses your macOS system default input device. Change it in Sound Settings."
                            ) {
                                Button("Open Sound Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    SettingsSectionCard("Language") {
                        SettingsCardRow(showsDivider: false) {
                            SettingsControlRow(
                                title: "Language detection",
                                systemImage: "globe",
                                description: "Automatically detects among 25 European languages"
                            ) {
                                Text("Auto-detect")
                                    .font(.headline)
                            }
                        }
                    }

                    SettingsSectionCard("Keyboard shortcut") {
                        SettingsCardRow {
                            HStack {
                                Text("Toggle transcription")
                                Spacer()
                                KeyboardShortcuts.Recorder(
                                    for: .toggleDictation,
                                    onChange: handleToggleShortcutChange
                                )
                            }
                        }

                        SettingsCardRow {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Hold input")
                                Picker("", selection: $appState.holdToTalkInputSource) {
                                    ForEach(HoldToTalkInputSource.allCases, id: \.rawValue) { source in
                                        Text(source.displayName).tag(source)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                        }

                        if appState.holdToTalkInputSource == .alternativeShortcut {
                            SettingsCardRow {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Hold-to-talk shortcut")
                                        Spacer()
                                        KeyboardShortcuts.Recorder(
                                            for: .holdToTalk,
                                            onChange: handleHoldShortcutChange
                                        )
                                    }

                                    if let hotkeyValidationMessage {
                                        Label(hotkeyValidationMessage, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }

                        SettingsCardRow(showsDivider: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Hotkey behavior")
                                Picker("", selection: $appState.hotkeyPressMode) {
                                    ForEach(HotkeyPressMode.allCases, id: \.rawValue) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)

                                Text(hotkeyBehaviorDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    SettingsSectionCard("Behavior") {
                        SettingsCardRow {
                            SettingsControlRow(
                                title: "Floating overlay",
                                systemImage: "sparkles",
                                description: "Shows a Dynamic-Island-style overlay with transcription state and input activity"
                            ) {
                                SettingsSwitch(isOn: $appState.showOverlay)
                            }
                        }

                        SettingsCardRow {
                            SettingsControlRow(
                                title: "Launch at login",
                                systemImage: "power"
                            ) {
                                SettingsSwitch(isOn: $appState.launchAtLogin)
                            }
                        }

                        SettingsCardRow {
                            SettingsControlRow(
                                title: "Auto-paste transcripts",
                                systemImage: "doc.on.clipboard"
                            ) {
                                SettingsSwitch(isOn: Binding(
                                    get: {
                                        permissionManager.hasAccessibilityPermission && appState.autoPasteEnabled
                                    },
                                    set: { newValue in
                                        if permissionManager.hasAccessibilityPermission {
                                            appState.autoPasteEnabled = newValue
                                        }
                                    }
                                ))
                                .disabled(!permissionManager.hasAccessibilityPermission)
                            }
                        }

                        if appState.autoPasteEnabled, !permissionManager.hasAccessibilityPermission {
                            SettingsCardRow {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Accessibility permission required")
                                            .font(.caption.weight(.semibold))
                                        Text("Enable accessibility permission to allow auto-pasting")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(Color.flowstayBlue)
                                }
                            }
                        }

                        SettingsCardRow {
                            SettingsControlRow(
                                title: "Auto-stop timeout",
                                systemImage: "timer",
                                description: "Transcription will stop when no speech detected for this period of time"
                            ) {
                                Picker("", selection: $appState.silenceTimeoutSeconds) {
                                    Text("Unlimited").tag(0.0)
                                    Text("15s").tag(15.0)
                                    Text("30s").tag(30.0)
                                    Text("45s").tag(45.0)
                                    Text("60s").tag(60.0)
                                    Text("90s").tag(90.0)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 80)
                            }
                        }

                        SettingsCardRow(showsDivider: false) {
                            SettingsControlRow(
                                title: "Audio Cues",
                                systemImage: "speaker.wave.2",
                                description: "Play sounds when recording starts, stops, or finishes"
                            ) {
                                SettingsSwitch(isOn: $appState.soundFeedbackEnabled)
                            }
                        }
                    }

                    SettingsSectionCard("Statistics") {
                        SettingsCardRow(showsDivider: false) {
                            SettingsControlRow(
                                title: "Average dictation speed",
                                systemImage: "chart.line.uptrend.xyaxis",
                                description: appState.averageWPM > 0 ? "Based on last \(min(settingsViewModel.validTranscriptsCount, 10)) sessions" : nil
                            ) {
                                if appState.averageWPM > 0 {
                                    Text("\(appState.averageWPM) wpm")
                                        .font(.headline)
                                        .foregroundStyle(Color.flowstayBlue)
                                } else {
                                    Text("Not enough data")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    SettingsSectionCard("Updates") {
                        SettingsCardRow(showsDivider: false) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Flowstay \(updateManager.currentVersion)")
                                        .font(.headline)
                                    Text(updateManager.unavailableReason ?? "Check for updates automatically on launch")
                                        .font(.caption)
                                        .foregroundStyle(updateManager.isUpdaterAvailable ? Color.secondary : Color.orange)
                                }

                                Spacer()

                                Button("Check for Updates") {
                                    updateManager.checkForUpdates()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(updateManager.isCheckingForUpdates || !updateManager.isUpdaterAvailable)
                            }
                        }
                    }

                    if recoverySnapshot.isDegradedLaunch {
                        SettingsSectionCard("Startup Help") {
                            SettingsCardRow(showsDivider: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Flowstay had trouble starting on its last launch.", systemImage: "wrench.and.screwdriver.fill")
                                        .foregroundStyle(.orange)

                                    Text("Flowstay opened in a safer mode for this launch, so some features may be temporarily limited until you review the suggested fixes.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Button("Fix Startup Issues") {
                                        MenuBarHelper.openRecovery()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .onAppear(perform: syncHotkeyState)
            .onChange(of: appState.holdToTalkInputSource) { _, _ in
                syncHotkeyState()
            }
        }
    }

    private var recoverySnapshot: StartupRecoverySnapshot {
        StartupRecoveryManager.shared.snapshot
    }

    private var toggleShortcutDescription: String {
        shortcutDescription(KeyboardShortcuts.getShortcut(for: .toggleDictation)) ?? "⌥Space"
    }

    private var holdShortcutDescription: String? {
        shortcutDescription(KeyboardShortcuts.getShortcut(for: .holdToTalk))
    }

    private var hotkeyBehaviorDescription: String {
        switch appState.hotkeyPressMode {
        case .toggle:
            "Press \(toggleShortcutDescription) to start or stop transcription."
        case .hold:
            if appState.holdToTalkInputSource == .functionKey {
                "Hold the Fn key while speaking, then release Fn to stop."
            } else if let holdShortcutDescription {
                "Hold \(holdShortcutDescription) while speaking, then release to stop."
            } else {
                "Set a hold-to-talk shortcut below, then hold it while speaking."
            }
        case .both:
            if appState.holdToTalkInputSource == .functionKey {
                "Use \(toggleShortcutDescription) as toggle, Fn as hold-to-talk."
            } else if let holdShortcutDescription {
                "Use \(toggleShortcutDescription) as toggle. Hold \(holdShortcutDescription) for hold-to-talk."
            } else {
                "Use \(toggleShortcutDescription) as toggle. Set a hold-to-talk shortcut below for hold-to-talk."
            }
        }
    }

    private func shortcutDescription(_ shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut else { return nil }
        return shortcut.description
    }

    private func syncHotkeyState() {
        lastValidToggleShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        let configuredHoldShortcut = KeyboardShortcuts.getShortcut(for: .holdToTalk)
        if appState.holdToTalkInputSource == .alternativeShortcut,
           let configuredHoldShortcut,
           configuredHoldShortcut == lastValidToggleShortcut
        {
            KeyboardShortcuts.setShortcut(nil, for: .holdToTalk)
            lastValidHoldShortcut = nil
            hotkeyValidationMessage = "Hold shortcut cannot match toggle shortcut. The hold shortcut was cleared."
            return
        }

        lastValidHoldShortcut = configuredHoldShortcut
        hotkeyValidationMessage = nil
    }

    private func handleToggleShortcutChange(_ newShortcut: KeyboardShortcuts.Shortcut?) {
        if appState.holdToTalkInputSource == .alternativeShortcut,
           let newShortcut,
           newShortcut == KeyboardShortcuts.getShortcut(for: .holdToTalk)
        {
            KeyboardShortcuts.setShortcut(lastValidToggleShortcut, for: .toggleDictation)
            hotkeyValidationMessage = "Toggle and hold shortcuts must be different."
            return
        }

        lastValidToggleShortcut = newShortcut
        hotkeyValidationMessage = nil
    }

    private func handleHoldShortcutChange(_ newShortcut: KeyboardShortcuts.Shortcut?) {
        guard appState.holdToTalkInputSource == .alternativeShortcut else {
            lastValidHoldShortcut = newShortcut
            hotkeyValidationMessage = nil
            return
        }

        if let newShortcut, newShortcut == KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            KeyboardShortcuts.setShortcut(lastValidHoldShortcut, for: .holdToTalk)
            hotkeyValidationMessage = "Toggle and hold shortcuts must be different."
            return
        }

        lastValidHoldShortcut = newShortcut
        hotkeyValidationMessage = nil
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
    }
}

private struct SettingsCardRow<Content: View>: View {
    let showsDivider: Bool
    @ViewBuilder let content: Content

    init(showsDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            if showsDivider {
                Divider()
                    .padding(.horizontal, 18)
            }
        }
    }
}

private struct SettingsControlRow<Trailing: View>: View {
    let title: String
    let systemImage: String
    let description: String?
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        systemImage: String,
        description: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 16)
                trailing
            }

            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(SettingsSwitchToggleStyle())
            .fixedSize()
    }
}

private struct SettingsSwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            guard isEnabled else { return }
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label

                ZStack {
                    Capsule(style: .continuous)
                        .fill(trackColor(isOn: configuration.isOn))
                        .frame(width: 54, height: 32)

                    Circle()
                        .fill(knobColor)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .strokeBorder(knobStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 2, y: 1)
                        .offset(x: configuration.isOn ? 11 : -11)
                }
                .animation(.easeInOut(duration: 0.12), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    private func trackColor(isOn: Bool) -> Color {
        if isOn {
            return isEnabled ? .flowstayBlue : Color.flowstayBlue.opacity(0.45)
        }

        return Color(nsColor: .quaternaryLabelColor).opacity(isEnabled ? 0.34 : 0.2)
    }

    private var knobColor: Color {
        Color(nsColor: colorScheme == .dark ? .windowBackgroundColor : .white)
    }

    private var knobStrokeColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08)
    }
}

private struct PersonaRadioRow: View {
    let isSelected: Bool
    let emoji: String?
    let name: String
    let description: String
    let isBuiltIn: Bool
    let onSelect: () -> Void
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)

            if let emoji {
                Text(emoji)
                    .font(.system(size: 24))
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(name)
                        .font(.subheadline)
                    if isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let onEdit, let onDelete {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NativeConfirmationDialog: View {
    let title: String
    let message: String?
    let confirmTitle: String
    let cancelTitle: String
    let isDestructive: Bool
    let dontAskAgainLabel: String?
    let dontAskAgain: Binding<Bool>?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    init(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        isDestructive: Bool = false,
        dontAskAgainLabel: String? = nil,
        dontAskAgain: Binding<Bool>? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.isDestructive = isDestructive
        self.dontAskAgainLabel = dontAskAgainLabel
        self.dontAskAgain = dontAskAgain
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let dontAskAgain, let dontAskAgainLabel {
                Divider()

                HStack {
                    Text(dontAskAgainLabel)
                        .font(.subheadline)
                    Spacer()
                    SettingsSwitch(isOn: dontAskAgain)
                }
            }

            HStack(spacing: 12) {
                Spacer()

                Button(cancelTitle, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                if isDestructive {
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}

// MARK: - Create Persona Modal

struct CreatePersonaView: View {
    let appState: AppState
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var instruction = ""
    @State private var emoji = ""
    @State private var showingDiscardAlert = false
    @State private var dontAskAgain = false
    @FocusState private var isEmojiFieldFocused: Bool

    private var hasChanges: Bool {
        !name.isEmpty || !instruction.isEmpty || !emoji.isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Create persona")
                .font(.headline)

            // Emoji and Name in same row
            HStack(spacing: 12) {
                // Emoji picker (button appearance with hidden text field)
                ZStack {
                    // Hidden text field that receives emoji input from character palette
                    TextField("", text: $emoji)
                        .textFieldStyle(.plain)
                        .opacity(0.001)
                        .frame(width: 56, height: 44)
                        .focused($isEmojiFieldFocused)
                        .onChange(of: emoji) { _, newValue in
                            // Limit to first emoji (typically 1-2 characters)
                            if newValue.count > 2 {
                                emoji = String(newValue.prefix(2))
                            }
                        }

                    // Visual button (what user sees and clicks)
                    Button {
                        isEmojiFieldFocused = true
                        NSApp.orderFrontCharacterPalette(nil)
                    } label: {
                        Text(emoji.isEmpty ? "😀" : emoji)
                            .font(.system(size: 32))
                            .frame(width: 56, height: 44)
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Click to choose an emoji")
                }
                .frame(width: 56, height: 44)

                // Name field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Persona name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            // Instruction Field
            VStack(alignment: .leading, spacing: 8) {
                Text("Instruction")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $instruction)
                    .font(.body)
                    .frame(height: 120)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    handleCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    savePersona()
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        Text("⌘↩")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(name.isEmpty || instruction.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingDiscardAlert) {
            NativeConfirmationDialog(
                title: "Discard changes?",
                confirmTitle: "Discard",
                isDestructive: true,
                dontAskAgainLabel: "Don't ask me again",
                dontAskAgain: $dontAskAgain,
                onCancel: { showingDiscardAlert = false },
                onConfirm: {
                    if dontAskAgain {
                        appState.showPersonaDiscardConfirmation = false
                    }
                    showingDiscardAlert = false
                    onDismiss()
                }
            )
        }
    }

    private func handleCancel() {
        if hasChanges, appState.showPersonaDiscardConfirmation {
            showingDiscardAlert = true
        } else {
            onDismiss()
        }
    }

    private func savePersona() {
        let newPersona = Persona(
            id: UUID().uuidString,
            name: name,
            instruction: instruction,
            emoji: emoji.isEmpty ? nil : emoji,
            isBuiltIn: false
        )
        appState.addPersona(newPersona)
        onDismiss()
    }
}

// MARK: - Edit Persona Modal

struct EditPersonaView: View {
    let persona: Persona
    let appState: AppState
    let onDismiss: () -> Void
    @State private var editedName: String
    @State private var editedInstruction: String
    @State private var editedEmoji: String
    @State private var showingDiscardAlert = false
    @State private var dontAskAgain = false
    @FocusState private var isEmojiFieldFocused: Bool

    init(persona: Persona, appState: AppState, onDismiss: @escaping () -> Void) {
        self.persona = persona
        self.appState = appState
        self.onDismiss = onDismiss
        _editedName = State(initialValue: persona.name)
        _editedInstruction = State(initialValue: persona.instruction)
        _editedEmoji = State(initialValue: persona.emoji ?? "")
    }

    private var hasChanges: Bool {
        let originalEmoji = persona.emoji ?? ""
        return editedName != persona.name || editedInstruction != persona.instruction || editedEmoji != originalEmoji
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Persona")
                .font(.headline)

            // Emoji and Name in same row
            HStack(spacing: 12) {
                // Emoji picker (button appearance with hidden text field)
                ZStack {
                    // Hidden text field that receives emoji input from character palette
                    TextField("", text: $editedEmoji)
                        .textFieldStyle(.plain)
                        .opacity(0.001)
                        .frame(width: 56, height: 44)
                        .focused($isEmojiFieldFocused)
                        .onChange(of: editedEmoji) { _, newValue in
                            // Limit to first emoji (typically 1-2 characters)
                            if newValue.count > 2 {
                                editedEmoji = String(newValue.prefix(2))
                            }
                        }

                    // Visual button (what user sees and clicks)
                    Button {
                        isEmojiFieldFocused = true
                        NSApp.orderFrontCharacterPalette(nil)
                    } label: {
                        Text(editedEmoji.isEmpty ? "😀" : editedEmoji)
                            .font(.system(size: 32))
                            .frame(width: 56, height: 44)
                            .background(Color.gray.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Click to choose an emoji")
                }
                .frame(width: 56, height: 44)

                // Name field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Persona name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            // Instruction Field
            VStack(alignment: .leading, spacing: 8) {
                Text("Instruction")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $editedInstruction)
                    .font(.body)
                    .frame(height: 120)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    handleCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    saveChanges()
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        Text("⌘↩")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editedName.isEmpty || editedInstruction.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showingDiscardAlert) {
            NativeConfirmationDialog(
                title: "Discard changes?",
                confirmTitle: "Discard",
                isDestructive: true,
                dontAskAgainLabel: "Don't ask me again",
                dontAskAgain: $dontAskAgain,
                onCancel: { showingDiscardAlert = false },
                onConfirm: {
                    if dontAskAgain {
                        appState.showPersonaDiscardConfirmation = false
                    }
                    showingDiscardAlert = false
                    onDismiss()
                }
            )
        }
    }

    private func handleCancel() {
        if hasChanges, appState.showPersonaDiscardConfirmation {
            showingDiscardAlert = true
        } else {
            onDismiss()
        }
    }

    private func saveChanges() {
        var updatedPersona = persona
        updatedPersona.name = editedName
        updatedPersona.instruction = editedInstruction
        updatedPersona.emoji = editedEmoji.isEmpty ? nil : editedEmoji
        appState.updatePersona(updatedPersona)
        onDismiss()
    }
}

// MARK: - Personas Tab

struct PersonasTab: View {
    @ObservedObject var appState: AppState
    @StateObject private var oauthManager = OpenRouterOAuthManager.shared
    @StateObject private var modelCache = OpenRouterModelCache.shared
    private let claudeCodeProvider = ClaudeCodeProvider()
    @State private var claudeCodeStatus: AIProviderStatus = .notConfigured(reason: "Checking Claude Code...")
    @State private var editingPrompt: Persona?
    @State private var showingCreatePersona = false
    @State private var showingAppRulePicker: DetectedApp?
    @State private var showingAppSelector = false
    @State private var personaToDelete: Persona?
    @State private var showingDeletePersonaAlert = false
    @State private var dontAskPersonaDeleteAgain = false
    @State private var appRuleToDelete: AppRule?
    @State private var showingDeleteAppRuleAlert = false
    @State private var dontAskAppRuleDeleteAgain = false
    @State private var showingDisconnectAlert = false

    var isPersonasAvailable: Bool {
        // Personas available based on selected provider
        switch appState.selectedAIProviderId {
        case AIProviderIdentifier.openRouter.rawValue:
            return oauthManager.isConnected
        case AIProviderIdentifier.claudeCode.rawValue:
            return claudeCodeStatus.isAvailable
        default:
            // Apple Intelligence
            if #available(macOS 26, *) {
                return AppleIntelligenceHelper.isAvailable()
            }
            return false
        }
    }

    var isAppleIntelligenceAvailable: Bool {
        if #available(macOS 26, *) {
            return AppleIntelligenceHelper.isAvailable()
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Personas")
                        .font(.albertSans(28, weight: .bold))
                    Text("Automatically adjust your tone for different apps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // AI Provider
                    SettingsSectionCard("AI Provider") {
                        SettingsCardRow(showsDivider: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                SettingsControlRow(
                                    title: "Text processing engine",
                                    systemImage: "cpu"
                                ) {
                                    Picker("", selection: Binding(
                                        get: { appState.selectedAIProviderId ?? AIProviderIdentifier.appleIntelligence.rawValue },
                                        set: { appState.selectedAIProviderId = $0 }
                                    )) {
                                        Text("Apple Intelligence").tag(AIProviderIdentifier.appleIntelligence.rawValue)
                                        Text("OpenRouter").tag(AIProviderIdentifier.openRouter.rawValue)
                                        Text("Claude Code (experimental)").tag(AIProviderIdentifier.claudeCode.rawValue)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }

                                // Dynamic privacy indicator based on selected provider
                                HStack(spacing: 6) {
                                    let (icon, color, text) = providerPrivacyInfo
                                    Image(systemName: icon)
                                        .font(.caption)
                                        .foregroundStyle(color)
                                    Text(text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                // Provider-specific configuration
                                switch appState.selectedAIProviderId {
                                case AIProviderIdentifier.openRouter.rawValue:
                                    openRouterConfigView

                                case AIProviderIdentifier.claudeCode.rawValue:
                                    claudeCodeConfigView

                                default:
                                    appleIntelligenceConfigView
                                }
                            }
                        }
                    }

                    // Personas
                    SettingsSectionCard("Personas") {
                        SettingsCardRow(showsDivider: false) {
                            VStack(alignment: .leading, spacing: 12) {
                                SettingsControlRow(
                                    title: "Enable personas",
                                    systemImage: "wand.and.stars"
                                ) {
                                    SettingsSwitch(isOn: Binding(
                                        get: { appState.personasEnabled && isPersonasAvailable },
                                        set: { newValue in
                                            if isPersonasAvailable {
                                                appState.personasEnabled = newValue
                                            }
                                        }
                                    ))
                                    .disabled(!isPersonasAvailable)
                                }

                                if isPersonasAvailable {
                                    Text("Automatically adjust writing style based on context – from professional to casual.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if appState.selectedAIProviderId == AIProviderIdentifier.openRouter.rawValue, !oauthManager.isConnected {
                                    Label("Connect OpenRouter above to enable personas", systemImage: "info.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.flowstayBlue)
                                } else if appState.selectedAIProviderId == AIProviderIdentifier.claudeCode.rawValue {
                                    switch claudeCodeStatus {
                                    case let .notConfigured(reason):
                                        Label(reason, systemImage: "info.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(Color.flowstayBlue)
                                    case let .unavailable(reason):
                                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    case .rateLimited:
                                        Label("Claude Code is currently rate limited", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    case .available:
                                        EmptyView()
                                    }
                                } else {
                                    DisclosureGroup {
                                        if #available(macOS 26, *) {
                                            Text("Apple Intelligence isn't enabled")
                                                .font(.caption.weight(.semibold))
                                            Text("Personas require Apple Intelligence to be enabled in System Settings.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            Button("Open Apple Intelligence Settings") {
                                                SystemSettingsHelper.openAppleIntelligenceSettings()
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        } else {
                                            Text("Requires macOS 26 with Apple Intelligence")
                                                .font(.caption.weight(.semibold))
                                            Text("Personas use Apple Intelligence to adjust your transcript tone. Update to macOS 26 to enable this feature.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            Button("Check for macOS Updates") {
                                                SystemSettingsHelper.openSoftwareUpdate()
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                        }
                                    } label: {
                                        Label("More information", systemImage: "info.circle.fill")
                                            .foregroundStyle(Color.flowstayBlue)
                                    }
                                }
                            }
                        }
                    }

                    // App-Specific Personas (only show if enabled)
                    if appState.personasEnabled, isPersonasAvailable {
                        SettingsSectionCard("App-Specific Personas") {
                            SettingsCardRow(showsDivider: appState.useSmartAppDetection) {
                                SettingsControlRow(
                                    title: "Smart app detection",
                                    systemImage: "apps.iphone",
                                    description: "Flowstay remembers which persona you prefer for each app"
                                ) {
                                    SettingsSwitch(isOn: $appState.useSmartAppDetection)
                                }
                            }

                            if appState.useSmartAppDetection {
                                SettingsCardRow(showsDivider: false) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        // Add new rule button
                                        Button {
                                            showingAppSelector = true
                                        } label: {
                                            Text("Add app rule")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        // Existing rules
                                        if !appState.appRules.isEmpty {
                                            ScrollView {
                                                LazyVStack(spacing: 8) {
                                                    ForEach(appState.appRules.sorted(by: { $0.appName < $1.appName })) { rule in
                                                        HStack(spacing: 12) {
                                                            if let iconData = rule.appIcon,
                                                               let nsImage = NSImage(data: iconData)
                                                            {
                                                                Image(nsImage: nsImage)
                                                                    .resizable()
                                                                    .frame(width: 32, height: 32)
                                                            } else {
                                                                Image(systemName: "app.fill")
                                                                    .font(.system(size: 24))
                                                                    .foregroundStyle(.secondary)
                                                            }

                                                            VStack(alignment: .leading, spacing: 2) {
                                                                Text(rule.appName)
                                                                    .font(.subheadline.weight(.medium))

                                                                if let persona = appState.allPersonas.first(where: { $0.id == rule.personaId }) {
                                                                    HStack(spacing: 6) {
                                                                        Text("\u{2192}")
                                                                            .foregroundStyle(.secondary)
                                                                        if let emoji = persona.emoji {
                                                                            Text(emoji)
                                                                                .font(.system(size: 14))
                                                                        }
                                                                        Text(persona.name)
                                                                            .font(.caption)
                                                                            .foregroundStyle(.secondary)
                                                                    }
                                                                } else if rule.personaId == "none" {
                                                                    HStack(spacing: 6) {
                                                                        Text("\u{2192}")
                                                                            .foregroundStyle(.secondary)
                                                                        Text("No persona")
                                                                            .font(.caption)
                                                                            .foregroundStyle(.secondary)
                                                                    }
                                                                } else {
                                                                    Text("Unknown persona")
                                                                        .font(.caption)
                                                                        .foregroundStyle(.red)
                                                                }
                                                            }

                                                            Spacer()

                                                            HStack(spacing: 8) {
                                                                Button {
                                                                    // Find the app and show picker
                                                                    if let iconData = rule.appIcon, let icon = NSImage(data: iconData) {
                                                                        showingAppRulePicker = DetectedApp(
                                                                            bundleId: rule.appBundleId,
                                                                            name: rule.appName,
                                                                            icon: icon
                                                                        )
                                                                    }
                                                                } label: {
                                                                    Image(systemName: "pencil")
                                                                        .foregroundStyle(.secondary)
                                                                }
                                                                .buttonStyle(.plain)

                                                                Button {
                                                                    if appState.showAppRuleDeleteConfirmation {
                                                                        appRuleToDelete = rule
                                                                        showingDeleteAppRuleAlert = true
                                                                    } else {
                                                                        appState.deleteAppRule(id: rule.id)
                                                                    }
                                                                } label: {
                                                                    Image(systemName: "trash")
                                                                        .foregroundStyle(.red)
                                                                }
                                                                .buttonStyle(.plain)
                                                            }
                                                        }
                                                        .padding(.vertical, 4)
                                                        .padding(.horizontal, 12)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                                                        )
                                                    }
                                                }
                                            }
                                            .frame(maxHeight: 300)
                                        }
                                    }
                                }
                            }
                        }

                        // Default Persona
                        SettingsSectionCard("Default Persona") {
                            SettingsCardRow(showsDivider: false) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Choose the default persona used when no app-specific rule applies.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 8) {
                                            PersonaRadioRow(
                                                isSelected: appState.selectedPersonaId == nil,
                                                emoji: nil,
                                                name: "No persona",
                                                description: "Use raw transcription",
                                                isBuiltIn: false,
                                                onSelect: { appState.selectedPersonaId = nil }
                                            )

                                            ForEach(appState.allPersonas) { prompt in
                                                PersonaRadioRow(
                                                    isSelected: appState.selectedPersonaId == prompt.id,
                                                    emoji: prompt.emoji,
                                                    name: prompt.name,
                                                    description: prompt.instruction,
                                                    isBuiltIn: prompt.isBuiltIn,
                                                    onSelect: { appState.selectedPersonaId = prompt.id },
                                                    onEdit: prompt.isBuiltIn ? nil : { editingPrompt = prompt },
                                                    onDelete: prompt.isBuiltIn ? nil : {
                                                        if appState.showPersonaDeleteConfirmation {
                                                            personaToDelete = prompt
                                                            showingDeletePersonaAlert = true
                                                        } else {
                                                            appState.deletePersona(id: prompt.id)
                                                        }
                                                    }
                                                )
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 400)

                                    Divider()

                                    Button("Add custom persona") {
                                        showingCreatePersona = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showingCreatePersona) {
            CreatePersonaView(
                appState: appState,
                onDismiss: { showingCreatePersona = false }
            )
        }
        .sheet(item: $editingPrompt) { persona in
            EditPersonaView(
                persona: persona,
                appState: appState,
                onDismiss: { editingPrompt = nil }
            )
        }
        .sheet(isPresented: $showingAppSelector) {
            AppSelectorView(
                appState: appState,
                onSelectApp: { app in
                    showingAppSelector = false
                    showingAppRulePicker = app
                },
                onDismiss: { showingAppSelector = false }
            )
        }
        .sheet(item: $showingAppRulePicker) { app in
            AppRulePickerView(
                app: app,
                appState: appState,
                onDismiss: { showingAppRulePicker = nil }
            )
        }
        .sheet(isPresented: $showingDeletePersonaAlert, onDismiss: {
            personaToDelete = nil
        }) {
            NativeConfirmationDialog(
                title: "Delete \(personaToDelete?.name ?? "persona")?",
                message: "This action cannot be undone",
                confirmTitle: "Delete",
                isDestructive: true,
                dontAskAgainLabel: "Don't ask me again",
                dontAskAgain: $dontAskPersonaDeleteAgain,
                onCancel: {
                    showingDeletePersonaAlert = false
                    personaToDelete = nil
                },
                onConfirm: {
                    if let persona = personaToDelete {
                        if dontAskPersonaDeleteAgain {
                            appState.showPersonaDeleteConfirmation = false
                        }
                        appState.deletePersona(id: persona.id)
                    }
                    showingDeletePersonaAlert = false
                    personaToDelete = nil
                }
            )
        }
        .sheet(isPresented: $showingDeleteAppRuleAlert, onDismiss: {
            appRuleToDelete = nil
        }) {
            NativeConfirmationDialog(
                title: "Delete app rule?",
                message: "This action cannot be undone",
                confirmTitle: "Delete",
                isDestructive: true,
                dontAskAgainLabel: "Don't ask me again",
                dontAskAgain: $dontAskAppRuleDeleteAgain,
                onCancel: {
                    showingDeleteAppRuleAlert = false
                    appRuleToDelete = nil
                },
                onConfirm: {
                    if let rule = appRuleToDelete {
                        if dontAskAppRuleDeleteAgain {
                            appState.showAppRuleDeleteConfirmation = false
                        }
                        appState.deleteAppRule(id: rule.id)
                    }
                    showingDeleteAppRuleAlert = false
                    appRuleToDelete = nil
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FlowstayWillTerminate"))) { _ in
            // Dismiss all open modals before app quits
            showingCreatePersona = false
            editingPrompt = nil
            showingAppSelector = false
            showingAppRulePicker = nil
            showingDeletePersonaAlert = false
            showingDeleteAppRuleAlert = false
        }
        .alert("Disconnect from OpenRouter?", isPresented: $showingDisconnectAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task {
                    await oauthManager.disconnect()
                }
            }
        } message: {
            Text("You'll need to reconnect to use OpenRouter models.")
        }
        .onAppear {
            // Check connection status and load models if connected
            Task {
                await oauthManager.checkConnectionStatus()
                if oauthManager.isConnected {
                    await modelCache.refreshIfNeeded()
                }
                await refreshClaudeCodeStatus()
            }
        }
        .onChange(of: appState.selectedAIProviderId) { _, newValue in
            if newValue == AIProviderIdentifier.claudeCode.rawValue {
                Task {
                    await refreshClaudeCodeStatus()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRouterAuthenticationCompleted)) { _ in
            // Load models after successful authentication
            Task {
                await modelCache.refresh()
            }
        }
    }

    // MARK: - Privacy Info Helper

    private var providerPrivacyInfo: (icon: String, color: Color, text: String) {
        switch appState.selectedAIProviderId {
        case AIProviderIdentifier.openRouter.rawValue:
            ("cloud.fill", .blue, "Cloud processing via OpenRouter")
        case AIProviderIdentifier.claudeCode.rawValue:
            ("terminal", .blue, "Local Claude Code CLI (uses your Claude account session)")
        default:
            ("lock.shield.fill", .green, "Private on-device processing")
        }
    }

    // MARK: - Apple Intelligence Config View

    private var appleIntelligenceConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAppleIntelligenceAvailable {
                Label("Apple Intelligence is ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                if #available(macOS 26, *) {
                    Label("Enable Apple Intelligence in System Settings", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        SystemSettingsHelper.openAppleIntelligenceSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Label("Requires macOS 26 (Tahoe)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - OpenRouter Config View

    private var openRouterConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)

            if oauthManager.isConnected {
                HStack {
                    Label("Connected to OpenRouter", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        showingDisconnectAlert = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                OpenRouterModelPickerView(
                    appState: appState,
                    modelCache: modelCache
                )
            } else {
                Text("Connect your OpenRouter account to use cloud AI models")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    oauthManager.startAuthentication()
                } label: {
                    HStack {
                        if oauthManager.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting...")
                        } else {
                            Image(systemName: "link")
                            Text("Connect OpenRouter")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(oauthManager.isAuthenticating)

                if let error = oauthManager.authError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let openRouterURL = URL(string: "https://openrouter.ai") {
                    Link("Create free OpenRouter account", destination: openRouterURL)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Claude Code Config View

    private var claudeCodeConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)

            switch claudeCodeStatus {
            case .available:
                Label("Claude Code is installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("Flowstay calls your local `claude` CLI for personas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Claude model", selection: Binding(
                    get: { appState.selectedClaudeCodeModelId ?? "" },
                    set: { appState.selectedClaudeCodeModelId = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Auto").tag("")
                    Text("Haiku (Fast)").tag("haiku")
                    Text("Sonnet (Balanced)").tag("sonnet")
                    Text("Opus (Highest quality)").tag("opus")
                }
                .pickerStyle(.menu)

                Text("Haiku is usually fastest. Sonnet is a good default for quality and speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Behavior mode", selection: $appState.claudeCodeProcessingMode) {
                    Text("Strict rewrite").tag(ClaudeCodeProcessingMode.rewriteOnly.rawValue)
                    Text("Assistant (experimental)").tag(ClaudeCodeProcessingMode.assistant.rawValue)
                }
                .pickerStyle(.menu)

                if appState.claudeCodeProcessingMode == ClaudeCodeProcessingMode.assistant.rawValue {
                    Text("Assistant mode can answer requests directly instead of only rewriting dictated transcript text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Strict rewrite disables Claude tools, enforces structured output, and rejects likely assistant-style replies. This is still best-effort, not a guarantee.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("If Claude Code is signed in with Pro/Max, usage follows that subscription. If `ANTHROPIC_API_KEY` is set for Claude Code, usage is billed via API credits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .notConfigured(reason):
                Label(reason, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.flowstayBlue)
                Text("Install Claude Code, then run `claude login` in Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .unavailable(reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .rateLimited:
                Label("Claude Code is rate limited right now", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("Re-check") {
                    Task { await refreshClaudeCodeStatus() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let claudeCodeURL = URL(string: "https://docs.anthropic.com/en/docs/claude-code/quickstart") {
                    Link("Claude Code setup guide", destination: claudeCodeURL)
                        .font(.caption)
                }
            }
        }
    }

    private func refreshClaudeCodeStatus() async {
        claudeCodeStatus = await claudeCodeProvider.getStatus()
    }
}

// MARK: - App Selector Sheet

struct AppSelectorView: View {
    let appState: AppState
    let onSelectApp: (DetectedApp) -> Void
    let onDismiss: () -> Void
    @State private var runningApps: [DetectedApp] = []
    @State private var searchText = ""

    var filteredApps: [DetectedApp] {
        if searchText.isEmpty {
            return runningApps
        }
        return runningApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select an app")
                .font(.headline)

            TextField("Search apps...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredApps) { app in
                        Button {
                            onSelectApp(app)
                        } label: {
                            HStack(spacing: 12) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 32, height: 32)
                                } else {
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(.secondary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.subheadline)

                                    // Show if rule already exists
                                    if let rule = appState.appRules.first(where: { $0.appBundleId == app.bundleId }) {
                                        if let persona = appState.allPersonas.first(where: { $0.id == rule.personaId }) {
                                            Text("Currently: \(persona.name)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else if rule.personaId == "none" {
                                            Text("Currently: No persona")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("Currently: Unknown persona")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text("No rule set")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 400)

            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()
            }
        }
        .padding()
        .frame(width: 450)
        .onAppear {
            loadRunningApps()
        }
    }

    private func loadRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
            .filter { app in
                guard app.bundleIdentifier != nil,
                      app.localizedName != nil,
                      app.activationPolicy == .regular else { return false }

                // Exclude Flowstay itself
                return app.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .compactMap { app -> DetectedApp? in
                guard let bundleId = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }

                return DetectedApp(
                    bundleId: bundleId,
                    name: name,
                    icon: app.icon
                )
            }
            .sorted { $0.name < $1.name }

        runningApps = apps
    }
}

// MARK: - App Rule Picker Sheet

struct AppRulePickerView: View {
    let app: DetectedApp
    let appState: AppState
    let onDismiss: () -> Void
    @State private var selectedPersonaId: String

    init(app: DetectedApp, appState: AppState, onDismiss: @escaping () -> Void) {
        self.app = app
        self.appState = appState
        self.onDismiss = onDismiss

        // Initialize with existing rule or default
        if let existingRule = appState.appRules.first(where: { $0.appBundleId == app.bundleId }) {
            _selectedPersonaId = State(initialValue: existingRule.personaId)
        } else {
            if let def = appState.selectedPersonaId {
                _selectedPersonaId = State(initialValue: def)
            } else {
                _selectedPersonaId = State(initialValue: "none")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let iconData = AppDetectionService.shared.getIconData(for: app),
                   let nsImage = NSImage(data: iconData)
                {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Set persona for")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(app.name)
                        .font(.headline)
                }
            }

            Divider()

            Text("Choose a persona")
                .font(.subheadline.weight(.medium))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // No persona option
                    Button {
                        selectedPersonaId = "none"
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedPersonaId == "none" ? "circle.fill" : "circle")
                                .foregroundStyle(selectedPersonaId == "none" ? Color.accentColor : .secondary)
                                .font(.system(size: 16))

                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("No persona")
                                    .font(.subheadline)
                                Text("Use raw transcription")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(selectedPersonaId == "none" ? Color.accentColor.opacity(0.08) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    ForEach(appState.allPersonas) { persona in
                        Button {
                            selectedPersonaId = persona.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedPersonaId == persona.id ? "circle.fill" : "circle")
                                    .foregroundStyle(selectedPersonaId == persona.id ? Color.accentColor : .secondary)
                                    .font(.system(size: 16))

                                // Emoji as visual identifier
                                if let emoji = persona.emoji {
                                    Text(emoji)
                                        .font(.system(size: 24))
                                } else {
                                    Circle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 24, height: 24)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(persona.name)
                                            .font(.subheadline)
                                        if persona.isBuiltIn {
                                            Text("Built-in")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(persona.instruction)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .background(selectedPersonaId == persona.id ? Color.accentColor.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    let iconData = AppDetectionService.shared.getIconData(for: app)
                    let rule = AppRule(
                        appBundleId: app.bundleId,
                        appName: app.name,
                        appIcon: iconData,
                        personaId: selectedPersonaId
                    )
                    appState.addAppRule(rule)
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        Text("⌘↩")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Permissions Tab

struct PermissionsTab: View {
    @ObservedObject var permissionManager: PermissionManager
    @State private var notificationPermissionGranted = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Permissions")
                        .font(.albertSans(28, weight: .bold))
                    Text("Manage app permissions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSectionCard("Required Permissions") {
                        SettingsCardRow(showsDivider: false) {
                            SettingsControlRow(
                                title: "Microphone",
                                systemImage: "mic"
                            ) {
                                if permissionManager.hasMicrophonePermission {
                                    Label("Granted", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                } else {
                                    Button("Grant") {
                                        Task {
                                            await permissionManager.requestMicrophonePermission()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    SettingsSectionCard("Optional Permissions") {
                        SettingsCardRow {
                            SettingsControlRow(
                                title: "Accessibility",
                                systemImage: "accessibility",
                                description: "Required for auto-paste functionality"
                            ) {
                                if permissionManager.hasAccessibilityPermission {
                                    Label("Granted", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                } else {
                                    Button("Grant") {
                                        Task {
                                            await permissionManager.requestAccessibilityPermission()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }

                        SettingsCardRow(showsDivider: false) {
                            SettingsControlRow(
                                title: "Notifications",
                                systemImage: "bell.badge",
                                description: "Get notified when transcription completes or models download"
                            ) {
                                if notificationPermissionGranted {
                                    Label("Granted", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                } else {
                                    Button("Grant") {
                                        Task {
                                            let granted = await NotificationManager.shared.requestPermissions()
                                            await MainActor.run {
                                                notificationPermissionGranted = granted
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    SettingsSectionCard("Status") {
                        SettingsCardRow(showsDivider: false) {
                            if permissionManager.criticalPermissionsGranted {
                                Label {
                                    Text("All required permissions granted")
                                        .font(.caption)
                                } icon: {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                }
                            } else {
                                Label {
                                    Text("Grant required permissions to enable transcription")
                                        .font(.caption)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    if recoverySnapshot.isDegradedLaunch {
                        SettingsSectionCard("Startup Help") {
                            SettingsCardRow(showsDivider: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Flowstay had trouble starting on its last launch.", systemImage: "wrench.and.screwdriver.fill")
                                        .foregroundStyle(.orange)

                                    Text("Flowstay opened in a safer mode for this launch, so some features may be temporarily limited until you review the suggested fixes.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Button("Fix Startup Issues") {
                                        MenuBarHelper.openRecovery()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            // Check initial notification permission status
            Task {
                let status = await NotificationManager.shared.checkPermissionStatus()
                await MainActor.run {
                    notificationPermissionGranted = status
                }
            }
        }
    }

    private var recoverySnapshot: StartupRecoverySnapshot {
        StartupRecoveryManager.shared.snapshot
    }
}

// MARK: - OpenRouter Model Picker

struct OpenRouterModelPickerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelCache: OpenRouterModelCache
    @State private var showingModelBrowser = false

    var body: some View {
        if modelCache.isLoading {
            loadingView
        } else if !modelCache.models.isEmpty {
            modelPickerContent
        } else {
            emptyStateView
        }
    }

    private var loadingView: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Loading models...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelPickerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Selected model button - opens browser
            Button {
                showingModelBrowser = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let selectedId = appState.selectedOpenRouterModelId,
                           let model = modelCache.model(for: selectedId)
                        {
                            HStack(spacing: 6) {
                                Text(model.name)
                                    .font(.subheadline.weight(.medium))
                                if model.isFree {
                                    Text("Free")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.15))
                                        .clipShape(Capsule())
                                } else if let price = model.pricePerMillionTokens {
                                    Text(price)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        } else {
                            Text("Select a model...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // Help text
            Text("\(modelCache.freeModels.count) free models • \(modelCache.paidModels.count) paid models available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingModelBrowser) {
            OpenRouterModelBrowserView(
                appState: appState,
                modelCache: modelCache,
                onDismiss: { showingModelBrowser = false }
            )
        }
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = modelCache.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Refresh Models") {
                Task {
                    await modelCache.refresh()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Model Browser Sheet

enum ModelPriceTier: String, CaseIterable {
    case all = "All"
    case free = "Free"
    case budget = "Budget" // < $0.50/M
    case standard = "Standard" // $0.50 - $5/M
    case premium = "Premium" // > $5/M

    var label: String {
        rawValue
    }
}

enum ModelSortOption: String, CaseIterable {
    case name = "Name"
    case priceLow = "Price: Low to High"
    case priceHigh = "Price: High to Low"
    case contextLength = "Context Length"

    var label: String {
        rawValue
    }
}

struct OpenRouterModelBrowserView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelCache: OpenRouterModelCache
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedProvider: String = "All"
    @State private var selectedPriceTier: ModelPriceTier = .all
    @State private var sortOption: ModelSortOption = .name

    private var providers: [String] {
        var providerSet = Set<String>()
        for model in modelCache.models where model.isTextModel {
            providerSet.insert(model.providerName)
        }
        return ["All"] + providerSet.sorted()
    }

    private var filteredModels: [OpenRouterModel] {
        var models = modelCache.models.filter(\.isTextModel)

        // Search filter
        if !searchText.isEmpty {
            models = models.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                    $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Provider filter
        if selectedProvider != "All" {
            models = models.filter { $0.providerName == selectedProvider }
        }

        // Price tier filter
        models = filterByPriceTier(models)

        // Sort
        models = sortModels(models)

        return models
    }

    private func filterByPriceTier(_ models: [OpenRouterModel]) -> [OpenRouterModel] {
        switch selectedPriceTier {
        case .all:
            models
        case .free:
            models.filter(\.isFree)
        case .budget:
            models.filter { !$0.isFree && getPriceValue($0) < 0.5 }
        case .standard:
            models.filter {
                let price = getPriceValue($0)
                return !$0.isFree && price >= 0.5 && price <= 5.0
            }
        case .premium:
            models.filter { !$0.isFree && getPriceValue($0) > 5.0 }
        }
    }

    private func getPriceValue(_ model: OpenRouterModel) -> Double {
        guard let promptPrice = Double(model.pricing.prompt),
              let completionPrice = Double(model.pricing.completion)
        else {
            return 0
        }
        return (promptPrice + completionPrice) / 2.0 * 1_000_000
    }

    private func sortModels(_ models: [OpenRouterModel]) -> [OpenRouterModel] {
        switch sortOption {
        case .name:
            models.sorted { $0.name < $1.name }
        case .priceLow:
            models.sorted { getPriceValue($0) < getPriceValue($1) }
        case .priceHigh:
            models.sorted { getPriceValue($0) > getPriceValue($1) }
        case .contextLength:
            models.sorted { $0.contextLength > $1.contextLength }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Choose a Model")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Search and filters
            VStack(spacing: 12) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search models...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Filter row
                HStack(spacing: 12) {
                    // Price tier picker
                    Picker("Price", selection: $selectedPriceTier) {
                        ForEach(ModelPriceTier.allCases, id: \.self) { tier in
                            Text(tier.label).tag(tier)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)

                    // Provider picker
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(providers, id: \.self) { provider in
                            Text(provider).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)

                    Spacer()

                    // Sort picker
                    Picker("Sort", selection: $sortOption) {
                        ForEach(ModelSortOption.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                // Results count
                HStack {
                    Text("\(filteredModels.count) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider()

            // Model list
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredModels) { model in
                        ModelRowView(
                            model: model,
                            isSelected: appState.selectedOpenRouterModelId == model.id,
                            onSelect: {
                                appState.selectedOpenRouterModelId = model.id
                                onDismiss()
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 600, height: 500)
    }
}

struct ModelRowView: View {
    let model: OpenRouterModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 18))

                // Model info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        if model.isFree {
                            Text("Free")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        Text(model.providerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("•")
                            .foregroundStyle(.secondary)

                        Text(model.contextLengthFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !model.isFree, let price = model.pricePerMillionTokens {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(price)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
