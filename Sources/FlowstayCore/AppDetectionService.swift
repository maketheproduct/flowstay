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

    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    private init() {
        // Subscribe to app activation notifications
        // Use block-based API with DispatchQueue.main to avoid @MainActor/@objc crash
        // when the notification is delivered from a non-main thread (macOS 26+).
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.detectFrontmostApp()
            }
        }

        // Initial detection
        detectFrontmostApp()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
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

    /// Apps the user can make rules for: everything installed in the usual app folders plus
    /// anything running from elsewhere. Sorted by name, one entry per bundle ID, excluding Flowstay.
    public func availableApps() async -> [DetectedApp] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> DetectedApp? in
                guard let bundleId = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return DetectedApp(bundleId: bundleId, name: name, icon: app.icon)
            }
        let installed = await Task.detached(priority: .userInitiated) { Self.installedApps() }.value
        return Self.mergeApps(installed + running, excluding: Bundle.main.bundleIdentifier)
    }

    nonisolated static func mergeApps(_ apps: [DetectedApp], excluding excludedBundleId: String?) -> [DetectedApp] {
        var seen = Set<String>()
        return apps
            .filter { $0.bundleId != excludedBundleId && seen.insert($0.bundleId).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func installedApps() -> [DetectedApp] {
        let fileManager = FileManager.default
        let folders = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        return folders.flatMap { folder -> [DetectedApp] in
            let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return contents
                .filter { $0.pathExtension == "app" }
                .compactMap { url in
                    guard let bundleId = Bundle(url: url)?.bundleIdentifier else { return nil }
                    let name = (fileManager.displayName(atPath: url.path) as NSString).deletingPathExtension
                    return DetectedApp(bundleId: bundleId, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
                }
        }
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
}
