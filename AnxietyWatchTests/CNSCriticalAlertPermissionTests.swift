import Testing
import UserNotifications
@testable import AnxietyWatch

struct CNSCriticalAlertPermissionTests {
    @Test("Critical authorization maps to critical granted")
    func criticalGranted() {
        let settings = NotificationSettingsStub(
            authorizationStatus: .authorized,
            criticalAlertSetting: .enabled,
            timeSensitiveSetting: .enabled
        )

        #expect(CNSCriticalAlertPermission.map(settings) == .criticalGranted)
    }

    @Test("Time-Sensitive authorization maps to time-sensitive only")
    func timeSensitiveOnly() {
        let settings = NotificationSettingsStub(
            authorizationStatus: .authorized,
            criticalAlertSetting: .disabled,
            timeSensitiveSetting: .enabled
        )

        #expect(CNSCriticalAlertPermission.map(settings) == .timeSensitiveOnly)
    }

    @Test("Standard authorization maps to standard only")
    func standardOnly() {
        let settings = NotificationSettingsStub(
            authorizationStatus: .authorized,
            criticalAlertSetting: .disabled,
            timeSensitiveSetting: .disabled
        )

        #expect(CNSCriticalAlertPermission.map(settings) == .standardOnly)
    }

    @Test("Denied authorization maps to denied regardless of feature settings")
    func denied() {
        let settings = NotificationSettingsStub(
            authorizationStatus: .denied,
            criticalAlertSetting: .enabled,
            timeSensitiveSetting: .enabled
        )

        #expect(CNSCriticalAlertPermission.map(settings) == .denied)
    }
}

private struct NotificationSettingsStub: NotificationSettingsShape {
    let authorizationStatus: UNAuthorizationStatus
    let criticalAlertSetting: UNNotificationSetting
    let timeSensitiveSetting: UNNotificationSetting
}
