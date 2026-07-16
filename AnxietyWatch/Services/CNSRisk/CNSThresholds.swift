import Foundation

/// Every tunable constant in the CNS-depression detection engine, in one
/// place (spec §3 "working thresholds", §14.2 quality gates, §14.4 companion
/// delta). Values are design inputs over population data — tunable envelopes,
/// not medical advice. Tests reference these members; never re-type a literal.
struct CNSThresholds: Sendable {

    // MARK: - SpO₂ (percent, 0–100)

    /// Trigger ceiling for users without an apnea-lowered baseline.
    var spo2OnsetDefault: Double = 88
    /// Subtracted from the personal SpO₂-nadir baseline (spec §3, N).
    var spo2NadirMargin: Double = 3
    /// PRODIGY terminal floor — severity saturates at 1.0 here (spec §3).
    var spo2Floor: Double = 85
    /// Width of the severity ramp (onset → saturation), matching the default
    /// 88 → 85 span. When a personal apnea-lowered nadir pushes the onset to
    /// or below the fixed `spo2Floor`, the floor must scale DOWN with it —
    /// otherwise the ramp degenerates to a step at 85 and a reading equal to
    /// the user's own normal nadir scores severity 1.0 (nightly false klaxon,
    /// the documented min/max-erratum failure one level deeper).
    var spo2RampWidth: Double = 3

    /// Personal baselines outside these ranges are treated as absent rather
    /// than trusted: a corrupted or mis-scaled value (the classic percent-vs-
    /// fraction bug would store 0.82 instead of 82) would otherwise push the
    /// ramp so low that a life-threatening reading scores severity 0 — the
    /// worst possible failure for the primary signal.
    var spo2NadirPlausibleRange: ClosedRange<Double> = 50...100
    var restingHeartRatePlausibleRange: ClosedRange<Double> = 30...120

    /// The SpO₂-nadir baseline the engine actually trusts: nil when absent OR
    /// implausible. Both the ramp functions below and the scorer's
    /// `baselineAvailable` (confidence) flag go through this single choke
    /// point so severity and confidence can never disagree about whether a
    /// baseline informed the assessment.
    func sanitizedSpO2Nadir(_ nadirBaseline: Double?) -> Double? {
        guard let nadir = nadirBaseline, spo2NadirPlausibleRange.contains(nadir) else { return nil }
        return nadir
    }

    /// Resting-HR twin of `sanitizedSpO2Nadir(_:)` — same single-choke-point
    /// contract.
    func sanitizedRestingHeartRate(_ restingBaseline: Double?) -> Double? {
        guard let resting = restingBaseline,
              restingHeartRatePlausibleRange.contains(resting) else { return nil }
        return resting
    }

    /// Early-warning onset: severity becomes nonzero below this value.
    /// `min`, NOT the spec's literal `max` — see the plan's "Spec erratum"
    /// section: `max` would put the trigger ABOVE an apnea user's normal
    /// nightly dips and alarm every night (the spec's own forbidden failure).
    func spo2Onset(nadirBaseline: Double?) -> Double {
        guard let nadir = sanitizedSpO2Nadir(nadirBaseline) else { return spo2OnsetDefault }
        return min(spo2OnsetDefault, nadir - spo2NadirMargin)
    }

    /// Onset AND saturation floor as a pair: the floor is the lower of the
    /// population floor (85) and `onset − spo2RampWidth`, so the ramp keeps
    /// its width for apnea-lowered baselines instead of degenerating.
    func spo2Ramp(nadirBaseline: Double?) -> (onset: Double, floor: Double) {
        let onset = spo2Onset(nadirBaseline: nadirBaseline)
        return (onset, min(spo2Floor, onset - spo2RampWidth))
    }

    // MARK: - Respiratory rate (breaths/min)

    /// Bradypnea early-warning onset (spec §3: sustained < ~8–10/min).
    var respiratoryRateOnset: Double = 10
    /// PRODIGY terminal floor (RR ≤ 5).
    var respiratoryRateFloor: Double = 5

    // MARK: - Heart rate (bpm) — corroborating only

    /// Subtracted from the personal resting-HR baseline for the bradycardia
    /// onset; without a baseline, `heartRateOnsetDefault` applies.
    var heartRateBaselineMargin: Double = 15
    var heartRateOnsetDefault: Double = 50
    /// Severity saturates at profound bradycardia.
    var heartRateFloor: Double = 40

    /// Narrowest acceptable severity ramp for heart rate. Unlike SpO₂ (whose
    /// ramp width equals the full default span), typical HR baselines (e.g.
    /// resting 62 → onset 47, floor 40) already have a healthy 7 bpm ramp —
    /// the floor only needs to scale DOWN when a low personal onset would
    /// compress the ramp below this width and degenerate it into a step that
    /// scores baseline-normal readings as maximal severity.
    var heartRateMinimumRampWidth: Double = 5

