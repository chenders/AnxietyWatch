import Foundation
import Testing

@testable import AnxietyWatch

/// PR1 (severity-scaled klaxon timing) behavioral tests, value- and time-driven,
/// fixed reference dates, every constant via `CNSThresholds.standard`:
///  1. the critical FAST PATH — a deep desat reaches klaxon in ~12 s, skipping
///     the graded watch→confirm ladder (a jump, not a ~150 s climb), while a
///     merely-elevated score still ladders and caps at confirm;
///  2. the ABSOLUTE SpO₂ backstop — a raw reading at/below the absolute danger
///     floor scores maximal severity regardless of a poisoned/depressed baseline;
///  3. the fidelity-gated lone-source UN-MUZZLE — a lone continuous oximeter may
///     escalate a moderate desat, while a lone opportunistic Watch stays damped.
struct CNSKlaxonFastPathTests {
    private let thresholds = CNSThresholds.standard
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Tier machine: critical fast path

    private func machine(companionPresent: Bool = true) -> CNSAlertTierMachine {
        CNSAlertTierMachine(thresholds: thresholds, companionPresent: companionPresent)
    }

    private func primary(_ score: Double) -> [CNSSignalAssessment] {
        [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: score, confidence: 0.9)]
    }

    /// Feed a constant primary-informed score once per second for `seconds`.
    @discardableResult
    private func feed(
        _ m: inout CNSAlertTierMachine, score: Double, seconds: Int,
        startingAt offset: TimeInterval = 0
    ) -> CNSAlertTier {
        var tier = m.tier
        for second in 0..<seconds {
            tier = m.ingest(
                .assessed(riskScore: score, contributions: primary(score)),
                at: t0.addingTimeInterval(offset + Double(second))
            )
        }
        return tier
    }

    @Test("A critical score fast-paths straight to klaxon in ~12s, not the graded ~150s")
    func criticalFastPathsToKlaxon() {
        var m = machine()   // companion
        // 0.95 ≥ klaxon threshold → critical. It SKIPS watch/confirm (a jump),
        // so it stays clear while the short validity window builds (< 12 s)…
        #expect(feed(&m, score: 0.95, seconds: 12) == .clear)   // ticks t=0…11 (11 s)
        // …then the 12 s critical sustain completes → straight to klaxon.
        let tier = m.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(12)
        )
        #expect(tier == .klaxon)
    }

    @Test("The critical fast path is companion-independent — ~12s alone too")
    func criticalFastPathCompanionIndependent() {
        var alone = machine(companionPresent: false)
        #expect(feed(&alone, score: 0.95, seconds: 12) == .clear)
        let tier = alone.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(12)
        )
        #expect(tier == .klaxon)
    }

    @Test("A critical spike shorter than the fast-path sustain does not klaxon (glitch rejection)")
    func criticalSpikeBelowSustainDoesNotKlaxon() {
        var m = machine()
        _ = feed(&m, score: 0.95, seconds: 9)                    // 9 s < 12 s sustain
        #expect(m.tier == .clear)
        // …and it resolves without ever alarming.
        #expect(feed(&m, score: 0.05, seconds: 5, startingAt: 9) == .clear)
    }

    @Test("A gap inside the critical fast-path window restarts it — no klaxon on bracketing lows")
    func criticalFastPathGapGuardRestarts() {
        var m = machine()
        _ = feed(&m, score: 0.95, seconds: 10)                   // candidate since t=0, last qual t=9
        #expect(m.tier == .clear)
        _ = m.ingest(.insufficientData, at: t0.addingTimeInterval(11))
        // A qualifying tick at t=16: last-qualifying was t=9, so the 7 s gap
        // exceeds the 5 s guard → restart. Two points bracketing the gap must
        // NOT complete the 12 s window.
        let tier = m.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(16)
        )
        #expect(tier == .clear)
        // A full uninterrupted 12 s from the restart (t=16 … t=28) does fire.
        let fired = feed(&m, score: 0.95, seconds: 13, startingAt: 17)
        #expect(fired == .klaxon)
    }

    @Test("A critical reading from an already-confirm tier fast-paths to klaxon in ~12s")
    func criticalFastPathFromConfirm() {
        var m = machine()
        _ = feed(&m, score: 0.7, seconds: 125)                   // ladder to confirm (~t121)
        #expect(m.tier == .confirm)
        #expect(feed(&m, score: 0.95, seconds: 12, startingAt: 125) == .confirm)  // t=125…136 (11 s)
        let tier = m.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(137)                       // t=137 = 125 + 12
        )
        #expect(tier == .klaxon)
    }

    // MARK: - Severity scorer: absolute backstop

    private func spo2Samples(value: Double) -> [CNSSignalSample] {
        (0...59).map { ago in
            CNSSignalSample(
                kind: .spo2, source: .emayOximeter, value: value,
                timestamp: t0.addingTimeInterval(60 - Double(ago)), perfusionIndex: 1.2
            )
        }
    }

    private var passingVerdict: CNSWindowVerdict {
        CNSWindowVerdict(quality: .pass, goodCoverageFraction: 1.0)
    }

    private func severity(spo2 value: Double, nadir: Double?) -> Double? {
        CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: value),
            verdict: passingVerdict,
            baselines: CNSBaselines(
                spo2Nadir: nadir, restingHeartRate: nil, hrvMean: nil, respiratoryRateMean: nil
            ),
            thresholds: thresholds
        )?.severity
    }

    @Test("A raw SpO₂ at/below the absolute danger floor scores maximal severity regardless of baseline")
    func absoluteBackstopOverridesRamp() throws {
        // No baseline: 78 ≤ 80 (absolute floor) → severity 1.0.
        #expect(abs(try #require(severity(spo2: 78, nadir: nil)) - 1.0) < 0.0001)
        // POISONED/depressed nadir (65 → ramp onset 62, floor 59): the personalized
        // ramp ALONE would score 78 as 0, but the absolute net still forces 1.0 —
        // a corrupted baseline can never launder real danger into "safe".
        #expect(abs(try #require(severity(spo2: 78, nadir: 65)) - 1.0) < 0.0001)
        // Above the absolute floor, between onset and ramp-floor: the ramp value
        // (0.5), NOT forced to 1.0 — the backstop only floors the deep-danger band.
        #expect(abs(try #require(severity(spo2: 86.5, nadir: nil)) - 0.5) < 0.0001)
    }

    // MARK: - Fusion: fidelity-gated lone-source un-muzzle

    private var engine: CNSFusionEngine { CNSFusionEngine(thresholds: thresholds) }

    @Test("A lone HIGH-fidelity continuous oximeter escalates a moderate desat past the lone-source cap")
    func loneContinuousOximeterUnmuzzled() {
        // EMAY alone at severity 0.667 (~SpO₂ 86), NOT the ≥0.9 extreme override.
        // The old lone-source cap pinned this at 0.5 (dead zone → watch forever);
        // now a trusted continuous oximeter escalates on its own.
        let lone = [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: 0.667, confidence: 0.72)]
        guard case .assessed(let score, _) = engine.fuse(lone) else {
            Issue.record("expected .assessed"); return
        }
        #expect(score > thresholds.loneSourceRiskCap)
    }

    @Test("A lone LOW-fidelity opportunistic Watch reading stays damped at the lone-source cap")
    func loneOpportunisticWatchStaysDamped() {
        // Identical severity from Apple Watch SpO₂ (fidelity 0.5 < the trusted
        // bar): a phantom opportunistic low must NOT escalate on its own.
        let lone = [CNSSignalAssessment(kind: .spo2, source: .appleWatch, severity: 0.667, confidence: 0.72)]
        guard case .assessed(let score, _) = engine.fuse(lone) else {
            Issue.record("expected .assessed"); return
        }
        #expect(abs(score - thresholds.loneSourceRiskCap) < 0.0001)
    }
}
