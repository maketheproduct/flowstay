import Foundation
import UserNotifications

/// Manages user notifications for Flowstay
/// Handles permission requests and notification delivery
@MainActor
public class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    private var permissionGranted = false

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Request notification permissions from the user
    public func requestPermissions() async -> Bool {
        let center = UNUserNotificationCenter.current()

        // First check if we already have a status
        let settings = await center.notificationSettings()
        print("[NotificationManager] 🔍 Current authorization status: \(settings.authorizationStatus.rawValue)")

        // If already determined (authorized or denied), return that status
        if settings.authorizationStatus == .authorized {
            print("[NotificationManager] ✅ Already authorized")
            permissionGranted = true
            return true
        } else if settings.authorizationStatus == .denied {
            print("[NotificationManager] ⚠️ Previously denied - user must enable in System Settings")
            return false
        }

        // Not determined yet, request authorization
        print("[NotificationManager] 📝 Requesting notification authorization...")
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            permissionGranted = granted
            if granted {
                print("[NotificationManager] ✅ Notification permissions granted")
            } else {
                print("[NotificationManager] ⚠️ Notification permissions denied by user")
            }
            return granted
        } catch {
            print("[NotificationManager] ❌ Failed to request notification permissions: \(error)")
            return false
        }
    }

    /// Check current notification permission status
    public func checkPermissionStatus() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        permissionGranted = settings.authorizationStatus == .authorized
        print("[NotificationManager] Permission status checked: \(permissionGranted ? "granted" : "denied")")
        return permissionGranted
    }

    /// Send a notification (checks permission status dynamically)
    public func sendNotification(title: String, body: String, identifier: String? = nil) {
        Task {
            // Check current permission status dynamically
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            guard settings.authorizationStatus == .authorized else {
                print("[NotificationManager] ⚠️ Cannot send notification - permissions not granted (status: \(settings.authorizationStatus.rawValue))")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: identifier ?? UUID().uuidString,
                content: content,
                trigger: nil
            )

            do {
                try await center.add(request)
                print("[NotificationManager] ✅ Notification sent: \(title)")
            } catch {
                print("[NotificationManager] ❌ Failed to send notification: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when app is in foreground
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound even when app is active
        completionHandler([.banner, .sound])
    }
}
