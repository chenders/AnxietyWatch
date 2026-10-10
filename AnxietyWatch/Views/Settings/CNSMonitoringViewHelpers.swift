import Foundation

enum CNSMonitoringViewHelpers {
    static func permissionStatusLabel(_ permission: CNSNotifyPermission?) -> String {
        guard let permission else { return "Checking permission..." }
        switch permission {
        case .standard:
            return "Standard notifications enabled"
        case .limited:
            return "Notifications allowed quietly — enable alerts in Settings"
        case .notDetermined:
            return "Permission not yet requested"
        case .denied:
            return "Notifications denied (haptics & audio still active in-app)"
        }
    }

    /// Health of the redundant server alert channel (sub-project C), as a
    /// user-facing label + a readiness flag. FAIL-SAFE: it returns
    /// `isReady == false` whenever the channel isn't configured for ordinary
    /// alert-and-sound delivery — the server isn't configured, no device token is
    /// registered, or notification settings are limited. That is the
    /// own-failure-must-be-visible invariant (the 2019 Dexcom lesson): a dark
    /// channel must never read as "all good". The last APNs-accepted age is
    /// purely informational — provider acceptance never claims that the device
    /// presented the alert.
    static func channelHealthStatus(
        apnsConfigured: Bool,
        registeredTokens: Int,
        permission: CNSNotifyPermission?,
        lastAPNsAcceptedAlert: Date?,
        now: Date
    ) -> (label: String, isReady: Bool) {
        if !apnsConfigured { return ("Server push not configured", false) }
        if registeredTokens == 0 { return ("No device registered for push", false) }
        guard let permission else { return ("Checking notification permission…", false) }
        switch permission {
        case .denied, .notDetermined:
            return ("Notifications not authorized", false)
        case .limited:
            return ("Notifications deliver quietly — enable alerts in Settings", false)
        case .standard:
            break
        }
        guard let last = lastAPNsAcceptedAlert else {
            return ("Configured — no alerts accepted by APNs yet", true)
        }
        let minutes = max(0, Int(now.timeIntervalSince(last) / 60))
        return ("Configured — APNs accepted an alert \(minutes)m ago", true)
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
