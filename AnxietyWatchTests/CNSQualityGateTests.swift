import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the §14.2 rolling-window quality gate: contiguous-coverage,
/// perfusion, and artifact rules. Samples are generated at 1 Hz to mirror
/// the EMAY stream cadence.
struct CNSQualityGateTests {
    private let thresholds = CNSThresholds.standard
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// 1 Hz SpO₂ samples covering `range` (seconds before `now` = t0 + 60).
    private func samples(
        secondsAgo range: ClosedRange<Int>,
        value: Double = 95,
        perfusionIndex: Double? = 1.2,
        isArtifact: Bool = false
    ) -> [CNSSignalSample] {
        range.map { ago in
            CNSSignalSample(
                kind: .spo2, source: .emayOximeter, value: value,
                timestamp: t0.addingTimeInterval(60 - Double(ago)),
                perfusionIndex: perfusionIndex, isArtifact: isArtifact
            )
        }
    }

    private var now: Date { t0.addingTimeInterval(60) }

    @Test("A full 60s of good 1Hz samples passes with full coverage")
    func fullWindowPasses() {
        let verdict = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...59), at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .pass)
        #expect(verdict.goodCoverageFraction > 0.9)
    }

    @Test("A 34s-span contiguous good run clears the 30s coverage bar")
    func contiguousRunAboveBarPasses() {
        let verdict = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...34), at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .pass)
    }

    @Test("40s of good data split into scattered 10s fragments is indeterminate")
    func scatteredFragmentsFail() {
        // Four 10-second runs separated by 5-plus-second holes: total coverage
        // 40s but no contiguous run reaches 30s (spec: "not scattered fragments").
        let fragments = samples(secondsAgo: 0...9) + samples(secondsAgo: 15...24)
            + samples(secondsAgo: 30...39) + samples(secondsAgo: 45...54)
        let verdict = CNSQualityGate.evaluate(
            samples: fragments, at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .indeterminate)
    }

    @Test("Empty window is indeterminate with zero coverage")
    func emptyWindowIndeterminate() {
        let verdict = CNSQualityGate.evaluate(samples: [], at: now, thresholds: thresholds)
        #expect(verdict.quality == .indeterminate)
        #expect(abs(verdict.goodCoverageFraction) < 0.001)
    }

    @Test("Samples older than the window are ignored")
    func staleSamplesExcluded() {
        // A perfect run that ended 2 minutes ago must not pass the gate now.
        let stale = samples(secondsAgo: 120...179)
        let verdict = CNSQualityGate.evaluate(samples: stale, at: now, thresholds: thresholds)
        #expect(verdict.quality == .indeterminate)
    }

    @Test("Contiguity is measured as span: 31 one-Hz samples (30s span) pass, 30 (29s span) do not")
    func contiguitySpanBoundary() {
        // The run length is last-minus-first timestamp (a span), not a sample
        // count: N samples at 1 Hz span N-1 seconds. Pinning both sides of the
        // 30s bar keeps the span semantics from silently changing.
        let exactlyAtBar = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...30), at: now, thresholds: thresholds
        )
        #expect(exactlyAtBar.quality == .pass)
        let justUnderBar = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...29), at: now, thresholds: thresholds
        )
        #expect(justUnderBar.quality == .indeterminate)
    }

    @Test("A sample exactly at the window start is excluded; exactly at now is included")
    func windowEdgeBoundaries() {
        // windowStart = now - 60. The filter is strictly-greater at the start
        // and inclusive at now.
        let atStart = CNSSignalSample(
            kind: .spo2, source: .emayOximeter, value: 95,
            timestamp: now.addingTimeInterval(-60), perfusionIndex: 1.2
        )
        let verdictAtStart = CNSQualityGate.evaluate(
            samples: [atStart], at: now, thresholds: thresholds
        )
        #expect(abs(verdictAtStart.goodCoverageFraction) < 0.001)
        let atNow = CNSSignalSample(
            kind: .spo2, source: .emayOximeter, value: 95,
            timestamp: now, perfusionIndex: 1.2
        )
        let verdictAtNow = CNSQualityGate.evaluate(
            samples: [atNow], at: now, thresholds: thresholds
        )
        #expect(verdictAtNow.goodCoverageFraction > 0)
    }

    @Test("Low-perfusion samples (PI below soft floor) don't count as good")
    func lowPerfusionExcluded() {
        // 60s stream but PI 0.5 throughout: SpO2 overestimates at low
        // perfusion — trusting it is the false-reassurance case.
        let verdict = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...59, perfusionIndex: 0.5),
            at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .indeterminate)
    }

    @Test("Sources without a PI channel are not PI-gated")
    func noPerfusionChannelSkipsPIRules() {
        let watchSamples = (0...59).map { ago in
            CNSSignalSample(
                kind: .heartRate, source: .appleWatch, value: 62,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let verdict = CNSQualityGate.evaluate(
            samples: watchSamples, at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .pass)
    }

    @Test("More than 5% artifact samples makes the window indeterminate")
    func artifactFractionRule() {
        // 56 good + 4 artifact = 6.7% artifacts within the window's samples.
        let mixed = samples(secondsAgo: 0...55) + samples(secondsAgo: 56...59, isArtifact: true)
        let verdict = CNSQualityGate.evaluate(samples: mixed, at: now, thresholds: thresholds)
        #expect(verdict.quality == .indeterminate)
    }

    @Test("At most 5% artifacts still passes")
    func smallArtifactFractionPasses() {
        // 58 good + 2 artifact = 3.3%.
        let mixed = samples(secondsAgo: 0...57) + samples(secondsAgo: 58...59, isArtifact: true)
        let verdict = CNSQualityGate.evaluate(samples: mixed, at: now, thresholds: thresholds)
        #expect(verdict.quality == .pass)
    }

    @Test("Exactly 5% artifacts is the inclusive boundary — still passes")
    func artifactFractionExactBoundaryPasses() {
        // 57 good + 3 artifact = exactly 3/60 = maxArtifactFraction (0.05).
        // The guard is <=, so exactly-at must pass; one more artifact tips it.
        let atBoundary = samples(secondsAgo: 0...56) + samples(secondsAgo: 57...59, isArtifact: true)
        let verdict = CNSQualityGate.evaluate(samples: atBoundary, at: now, thresholds: thresholds)
        #expect(verdict.quality == .pass)
    }
}
