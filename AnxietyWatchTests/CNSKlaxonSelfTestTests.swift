#if DEBUG
import Testing
import Foundation
@testable import AnxietyWatch

/// Regression coverage for the in-app klaxon self-test: the same scripted
/// desaturation the `tools/emay-emulator-nrf52840` firmware streams must drive
/// the real `CNSDetectionPipeline` from clear → klaxon, via watch and confirm,
/// without false-alarming during the healthy warmup.
@Suite struct CNSKlaxonSelfTestTests {

    @Test func desaturationEscalatesToKlaxon() {
        let steps = CNSKlaxonSelfTest.run()
        #expect(steps.first?.tier == .clear)
        #expect(steps.contains { $0.canAssess }, "quality gate should reach canAssess during the warmup")
        #expect(steps.contains { $0.tier == .klaxon },
                "the engine must escalate to klaxon on a sustained hypoxic desaturation")
    }

    @Test func healthyWarmupDoesNotFalseAlarm() {
        let steps = CNSKlaxonSelfTest.run()
        // The first 45 virtual seconds are healthy (SpO₂ 97) — must never klaxon.
        let earlyKlaxon = steps.prefix(45).contains { $0.tier == .klaxon }
        #expect(!earlyKlaxon, "a healthy warmup must not trigger the klaxon")
    }

    @Test func escalationPassesThroughWatchAndConfirm() {
        let steps = CNSKlaxonSelfTest.run()
        guard let klaxonSecond = steps.firstIndex(where: { $0.tier == .klaxon }) else {
            Issue.record("scenario never reached klaxon")
            return
        }
        // The tier machine advances one step at a time (clear→watch→confirm→klaxon),
        // so both intermediate tiers must have been observed before klaxon.
        let priorTiers = Set(steps.prefix(klaxonSecond).map(\.tier))
        #expect(priorTiers.contains(.watch), "klaxon should be reached via watch")
        #expect(priorTiers.contains(.confirm), "klaxon should be reached via confirm")
    }

    @Test func transitionsAreMonotonicallyRising() {
        let steps = CNSKlaxonSelfTest.run()
        let rises = CNSKlaxonSelfTest.transitions(in: steps).prefix { $0.to != .clear }
        // Rising leg only steps up by exactly one tier at a time.
        for transition in rises {
            #expect(transition.to.rawValue == transition.from.rawValue + 1,
                    "tier machine must never skip a tier while rising")
        }
        #expect(rises.contains { $0.to == .klaxon }, "rising leg should reach klaxon")
    }

    @Test func scenarioInterpolationBounds() {
        #expect(CNSKlaxonSelfTest.scenarioValue(at: 0).spo2 == 97)
        #expect(CNSKlaxonSelfTest.scenarioValue(at: 130).spo2 == 80)  // deep in the hypoxia hold
    }
}
#endif
