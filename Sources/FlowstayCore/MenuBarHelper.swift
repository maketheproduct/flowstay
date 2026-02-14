import AppKit

/// Protocol for controlling the menu bar popover and windows
/// Implemented by FlowstayAppDelegate
@MainActor
public protocol MenuBarPopoverController: AnyObject {
    func showPopover()
    func closePopover()
    func openSettingsWindow()
    func openOnboardingWindow()
}

/// Helper to programmatically control the menu bar popover and windows
@MainActor
public class MenuBarHelper {
    /// Delegate that controls the popover and windows (set by FlowstayAppDelegate)
    public weak static var delegate: (any MenuBarPopoverController)?

    /// Programmatically open the menu bar popover
    public static func openMenuBar() {
        if let delegate {
            print("[MenuBarHelper] Opening menu bar via delegate")
            delegate.showPopover()
        } else {
            print("[MenuBarHelper] ⚠️ No delegate set, cannot open menu bar")
        }
    }

    /// Programmatically close the menu bar popover
    public static func closeMenuBar() {
        delegate?.closePopover()
    }

    /// Open the settings window
    public static func openSettings() {
        delegate?.openSettingsWindow()
    }

    /// Open the onboarding window
    public static func openOnboarding() {
        delegate?.openOnboardingWindow()
    }
}
