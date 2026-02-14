import AppKit
import Foundation
import os

/// Information about a detected application
public nonisolated struct DetectedApp: Identifiable, Sendable {
    public var id: String {
        bundleId
    }

    public let bundleId: String
    public let name: String
    public let icon: NSImage?

    public init(bundleId: String, name: String, icon: NSImage?) {
        self.bundleId = bundleId
        self.name = name
        self.icon = icon
    }
}

/// Singleton service for detecting the frontmost application
@MainActor
public class AppDetectionService: ObservableObject {
    public static let shared = AppDetectionService()

    @Published public private(set) var currentApp: DetectedApp?
    private let logger = Logger(subsystem: "com.flowstay.core", category: "AppDetection")

    private init() {
        // Subscribe to app activation notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Initial detection
        detectFrontmostApp()
    }

    /// Detect the currently frontmost application
    public func detectFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            logger.warning("[AppDetection] No frontmost application detected")
            currentApp = nil
            return
        }

        // Don't detect Flowstay itself
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            logger.info("[AppDetection] Flowstay is frontmost, ignoring")
            currentApp = nil
            return
        }

        guard let bundleId = app.bundleIdentifier else {
            logger.warning("[AppDetection] Frontmost app has no bundle identifier")
            currentApp = nil
            return
        }

        let name = app.localizedName ?? "Unknown App"
        let icon = app.icon

        currentApp = DetectedApp(bundleId: bundleId, name: name, icon: icon)
        logger.info("[AppDetection] Detected: \(name) (\(bundleId))")
    }

    /// Get icon data (PNG) for storage
    public func getIconData(for app: DetectedApp) -> Data? {
        guard let icon = app.icon else { return nil }

        // Resize to 128x128 for consistent storage using modern API
        let size = NSSize(width: 128, height: 128)
        let resizedIcon = NSImage(size: size, flipped: false) { rect in
            icon.draw(
                in: rect,
                from: NSRect(origin: .zero, size: icon.size),
                operation: .copy,
                fraction: 1.0
            )
            return true
        }

        // Convert to PNG data
        guard let tiffData = resizedIcon.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmapRep.representation(using: .png, properties: [:])
    }

    @objc private func appDidActivate(_: Notification) {
        detectFrontmostApp()
    }
}
