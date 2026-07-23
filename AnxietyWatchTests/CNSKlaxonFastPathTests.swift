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
    /// The critical fast-path sustain (seconds), via the threshold — never the
    /// literal, so the tests track the tunable (file convention above).
    private var sustain: Int { Int(thresholds.criticalFastPathSustainSeconds) }

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

    @Test("A critical score fast-paths straight to klaxon in one fast-path window, not the graded ~150s")
    func criticalFastPathsToKlaxon() {
        var m = machine()   // companion
        // 0.95 ≥ klaxon threshold → critical. It SKIPS watch/confirm (a jump), so
        // it stays clear while the short validity window builds (< the sustain)…
        #expect(feed(&m, score: 0.95, seconds: sustain) == .clear)  // ticks t=0…sustain-1
        // …then the fast-path sustain completes → straight to klaxon.
        let tier = m.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(TimeInterval(sustain))
        )
        #expect(tier == .klaxon)
    }

    @Test("The critical fast path is companion-independent — one sustain window alone too")
    func criticalFastPathCompanionIndependent() {
        var alone = machine(companionPresent: false)
        #expect(feed(&alone, score: 0.95, seconds: sustain) == .clear)
        let tier = alone.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(TimeInterval(sustain))
        )
        #expect(tier == .klaxon)
    }

    @Test("A critical spike shorter than the fast-path sustain does not klaxon (glitch rejection)")
    func criticalSpikeBelowSustainDoesNotKlaxon() {
        var m = machine()
        _ = feed(&m, score: 0.95, seconds: sustain - 3)          // short of the fast-path sustain
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
        // NOT complete the fast-path window.
        let tier = m.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(16)
        )
        #expect(tier == .clear)
        // A full uninterrupted sustain window from the restart (t=16 onward) does fire.
        let fired = feed(&m, score: 0.95, seconds: sustain + 1, startingAt: 17)
        #expect(fired == .klaxon)
    }

    @Test("A critical reading from an already-confirm tier fast-paths to klaxon in one sustain window")
    func criticalFastPathFromConfirm() {
        var m = machine()
        _ = feed(&m, score: 0.7, seconds: 125)                   // ladder to confirm (~t121)
        #expect(m.tier == .confirm)
        // sustain-1 s in from t=125: not yet.
        #expect(feed(&m, score: 0.95, seconds: sustain, startingAt: 125) == .confirm)
        let tier = m.ingest(
            .assessed(riskScore: 0.95, contributions: primary(0.95)),
            at: t0.addingTimeInterval(125 + TimeInterval(sustain))
        )
        #expect(tier == .klaxon)
    }

    /// A primary contribution at an arbitrary severity, so a test can set the
    /// fused riskScore and the raw primary severity independently.
    private func primary(severity: Double) -> [CNSSignalAssessment] {
        [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: severity, confidence: 0.9)]
    }

    @Test("Corroboration cannot buy the fast-path express lane — a moderate primary klaxons only via the graded ladder")
    func criticalFastPathIgnoresCorroborationInflation() {
        var m = machine()
        // A MODERATE primary (SpO₂ severity 0.55, ~SpO₂ 86.4) plus screaming HR+HRV
        // fuses to 0.9 — above the klaxon threshold. Gating the fast path on the
        // FUSED score (the pre-fix bug) would fire klaxon within the fast-path
        // window. It now keys on RAW primary severity (0.55 < criticalPrimary-
        // Severity 0.85), so corroboration can't manufacture a crash.
        let corroborated: [CNSSignalAssessment] = [
            CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: 0.55, confidence: 0.9),
            CNSSignalAssessment(kind: .heartRate, source: .polarH10, severity: 1.0, confidence: 0.95),
            CNSSignalAssessment(kind: .hrv, source: .polarH10, severity: 1.0, confidence: 0.9)
        ]
        for second in 0..<(sustain + 1) {   // through the fast-path window (t=sustain)
            _ = m.ingest(.assessed(riskScore: 0.9, contributions: corroborated),
                         at: t0.addingTimeInterval(Double(second)))
        }
        #expect(m.tier == .clear)   // no fast path fired; the ladder hasn't reached watch
        // It DOES still escalate — over the graded ladder (err toward alarm):
        // watch ~t60, confirm ~t121, klaxon ~t152. Drive well past that.
        var tier = m.tier
        for second in (sustain + 1)..<170 {
            tier = m.ingest(.assessed(riskScore: 0.9, contributions: corroborated),
                            at: t0.addingTimeInterval(Double(second)))
        }
        #expect(tier == .klaxon)
    }

    @Test("Oscillating across the critical boundary does not wedge the graded ladder")
    func criticalBoundaryOscillationDoesNotWedgeLadder() {
        var m = machine()
        // Alternate a CRITICAL primary (severity 0.9 → fast-path eligible) with a
        // sub-critical but still-elevated one (0.7, above the confirm entry). Both
        // are primary-informed and both clear the confirm threshold, so the
        // ladder's candidate accumulates CONTINUOUSLY. Pre-fix, the target
        // flip-flopped klaxon↔confirm every tick and reset the SHARED candidate,
        // wedging the machine below confirm forever. With independent clocks the
        // ladder still reaches confirm on schedule, while the alternation keeps
        // the fast path from ever completing (it resets every other tick).
        var tier = m.tier
        for second in 0..<130 {
            let severity = second.isMultiple(of: 2) ? 0.9 : 0.7
            tier = m.ingest(
                .assessed(riskScore: severity, contributions: primary(severity: severity)),
                at: t0.addingTimeInterval(Double(second))
            )
        }
        // Reached confirm via the ladder (not wedged at clear/watch), and NOT
        // klaxon (the alternation never lets the 12 s critical window complete).
        #expect(tier == .confirm)
    }

    @Test("A single noisy critical spike mid-ladder does not reset confirm progress")
    func singleNoisyCriticalSpikeDoesNotResetLadderProgress() {
        var m = machine()
        // Rise to watch (0.5, 60 s companion sustain), then build 30 s of confirm
        // progress at 0.7 (under the 60 s hop).
        _ = feed(&m, score: 0.5, seconds: 61)                    // watch at t=60
        #expect(m.tier == .watch)
        #expect(feed(&m, score: 0.7, seconds: 30, startingAt: 61) == .watch)  // t61…90, not yet confirm
        // ONE noisy tick at t=91 spikes to critical (0.9 ≥ klaxon) — a single
        // sample, nowhere near the 12 s fast-path window — then reverts to 0.7.
        // Pre-fix, that spike flipped the shared candidate's target to klaxon and
        // wiped the confirm progress, pushing confirm from t=121 out to t=152.
        _ = m.ingest(.assessed(riskScore: 0.9, contributions: primary(0.9)), at: t0.addingTimeInterval(91))
        _ = m.ingest(.assessed(riskScore: 0.7, contributions: primary(0.7)), at: t0.addingTimeInterval(92))
        // The confirm candidate started at t=61, so 0.7 sustained to t=121 fires
        // confirm ON SCHEDULE — the spike cost nothing (independent clocks).
        let tier = feed(&m, score: 0.7, seconds: 29, startingAt: 93)  // t93…121
        #expect(tier == .confirm)
    }

    @Test("A maximal low-confidence primary fast-paths despite a confidence-damped fused score below klaxon entry")
    func criticalFastPathFiresOnMaximalLowConfidencePrimary() {
        var m = machine()   // companion — klaxon entry 0.85
        // Lone EMAY at the absolute danger floor: severity 1.0, but worst-case
        // confidence 0.36 (fidelity 0.9 × density-floor 0.5 × missing-baseline
        // 0.8) — the "crash starves its own detector" state (perfusion collapses
        // during a real desat, dropping coverage exactly when severity peaks).
        // The fused score is only 1.0 × (0.5 + 0.5 × 0.36) = 0.68, BELOW the 0.85
        // klaxon entry, so a fused-score gate would strand this maximal reading at
        // confirm. The source-fidelity gate fires it: EMAY (0.9) is trusted,
        // severity 1.0 is critical — confidence is irrelevant to the express lane.
        let maximal = [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: 1.0, confidence: 0.36)]
        for second in 0..<sustain {   // t=0…sustain-1: one short of the sustain
            _ = m.ingest(.assessed(riskScore: 0.68, contributions: maximal),
                         at: t0.addingTimeInterval(Double(second)))
        }
        #expect(m.tier == .clear)
        let tier = m.ingest(.assessed(riskScore: 0.68, contributions: maximal),
                            at: t0.addingTimeInterval(TimeInterval(sustain)))
        #expect(tier == .klaxon)   // fired despite fused score 0.68 < klaxon entry
    }

    @Test("A high-severity LOW-fidelity primary never fast-paths, even at a klaxon-level fused score")
    func lowFidelityPrimaryNeverFastPaths() {
        var m = machine()
        // Apple Watch SpO₂ (fidelity 0.5 < trusted 0.8) reporting a phantom
        // severity 0.95 with a fused score AT the klaxon entry. A fused-score gate
        // would fire the 12 s express on this artifact-prone spot-check; the
        // fidelity gate keeps it off the express lane entirely (the ladder, whose
        // input the fusion engine damps in practice, remains the only route up).
        let watchSpike = [CNSSignalAssessment(kind: .spo2, source: .appleWatch, severity: 0.95, confidence: 0.5)]
        for second in 0..<20 {   // 20 s — well past the 12 s fast-path window
            _ = m.ingest(.assessed(riskScore: 0.9, contributions: watchSpike),
                         at: t0.addingTimeInterval(Double(second)))
        }
        // No fast path fired (else klaxon by t=12); the ladder is still mid-first
        // hop (watch needs 60 s), so the tier is clear — definitely not klaxon.
        #expect(m.tier == .clear)
    }

    @Test("A corroborating-only tick mid-build leaves the critical fast-path candidate intact")
    func corroboratingOnlyTickDoesNotResetCriticalCandidate() {
        var m = machine()
        let critical = [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: 1.0, confidence: 0.9)]
        let corroborating = [CNSSignalAssessment(kind: .heartRate, source: .polarH10, severity: 1.0, confidence: 0.95)]
        // Critical candidate opens at t=0 and builds toward the sustain…
        for second in 0...(sustain - 4) {
            _ = m.ingest(.assessed(riskScore: 0.95, contributions: critical),
                         at: t0.addingTimeInterval(Double(second)))
        }
        #expect(m.tier == .clear)
        // …a lone HR tick (the primary stream is silent this tick) must NOT reset
        // the candidate — a corroborating signal can't testify about the primary
        // that opened it, so it leaves it intact (the gap guard still governs
        // staleness), mirroring the ladder.
        _ = m.ingest(.assessed(riskScore: 0.5, contributions: corroborating),
                     at: t0.addingTimeInterval(Double(sustain - 3)))
        #expect(m.tier == .clear)
        // Critical resumes within the gap tolerance; the ORIGINAL t=0 candidate is
        // still running, so it completes at t=sustain — not a full window later, as
        // a reset-on-corroborating bug would give.
        _ = m.ingest(.assessed(riskScore: 0.95, contributions: critical),
                     at: t0.addingTimeInterval(Double(sustain - 2)))
        _ = m.ingest(.assessed(riskScore: 0.95, contributions: critical),
                     at: t0.addingTimeInterval(Double(sustain - 1)))
        let tier = m.ingest(.assessed(riskScore: 0.95, contributions: critical),
                            at: t0.addingTimeInterval(TimeInterval(sustain)))
        #expect(tier == .klaxon)
    }

    @Test("A maximal RR-only reading does not fast-path in Phase 1 (no trusted RR source yet)")
    func respiratoryRatePrimaryDoesNotFastPathPhase1() {
        var m = machine()
        // RR ≈ 5 (severity 1.0) from Apple Watch — a PRIMARY signal, exercising
        // the primary path for the respiratory-rate kind (not just SpO₂). But its
        // fidelity (0.6) is below the trusted-continuous bar (0.8), and no Phase-1
        // source emits a high-fidelity RR, so a maximal RR reading never takes the
        // 12 s express lane; independent RR/apnea fast escalation is a later phase.
        let rr = [CNSSignalAssessment(kind: .respiratoryRate, source: .appleWatch, severity: 1.0, confidence: 0.6)]
        for second in 0..<20 {   // 20 s — well past the 12 s fast-path window
            _ = m.ingest(.assessed(riskScore: 0.9, contributions: rr), at: t0.addingTimeInterval(Double(second)))
        }
        #expect(m.tier == .clear)   // no fast path; ladder still mid-first-hop
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

    @Test("A lone continuous oximeter (no baseline) clears the lone-source cap but a moderate desat lands just shy of confirm")
    func loneContinuousOximeterUnmuzzledNoBaseline() {
        // EMAY alone at severity 0.667 (~SpO₂ 86), NOT the ≥0.9 extreme override,
        // at NO-BASELINE confidence (fidelity 0.9 × density 1.0 × missing-baseline
        // 0.8 = 0.72). The old lone-source cap pinned this at 0.5 (dead zone →
        // watch forever); un-muzzling lifts it ABOVE the cap. But with no personal
        // baseline the confidence soft-scale leaves the composite just BELOW
        // confirm — 0.667 × (0.5 + 0.5 × 0.72) = 0.574 < 0.6 — so a brand-new
        // user's first-night sustained moderate desat reaches WATCH, not confirm.
        // This is a DOCUMENTED residual of the un-muzzle (medical-review finding):
        // a baseline closes it (see the with-baseline sibling), and the
        // klaxon/critical paths are unaffected. Tracked as a follow-up, not a
        // regression — pre-PR1 this same case was capped strictly lower (0.5).
        let lone = [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: 0.667, confidence: 0.72)]
        guard case .assessed(let score, _) = engine.fuse(lone) else {
            Issue.record("expected .assessed"); return
        }
        #expect(score > thresholds.loneSourceRiskCap)
        #expect(score < thresholds.confirmThreshold)
    }

    @Test("A lone continuous oximeter WITH a baseline escalates a moderate desat to confirm")
    func loneContinuousOximeterWithBaselineReachesConfirm() {
        // Same severity 0.667, but a personal baseline lifts confidence to
        // fidelity 0.9 × density 1.0 × 1.0 = 0.9, so the soft-scaled composite
        // 0.667 × (0.5 + 0.5 × 0.9) = 0.634 clears confirm (0.6). This is exactly
        // the case the design doc's "86–87% dead zone" targeted: once ANY personal
        // baseline exists, a trusted lone oximeter's sustained moderate desat
        // reaches confirm rather than being muzzled to watch.
        let lone = [CNSSignalAssessment(kind: .spo2, source: .emayOximeter, severity: 0.667, confidence: 0.9)]
        guard case .assessed(let score, _) = engine.fuse(lone) else {
            Issue.record("expected .assessed"); return
        }
        #expect(score >= thresholds.confirmThreshold)
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
