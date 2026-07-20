import UserNotifications

protocol NotificationSettingsShape {
    nonisolated var authorizationStatus: UNAuthorizationStatus { get }
    nonisolated var criticalAlertSetting: UNNotificationSetting { get }
    nonisolated var timeSensitiveSetting: UNNotificationSetting { get }
}

extension UNNotificationSettings: NotificationSettingsShape {}

nonisolated enum CNSNotifyPermission: Equatable, Sendable {
    case criticalGranted
    case timeSensitiveOnly
    case standardOnly
    case notDetermined
    case denied
}

actor CNSCriticalAlertPermission {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    nonisolated static func map(_ settings: some NotificationSettingsShape) -> CNSNotifyPermission {
        guard settings.authorizationStatus != .denied else { return .denied }
        guard settings.authorizationStatus != .notDetermined else { return .notDetermined }
        if settings.criticalAlertSetting == .enabled {
            return .criticalGranted
        }
        if settings.timeSensitiveSetting == .enabled {
            return .timeSensitiveOnly
        }
        if settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral {
            return .standardOnly
        }
        // Any future status the SDK may add — treat with maximal paranoia.
        return .notDetermined
    }

    @discardableResult
    func requestIfNeeded() async -> CNSNotifyPermission {
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .criticalAlert])
            settings = await center.notificationSettings()
        }
        return Self.map(settings)
    }

    func currentStatus() async -> CNSNotifyPermission {
        Self.map(await center.notificationSettings())
    }
}
