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

    /// Health of the redundant server alert channel (sub-project C), as a
    /// user-facing label + a healthy flag. FAIL-SAFE: it returns
    /// `isHealthy == false` (never an "OK" label) whenever the channel cannot
    /// actually deliver a push — the server isn't configured, no device token is
    /// registered, or notifications aren't authorized. That is the
    /// own-failure-must-be-visible invariant (the 2019 Dexcom lesson): a dark
    /// channel must never read as "all good". The last-delivered age is purely
    /// informational — folded into the healthy label, never a health gate by
    /// itself (a channel that delivered an alert hours ago but is now
    /// misconfigured is NOT healthy).
    static func channelHealthStatus(
        apnsConfigured: Bool,
        registeredTokens: Int,
        permission: CNSNotifyPermission?,
        lastDeliveredAlert: Date?,
        now: Date
    ) -> (label: String, isHealthy: Bool) {
        if !apnsConfigured { return ("Server push not configured", false) }
        if registeredTokens == 0 { return ("No device registered for push", false) }
        guard let permission else { return ("Checking notification permission…", false) }
        switch permission {
        case .denied, .notDetermined:
            return ("Notifications not authorized", false)
        case .criticalGranted, .timeSensitiveOnly, .standardOnly:
            break
        }
        guard let last = lastDeliveredAlert else {
            return ("Active — ready (no alerts delivered yet)", true)
        }
        let minutes = max(0, Int(now.timeIntervalSince(last) / 60))
        return ("Active — last alert delivered \(minutes)m ago", true)
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
