import Testing
@testable import AnxietyWatch

struct CNSAlarmChannelPolicyTests {
    @Test("Klaxon with Critical granted uses the critical channel and haptics")
    func klaxonCritical() {
        let channels = CNSAlarmChannelPolicy.channels(
            tier: .klaxon,
            criticalGranted: true,
            timeSensitiveGranted: true,
            appActive: false
        )

        #expect(channels.contains(.criticalNotification))
        #expect(channels.contains(.watchHaptic))
        #expect(!channels.contains(.timeSensitiveNotification))
    }

    @Test("Klaxon with Critical denied falls back to Time-Sensitive, never silent")
    func klaxonFallback() {
        let channels = CNSAlarmChannelPolicy.channels(
            tier: .klaxon,
            criticalGranted: false,
            timeSensitiveGranted: true,
            appActive: false
        )

        #expect(channels.contains(.timeSensitiveNotification))
        #expect(channels.contains(.watchHaptic))
        #expect(!channels.isEmpty)
    }

    @Test("Klaxon without notification permission still uses watch haptics")
    func klaxonNotificationDenied() {
        let channels = CNSAlarmChannelPolicy.channels(
            tier: .klaxon,
            criticalGranted: false,
            timeSensitiveGranted: false,
            appActive: false
        )

        #expect(channels == [.watchHaptic])
    }

    @Test("Active klaxon adds foreground channels")
    func activeKlaxon() {
        let channels = CNSAlarmChannelPolicy.channels(
            tier: .klaxon,
            criticalGranted: false,
            timeSensitiveGranted: false,
            appActive: true
        )

        #expect(channels.contains(.watchHaptic))
        #expect(channels.contains(.foregroundAudio))
        #expect(channels.contains(.inAppBanner))
    }

    @Test("Below-klaxon tiers fire no alarm channel")
    func belowKlaxonSilent() {
        for tier in [CNSAlertTier.clear, .watch, .confirm] {
            #expect(CNSAlarmChannelPolicy.channels(
                tier: tier,
                criticalGranted: true,
                timeSensitiveGranted: true,
                appActive: false
            ).isEmpty)
        }
    }
}
