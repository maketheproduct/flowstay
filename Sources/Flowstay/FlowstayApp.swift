import AppKit
import AVFoundation
import Combine
import FlowstayCore
import FlowstayPermissions
import FlowstayUI
import KeyboardShortcuts
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

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("[AppDelegate] applicationDidFinishLaunching - initializing app")

        // Register custom fonts
        FontLoader.registerFonts()

        // Initialize all state objects (previously in SwiftUI App.init)
        initializeState()

        // Setup UI
        setupStatusItem()
        setupRecordingObserver()
        setupOverlayObserver()
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
                guard let appState = self.appState,
                      let permissionManager = self.permissionManager,
                      let personasEngine = self.personasEngine
                else {
                    self.logger.error("[AppDelegate] Missing required state objects in transcription callback")
                    return
                }

                self.logger.info("[AppDelegate] Transcription complete (\(finalText.count) chars, duration: \(String(format: "%.1f", duration))s)")

                // Use app captured at recording start to keep routing stable even if focus changed.
                let detectedApp = self.recordingTargetApp ?? AppDetectionService.shared.currentApp

                // Process with personas if enabled
                var processedText = finalText
                var usedPersonaId: String? = nil

                if appState.personasEnabled {
                    // Check if we have an app-specific rule
                    var selectedPersonaId = appState.selectedPersonaId // Default

                    if appState.useSmartAppDetection,
                       let app = detectedApp,
                       let appPersonaId = appState.getPersonaForApp(app.bundleId)
                    {
                        selectedPersonaId = appPersonaId
                        self.logger.info("[AppDelegate] Using app-specific persona for \(app.name): \(appPersonaId)")
                    } else {
                        self.logger.info("[AppDelegate] Using default persona: \(selectedPersonaId ?? "none")")
                    }

                    // Treat sentinel "none" as explicit skip
                    if selectedPersonaId == "none" {
                        self.logger.info("[AppDelegate] Skipping persona per app rule")
                    }

                    // Get the instruction for the currently selected persona
                    if let personaId = selectedPersonaId,
                       let persona = appState.allPersonas.first(where: { $0.id == personaId })
                    {
                        self.logger.info("[AppDelegate] Processing with persona: \(persona.name)")

                        // Start a timer to notify user if processing takes too long (5 seconds)
                        let processingTimer = Task {
                            try? await Task.sleep(for: .seconds(5))
                            // Only send notification if not cancelled (processing still ongoing)
                            guard !Task.isCancelled else { return }
                            NotificationManager.shared.sendNotification(
                                title: "Processing transcription...",
                                body: "AI is still working on your text",
                                identifier: "processing-delay"
                            )
                        }

                        processedText = await personasEngine.processTranscription(
                            finalText,
                            instruction: persona.instruction,
                            appState: appState
                        )

                        // Cancel the timer (processing completed)
                        processingTimer.cancel()

                        // Capture the persona ID that was used
                        usedPersonaId = personaId

                        self.logger.info("[AppDelegate] Personas processing complete (\(processedText.count) chars)")
                    }
                }

                // Clear snapshot once this transcription is fully processed.
                self.recordingTargetApp = nil

                // Add to history with both original and processed text
                appState.recentTranscripts.insert(
                    TranscriptItem(
                        text: processedText,
                        originalText: usedPersonaId != nil ? finalText : nil,
                        personaId: usedPersonaId,
                        timestamp: Date(),
                        duration: duration
                    ),
                    at: 0
                )

                // Save to persistent history (markdown files)
                let record = TranscriptionRecord(
                    duration: duration,
                    rawText: finalText,
                    processedText: processedText,
                    personaId: usedPersonaId,
                    personaName: usedPersonaId != nil ? appState.allPersonas.first(where: { $0.id == usedPersonaId })?.name : nil,
                    appBundleId: detectedApp?.bundleId,
                    appName: detectedApp?.name
                )
                await TranscriptionHistoryStore.shared.addIgnoringErrors(record)

                // Auto-paste if enabled and we have accessibility permission
                if appState.autoPasteEnabled, permissionManager.hasAccessibilityPermission {
                    self.logger.info("[AppDelegate] Auto-pasting transcript...")
                    await TextPaster.pasteText(processedText)
                } else if appState.autoPasteEnabled {
                    self.logger.info("[AppDelegate] Auto-paste enabled but accessibility permission not granted")
                }

                // Play completion sound AFTER paste (or if no paste, after processing)
                if appState.soundFeedbackEnabled {
                    SoundManager.shared.playTranscriptionComplete()
                }
            }
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
                if isRecording {
                    AppDetectionService.shared.detectFrontmostApp()
                    self?.recordingTargetApp = AppDetectionService.shared.currentApp
                    if let app = self?.recordingTargetApp {
                        self?.logger.info("[AppDelegate] Captured recording target app: \(app.name) (\(app.bundleId))")
                    } else {
                        self?.logger.info("[AppDelegate] Recording started with no detected target app")
                    }
                }
                self?.updateStatusIcon(isRecording: isRecording)
                self?.applyOverlayVisibility()
            }
            .store(in: &cancellables)
    }

    private func setupOverlayObserver() {
        applyOverlayVisibility()

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyOverlayVisibility()
            }
            .store(in: &cancellables)
    }

    private func applyOverlayVisibility() {
        let showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        if showOverlay, engineCoordinator.isRecording {
            overlayWindowController?.show()
        } else {
            overlayWindowController?.hide()
        }
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
