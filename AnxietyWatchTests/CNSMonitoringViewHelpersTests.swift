import Foundation
import Testing
@testable import AnxietyWatch

struct CNSMonitoringViewHelpersTests {
    @Test("Permission status label formats correctly")
    func permissionStatusLabel() {
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(nil) == "Checking permission...")
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(.standard) == "Standard notifications enabled")
        #expect(CNSMonitoringViewHelpers.permissionStatusLabel(.limited) == "Notifications allowed quietly — enable alerts in Settings")
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

    private let ref = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Channel health is degraded (never OK) whenever it can't deliver")
    func channelHealthDegradedWhenUndeliverable() {
        let recent = ref.addingTimeInterval(-600)
        // Server not configured -> degraded even with tokens, permission, recent delivery.
        #expect(CNSMonitoringViewHelpers.channelHealthStatus(
            apnsConfigured: false, registeredTokens: 3, permission: .standard,
            lastAPNsAcceptedAlert: recent, now: ref).isReady == false)
        // No registered device token -> degraded.
        #expect(CNSMonitoringViewHelpers.channelHealthStatus(
            apnsConfigured: true, registeredTokens: 0, permission: .standard,
            lastAPNsAcceptedAlert: recent, now: ref).isReady == false)
        // Notifications denied / limited / not-yet-determined / unknown -> degraded.
        for perm: CNSNotifyPermission? in [.denied, .limited, .notDetermined, nil] {
            #expect(CNSMonitoringViewHelpers.channelHealthStatus(
                apnsConfigured: true, registeredTokens: 1, permission: perm,
                lastAPNsAcceptedAlert: recent, now: ref).isReady == false)
        }
    }

    @Test("Channel health is OK only when configured, registered, and authorized")
    func channelHealthOKWhenDeliverable() {
        for perm in [CNSNotifyPermission.standard] {
            let status = CNSMonitoringViewHelpers.channelHealthStatus(
                apnsConfigured: true, registeredTokens: 1, permission: perm,
                lastAPNsAcceptedAlert: ref.addingTimeInterval(-1800), now: ref)
            #expect(status.isReady == true)
            #expect(status.label.contains("30m"))  // last-accepted age folded in
        }
        // Deliverable but no alert has ever been delivered -> still healthy.
        let fresh = CNSMonitoringViewHelpers.channelHealthStatus(
            apnsConfigured: true, registeredTokens: 2, permission: .standard,
            lastAPNsAcceptedAlert: nil, now: ref)
        #expect(fresh.isReady == true)
    }

    @Test("A future APNs-accepted timestamp (clock skew) clamps to 0m, stays ready")
    func channelHealthClampsFutureAPNsAccepted() {
        let status = CNSMonitoringViewHelpers.channelHealthStatus(
            apnsConfigured: true, registeredTokens: 1, permission: .standard,
            lastAPNsAcceptedAlert: ref.addingTimeInterval(300), now: ref)
        #expect(status.isReady == true)
        #expect(status.label.contains("0m"))
    }
}