    /// Onset AND saturation floor as a pair. Onset is baseline-relative
    /// (resting HR − margin) or the population default; the floor is the
    /// lower of the population floor and `onset − heartRateMinimumRampWidth`,
    /// so a low personal baseline scales the floor down instead of inverting
    /// the ramp (spec §3: absolute floors sit WELL BELOW the personal norm).
    func heartRateRamp(restingBaseline: Double?) -> (onset: Double, floor: Double) {
        let onset = sanitizedRestingHeartRate(restingBaseline)
            .map { $0 - heartRateBaselineMargin } ?? heartRateOnsetDefault
        return (onset, min(heartRateFloor, onset - heartRateMinimumRampWidth))
    }

    // MARK: - HRV — corroborating only, as a fraction of the personal baseline mean

    /// Severity becomes nonzero below this fraction of baseline.
    var hrvOnsetFraction: Double = 0.6
    /// Severity saturates at this fraction (acute collapse).
    var hrvFloorFraction: Double = 0.3

    // MARK: - Quality gate (spec §14.2)

    var gateWindowSeconds: TimeInterval = 60
    /// Contiguous good-quality coverage required inside the window.
    var gateMinContiguousGoodSeconds: TimeInterval = 30
    /// Max gap between consecutive samples that still counts as contiguous
    /// (sources stream ~1 Hz; a 3 s hole breaks the run).
    var gateMaxContiguousGapSeconds: TimeInterval = 3
    /// PI below this → the value can't be trusted for reassurance (SpO₂
    /// overestimates at low perfusion — the false-reassurance case).
    var perfusionSoftFloor: Double = 0.6
    /// PI below this → hard reject the sample entirely. Deliberately unwired
    /// in Phase 1: the gate hard-excludes everything below the SOFT floor,
    /// which is strictly more conservative for reassurance (no low-PI reading
    /// can ever count as "good"). The two-tier scheme becomes meaningful in
    /// Phase 2, when low-PI LOW readings should count toward ESCALATION
    /// (hypoperfusion accompanies overdose) while remaining ineligible for
    /// reassurance. Constant reserved for that.
    var perfusionHardFloor: Double = 0.4
    /// More than this fraction of artifact samples → window indeterminate.
    var maxArtifactFraction: Double = 0.05
    /// Fewer than this many samples in the window → indeterminate regardless
    /// of coverage. Guards against feeding sparse streams (Apple Watch
    /// spot-checks at ~1/hour) through the per-second-coverage math, which
    /// would silently return near-zero coverage and look like "bad data"
    /// rather than the correct signal: "this source is too sparse to assess."
    ///
    /// Phase-1 floor: at the `standard` values this is presently redundant.
    /// A 0-sample window is already rejected by the empty-window guard in
    /// `CNSQualityGate.evaluate`, and a 1-sample window by the near-zero
    /// contiguous-run check (`gateMinContiguousGoodSeconds`, 30 s) or the
    /// artifact-fraction check. It becomes load-bearing only when a real
    /// sparse-cadence adapter lands — at which point the minimum should be
    /// derived from the window/cadence rather than left a flat constant.
    var gateMinSampleCount: Int = 2

    // MARK: - Confidence

    /// Multiplier when the relevant personal baseline is missing.
    var missingBaselineConfidenceFactor: Double = 0.8
    /// Per-(kind, source) fidelity: how much a passing window from this
    /// source is worth (spec §4 sensor-capability table). 0 = the source
    /// does not produce this signal.
    func sourceFidelity(kind: CNSSignalKind, source: CNSSignalSource) -> Double {
        switch (kind, source) {
        case (.spo2, .emayOximeter): return 0.9   // continuous, verified stream
        case (.spo2, .appleWatch): return 0.5     // periodic spot-checks only
        case (.spo2, .polarH10): return 0
        case (.respiratoryRate, .appleWatch): return 0.6  // sleep-session estimate
        case (.respiratoryRate, .emayOximeter): return 0
        case (.respiratoryRate, .polarH10): return 0      // derived RR is a future phase
        case (.heartRate, .polarH10): return 0.95
        case (.heartRate, .emayOximeter): return 0.8      // pulse from the oximeter
        case (.heartRate, .appleWatch): return 0.7
        case (.hrv, .polarH10): return 0.9
        case (.hrv, .appleWatch): return 0.6
        case (.hrv, .emayOximeter): return 0
        }
    }

    // MARK: - Fusion (spec §5.2)

