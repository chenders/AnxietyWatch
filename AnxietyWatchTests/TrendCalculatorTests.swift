import Foundation
import Testing

@testable import AnxietyWatch

struct TrendCalculatorTests {

    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSamples(_ values: [(minutesAgo: Int, value: Double)]) -> [HealthSample] {
        values.map { pair in
            HealthSample(
                type: "hr",
                value: pair.value,
                timestamp: baseTime.addingTimeInterval(-Double(pair.minutesAgo) * 60)
            )
        }
    }

    @Test("Returns nil with no samples")
    func noSamples() {
        let result = TrendCalculator.direction(samples: [], threshold: 3)
        #expect(result == nil)
    }

    @Test("Returns nil with only one sample")
    func singleSample() {
        let samples = makeSamples([(0, 72)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3)
        #expect(result == nil)
    }

    @Test("Stable when latest is within threshold of 1h average")
    func stableWithinThreshold() {
        let samples = makeSamples([(0, 72), (10, 71), (20, 70), (40, 72)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3)
        #expect(result == .stable)
    }

    @Test("Rising when latest exceeds 1h average plus threshold")
    func risingAboveThreshold() {
        let samples = makeSamples([(0, 80), (10, 70), (20, 70), (40, 70)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3)
        #expect(result == .rising)
    }

    @Test("Dropping when latest is below 1h average minus threshold")
    func droppingBelowThreshold() {
        let samples = makeSamples([(0, 70), (10, 80), (20, 80), (40, 80)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3)
        #expect(result == .dropping)
    }

    @Test("Only considers samples within the last hour for average")
    func ignoresOlderThanOneHour() {
        let samples = makeSamples([(0, 72), (10, 70), (20, 70), (90, 90), (120, 90)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3)
        #expect(result == .stable)
    }
}
