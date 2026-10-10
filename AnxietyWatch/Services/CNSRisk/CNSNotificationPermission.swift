import UserNotifications

protocol NotificationSettingsShape {
    nonisolated var authorizationStatus: UNAuthorizationStatus { get }
    nonisolated var alertSetting: UNNotificationSetting { get }
    nonisolated var soundSetting: UNNotificationSetting { get }
    nonisolated var scheduledDeliverySetting: UNNotificationSetting { get }
}

extension UNNotificationSettings: NotificationSettingsShape {}

nonisolated enum CNSNotifyPermission: Equatable, Sendable {
    case standard
    case limited
    case notDetermined
    case denied
}

actor CNSNotificationPermission {
    nonisolated static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    nonisolated static func map(_ settings: some NotificationSettingsShape) -> CNSNotifyPermission {
        guard settings.authorizationStatus != .denied else { return .denied }
        guard settings.authorizationStatus != .notDetermined else { return .notDetermined }
        if settings.authorizationStatus == .authorized,
           settings.alertSetting == .enabled,
           settings.soundSetting == .enabled,
           settings.scheduledDeliverySetting != .enabled {
            return .standard
        }
        if settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral {
            return .limited
        }
        // Any future status the SDK may add — treat with maximal paranoia.
        return .notDetermined
    }

    @discardableResult
    func requestIfNeeded() async -> CNSNotifyPermission {
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: Self.authorizationOptions)
            settings = await center.notificationSettings()
        }
        return Self.map(settings)
    }

    func currentStatus() async -> CNSNotifyPermission {
        Self.map(await center.notificationSettings())
    }
}
