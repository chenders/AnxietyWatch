import Testing
import UserNotifications
@testable import AnxietyWatch

struct CNSNotificationPermissionTests {
    @Test("Authorization requests exactly standard alert and sound notifications")
    func authorizationOptionsAreExactlyStandardAlertAndSound() {
        let options = CNSNotificationPermission.authorizationOptions

        #expect(options == [.alert, .sound])
    }

    @Test("Standard authorization maps to standard")
    func standard() {
        let settings = NotificationSettingsStub(
            authorizationStatus: .authorized
        )

        #expect(CNSNotificationPermission.map(settings) == .standard)
    }

    @Test("Provisional and ephemeral authorization map to limited")
    func limited() {
        for status in [UNAuthorizationStatus.provisional, .ephemeral] {
            let settings = NotificationSettingsStub(authorizationStatus: status)
            #expect(CNSNotificationPermission.map(settings) == .limited)
        }
    }

    @Test("Authorized settings are limited when alerts, sounds, or immediate delivery are disabled")
    func authorizedButDegradedSettingsMapToLimited() {
        let degraded = [
            NotificationSettingsStub(authorizationStatus: .authorized, alertSetting: .disabled),
            NotificationSettingsStub(authorizationStatus: .authorized, soundSetting: .disabled),
            NotificationSettingsStub(authorizationStatus: .authorized, scheduledDeliverySetting: .enabled),
        ]

        for settings in degraded {
            #expect(CNSNotificationPermission.map(settings) == .limited)
        }
    }

    @Test("Denied authorization maps to denied regardless of feature settings")
    func denied() {
        let settings = NotificationSettingsStub(
            authorizationStatus: .denied
        )

        #expect(CNSNotificationPermission.map(settings) == .denied)
    }
}

private struct NotificationSettingsStub: NotificationSettingsShape {
    let authorizationStatus: UNAuthorizationStatus
    let alertSetting: UNNotificationSetting
    let soundSetting: UNNotificationSetting
    let scheduledDeliverySetting: UNNotificationSetting

    init(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting = .enabled,
        soundSetting: UNNotificationSetting = .enabled,
        scheduledDeliverySetting: UNNotificationSetting = .disabled
    ) {
        self.authorizationStatus = authorizationStatus
        self.alertSetting = alertSetting
        self.soundSetting = soundSetting
        self.scheduledDeliverySetting = scheduledDeliverySetting
    }
}
