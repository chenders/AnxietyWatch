import Foundation

/// §5.1 per-signal scoring: severity (how far toward danger, 0–1, mostly
/// baseline-relative — SpO₂ additionally has an absolute safety-net floor
/// that scores maximal danger independent of any baseline, see
/// `CNSThresholds.spo2AbsoluteDangerFloor`) and confidence (how much to trust
/// it, 0–1). Pure — no clock, no I/O. Returns nil rather than scoring anything
/// it can't score honestly (indeterminate window, impossible (kind, source) pair).
///
/// The median is computed over every good sample handed in: callers MUST
/// pre-trim to the current gate window (see `CNSDetectionPipeline`) —
/// an unbounded rolling buffer makes the median lag a declining trend by
/// half its length, which delays or entirely suppresses escalation.
enum CNSSeverityScorer {

    /// Linear lower-is-worse ramp: 0 at `onset`, 1 at `floor`, clamped.
    static func rampSeverity(value: Double, onset: Double, floor: Double) -> Double {
        guard onset > floor else { return value <= floor ? 1 : 0 }
        return min(max((onset - value) / (onset - floor), 0), 1)
    }

    static func assess(
        kind: CNSSignalKind,
        source: CNSSignalSource,
        samples: [CNSSignalSample],
        verdict: CNSWindowVerdict,
        baselines: CNSBaselines,
        thresholds: CNSThresholds
    ) -> CNSSignalAssessment? {
        guard verdict.quality == .pass else { return nil }
        let fidelity = thresholds.sourceFidelity(kind: kind, source: source)
        guard fidelity > 0 else { return nil }
        let good = CNSQualityGate.goodSamples(samples, thresholds: thresholds)
            .filter { $0.kind == kind && $0.source == source }
        guard let representative = median(of: good.map(\.value)) else { return nil }

        guard let (severity, baselineAvailable) = severity(
            kind: kind, value: representative, baselines: baselines, thresholds: thresholds
        ) else { return nil }

        let baselineFactor = baselineAvailable ? 1.0 : thresholds.missingBaselineConfidenceFactor
        // Coverage already cleared the 30s contiguous bar; map the density
        // range [0.5, 1.0] so a barely-passing window still carries weight.
        let densityFactor = max(verdict.goodCoverageFraction, 0.5)
        let confidence = fidelity * densityFactor * baselineFactor
        return CNSSignalAssessment(
            kind: kind, source: source, severity: severity, confidence: confidence
        )
    }

    /// Returns (severity, whether a personal baseline informed it), or nil
    /// when the kind can't be scored yet.
    private static func severity(
        kind: CNSSignalKind,
        value: Double,
        baselines: CNSBaselines,
        thresholds: CNSThresholds
    ) -> (Double, Bool)? {
        switch kind {
        case .spo2:
            // `sanitized*` is the same choke point the ramp uses internally:
            // an implausible (e.g. fraction-scale) baseline is NOT available,
            // so severity falls back to the default ramp AND confidence
            // carries the missing-baseline factor — the two can't disagree.
            let ramp = thresholds.spo2Ramp(nadirBaseline: baselines.spo2Nadir)
            let rampSev = rampSeverity(value: value, onset: ramp.onset, floor: ramp.floor)
            // Absolute safety net, independent of the personalized ramp: a raw
            // SpO₂ at/below the absolute danger floor is maximal severity no
            // matter the baseline, so a poisoned/depressed nadir can never score
            // real danger as safe. OR'd with the ramp (max wins).
            let sev = value <= thresholds.spo2AbsoluteDangerFloor ? 1.0 : rampSev
            return (
                sev,
                thresholds.sanitizedSpO2Nadir(baselines.spo2Nadir) != nil
            )
        case .respiratoryRate:
            // RR severity uses only the population 10/5 ramp in Phase 1 —
            // `respiratoryRateMean` never informs it, so it must not inflate
            // confidence; the spec §3 "downward trend vs baseline" clause is
            // deferred to Phase 2 (needs trend windows over real RR sources).
            return (
                rampSeverity(
                    value: value,
                    onset: thresholds.respiratoryRateOnset,
                    floor: thresholds.respiratoryRateFloor
                ),
                false
            )
        case .heartRate:
            let ramp = thresholds.heartRateRamp(restingBaseline: baselines.restingHeartRate)
            return (
                rampSeverity(value: value, onset: ramp.onset, floor: ramp.floor),
                thresholds.sanitizedRestingHeartRate(baselines.restingHeartRate) != nil
            )
        case .hrv:
            // Severity is a collapse ramp on the fraction of the personal
            // baseline mean. Without a baseline there is nothing to compare
            // against — never score (a raw ms number is not interpretable).
            guard let baselineMean = baselines.hrvMean, baselineMean > 0 else { return nil }
            let fraction = value / baselineMean
            return (
                rampSeverity(
                    value: fraction,
                    onset: thresholds.hrvOnsetFraction,
                    floor: thresholds.hrvFloorFraction
                ),
                true
            )
        }
    }

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
