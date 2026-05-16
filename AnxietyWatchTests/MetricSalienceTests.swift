import Foundation
import Testing
@testable import AnxietyWatch

struct MetricSalienceTests {

    @Test("VO2 Max with no baseline: surfaces (insufficient data is itself notable)")
    func vo2NoBaseline() {
        let v = MetricSalience.vo2MaxVerdict(latest: 39.0, baseline90d: nil)
        #expect(v == .surface)
    }

    @Test("VO2 Max with >10% drop from 90-day baseline: surfaces")
    func vo2BigDrop() {
        let v = MetricSalience.vo2MaxVerdict(latest: 35.0, baseline90d: 40.0)
        #expect(v == .surface)
    }

    @Test("VO2 Max within 10%: demoted")
    func vo2Stable() {
        let v = MetricSalience.vo2MaxVerdict(latest: 38.5, baseline90d: 40.0)
        #expect(v == .demote)
    }

    @Test("Walking HR > baseline + 1σ: surfaces")
    func walkingHRHigh() {
        let v = MetricSalience.walkingHRVerdict(
            recentAvg: 115,
            baselineMean: 100, baselineSD: 8
        )
        #expect(v == .surface)
    }

    @Test("AFib burden 0%: demoted")
    func afibZero() {
        #expect(MetricSalience.afibBurdenVerdict(burden: 0, weekDelta: 0) == .demote)
    }

    @Test("AFib burden any nonzero: surfaces")
    func afibNonzero() {
        #expect(MetricSalience.afibBurdenVerdict(burden: 0.005, weekDelta: 0) == .surface)
    }

    @Test("Barometric: 24h drop > 0.5 kPa surfaces")
    func baroDrop() {
        #expect(MetricSalience.barometricVerdict(deltaKPa24h: -0.7) == .surface)
        #expect(MetricSalience.barometricVerdict(deltaKPa24h: -0.3) == .demote)
    }
}
