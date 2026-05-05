import Foundation
import Testing

@testable import AnxietyWatch

struct StatisticsTests {
    @Test("stdDev nil for empty")
    func stdDevEmpty() {
        #expect(Statistics.stdDev([]) == nil)
    }

    @Test("stdDev zero for single value")
    func stdDevSingle() {
        #expect(Statistics.stdDev([100.0]) == 0.0)
    }

    @Test("stdDev computes population SD for multi-value")
    func stdDevMulti() {
        // [100, 110, 120] — mean=110, variance=200/3, SD≈8.165
        let result = Statistics.stdDev([100, 110, 120])!
        #expect(abs(result - 8.165) < 0.01)
    }

    @Test("CV returns SD/mean*100")
    func cvBasic() {
        // [100, 110, 120] — SD≈8.165, mean=110, CV≈7.42%
        let result = Statistics.coefficientOfVariation([100, 110, 120])!
        #expect(abs(result - 7.42) < 0.05)
    }

    @Test("CV nil for empty")
    func cvEmpty() {
        #expect(Statistics.coefficientOfVariation([]) == nil)
    }

    @Test("CV nil when mean is zero")
    func cvZeroMean() {
        #expect(Statistics.coefficientOfVariation([0.0, 0.0]) == nil)
    }

    @Test("timeBelowThresholdMinutes is 0 for empty")
    func t90Empty() {
        #expect(Statistics.timeBelowThresholdMinutes([], threshold: 0.90) == 0)
    }

