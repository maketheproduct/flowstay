import Foundation
import os
import Sparkle

/// Manages app updates using Sparkle framework
@MainActor
public class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController?
    private let logger = Logger(subsystem: "com.flowstay.core", category: "UpdateManager")
    @Published public var isCheckingForUpdates = false
    @Published public private(set) var isUpdaterAvailable = false
    @Published public private(set) var unavailableReason: String?

    private init() {}

    /// Initialize Sparkle updater with configuration
    public func initialize() {
        StartupRecoveryManager.shared.markStage(.updateInitializing)
        isUpdaterAvailable = false
        unavailableReason = nil

        if StartupRecoveryManager.shared.shouldSkipAutoUpdate {
            let bundlePath = Bundle.main.bundlePath
            print("[UpdateManager] Recovery mode active - skipping Sparkle initialization for this launch")
            StartupRecoveryManager.shared.markSubsystemSkipped(.autoUpdate)
            StartupRecoveryManager.shared.appendDiagnostic(
                "skipping Sparkle initialization during recovery launch bundlePath=\(bundlePath)"
            )
            unavailableReason = "Update checks are paused while Flowstay is in safer startup mode."
            return
        }

        print("[UpdateManager] Initializing Sparkle auto-updater...")
        let bundlePath = Bundle.main.bundlePath
        let isTranslocated = bundlePath.contains("/AppTranslocation/")
        let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "missing"
        let publicKeyPresent = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
        let startupContext =
            "bundlePath=\(bundlePath) translocated=\(isTranslocated) feedURL=\(feedURLString) publicKeyPresent=\(publicKeyPresent)"
        logger.info("[UpdateManager] Startup context: \(startupContext, privacy: .public)")
        StartupRecoveryManager.shared.appendDiagnostic("Sparkle startup context \(startupContext)")

        // Create updater controller with app bundle
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Configure update checks
        if let updater = updaterController?.updater {
            // Check for updates on every app launch
            updater.automaticallyChecksForUpdates = true
            updater.updateCheckInterval = 0 // Check every launch
            isUpdaterAvailable = true

            print("[UpdateManager] ✅ Sparkle initialized")
            print("[UpdateManager] Appcast URL: \(updater.feedURL?.absoluteString ?? "not set")")
            print("[UpdateManager] Auto-check enabled: \(updater.automaticallyChecksForUpdates)")
        } else {
            unavailableReason = "Update checks are unavailable right now."
            print("[UpdateManager] ⚠️ Failed to initialize Sparkle updater")
        }
    }

    /// Manually check for updates (user-initiated from Settings)
    public func checkForUpdates() {
        guard isUpdaterAvailable, let updaterController else {
            print("[UpdateManager] Manual update check ignored - updater unavailable")
            return
        }

        print("[UpdateManager] Manual update check requested...")
        isCheckingForUpdates = true

        updaterController.checkForUpdates(nil)

        // Reset flag after a delay
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await MainActor.run {
                isCheckingForUpdates = false
            }
        }
    }

    /// Get current app version
    public var currentVersion: String {
        guard let infoDict = Bundle.main.infoDictionary else {
            print("[UpdateManager] ⚠️ Bundle.main.infoDictionary is nil - Info.plist may be missing")
            return "Unknown (Build 0)"
        }

        let version = infoDict["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = infoDict["CFBundleVersion"] as? String ?? "0"
        return "\(version) (Build \(build))"
    }
}
