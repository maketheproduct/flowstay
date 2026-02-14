import AppKit
import SwiftUI

/// Helper to load and provide menu bar icon from assets
public enum MenuBarIcon {
    /// Load the Flowstay logo as a menu bar icon
    public static func loadIcon(isRecording: Bool) -> NSImage? {
        // Try multiple approaches to find the bundle
        var bundle: Bundle?

        // Approach 1: Look for resource bundle by name
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = (resourcePath as NSString).appendingPathComponent("Flowstay_FlowstayUI.bundle")
            bundle = Bundle(path: bundlePath)
        }

        // Approach 2: Search all bundles
        if bundle == nil {
            bundle = Bundle.allBundles.first(where: { $0.bundlePath.contains("FlowstayUI") })
        }

        guard let resourceBundle = bundle else {
            return nil
        }

        // Use PNG files - macOS menu bar requires bitmap template images
        let logoName = isRecording ? "menubar-logo-recording" : "menubar-logo"

        // Try to load PNG from bundle root (SPM flattens .process() resources)
        guard let pngURL = resourceBundle.url(forResource: logoName, withExtension: "png") else {
            return nil
        }

        guard let image = NSImage(contentsOf: pngURL) else {
            return nil
        }

        // Set the image as a template to work with menu bar theming (light/dark mode)
        image.isTemplate = true

        return image
    }

    /// Get system fallback icon name
    public static func systemIconName(isRecording: Bool) -> String {
        isRecording ? "waveform.circle.fill" : "waveform.circle"
    }
}
