import AppKit
import FlowstayCore
import KeyboardShortcuts

@MainActor
final class OnboardingHotkeyMonitor {
    var onToggleShortcut: (() -> Void)?
    var onHoldPressedChanged: ((Bool) -> Void)?

    private var toggleShortcutListenerTask: Task<Void, Never>?
    private var holdShortcutListenerTask: Task<Void, Never>?
    private var functionKeyGlobalMonitor: Any?
    private var functionKeyLocalMonitor: Any?

    private var holdInputSource: HoldToTalkInputSource = .functionKey
    private var holdShortcut: KeyboardShortcuts.Shortcut?
    private var isHoldPressed = false
    private var isStarted = false

    func updateBindings(
        toggleShortcut _: KeyboardShortcuts.Shortcut,
        holdInputSource: HoldToTalkInputSource,
        holdShortcut: KeyboardShortcuts.Shortcut?
    ) {
        self.holdInputSource = holdInputSource
        self.holdShortcut = holdShortcut

        if holdInputSource == .alternativeShortcut,
           holdShortcut == nil,
           isHoldPressed
        {
            isHoldPressed = false
            onHoldPressedChanged?(false)
        }

        guard isStarted else { return }
        configureHoldMonitoring()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        startToggleListenerIfNeeded()
        configureHoldMonitoring()
    }

    func stop() {
        isStarted = false
        toggleShortcutListenerTask?.cancel()
        toggleShortcutListenerTask = nil
        holdShortcutListenerTask?.cancel()
        holdShortcutListenerTask = nil
        removeFunctionKeyMonitors()

        if isHoldPressed {
            isHoldPressed = false
            onHoldPressedChanged?(false)
        }
    }

    private func startToggleListenerIfNeeded() {
        guard toggleShortcutListenerTask == nil else { return }

        toggleShortcutListenerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in KeyboardShortcuts.events(for: .toggleDictation) {
                if Task.isCancelled {
                    break
                }
                guard isStarted else { continue }
                if case .keyDown = event {
                    onToggleShortcut?()
                }
            }
        }
    }

    private func configureHoldMonitoring() {
        holdShortcutListenerTask?.cancel()
        holdShortcutListenerTask = nil
        removeFunctionKeyMonitors()

        switch holdInputSource {
        case .functionKey:
            installFunctionKeyMonitors()
        case .alternativeShortcut:
            guard holdShortcut != nil else {
                if isHoldPressed {
                    isHoldPressed = false
                    onHoldPressedChanged?(false)
                }
                return
            }
            startHoldShortcutListenerIfNeeded()
        }
    }

    private func startHoldShortcutListenerIfNeeded() {
        guard holdShortcutListenerTask == nil else { return }
        holdShortcutListenerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in KeyboardShortcuts.events(for: .holdToTalk) {
                if Task.isCancelled {
                    break
                }
                guard isStarted, holdInputSource == .alternativeShortcut else { continue }

                switch event {
                case .keyDown:
                    guard !isHoldPressed else { continue }
                    isHoldPressed = true
                    onHoldPressedChanged?(true)
                case .keyUp:
                    guard isHoldPressed else { continue }
                    isHoldPressed = false
                    onHoldPressedChanged?(false)
                }
            }
        }
    }

    private func installFunctionKeyMonitors() {
        functionKeyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFunctionKeyFlagsChanged(event)
            }
        }

        functionKeyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFunctionKeyFlagsChanged(event)
            }
            return event
        }
    }

    private func removeFunctionKeyMonitors() {
        if let functionKeyGlobalMonitor {
            NSEvent.removeMonitor(functionKeyGlobalMonitor)
            self.functionKeyGlobalMonitor = nil
        }
        if let functionKeyLocalMonitor {
            NSEvent.removeMonitor(functionKeyLocalMonitor)
            self.functionKeyLocalMonitor = nil
        }
    }

    private func handleFunctionKeyFlagsChanged(_ event: NSEvent) {
        guard holdInputSource == .functionKey else { return }

        let functionPressed = event.modifierFlags.contains(.function)
        guard functionPressed != isHoldPressed else { return }

        isHoldPressed = functionPressed
        onHoldPressedChanged?(functionPressed)
    }
}
