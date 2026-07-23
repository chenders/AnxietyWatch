import Testing
@testable import AnxietyWatch

/// Coverage for `EMAYRealtimeService.shouldAccept(name:targetName:)` — the
/// `didDiscover` device-acceptance decision. The load-bearing invariant: the
/// production instance (targetName nil) must never adopt the DEBUG emulator
/// dongle, which shares the `SleepO2` name prefix, so a real user's oximeter
/// pairing can't be hijacked by a test rig left powered on nearby.
@Suite struct EMAYDeviceAcceptanceTests {

    @Test func targetedInstanceAcceptsOnlyItsDongle() {
        // Ephemeral self-test: connect ONLY to the named emulator...
        #expect(EMAYRealtimeService.shouldAccept(name: "SleepO2-SIM", targetName: "SleepO2-SIM"))
        // ...never a real EMAY (or a nameless device) on the same FF12 service.
        #expect(!EMAYRealtimeService.shouldAccept(name: "SleepO2", targetName: "SleepO2-SIM"))
        #expect(!EMAYRealtimeService.shouldAccept(name: "", targetName: "SleepO2-SIM"))
    }

    @Test func productionRejectsTheSimulatorRig() {
        #expect(!EMAYRealtimeService.shouldAccept(name: "SleepO2-SIM", targetName: nil),
                "production must never adopt the emulator dongle as the user's oximeter")
    }

    @Test func productionAcceptsRealDeviceOrNamelessDevice() {
        #expect(EMAYRealtimeService.shouldAccept(name: "SleepO2", targetName: nil))
        #expect(EMAYRealtimeService.shouldAccept(name: "SleepO2 1234", targetName: nil))
        // No advertised name → can't filter → accept rather than reject the real device.
        #expect(EMAYRealtimeService.shouldAccept(name: "", targetName: nil))
        #expect(!EMAYRealtimeService.shouldAccept(name: "SomeOtherDevice", targetName: nil))
    }
}
