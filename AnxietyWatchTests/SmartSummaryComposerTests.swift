import Foundation
import Testing
@testable import AnxietyWatch

struct SmartSummaryComposerTests {

    private func baseline(mean: Double, sd: Double, lo: Double, hi: Double) -> BaselineCalculator.BaselineResult {
        BaselineCalculator.BaselineResult(mean: mean, standardDeviation: sd, lowerBound: lo, upperBound: hi)
    }

    @Test("All-quiet day returns .quiet")
    func quietDay() {
        let input = SmartSummaryComposer.Input(
            hrv: .init(value: 50, baseline: baseline(mean: 50, sd: 5, lo: 40, hi: 60)),
            restingHR: .init(value: 58, baseline: baseline(mean: 60, sd: 4, lo: 52, hi: 68)),
            sleepEfficiencyPct: 90.0, sleepEfficiencyBaseline: 88,
            ahi: nil, ahiBaseline: nil,
            anxietyLast24h: nil
        )
        #expect(SmartSummaryComposer.compose(input: input).kind == .quiet)
    }

    @Test("One big drop produces a single-clause sentence")
    func oneSignal() {
        let input = SmartSummaryComposer.Input(
            hrv: .init(value: 36, baseline: baseline(mean: 50, sd: 5, lo: 40, hi: 60)),
            restingHR: .init(value: 58, baseline: baseline(mean: 60, sd: 4, lo: 52, hi: 68)),
            sleepEfficiencyPct: 88, sleepEfficiencyBaseline: 88,
            ahi: nil, ahiBaseline: nil,
            anxietyLast24h: nil
        )
        let r = SmartSummaryComposer.compose(input: input)
        #expect(r.kind == .summary)
        #expect(r.text.contains("HRV"))
        #expect(r.text.contains("below"))
    }

    // F-010: a missing metric must produce no candidate at all — the old
    // `?? 0` collapse fabricated a ~-10σ "Resting HR down 60 bpm" headline
    // from a snapshot that simply hadn't recorded resting HR yet.
    @Test("Nil metric values produce no false below-baseline headline")
    func nilMetricsAreSkipped() {
        let input = SmartSummaryComposer.Input(
            hrv: .init(value: nil, baseline: baseline(mean: 50, sd: 5, lo: 40, hi: 60)),
            restingHR: .init(value: nil, baseline: baseline(mean: 60, sd: 4, lo: 52, hi: 68)),
            sleepEfficiencyPct: 88, sleepEfficiencyBaseline: 88,
            ahi: nil, ahiBaseline: nil,
            anxietyLast24h: nil
        )
        let r = SmartSummaryComposer.compose(input: input)
        #expect(r.kind == .quiet)
        #expect(!r.text.contains("HRV"))
        #expect(!r.text.contains("Resting HR"))
    }

    // F-011: nil efficiency (no sleep events last night) must be skipped —
    // the old non-optional input reported a fabricated "0% (typical 88%)".
    @Test("Nil sleep efficiency produces no fabricated 0% clause")
    func nilEfficiencyIsSkipped() {
        let input = SmartSummaryComposer.Input(
            hrv: .init(value: 50, baseline: baseline(mean: 50, sd: 5, lo: 40, hi: 60)),
            restingHR: .init(value: 60, baseline: baseline(mean: 60, sd: 4, lo: 52, hi: 68)),
            sleepEfficiencyPct: nil, sleepEfficiencyBaseline: 88,
            ahi: nil, ahiBaseline: nil,
            anxietyLast24h: nil
        )
        let r = SmartSummaryComposer.compose(input: input)
        #expect(r.kind == .quiet)
        #expect(!r.text.contains("Sleep efficiency"))
    }

    @Test("High anxiety with no z-score breaches and no alerts gets a sentence about the anxiety log")
    func highAnxietyDominantSignal() {
        let input = SmartSummaryComposer.Input(
            hrv: .init(value: 50, baseline: baseline(mean: 50, sd: 5, lo: 40, hi: 60)),
            restingHR: .init(value: 60, baseline: baseline(mean: 60, sd: 4, lo: 52, hi: 68)),
            sleepEfficiencyPct: 88, sleepEfficiencyBaseline: 88,
            ahi: nil, ahiBaseline: nil,
            anxietyLast24h: 7
        )
        let r = SmartSummaryComposer.compose(input: input)
        #expect(r.kind == .summary)
        #expect(r.text.contains("7/10"))
        #expect(!r.text.hasPrefix("."))
    }

    @Test("Picks top 1-3 ranked by |z|, downward-bias")
    func topThreeOrdering() {
        let input = SmartSummaryComposer.Input(
            hrv: .init(value: 35, baseline: baseline(mean: 50, sd: 5, lo: 40, hi: 60)),
            restingHR: .init(value: 68, baseline: baseline(mean: 60, sd: 4, lo: 52, hi: 68)),
            sleepEfficiencyPct: 70, sleepEfficiencyBaseline: 88,
            ahi: nil, ahiBaseline: nil,
            anxietyLast24h: nil
        )
        let r = SmartSummaryComposer.compose(input: input)
        #expect(r.kind == .summary)
        let hrvIdx = r.text.range(of: "HRV")?.lowerBound
        let sleepIdx = r.text.range(of: "leep")?.lowerBound
        #expect(hrvIdx != nil)
        #expect(sleepIdx != nil)
        if let h = hrvIdx, let s = sleepIdx { #expect(h < s) }
    }
}
