import Foundation
import Testing

@testable import AnxietyWatch

struct SleepDeduplicationTests {

    @Test("Non-overlapping intervals are summed directly")
    func nonOverlapping() {
        let intervals: [(Date, Date)] = [
            (d("2026-06-15T23:00:00"), d("2026-06-16T01:00:00")),  // 120 min
            (d("2026-06-16T02:00:00"), d("2026-06-16T04:00:00")),  // 120 min
        ]
        #expect(SleepIntervalMerger.mergedMinutes(intervals) == 240)
    }

    @Test("Fully overlapping intervals are deduplicated")
    func fullyOverlapping() {
        let intervals: [(Date, Date)] = [
            (d("2026-06-15T23:00:00"), d("2026-06-16T07:00:00")),  // 480 min
            (d("2026-06-16T00:00:00"), d("2026-06-16T06:00:00")),  // 360 min (subset)
        ]
        #expect(SleepIntervalMerger.mergedMinutes(intervals) == 480)
    }

    @Test("Partially overlapping intervals are merged")
    func partiallyOverlapping() {
        // 23:00–03:00 (240 min) + 02:00–07:00 (300 min) → 23:00–07:00 (480 min)
        let intervals: [(Date, Date)] = [
            (d("2026-06-15T23:00:00"), d("2026-06-16T03:00:00")),
            (d("2026-06-16T02:00:00"), d("2026-06-16T07:00:00")),
        ]
        #expect(SleepIntervalMerger.mergedMinutes(intervals) == 480)
    }

    @Test("Empty intervals return zero")
    func emptyIntervals() {
        #expect(SleepIntervalMerger.mergedMinutes([]) == 0)
    }

    @Test("Single interval returns its duration")
    func singleInterval() {
        let intervals: [(Date, Date)] = [
            (d("2026-06-15T23:00:00"), d("2026-06-16T07:00:00")),
        ]
        #expect(SleepIntervalMerger.mergedMinutes(intervals) == 480)
    }

    @Test("Three overlapping intervals merge correctly")
    func threeOverlapping() {
        // A: 23:00–02:00, B: 01:00–05:00, C: 04:00–07:00 → 23:00–07:00 = 480
        let intervals: [(Date, Date)] = [
            (d("2026-06-15T23:00:00"), d("2026-06-16T02:00:00")),
            (d("2026-06-16T01:00:00"), d("2026-06-16T05:00:00")),
            (d("2026-06-16T04:00:00"), d("2026-06-16T07:00:00")),
        ]
        #expect(SleepIntervalMerger.mergedMinutes(intervals) == 480)
    }

    @Test("Adjacent intervals (no gap) are merged")
    func adjacent() {
        let intervals: [(Date, Date)] = [
            (d("2026-06-15T23:00:00"), d("2026-06-16T03:00:00")),
            (d("2026-06-16T03:00:00"), d("2026-06-16T07:00:00")),
        ]
        #expect(SleepIntervalMerger.mergedMinutes(intervals) == 480)
    }

    private func d(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso + "Z")!
    }
}
