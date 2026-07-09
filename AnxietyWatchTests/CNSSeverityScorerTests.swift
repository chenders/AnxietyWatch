import Foundation
import Testing

@testable import AnxietyWatch

/// Covers `CNSThresholds` + the pure severity/confidence scoring in
/// `CNSSeverityScorer` (spec §3, §5.1, §14.2). All values baseline-relative;
/// every constant referenced via `CNSThresholds.standard` — no re-typed literals.
struct CNSSeverityScorerTests {
    private let thresholds = CNSThresholds.standard
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

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

    @Test("Alert tiers order clear < watch < confirm < klaxon")
    func tierOrdering() {
        #expect(CNSAlertTier.clear < .watch)
        #expect(CNSAlertTier.watch < .confirm)
        #expect(CNSAlertTier.confirm < .klaxon)
    }

    @Test("SpO2 onset is min(default, nadir - margin) — spec-erratum semantics")
    func spo2OnsetRespectsApneaBaseline() {
        // No baseline → the 88% default.
        #expect(abs(thresholds.spo2Onset(nadirBaseline: nil) - thresholds.spo2OnsetDefault) < 0.001)
        // Healthy nadir (96): default caps the onset at 88 — nadir − 3 = 93 would over-trigger.
        #expect(abs(thresholds.spo2Onset(nadirBaseline: 96) - thresholds.spo2OnsetDefault) < 0.001)
        // Apnea-affected nadir (84): onset drops BELOW the personal nadir (81),
        // so normal nightly dips never trigger (the spec's central confound).
        #expect(abs(thresholds.spo2Onset(nadirBaseline: 84) - 81) < 0.001)
    }