    /// Below this best-available confidence the composite is `.insufficientData`.
    var minimumAssessableConfidence: Double = 0.2
    /// Confidence soft-scales a primary signal's severity between this floor
    /// and 1.0 (score = severity × (floor + (1 − floor) × confidence)) instead
    /// of multiplying directly — a fully-saturated severity from a
    /// moderate-confidence continuous stream must still be able to reach the
    /// klaxon threshold (an EMAY-only night with no baseline yet is the
    /// primary overdose scenario, at confidence 0.72).
    var confidenceSoftScaleFloor: Double = 0.5
    /// Per-corroborating-signal boost cap and scale.
    var corroborationScale: Double = 0.3
    var corroborationPerSignalCap: Double = 0.15
    /// Total corroboration contribution is capped regardless of how many
    /// HR/HRV streams co-report — five concurrent corroborating assessments
    /// must not sum their way past what two can say.
    var corroborationAggregateCap: Double = 0.3
    /// When NO primary signal (SpO₂ / respiratory rate) is meaningfully
    /// elevated, the composite is capped here — below even the alone-mode
    /// confirm tier. Corroborating signals raise watchfulness; they never
    /// confirm CNS depression on their own (spec §5.2), no matter how many
    /// devices agree.
    var corroboratingOnlyRiskCap: Double = 0.5
    /// Bonus when ≥ 2 distinct sources are independently elevated.
    var multiSourceBonus: Double = 0.1
    /// "Elevated" for corroboration/multi-source purposes.
    var elevatedSeverityFloor: Double = 0.5
    var elevatedConfidenceFloor: Double = 0.5
    /// A single source screaming alone is capped here — matching
    /// `corroboratingOnlyRiskCap`, safely below even the alone-mode confirm
    /// threshold (0.55) — unless extreme AND high-confidence (spec §5.2).
    /// 0.55 previously sat EXACTLY on the alone-mode confirm boundary and
    /// only stayed below it by one floating-point ulp. Computed, not stored:
    /// the two caps must move together (they previously drifted).
    var loneSourceRiskCap: Double { corroboratingOnlyRiskCap }
    var loneSourceOverrideSeverity: Double = 0.9
    /// The override asks "did a strictly-valid, high-fidelity stream
    /// saturate?" — contact quality is already adjudicated by the quality
    /// gate, so this floor must sit below the WORST-CASE confidence of a
    /// gate-passing window from the highest-fidelity source with no baseline:
    /// fidelity 0.9 × minimum passing density (31 good samples / 60 s ≈ 0.52)
    /// × missing-baseline 0.8 ≈ 0.37. The old 0.7 demanded ≥ 59/60 good
    /// samples — two dropped BLE packets per minute silenced the klaxon.
    /// The score-level klaxon threshold is still coverage-bound: with no
    /// baseline, a saturated lone stream needs confidence ≥ 0.6 for the
    /// alone-mode klaxon (0.80) — density ≥ 0.6 / 0.72 ≈ 83% coverage — and
    /// ≥ 0.7 (≈ 97% coverage) for the companion-mode klaxon (0.85); with a
    /// baseline the density factors relax accordingly. Degraded-but-passing
    /// streams reach confirm.
    var loneSourceOverrideConfidence: Double = 0.35
    /// Severity at/above which an assessment counts toward lone-source logic.
    var contributingSeverityFloor: Double = 0.2

    // MARK: - Tiers (spec §5.3, §14.4)

    var watchThreshold: Double = 0.3
    var confirmThreshold: Double = 0.6
    var klaxonThreshold: Double = 0.85
    /// Alone-mode lowers every tier threshold by this much (fires earlier
    /// while the user is still rousable — spec §14.4; delta deliberately
    /// modest). Companion-present uses the base thresholds.
    var aloneModeThresholdDelta: Double = 0.05
    /// Sustain required to RISE into watch/confirm (spec §3: ≥ ~60–90 s).
    var riseSustainSeconds: TimeInterval = 60
    /// Sustain to escalate confirm → klaxon (shorter: danger already confirmed).
    var klaxonRiseSustainSeconds: TimeInterval = 30
    /// Score must sit below (threshold − hysteresis) this long to FALL.
    var clearSustainSeconds: TimeInterval = 120
    var clearHysteresis: Double = 0.1
    /// Longest gap between qualifying assessed updates that still counts as
    /// one continuous sustain window — in BOTH directions. Tolerates
    /// scheduling jitter, but a real data gap restarts the candidate: a rise
    /// must be earned by OBSERVED sustained evidence, never by two readings
    /// bracketing a blackout — and symmetrically, a clear must never be
    /// completed by two low readings bracketing one (tick starvation during
    /// app suspension must not read as sustained recovery). (In practice any
    /// genuine sensor dropout also forces the quality gate to re-earn its 30s
    /// contiguous run, so this primarily guards the tier machine's own
    /// bookkeeping.)
    var sustainMaxGapSeconds: TimeInterval = 5

    static let standard = CNSThresholds()
}
