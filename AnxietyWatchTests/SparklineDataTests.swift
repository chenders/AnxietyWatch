import Foundation
import Testing

@testable import AnxietyWatch

struct SparklineDataTests {

    private let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    private func makeSamples(_ minuteValuePairs: [(Int, Double)]) -> [HealthSample] {
        minuteValuePairs.map { (minutesSinceMidnight, value) in
            HealthSample(
                type: "hr",
                value: value,
                timestamp: midnight.addingTimeInterval(Double(minutesSinceMidnight) * 60)
            )
        }
    }

    @Test("Points are normalized to 0-1 on both axes")
    func normalizesPoints() {
        let samples = makeSamples([(0, 60), (720, 80)]) // midnight and noon
        let now = midnight.addingTimeInterval(720 * 60) // noon
        let result = SparklineData.points(from: samples, midnight: midnight, now: now)

        #expect(result.count == 2)
        #expect(abs(result[0].x - 0.0) < 0.01)
        #expect(abs(result[0].y - 1.0) < 0.01) // 60 is min → y=1 (inverted)
        #expect(abs(result[1].x - 1.0) < 0.01)
        #expect(abs(result[1].y - 0.0) < 0.01) // 80 is max → y=0 (inverted)
    }

    @Test("Returns empty for no samples")
    func emptyForNoSamples() {
        let result = SparklineData.points(from: [], midnight: midnight, now: midnight)
        #expect(result.isEmpty)
    }

    @Test("Single sample returns one point")
    func singleSample() {
        let samples = makeSamples([(360, 70)]) // 6 AM
        let now = midnight.addingTimeInterval(720 * 60)
        let result = SparklineData.points(from: samples, midnight: midnight, now: now)
        #expect(result.count == 1)
        #expect(abs(result[0].x - 0.5) < 0.01) // 6 AM is 50% of midnight-to-noon
    }

    @Test("Gap segments split at 2-hour gaps")
    func detectsGaps() {
        let samples = makeSamples([(60, 70), (70, 71), (360, 72), (370, 73)])
        let now = midnight.addingTimeInterval(720 * 60)
        let segments = SparklineData.segments(from: samples, midnight: midnight, now: now, gapThresholdMinutes: 120)
        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 2)
    }

    @Test("No gap when readings are close together")
    func noGapWhenClose() {
        let samples = makeSamples([(60, 70), (90, 71), (120, 72)])
        let now = midnight.addingTimeInterval(720 * 60)
        let segments = SparklineData.segments(from: samples, midnight: midnight, now: now, gapThresholdMinutes: 120)
        #expect(segments.count == 1)
        #expect(segments[0].count == 3)
    }
}
