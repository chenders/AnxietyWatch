import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the §5.3 hysteretic tier machine: sustained-rise, decisive-fall,
/// can't-assess hold, and the §14.4 alone-mode threshold delta.
struct CNSAlertTierMachineTests {
    private let thresholds = CNSThresholds.standard
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func machine(companionPresent: Bool = false) -> CNSAlertTierMachine {
        CNSAlertTierMachine(thresholds: thresholds, companionPresent: companionPresent)
    }

    /// A single primary (SpO₂) contribution: plain score ticks count as
    /// primary-informed, which is what every pre-C1 test assumed.
    private func primary(_ score: Double) -> [CNSSignalAssessment] {
        [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: score, confidence: 0.9)]
    }

    /// A corroborating-only contribution (HR): can qualify a rise, but can
    /// neither clear a tier nor reset a primary rise candidate.
    private func corroboratingOnly(_ score: Double) -> [CNSSignalAssessment] {
        [CNSSignalAssessment(kind: .heartRate, source: .polarH10, severity: score, confidence: 0.9)]
    }

    /// Feed a constant primary-informed score once per second for `seconds`,
    /// returning the tier after the last ingest.
    private func feed(
        _ machine: inout CNSAlertTierMachine, score: Double,
        seconds: Int, startingAt offset: TimeInterval = 0
    ) -> CNSAlertTier {
        var tier = machine.tier
        for second in 0..<seconds {
            tier = machine.ingest(
                .assessed(riskScore: score, contributions: primary(score)),
                at: t0.addingTimeInterval(offset + Double(second))
            )
        }
        return tier
    }

    @Test("A momentary spike does not change the tier")
    func momentarySpikeIgnored() {
        var m = machine()
        let tier = feed(&m, score: 0.7, seconds: 5)
        #expect(tier == .clear)
    }

    @Test("A sustained elevated score rises to the matching tier after the sustain window")
    func sustainedRise() {
        var m = machine()
        // 0.5 sits between watch (0.3 - 0.05 alone delta = 0.25) and confirm.
        let tier = feed(&m, score: 0.5, seconds: 70)
        #expect(tier == .watch)
    }

    @Test("Klaxon escalates tier-by-tier: two 60s sustains, then a 30s one")
    func klaxonEscalatesThroughConfirm() {
        var m = machine()
        // Escalation is chained, never skipped: watch at ~t=60, confirm
        // candidate starts fresh at t=61 and lands at ~t=121.
        _ = feed(&m, score: 0.95, seconds: 125)
        #expect(m.tier == .confirm)
        // Klaxon candidate began right after confirm (~t=122); its shorter
        // 30s sustain completes around t=152.
        let tier = feed(&m, score: 0.95, seconds: 35, startingAt: 125)
        #expect(tier == .klaxon)
    }

    @Test("Clearing requires sustained decisively-low scores")
    func decisiveClear() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch
        #expect(m.tier == .watch)
        // 0.28 is below watch(alone)=0.25 + hysteresis? No: clearing needs
        // score < threshold - hysteresis = 0.25 - 0.1 = 0.15. 0.2 must NOT clear.
        _ = feed(&m, score: 0.2, seconds: 130, startingAt: 70)
        #expect(m.tier == .watch)
        let tier = feed(&m, score: 0.1, seconds: 130, startingAt: 200)
        #expect(tier == .clear)
    }

    @Test("Insufficient data holds the tier and flags can't-assess")
    func insufficientDataHolds() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch
        let tier = m.ingest(.insufficientData, at: t0.addingTimeInterval(71))
        #expect(tier == .watch)
        #expect(m.canAssess == false)
        // Recovering data restores assessability.
        _ = m.ingest(.assessed(riskScore: 0.5, contributions: primary(0.5)), at: t0.addingTimeInterval(72))
        #expect(m.canAssess == true)
    }

    @Test("A data gap resets progress toward clearing — never clear on silence")
    func gapResetsClearProgress() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch
        // 100s of decisively-low scores (not yet the 120s needed)...
        _ = feed(&m, score: 0.1, seconds: 100, startingAt: 70)
        #expect(m.tier == .watch)
        // ...then a data gap. The partial clear progress must be discarded.
        _ = m.ingest(.insufficientData, at: t0.addingTimeInterval(170))
        // 30 more seconds of low scores would have finished the original 120s
        // window, but the reset means it must NOT clear yet.
        _ = feed(&m, score: 0.1, seconds: 30, startingAt: 171)
        #expect(m.tier == .watch)
        // A full uninterrupted clear window does clear.
        let tier = feed(&m, score: 0.1, seconds: 121, startingAt: 201)
        #expect(tier == .clear)
    }

    @Test("Companion-present raises effective thresholds by the alone delta")
    func companionDelta() {
        // 0.28 is above the alone watch threshold (0.25) but below the
        // companion one (0.3): rises alone, stays clear with a companion.
        var alone = machine(companionPresent: false)
        #expect(feed(&alone, score: 0.28, seconds: 70) == .watch)
        var accompanied = machine(companionPresent: true)
        #expect(feed(&accompanied, score: 0.28, seconds: 70) == .clear)
    }

    @Test("A data gap inside a rise window restarts the sustain — no escalation on bracketing evidence")
    func dataGapDoesNotCountTowardRise() {
        var m = machine()
        _ = feed(&m, score: 0.95, seconds: 125)          // -> confirm (t=121)
        #expect(m.tier == .confirm)
        // One qualifying tick starts the klaxon candidate...
        _ = m.ingest(.assessed(riskScore: 0.95, contributions: primary(0.95)), at: t0.addingTimeInterval(125))
        // ...then a 29s blackout, then a single qualifying tick at t=155.
        for second in 126...154 {
            _ = m.ingest(.insufficientData, at: t0.addingTimeInterval(Double(second)))
        }
        let tier = m.ingest(.assessed(riskScore: 0.95, contributions: primary(0.95)), at: t0.addingTimeInterval(155))
        // Pre-fix this fired klaxon (155-125 >= 30 on two observed points).
        #expect(tier == .confirm)
        // Sustained OBSERVED evidence from t=155 does escalate: 30 more seconds.
        let after = feed(&m, score: 0.95, seconds: 31, startingAt: 156)
        #expect(after == .klaxon)
    }

    @Test("Sub-tolerance jitter gaps do not restart the rise window")
    func jitterGapsTolerated() {
        var m = machine()
        // Qualifying updates every 4 seconds (inside the 5s tolerance):
        // the watch rise must still complete on schedule (~60s).
        var tier = m.tier
        for step in 0...16 {
            tier = m.ingest(
                .assessed(riskScore: 0.5, contributions: primary(0.5)),
                at: t0.addingTimeInterval(Double(step) * 4)
            )
        }
        #expect(tier == .watch)   // last update at t=64 >= 60s sustain
    }

    @Test("A raised tier is never cleared by corroborating-only ticks, however low or long")
    func corroboratingOnlyTicksCannotClear() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch (primary-informed)
        #expect(m.tier == .watch)
        // 300s of decisively-low HR-only scores — 2.5x the 120s clear sustain
        // — must NOT clear: a healthy chest strap can't vouch for a missing
        // oximeter. Reassurance is earned only by primary evidence.
        var tier = m.tier
        for second in 0..<300 {
            tier = m.ingest(
                .assessed(riskScore: 0.05, contributions: corroboratingOnly(0.05)),
                at: t0.addingTimeInterval(70 + Double(second))
            )
        }
        #expect(tier == .watch)
    }

    @Test("Corroborating-only low ticks between qualifying primary ticks do not reset a rise candidate")
    func corroboratingOnlyLowTicksLeaveRiseCandidateIntact() {
        var m = machine()
        // Qualifying primary ticks every 4s (inside the 5s gap tolerance)
        // with decisively-low corroborating-only ticks on the seconds
        // between. A low HR-only score can't testify about the primary
        // stream that started the candidate, so it must not reset it — the
        // watch rise completes on schedule (~60s).
        var tier = m.tier
        for second in 0...64 {
            let now = t0.addingTimeInterval(Double(second))
            if second.isMultiple(of: 4) {
                tier = m.ingest(.assessed(riskScore: 0.5, contributions: primary(0.5)), at: now)
            } else {
                tier = m.ingest(
                    .assessed(riskScore: 0.05, contributions: corroboratingOnly(0.05)), at: now
                )
            }
        }
        #expect(tier == .watch)
    }

    @Test("Corroborating-only qualifying scores can still rise to watch")
    func corroboratingOnlyCanRiseToWatch() {
        var m = machine()
        // Watchfulness is exactly what corroborating signals may raise
        // (spec §5.2): a sustained HR-only score above the watch threshold
        // still escalates to watch — only clearing and contradicting a rise
        // require primary evidence.
        var tier = m.tier
        for second in 0..<70 {
            tier = m.ingest(
                .assessed(riskScore: 0.4, contributions: corroboratingOnly(0.4)),
                at: t0.addingTimeInterval(Double(second))
            )
        }
        #expect(tier == .watch)
    }

    @Test("Corroborating-only evidence can never escalate past watch, however high or long")
    func corroboratingOnlyCannotEscalatePastWatch() {
        var m = machine()
        // An HR-only stream (no SpO₂/RR sensor) with a score well above the
        // confirm/klaxon thresholds (0.55/0.80 alone-mode) sustained for far
        // longer than every rise window combined must cap at watch: only
        // primary (SpO₂/RR) evidence may push a tier past watch (spec §5.2).
        // Guards the `next > .watch` primary-informed gate in advanceRise
        // directly, independent of CNSFusionEngine's corroborating risk cap —
        // so a future threshold/fusion retune can't silently reopen the path.
        var tier = m.tier
        for second in 0..<400 {
            tier = m.ingest(
                .assessed(riskScore: 0.95, contributions: corroboratingOnly(0.95)),
                at: t0.addingTimeInterval(Double(second))
            )
        }
        #expect(tier == .watch)
    }

    @Test("A primary-raised watch tier is never wedged higher by a later corroborating-only stream")
    func corroboratingOnlyDoesNotWedgeTierAboveWatch() {
        var m = machine()
        // Rise to watch on genuine primary evidence …
        let raised = feed(&m, score: 0.4, seconds: 70)
        #expect(raised == .watch)
        // … then the SpO₂ sensor drops out and only a high HR stream
        // remains for well beyond the clear-sustain window. The tier must not
        // escalate past watch, since no primary evidence is present to do so.
        // (The complementary invariant — that a raised tier can't be *cleared*
        // by corroborating-only evidence either — is covered separately by
        // `corroboratingOnlyTicksCannotClear`.) It should hold at watch.
        var tier = raised
        for second in 70..<400 {
            tier = m.ingest(
                .assessed(riskScore: 0.95, contributions: corroboratingOnly(0.95)),
                at: t0.addingTimeInterval(Double(second))
            )
        }
        #expect(tier == .watch)
    }

    @Test("A tick-starvation blackout inside a clear window restarts it — never clear on bracketing lows")
    func blackoutRestartsClearWindow() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch
        #expect(m.tier == .watch)
        // One decisively-low tick opens a clear candidate...
        _ = m.ingest(.assessed(riskScore: 0.1, contributions: primary(0.1)), at: t0.addingTimeInterval(70))
        // ...then 130s with NO ingests at all (app suspension), then one more
        // low tick. Two lows bracketing a blackout span the 120s clear
        // sustain on paper, but unobserved time never counts: restart.
        let tier = m.ingest(.assessed(riskScore: 0.1, contributions: primary(0.1)), at: t0.addingTimeInterval(200))
        #expect(tier == .watch)
        // A full uninterrupted 121s of low ticks from here does clear.
        let cleared = feed(&m, score: 0.1, seconds: 121, startingAt: 201)
        #expect(cleared == .clear)
    }

    @Test("Flipping companionPresent mid-sustain toward confirm does not reset the rise clock")
    func companionFlipPreservesConfirmSustainClock() throws {
        // 0.95 saturates every threshold (watch/confirm/klaxon) in BOTH alone
        // and companion mode, so the flip can never gate on the threshold
        // delta itself — any timing difference could only come from a
        // sustain-clock reset, which is exactly what this test rules out.
        let score = 0.95

        // Control: never flips, stays alone throughout. Records the first
        // second confirm is reached.
        var control = machine(companionPresent: false)
        var controlConfirmSecond: Int?
        for second in 0..<200 {
            let tier = control.ingest(
                .assessed(riskScore: score, contributions: primary(score)),
                at: t0.addingTimeInterval(Double(second))
            )
            if tier == .confirm, controlConfirmSecond == nil { controlConfirmSecond = second }
        }
        let controlConfirm = try #require(controlConfirmSecond)

        // Flip run: identical trajectory, alone up through watch and partway
        // into the confirm rise-sustain window, then flip to companion
        // present and keep driving with the same score.
        let flipSecond = 90
        #expect(flipSecond > 60)             // after watch is reached
        #expect(flipSecond < controlConfirm) // before confirm would arrive

        var flipped = machine(companionPresent: false)
        var flippedConfirmSecond: Int?
        for second in 0..<200 {
            if second == flipSecond {
                let tierBeforeFlip = flipped.tier
                let canAssessBeforeFlip = flipped.canAssess
                flipped.setCompanionPresent(true)
                // The flip instant itself must not perturb tier/canAssess —
                // it only changes the threshold context for future compares.
                #expect(flipped.tier == tierBeforeFlip)
                #expect(flipped.tier == .watch)
                #expect(flipped.canAssess == canAssessBeforeFlip)
                #expect(flipped.canAssess == true)
            }
            let tier = flipped.ingest(
                .assessed(riskScore: score, contributions: primary(score)),
                at: t0.addingTimeInterval(Double(second))
            )
            if tier == .confirm, flippedConfirmSecond == nil { flippedConfirmSecond = second }
        }
        let flippedConfirm = try #require(flippedConfirmSecond)

        // Saturating score => the alone/companion threshold delta never
        // gates this trajectory, so confirm must arrive at EXACTLY the same
        // second as the no-flip control. A naive re-init-on-flip
        // implementation would instead restart the sustain clock at
        // `flipSecond` and land ~30s later.
        #expect(flippedConfirm == controlConfirm)
    }
}