    @Test("timeBelowThresholdMinutes sums durations under threshold")
    func t90Mixed() {
        let base = Date()
        let samples = [
            QuantitySample(start: base, end: base.addingTimeInterval(60), value: 0.85),
            QuantitySample(start: base.addingTimeInterval(60), end: base.addingTimeInterval(120), value: 0.92),
            QuantitySample(start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), value: 0.88),
        ]
        // Below 0.90: indices 0 and 2 = 60s + 60s = 120s = 2 min
        #expect(Statistics.timeBelowThresholdMinutes(samples, threshold: 0.90) == 2)
    }

    @Test("countDesatEvents is 0 with no drops")
    func desatNone() {
        let base = Date()
        let samples = (0..<10).map { i in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 5),
                end: base.addingTimeInterval(Double(i + 1) * 5),
                value: 0.97
            )
        }
        #expect(Statistics.countDesatEvents(samples, dropThreshold: 0.04, recoveryThreshold: 0.02) == 0)
    }

    @Test("countDesatEvents counts a single drop with recovery")
    func desatSingle() {
        // Baseline 0.97, drop to 0.92 (5%), recover above 0.95
        let values: [Double] = [0.97, 0.97, 0.97, 0.97, 0.97, 0.92, 0.93, 0.96, 0.97, 0.97]
        let base = Date()
        let samples = values.enumerated().map { i, v in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 5),
                end: base.addingTimeInterval(Double(i + 1) * 5),
                value: v
            )
        }
        #expect(Statistics.countDesatEvents(samples, dropThreshold: 0.04, recoveryThreshold: 0.02) == 1)
    }

    @Test("timeBelowThresholdMinutes sums fractional intervals before truncating to minutes")
    func t90FragmentedShortIntervals() {
        // Two non-overlapping 40-second below-threshold runs = 80s total.
        // Naive per-interval Int truncation would return 0 (each 40s → 0 min);
        // correct behavior sums seconds first, then divides → 1 min.
        let base = Date()
        let samples = [
            QuantitySample(start: base, end: base.addingTimeInterval(40), value: 0.85),
            QuantitySample(start: base.addingTimeInterval(60), end: base.addingTimeInterval(100), value: 0.86),
        ]
        #expect(Statistics.timeBelowThresholdMinutes(samples, threshold: 0.90) == 1)
    }

    @Test("timeBelowThresholdMinutes merges overlapping samples from multiple sources")
    func t90MergesOverlaps() {
        // Two HealthKit sources both reporting low SpO2 over the same interval.
        // Without merging, the duration would be double-counted.
        let base = Date()
        let watchInterval = QuantitySample(
            start: base, end: base.addingTimeInterval(120), value: 0.85)
        let ringInterval = QuantitySample(
            start: base.addingTimeInterval(60), end: base.addingTimeInterval(180), value: 0.86)
        // Merged span: [0, 180s] = 3 minutes (not 4 = 2 + 2)
        #expect(Statistics.timeBelowThresholdMinutes([watchInterval, ringInterval], threshold: 0.90) == 3)
    }

    @Test("countDesatEvents collapses cross-source overlap as a single event")
    func desatCollapsesCrossSourceOverlap() {
        // Simulates Watch + Ring writing SpO2 to HealthKit during the same
        // physiologic desat with offset recovery. Without overlap collapsing,
        // the early recovery from one source clears `inEvent` and the
        // still-low samples from the other source re-trigger a second event
        // for the same dip.
        let base = Date()
        let timed: [(TimeInterval, Double)] = [
            (0, 0.97),     // Watch baseline
            (60, 0.92),    // Watch dip
            (90, 0.92),    // Ring still low
            (120, 0.97),   // Watch recovery
            (120, 0.92),   // Ring still low (overlaps Watch recovery in time)
            (180, 0.97),   // Ring recovery
        ]
        let samples = timed.map { offset, v in
            QuantitySample(
                start: base.addingTimeInterval(offset),
                end: base.addingTimeInterval(offset + 5),
                value: v
            )
        }
        #expect(Statistics.countDesatEvents(
            samples, dropThreshold: 0.04, recoveryThreshold: 0.02) == 1)
    }

    @Test("collapseOverlaps produces piecewise-constant intervals using min over active samples")
    func collapseOverlapsBasic() {
        // Sample A spans 0–60 at 0.97. Sample B spans 30–90 at 0.92.
        // Sample C spans 120–150 at 0.95 (no overlap with A or B).
        // Expected piecewise output:
        //   0–30 only A active → 0.97
        //   30–60 both active → min = 0.92
        //   60–90 only B active → 0.92  (coalesces with prior interval)
        //   120–150 only C active → 0.95
        let base = Date()
        let samples = [
            QuantitySample(start: base, end: base.addingTimeInterval(60), value: 0.97),
            QuantitySample(start: base.addingTimeInterval(30), end: base.addingTimeInterval(90), value: 0.92),
            QuantitySample(start: base.addingTimeInterval(120), end: base.addingTimeInterval(150), value: 0.95),
        ]
        let merged = Statistics.collapseOverlaps(samples)
        #expect(merged.count == 3)
        #expect(merged[0].value == 0.97)
        #expect(merged[0].start == base)
        #expect(merged[0].end == base.addingTimeInterval(30))
        #expect(merged[1].value == 0.92)
        #expect(merged[1].start == base.addingTimeInterval(30))
        #expect(merged[1].end == base.addingTimeInterval(90))
        #expect(merged[2].value == 0.95)
        #expect(merged[2].start == base.addingTimeInterval(120))
        #expect(merged[2].end == base.addingTimeInterval(150))
    }

    @Test("collapseOverlaps preserves drop transition with partial overlap")
    func collapseOverlapsPreservesDrop() {
        // The Copilot scenario: 0.97 sample from 0–7200s overlapping 0.92
        // sample from 3600–10800s. The earlier "union-min" code collapsed
        // this to a single (0–10800, 0.92) interval, losing the drop. The
        // sweep-line version should preserve a 0.97 interval before the
        // drop so countDesatEvents still sees the transition.
        let base = Date()
        let samples = [
            QuantitySample(start: base, end: base.addingTimeInterval(7200), value: 0.97),
            QuantitySample(start: base.addingTimeInterval(3600), end: base.addingTimeInterval(10800), value: 0.92),
        ]
        let merged = Statistics.collapseOverlaps(samples)
        #expect(merged.count == 2)
        #expect(merged[0].value == 0.97)
        #expect(merged[0].end == base.addingTimeInterval(3600))
        #expect(merged[1].value == 0.92)
        #expect(merged[1].end == base.addingTimeInterval(10800))
    }

    @Test("countDesatEvents respects baselineWindowSeconds parameter")
    func desatBaselineWindow() {
        // Three 1-second samples spaced 60s apart at 0.97 → 0.93 → 0.89.
        // With a wide window the prior samples remain in the lookback so
        // the 0.97 baseline catches the first drop. With a 10s window each
        // prior sample's end (≈sample start + 1s) is well before the next
        // sample's lookback cutoff, so the baseline collapses to the
        // current value and no event fires.
        let base = Date()
        let values: [Double] = [0.97, 0.93, 0.89]
        let samples = values.enumerated().map { i, v in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 60),
                end: base.addingTimeInterval(Double(i) * 60 + 1),
                value: v
            )
        }
        #expect(Statistics.countDesatEvents(
            samples, dropThreshold: 0.04, recoveryThreshold: 0.02,
            baselineWindowSeconds: 300) == 1)
        #expect(Statistics.countDesatEvents(
            samples, dropThreshold: 0.04, recoveryThreshold: 0.02,
            baselineWindowSeconds: 10) == 0)
    }

    @Test("countDesatEvents detects drop after a long high-baseline segment")
    func desatLongHighBaseline() {
        // 5-hour 0.97 segment followed by a 0.92 sample. Eviction must use
        // end-time, not start-time — otherwise the long segment's start
        // ages out of the 120s lookback window long before the segment
        // itself ends, and the desat would be missed.
        let base = Date()
        let samples = [
            QuantitySample(
                start: base,
                end: base.addingTimeInterval(18_000),
                value: 0.97
            ),
            QuantitySample(
                start: base.addingTimeInterval(18_000),
                end: base.addingTimeInterval(18_001),
                value: 0.92
            ),
        ]
        #expect(Statistics.countDesatEvents(
            samples, dropThreshold: 0.04, recoveryThreshold: 0.02
        ) == 1)
    }

    @Test("countDesatEvents counts two drops separated by recovery")
    func desatTwo() {
        let values: [Double] = Array(repeating: 0.97, count: 5)
            + [0.92, 0.93, 0.96, 0.97]
            + [0.91, 0.93, 0.97]
        let base = Date()
        let samples = values.enumerated().map { i, v in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 5),
                end: base.addingTimeInterval(Double(i + 1) * 5),
                value: v
            )
        }
        #expect(Statistics.countDesatEvents(samples, dropThreshold: 0.04, recoveryThreshold: 0.02) == 2)
    }
}
