import Foundation

enum CNSMonitoringViewHelpers {
    static func permissionStatusLabel(_ permission: CNSNotifyPermission?) -> String {
        guard let permission else { return "Checking permission..." }
        switch permission {
        case .criticalGranted:
            return "Critical Alerts enabled (bypasses mute)"
        case .timeSensitiveOnly:
            return "Time Sensitive only (Critical denied)"
        case .standardOnly:
            return "Standard only (Time Sensitive denied)"
        case .notDetermined:
            return "Permission not yet requested"
        case .denied:
            return "Notifications denied (haptics & audio still active in-app)"
        }
    }

    static func alarmStateSubtitle(isMonitoring: Bool, tier: CNSAlertTier) -> String {
        guard isMonitoring else { return "Monitoring inactive" }
        switch tier {
        case .clear: return "Safe (no depressant signs detected)"
        case .watch: return "Elevated risk (monitoring closely)"
        case .confirm: return "High risk (please confirm you are awake)"
        case .klaxon: return "CRITICAL RISK (ALARM SOUNDING)"
        }
    }

    static func tierText(_ tier: CNSAlertTier) -> String {
        switch tier {
        case .clear: return "Clear"
        case .watch: return "Watch"
        case .confirm: return "Confirm"
        case .klaxon: return "Klaxon"
        }
    }
}