    @Test("Ramp: zero at onset, one at floor, linear between, clamped outside")
    func rampBehavior() {
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 88, onset: 88, floor: 85)) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 85, onset: 88, floor: 85) - 1.0) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 86.5, onset: 88, floor: 85) - 0.5) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 95, onset: 88, floor: 85)) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 40, onset: 88, floor: 85) - 1.0) < 0.001)
    }

    @Test("SpO2 at a healthy 95 with no baseline scores zero severity")
    func healthySpO2ScoresZero() throws {
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 95),
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity) < 0.001)
    }

    @Test("SpO2 at the PRODIGY floor saturates severity at 1.0")
    func floorSpO2Saturates() throws {
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 85),
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 1.0) < 0.001)
    }

    @Test("Apnea baseline lowers the SpO2 onset so a normal dip scores zero")
    func apneaBaselineSuppressesNormalDips() throws {
        // Personal nadir 84 → onset 81. A dip to 86 is normal for this user.
        let baselines = CNSBaselines(
            spo2Nadir: 84, restingHeartRate: nil, hrvMean: nil, respiratoryRateMean: nil
        )
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 86),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity) < 0.001)
    }

    @Test("Respiratory rate ramps between onset 10 and floor 5")
    func respiratoryRateRamp() throws {
        let samples = (0...59).map { ago in
            CNSSignalSample(
                kind: .respiratoryRate, source: .appleWatch, value: 7.5,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .respiratoryRate, source: .appleWatch, samples: samples,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
    }

    @Test("An indeterminate verdict yields no assessment — never a score")
    func indeterminateYieldsNil() {
        let verdict = CNSWindowVerdict(quality: .indeterminate, goodCoverageFraction: 0.2)
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 70),
            verdict: verdict, baselines: .none, thresholds: thresholds
        )
        #expect(assessment == nil)
    }

    @Test("Zero-fidelity (kind, source) pairs yield no assessment")
    func zeroFidelityYieldsNil() {
        // Polar H10 has no SpO2 channel; a sample claiming otherwise is a bug
        // upstream and must not be scored.
        let bogus = (0...59).map { ago in
            CNSSignalSample(
                kind: .spo2, source: .polarH10, value: 70,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .polarH10, samples: bogus,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        #expect(assessment == nil)
    }

    @Test("Apnea-lowered onset scales the floor down — no degenerate step at 85")
    func apneaBaselineScalesFloorDown() throws {
        // Nadir 84 → onset 81, floor 78 (NOT the population 85). A reading
        // equal to the user's own normal nadir must score zero severity.
        let baselines = CNSBaselines(
            spo2Nadir: 84, restingHeartRate: nil, hrvMean: nil, respiratoryRateMean: nil
        )
        let atOwnNadir = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 84),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        ))
        #expect(abs(atOwnNadir.severity) < 0.001)
        // Midway down the shifted ramp (79.5 between 81 and 78) → 0.5.
        let midRamp = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 79.5),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        ))
        #expect(abs(midRamp.severity - 0.5) < 0.001)
        // At the shifted floor (78) severity saturates.
        let atFloor = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 78),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        ))
        #expect(abs(atFloor.severity - 1.0) < 0.001)
    }

    @Test("SpO2 confidence composes fidelity, density, and the missing-baseline factor")
    func spo2ConfidenceComposition() throws {
        // EMAY fidelity x full-coverage density 1.0 x missing-baseline factor.
        let assessment = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 95),
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        ))
        let expected = thresholds.sourceFidelity(kind: .spo2, source: .emayOximeter)
            * 1.0 * thresholds.missingBaselineConfidenceFactor
        #expect(abs(assessment.confidence - expected) < 0.001)
    }

    @Test("An implausible (fraction-scale) SpO2 baseline is treated as absent, never trusted")
    func implausibleSpO2BaselineTreatedAsAbsent() throws {
        // The classic percent-vs-fraction bug: 0.82 stored instead of 82.
        // Trusting it would put the onset below zero and score a
        // life-threatening reading of 40 as severity 0 — the worst possible
        // false reassurance. It must behave exactly like no baseline at all:
        // default ramp (severity 1.0 at 40) AND the missing-baseline
        // confidence factor (scorer and thresholds share the sanitizer).
        let corrupted = CNSBaselines(
            spo2Nadir: 0.82, restingHeartRate: nil, hrvMean: nil, respiratoryRateMean: nil
        )
        let assessment = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 40),
            verdict: passingVerdict, baselines: corrupted, thresholds: thresholds
        ))
        #expect(abs(assessment.severity - 1.0) < 0.001)
        let expected = thresholds.sourceFidelity(kind: .spo2, source: .emayOximeter)
            * 1.0 * thresholds.missingBaselineConfidenceFactor
        #expect(abs(assessment.confidence - expected) < 0.001)
    }

    @Test("An implausible resting-HR baseline is treated as absent, never trusted")
    func implausibleRestingHRBaselineTreatedAsAbsent() throws {
        // A corrupted resting HR of 5 bpm would drag the onset to -10 and
        // zero out real bradycardia. Same shape as the SpO2 guard: default
        // onset 50 / floor 40 (value 45 -> severity 0.5) and the
        // missing-baseline confidence factor.
        let corrupted = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: 5, hrvMean: nil, respiratoryRateMean: nil
        )
        let assessment = try #require(CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 45),
            verdict: passingVerdict, baselines: corrupted, thresholds: thresholds
        ))
        #expect(abs(assessment.severity - 0.5) < 0.001)
        let expected = thresholds.sourceFidelity(kind: .heartRate, source: .polarH10)
            * 1.0 * thresholds.missingBaselineConfidenceFactor
        #expect(abs(assessment.confidence - expected) < 0.001)
    }

    @Test("Median: odd-count heterogeneous samples pick the middle value")
    func medianOddCountHeterogeneous() throws {
        // 61 samples: 30 at 95, one at 87, 30 at 86 — sorted median is 87.
        // Onset 88, floor 85 → severity (88-87)/3.
        var samples: [CNSSignalSample] = []
        for index in 0..<30 {
            samples.append(CNSSignalSample(
                kind: .spo2, source: .emayOximeter, value: 95,
                timestamp: t0.addingTimeInterval(Double(index)), perfusionIndex: 1.2
            ))
        }
        samples.append(CNSSignalSample(
            kind: .spo2, source: .emayOximeter, value: 87,
            timestamp: t0.addingTimeInterval(30), perfusionIndex: 1.2
        ))
        for index in 31..<61 {
            samples.append(CNSSignalSample(
                kind: .spo2, source: .emayOximeter, value: 86,
                timestamp: t0.addingTimeInterval(Double(index)), perfusionIndex: 1.2
            ))
        }
        let assessment = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: samples,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        ))
        #expect(abs(assessment.severity - (88.0 - 87.0) / 3.0) < 0.001)
    }

    @Test("Samples of another kind or source never contaminate the median")
    func crossStreamSamplesExcluded() throws {
        // A healthy SpO2 stream plus interleaved low pulse-rate readings from
        // the same device: the pulse values must not drag the SpO2 median.
        let spo2 = spo2Samples(value: 95)
        let pulse = (0...59).map { ago in
            CNSSignalSample(
                kind: .heartRate, source: .emayOximeter, value: 40,
                timestamp: t0.addingTimeInterval(60 - Double(ago)), perfusionIndex: 1.2
            )
        }
        let assessment = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2 + pulse,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        ))
        #expect(abs(assessment.severity) < 0.001)
    }

    private func hrSamples(value: Double, source: CNSSignalSource = .polarH10) -> [CNSSignalSample] {
        (0...59).map { ago in
            CNSSignalSample(
                kind: .heartRate, source: source, value: value,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
    }

    @Test("HR onset is baseline-relative: restingHR 62 puts onset at 47")
    func heartRateBaselineRelativeOnset() throws {
        let baselines = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: 62, hrvMean: nil, respiratoryRateMean: nil
        )
        // Onset = 62 − 15 = 47, floor = 40. Value 43.5 → severity 0.5.
        let assessment = CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 43.5),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
    }

    @Test("HR without a baseline uses the default onset at reduced confidence")
    func heartRateDefaultOnset() throws {
        // Onset 50, floor 40. Value 45 → severity 0.5. Confidence carries the
        // missing-baseline factor: Polar fidelity x 1.0 density x the factor.
        let assessment = CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 45),
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
        let expected = thresholds.sourceFidelity(kind: .heartRate, source: .polarH10)
            * 1.0 * thresholds.missingBaselineConfidenceFactor
        #expect(abs(unwrapped.confidence - expected) < 0.001)
    }

    @Test("A low resting-HR baseline scales the floor down — no step at 40 bpm")
    func lowRestingHRScalesFloorDown() throws {
        // Resting HR 50 → onset 35, floor min(40, 30) = 30. A value of 38 is
        // ABOVE this user's personal onset (35) — still normal for them — and
        // must score zero, not the maximal severity the old 40 bpm step gave.
        let baselines = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: 50, hrvMean: nil, respiratoryRateMean: nil
        )
        let aboveOnset = try #require(CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 38),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        ))
        #expect(abs(aboveOnset.severity) < 0.001)
        // Midway down the shifted ramp (32.5 between 35 and 30) → 0.5.
        let midRamp = try #require(CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 32.5),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        ))
        #expect(abs(midRamp.severity - 0.5) < 0.001)
        // At the shifted floor (30) severity saturates.
        let atFloor = try #require(CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 30),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        ))
        #expect(abs(atFloor.severity - 1.0) < 0.001)
    }

    @Test("HRV severity is a fraction-of-baseline collapse ramp")
    func hrvCollapseRamp() throws {
        let baselines = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: nil, hrvMean: 40, respiratoryRateMean: nil
        )
        // 45% of baseline (18ms of 40ms): halfway between onset 0.6 and floor 0.3.
        let samples = (0...59).map { ago in
            CNSSignalSample(
                kind: .hrv, source: .polarH10, value: 18,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .hrv, source: .polarH10, samples: samples,
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
    }

    @Test("HRV without a baseline yields no assessment — a fraction of nothing is meaningless")
    func hrvWithoutBaselineYieldsNil() {
        let samples = (0...59).map { ago in
            CNSSignalSample(
                kind: .hrv, source: .polarH10, value: 18,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .hrv, source: .polarH10, samples: samples,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        #expect(assessment == nil)
    }

    @Test("Same-kind samples from a different source never contaminate the median")
    func differentSourceSamplesExcluded() throws {
        // Healthy EMAY SpO2 stream plus interleaved LOW SpO2 spot-checks
        // attributed to the watch: scoring the EMAY stream must ignore them.
        // (Guards the source clause of the scorer's (kind, source) filter.)
        let emay = spo2Samples(value: 95)
        let watch = (0...59).map { ago in
            CNSSignalSample(
                kind: .spo2, source: .appleWatch, value: 80,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = try #require(CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: emay + watch,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        ))
        #expect(abs(assessment.severity) < 0.001)
    }
}
