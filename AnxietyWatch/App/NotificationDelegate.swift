import Foundation
import UserNotifications

/// Handles notification presentation and tap actions.
/// Without this delegate, iOS silently suppresses notifications when the app
/// is in the foreground, and tapping a notification does nothing special.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Called when a notification arrives while the app is in the foreground.
    /// Without this, notifications are silently swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Called when the user taps a notification (from lock screen, banner, or Watch).
    /// Posts a Notification so the app can react (e.g., show the follow-up sheet).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationCenter.default.post(name: .didTapLocalNotification, object: nil)
    }
}

extension Notification.Name {
    static let didTapLocalNotification = Notification.Name("didTapLocalNotification")
}
