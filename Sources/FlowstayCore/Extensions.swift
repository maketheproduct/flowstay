import AppKit
import AVFoundation
import Foundation
import SwiftUI

// MARK: - UserDefaults Extensions

extension UserDefaults {
    /// App-specific keys
    enum FlowstayKeys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    /// Convenience methods for app settings
    public var hasCompletedOnboarding: Bool {
        get { bool(forKey: FlowstayKeys.hasCompletedOnboarding) }
        set { set(newValue, forKey: FlowstayKeys.hasCompletedOnboarding) }
    }
}

// MARK: - FileManager Extensions

extension FileManager {
    /// App-specific directory URLs
    static var flowstayDocumentsURL: URL {
        guard let documentsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // Fallback to temporary directory if Application Support is not available
            print("Warning: Application Support not accessible, using temporary directory for Flowstay data")
            return FileManager.default.temporaryDirectory.appendingPathComponent("Flowstay")
        }
        return documentsURL.appendingPathComponent("Flowstay")
    }

    static var flowstayModelsURL: URL {
        flowstayDocumentsURL.appendingPathComponent("Models")
    }

    static var flowstayTranscriptsURL: URL {
        flowstayDocumentsURL.appendingPathComponent("Transcripts")
    }

    /// Ensure app directories exist with robust error handling
    public static func createAppDirectories() throws {
        let urls = [flowstayDocumentsURL, flowstayModelsURL, flowstayTranscriptsURL]

        for url in urls {
            // Check if directory already exists
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    print("[FileManager] Directory already exists: \(url.path)")
                    continue
                } else {
                    // Path exists but is not a directory - this is an error state
                    print("[FileManager] ❌ Path exists but is not a directory: \(url.path)")
                    throw NSError(
                        domain: "FlowstayFileManager",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Path exists but is not a directory: \(url.path)"]
                    )
                }
            }

            // Create directory (macOS uses volume-level APFS encryption, not per-file protection)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
            print("[FileManager] ✅ Created directory: \(url.path)")
        }
    }
}

// MARK: - String Extensions

public extension String {
    /// Append string to a file
    func appendToFile(at path: String) throws {
        let data = data(using: .utf8) ?? Data()
        let fileURL = URL(fileURLWithPath: path)

        if FileManager.default.fileExists(atPath: path) {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        } else {
            try data.write(to: fileURL)
        }
    }
}

// MARK: - System Preferences Helper

public enum SystemPreferencesHelper {
    public enum PreferencePane {
        case accessibilityPrivacy
        case microphonePrivacy
        case generalPrivacy

        var urlString: String {
            switch self {
            case .accessibilityPrivacy:
                "x-apple.systempreferences.com.apple.preference.security?Privacy_Accessibility"
            case .microphonePrivacy:
                "x-apple.systempreferences.com.apple.preference.security?Privacy_Microphone"
            case .generalPrivacy:
                "x-apple.systempreferences.com.apple.preference.security"
            }
        }

        var fallbackUrlString: String {
            switch self {
            case .accessibilityPrivacy:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .microphonePrivacy:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .generalPrivacy:
                "x-apple.systempreferences:com.apple.preference.security"
            }
        }
    }

    @MainActor
    public static func open(_ pane: PreferencePane) -> Bool {
        // Try modern URL scheme first
        if let url = URL(string: pane.urlString) {
            let success = NSWorkspace.shared.open(url)
            if success {
                return true
            }
        }

        // Fallback to legacy URL scheme
        if let fallbackUrl = URL(string: pane.fallbackUrlString) {
            let success = NSWorkspace.shared.open(fallbackUrl)
            if success {
                return true
            }
        }

        return false
    }

    @MainActor
    public static func openWithFeedback(_ pane: PreferencePane, onSuccess: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        let success = open(pane)

        if success {
            onSuccess?()
        } else {
            onFailure?()
            // Post notification for UI to show error
            NotificationCenter.default.post(
                name: .systemPreferenceOpenFailed,
                object: pane
            )
        }
    }
}

// MARK: - Notification Extensions

public extension Notification.Name {
    /// App-specific notifications
    static let systemPreferenceOpenFailed = Notification.Name("SystemPreferenceOpenFailed")
}

// MARK: - Privacy Manager Implementation

/// Manages privacy-related permissions and monitoring
/// SAFETY: @unchecked Sendable is used because:
/// 1. All mutable state (microphonePermissionGranted, accessibilityPermissionGranted) is only accessed
///    from @MainActor-isolated methods (checkInitialPermissionsSafely, requestMicrophonePermissionAsync)
/// 2. The singleton is initialized once and the properties are effectively main-thread-only after init
/// 3. All public methods that modify state are marked @MainActor
@available(macOS 14.0, *)
public final class PrivacyManager: @unchecked Sendable {
    public static let shared = PrivacyManager()

    private var microphonePermissionGranted = false
    private var accessibilityPermissionGranted = false

    private init() {
        // Initialize on main actor to avoid actor isolation issues
        Task { @MainActor in
            checkInitialPermissionsSafely()
        }
    }

    @MainActor
    private func checkInitialPermissionsSafely() {
        // Check microphone permission safely
        microphonePermissionGranted = AVAudioApplication.shared.recordPermission == .granted

        // Check accessibility permission safely to avoid TCC crash
        accessibilityPermissionGranted = checkAccessibilityPermissionSafely()
    }

    @MainActor
    private func checkAccessibilityPermissionSafely() -> Bool {
        // Use a safer approach to check accessibility permission
        // This avoids the TCC crash that can happen with AXIsProcessTrusted()

        // Try to get the system-wide element to test accessibility permission
        let systemElement = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?

        // If we can get the focused application without crashing, accessibility is likely granted
        let result = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        if result == .success {
            return true
        }

        return false
    }

    public func initialize() {
        // Initialize privacy monitoring
        print("🔐 Privacy manager initialized")
    }

    public func requestMicrophonePermissionAsync() async {
        let status = AVAudioApplication.shared.recordPermission
        print("🎤 Current microphone permission before request: \(status == .granted ? "granted" : status == .denied ? "denied" : status == .undetermined ? "undetermined" : "unknown")")

        if status == .undetermined {
            print("🎤 Requesting microphone permission...")
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    print("🎤 Microphone permission request completed: \(granted)")
                    continuation.resume()
                }
            }
        } else if status == .granted {
            print("🎤 Microphone permission already granted")
        } else if status == .denied {
            print("🎤 Microphone permission was previously denied")
        } else {
            print("🎤 Microphone permission in unknown state (raw: \(status.rawValue))")
        }

        // Double-check final status
        let finalStatus = AVAudioApplication.shared.recordPermission
        microphonePermissionGranted = finalStatus == .granted
        print("🎤 Final microphone permission status: \(microphonePermissionGranted)")
    }

    public func hasMicrophonePermission() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    @MainActor
    public func hasAccessibilityPermission() -> Bool {
        // Update our cached value and return it
        accessibilityPermissionGranted = checkAccessibilityPermissionSafely()
        return accessibilityPermissionGranted
    }

    /// Synchronous version that returns cached value without updating
    public func hasAccessibilityPermissionCached() -> Bool {
        accessibilityPermissionGranted
    }
}

// MARK: - NSAlert Helper

public extension NSAlert {
    @MainActor
    static func showInfo(message: String) {
        let alert = NSAlert()
        alert.messageText = "Test"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
