import UserNotifications

protocol NotificationSettingsShape {
    var authorizationStatus: UNAuthorizationStatus { get }
    var criticalAlertSetting: UNNotificationSetting { get }
    var timeSensitiveSetting: UNNotificationSetting { get }
}

extension UNNotificationSettings: NotificationSettingsShape {}

enum CNSNotifyPermission: Equatable, Sendable {
    case criticalGranted
    case timeSensitiveOnly
    case standardOnly
    case denied
}

actor CNSCriticalAlertPermission {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    nonisolated static func map(_ settings: some NotificationSettingsShape) -> CNSNotifyPermission {
        guard settings.authorizationStatus != .denied else { return .denied }
        if settings.criticalAlertSetting == .enabled {
            return .criticalGranted
        }
        if settings.timeSensitiveSetting == .enabled {
            return .timeSensitiveOnly
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            ? .standardOnly
            : .denied
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
