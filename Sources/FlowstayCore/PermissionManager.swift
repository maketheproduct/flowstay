import Accessibility
import AppKit
import AVFoundation
import os
import SwiftUI

// MARK: - Permission Manager

/// Manages microphone and accessibility permissions for the app
public class PermissionManager: ObservableObject {
    @Published public var microphoneStatus: PermissionStatus = .notDetermined

    @Published public var accessibilityStatus: PermissionStatus = .notDetermined

    private var notificationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.flowstay.core", category: "PermissionManager")

    public init() {
        // Don't check permissions on init to avoid crashes
        // Permissions will be checked when needed

        // Set up listener for when app becomes active (user returns from System Preferences)
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Refresh permission status when app becomes active
                await self?.checkAccessibilityPermissionOnly()
            }
        }
    }

    deinit {
        // Use synchronous cleanup for deinit - we can't await in deinit
        // The observer will be cleaned up when the object is deallocated
        // Note: NotificationCenter observers using blocks are automatically removed
        // when the observer object is deallocated, so this is safe
    }

    /// Clean up resources when done
    public func cleanup() {
        // Clean up notification observer
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
            notificationObserver = nil
        }
        logger.debug("[PermissionManager] Cleaned up resources")
    }

    public var hasMicrophonePermission: Bool {
        microphoneStatus == .authorized
    }

    public var hasAccessibilityPermission: Bool {
        accessibilityStatus == .authorized
    }

    public var criticalPermissionsGranted: Bool {
        microphoneStatus == .authorized
    }

    public var allPermissionsGranted: Bool {
        microphoneStatus == .authorized &&
            accessibilityStatus == .authorized
    }

    /// Add async methods for requesting permissions
    public func requestMicrophonePermission() async {
        logger.info("[PermissionManager] Requesting microphone permission...")

        // Check current status first to avoid unnecessary requests
        let currentStatus = AVAudioApplication.shared.recordPermission

        if currentStatus == .granted {
            microphoneStatus = .authorized
            return
        } else if currentStatus == .denied {
            microphoneStatus = .denied
            return
        }

        // Request actual microphone permission only if undetermined
        let granted = await Task.detached {
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }.value

        // Update status
        microphoneStatus = granted ? .authorized : .denied
        logger.info("[PermissionManager] Microphone request completed: \(granted)")
    }

    public func requestAccessibilityPermission() async {
        logger.info("[PermissionManager] Requesting accessibility permission with proper registration...")

        // First check current status
        let currentAccess = AXIsProcessTrusted()
        if currentAccess {
            logger.info("[PermissionManager] Accessibility already granted")
            accessibilityStatus = .authorized
            return
        }

        // Force the app to appear in System Preferences by actually attempting to use accessibility
        logger.debug("[PermissionManager] Triggering accessibility system registration...")
        triggerAccessibilityRegistration()

        // Use the proper modern approach to request permissions
        // Use hardcoded string to avoid concurrency issues
        let options: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
        let optionsDict = options as CFDictionary
        let hasAccess = AXIsProcessTrustedWithOptions(optionsDict)

        if hasAccess {
            logger.info("[PermissionManager] Accessibility permission granted immediately")
            accessibilityStatus = .authorized
        } else {
            logger.info("[PermissionManager] Accessibility permission dialog shown to user")
            accessibilityStatus = .notDetermined // User needs to approve in the dialog
            // Note: The system dialog is now showing - don't also open System Preferences
        }
    }

    /// Forces the app to register with the accessibility system by attempting to use accessibility features
    private func triggerAccessibilityRegistration() {
        logger.debug("[PermissionManager] Attempting accessibility operation to trigger registration...")

        // Multiple attempts to ensure registration with the accessibility system

        // 1. Create system-wide accessibility element
        let systemElement = AXUIElementCreateSystemWide()

        // 2. Try to get focused application - this will cause macOS to register our app
        var focusedApp: AnyObject?
        let result1 = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        logger.debug("[PermissionManager] Focus probe result: \(result1 == .success ? "success" : "failed")")

        // 3. Try to create an element for the current process and access its properties
        let processElement = AXUIElementCreateApplication(getpid())
        var processTitle: AnyObject?
        let result2 = AXUIElementCopyAttributeValue(processElement, kAXTitleAttribute as CFString, &processTitle)
        logger.debug("[PermissionManager] Process probe result: \(result2 == .success ? "success" : "failed")")

        // 4. Try to get role of our own process
        var processRole: AnyObject?
        let result3 = AXUIElementCopyAttributeValue(processElement, kAXRoleAttribute as CFString, &processRole)
        logger.debug("[PermissionManager] Role probe result: \(result3 == .success ? "success" : "failed")")

        // 5. Try to access window information (another trigger for registration)
        var windowList: AnyObject?
        let result4 = AXUIElementCopyAttributeValue(processElement, kAXWindowsAttribute as CFString, &windowList)
        logger.debug("[PermissionManager] Windows probe result: \(result4 == .success ? "success" : "failed")")

        logger.debug("[PermissionManager] Accessibility registration attempts completed")
    }

    public func openAccessibilitySettings() {
        logger.info("[PermissionManager] Opening System Preferences > Accessibility...")

        // For modern macOS, try multiple URL approaches
        let modernUrls = [
            // Direct accessibility settings (most modern)
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Assistive",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            // Settings app approach (macOS 13+)
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
            // Alternative accessibility paths
            "x-apple.systempreferences:com.apple.preference.assistivetechs",
            "x-apple.systempreferences:com.apple.preference.universalaccess?Assistive",
        ]

        // Try modern URLs first
        for urlString in modernUrls {
            if let url = URL(string: urlString) {
                let success = NSWorkspace.shared.open(url)
                if success {
                    logger.debug("[PermissionManager] Successfully opened accessibility settings")

                    // Set up a timer to refresh permission status when user likely returns
                    schedulePermissionRefresh()
                    return
                }
            }
        }

        // Legacy fallback URLs
        let legacyUrls = [
            "x-apple.systempreferences:com.apple.preference.security",
            "x-apple.systempreferences:com.apple.preferences.security",
        ]

        for urlString in legacyUrls {
            if let url = URL(string: urlString) {
                let success = NSWorkspace.shared.open(url)
                if success {
                    logger.debug("[PermissionManager] Opened settings with fallback URL")
                    schedulePermissionRefresh()
                    return
                }
            }
        }

        logger.error("[PermissionManager] Failed to open System Preferences")
    }

    /// Schedules periodic permission status checks after opening System Preferences
    private func schedulePermissionRefresh() {
        logger.debug("[PermissionManager] Scheduling permission status refresh...")

        // Use a simple approach: schedule a task that checks permissions periodically
        Task { @MainActor in
            let startTime = Date()
            let timeout: TimeInterval = 30 // 30 seconds

            while Date().timeIntervalSince(startTime) < timeout {
                let previousStatus = self.accessibilityStatus
                await self.checkAccessibilityPermissionOnly()

                if self.accessibilityStatus == .authorized, previousStatus != .authorized {
                    logger.info("[PermissionManager] Detected accessibility permission granted!")
                    break
                }

                // Wait 2 seconds before checking again
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }

            logger.debug("[PermissionManager] Stopped checking for permission changes")
        }
    }

    public func checkPermissions() async {
        logger.info("[PermissionManager] Checking permissions...")

        // Check microphone - use the same API as requestMicrophonePermission
        let audioStatus = AVAudioApplication.shared.recordPermission
        microphoneStatus = switch audioStatus {
        case .granted: .authorized
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .notDetermined
        }

        // Check accessibility - safe check without prompt
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .authorized : .notDetermined

        let currentMicrophoneStatus = microphoneStatus
        let currentAccessibilityStatus = accessibilityStatus
        logger.info("[PermissionManager] Permission check completed: Mic=\(String(describing: currentMicrophoneStatus)), Accessibility=\(String(describing: currentAccessibilityStatus))")
    }

    /// Check only accessibility permission (for periodic refresh)
    public func checkAccessibilityPermissionOnly() async {
        let previousStatus = accessibilityStatus
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .authorized : .notDetermined

        if accessibilityStatus != previousStatus {
            let currentAccessibilityStatus = accessibilityStatus
            logger.info("[PermissionManager] Accessibility permission status changed: \(String(describing: previousStatus)) -> \(String(describing: currentAccessibilityStatus))")
        }
    }
}
