import AppKit

/// Protocol for controlling the menu bar popover and windows
/// Implemented by FlowstayAppDelegate
public protocol MenuBarPopoverController: AnyObject {
    func showPopover()
    func closePopover()
    func openSettingsWindow()
    func openOnboardingWindow()
    func openRecoveryWindow()
    func toggleTranscriptionFromMenuBar()
}

/// Helper to programmatically control the menu bar popover and windows
public class MenuBarHelper {
    /// Delegate that controls the popover and windows (set by FlowstayAppDelegate)
    public nonisolated(unsafe) weak static var delegate: (any MenuBarPopoverController)?

    private static func performOnMain(_ action: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    /// Programmatically open the menu bar popover
    public static func openMenuBar() {
        performOnMain {
            if let delegate {
                print("[MenuBarHelper] Opening menu bar via delegate")
                delegate.showPopover()
            } else {
                print("[MenuBarHelper] ⚠️ No delegate set, cannot open menu bar")
            }
        }
    }

    /// Programmatically close the menu bar popover
    public static func closeMenuBar() {
        performOnMain {
            delegate?.closePopover()
        }
    }

    /// Open the settings window
    public static func openSettings() {
        performOnMain {
            delegate?.openSettingsWindow()
        }
    }

    /// Open the onboarding window
    public static func openOnboarding() {
        performOnMain {
            delegate?.openOnboardingWindow()
        }
    }

    /// Open the startup recovery window
    public static func openRecovery() {
        performOnMain {
            delegate?.openRecoveryWindow()
        }
    }

    /// Toggle transcription using the app delegate policy path.
    public static func toggleTranscription() {
        performOnMain {
            delegate?.toggleTranscriptionFromMenuBar()
        }
    }
}
