import Foundation
import Sparkle

/// Manages app updates using Sparkle framework
@MainActor
public class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController?
    @Published public var isCheckingForUpdates = false

    private init() {}

    /// Initialize Sparkle updater with configuration
    public func initialize() {
        print("[UpdateManager] Initializing Sparkle auto-updater...")

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

            print("[UpdateManager] ✅ Sparkle initialized")
            print("[UpdateManager] Appcast URL: \(updater.feedURL?.absoluteString ?? "not set")")
            print("[UpdateManager] Auto-check enabled: \(updater.automaticallyChecksForUpdates)")
        } else {
            print("[UpdateManager] ⚠️ Failed to initialize Sparkle updater")
        }
    }

    /// Manually check for updates (user-initiated from Settings)
    public func checkForUpdates() {
        print("[UpdateManager] Manual update check requested...")
        isCheckingForUpdates = true

        updaterController?.checkForUpdates(nil)

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
