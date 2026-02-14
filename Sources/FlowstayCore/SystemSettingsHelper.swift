import AppKit
import Foundation

public enum SystemSettingsHelper {
    /// Open Apple Intelligence & Siri settings
    @available(macOS 26, *)
    public static func openAppleIntelligenceSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.intelligence") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Open Software Update settings
    public static func openSoftwareUpdate() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
