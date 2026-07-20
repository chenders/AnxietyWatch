import Testing
@testable import AnxietyWatch

struct CNSMonitoringViewHelpersTests {
    @Test("Permission status label formats correctly")
    func permissionStatusLabel() {
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(nil) == "Checking permission...")
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(.criticalGranted) == "Critical Alerts enabled (bypasses mute)")
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(.timeSensitiveOnly) == "Time Sensitive only (Critical denied)")
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(.standardOnly) == "Standard only (Time Sensitive denied)")
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(.notDetermined) == "Permission not yet requested")
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(.denied) == "Notifications denied (haptics & audio still active in-app)")
    }

    @Test("Alarm state subtitle formats correctly")
    func alarmStateSubtitle() {
        #expect(CNSMonitoringViewHelpers.alarmStateSubtitle(isMonitoring: false, tier: .klaxon) == "Monitoring inactive")
        #expect(CNSMonitoringViewHelpers.alarmStateSubtitle(isMonitoring: true, tier: .clear) == "Safe (no depressant signs detected)")
        #expect(CNSMonitoringViewHelpers.alarmStateSubtitle(isMonitoring: true, tier: .watch) == "Elevated risk (monitoring closely)")
        #expect(CNSMonitoringViewHelpers.alarmStateSubtitle(isMonitoring: true, tier: .confirm) == "High risk (please confirm you are awake)")
        #expect(CNSMonitoringViewHelpers.alarmStateSubtitle(isMonitoring: true, tier: .klaxon) == "CRITICAL RISK (ALARM SOUNDING)")
    }
}
