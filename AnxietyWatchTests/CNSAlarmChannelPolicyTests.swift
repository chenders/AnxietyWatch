import Testing
@testable import AnxietyWatch

struct CNSAlarmChannelPolicyTests {
    @Test("Klaxon uses standard notification and haptics")
    func klaxonNotificationDenied() {
        let channels = CNSAlarmChannelPolicy.channels(
            tier: .klaxon,
            appActive: false
        )

        #expect(channels == [.watchHaptic, .standardNotification])
    }

    @Test("Active klaxon adds foreground channels")
    func activeKlaxon() {
        let channels = CNSAlarmChannelPolicy.channels(
            tier: .klaxon,
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
                appActive: false
            ).isEmpty)
        }
    }
}
