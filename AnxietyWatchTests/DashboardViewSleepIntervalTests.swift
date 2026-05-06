import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for `SleepIntervalMerger.coalesce`, the helper backing
/// `DashboardView.sleepIntervalsFromEvents`. Per-stage `SleepStageEvent`
/// rows produce dozens of tiny `RectangleMark`s in the glucose chart's
/// sleep overlay; coalescing into contiguous asleep windows keeps the
/// chart's per-render cost bounded.
@Suite("SleepIntervalMerger.coalesce")
struct DashboardViewSleepIntervalTests {

    @Test("Empty input returns empty")
    func emptyInput() {
        let merged = SleepIntervalMerger.coalesce([])
        #expect(merged.isEmpty)
    }

    @Test("Two non-overlapping intervals stay separate")
    func nonOverlappingStaysSeparate() {
        // Gap of 30 minutes — well beyond the 5-minute tolerance.
        let a = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T01:00:00"))
        let b = (start: d("2026-06-16T01:30:00"), end: d("2026-06-16T03:00:00"))

        let merged = SleepIntervalMerger.coalesce([a, b])

        #expect(merged.count == 2)
        #expect(merged[0].start == a.start)
        #expect(merged[0].end == a.end)
        #expect(merged[1].start == b.start)
        #expect(merged[1].end == b.end)
    }

    @Test("Two overlapping intervals merge into one")
    func overlappingMerges() {
        let a = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T03:00:00"))
        let b = (start: d("2026-06-16T02:00:00"), end: d("2026-06-16T07:00:00"))

        let merged = SleepIntervalMerger.coalesce([a, b])

        #expect(merged.count == 1)
        #expect(merged[0].start == a.start)
        #expect(merged[0].end == b.end)
    }

    @Test("Adjacent intervals within 5-minute gap merge")
    func adjacentWithinToleranceMerges() {
        // Gap of 4 minutes — under the 5-minute default tolerance, e.g. a
        // single brief stage transition between asleepCore and asleepDeep.
        let a = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T01:00:00"))
        let b = (start: d("2026-06-16T01:04:00"), end: d("2026-06-16T03:00:00"))

        let merged = SleepIntervalMerger.coalesce([a, b])

        #expect(merged.count == 1)
        #expect(merged[0].start == a.start)
        #expect(merged[0].end == b.end)
    }

    @Test("Gap exactly at threshold (5 min) merges")
    func gapAtThresholdMerges() {
        // Tolerance is inclusive (`<=`).
        let a = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T01:00:00"))
        let b = (start: d("2026-06-16T01:05:00"), end: d("2026-06-16T03:00:00"))

        let merged = SleepIntervalMerger.coalesce([a, b])

        #expect(merged.count == 1)
        #expect(merged[0].end == b.end)
    }

    @Test("Gap just over threshold stays separate")
    func gapJustOverThresholdStaysSeparate() {
        // 5 minutes 1 second — beyond tolerance.
        let a = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T01:00:00"))
        let b = (start: d("2026-06-16T01:05:01"), end: d("2026-06-16T03:00:00"))

        let merged = SleepIntervalMerger.coalesce([a, b])

        #expect(merged.count == 2)
    }

    @Test("Already-merged single interval stays untouched")
    func alreadyMergedStaysUntouched() {
        // A single contiguous interval — no other input to merge with.
        let only = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T07:00:00"))

        let merged = SleepIntervalMerger.coalesce([only])

        #expect(merged.count == 1)
        #expect(merged[0].start == only.start)
        #expect(merged[0].end == only.end)
    }

    @Test("Out-of-order input is sorted before coalescing")
    func unsortedInputIsSorted() {
        // Pass intervals in reverse order. The helper must sort first; if it
        // didn't, the later interval would land in the output before the
        // earlier one and they wouldn't merge.
        let a = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T01:00:00"))
        let b = (start: d("2026-06-16T01:02:00"), end: d("2026-06-16T03:00:00"))

        let merged = SleepIntervalMerger.coalesce([b, a])

        #expect(merged.count == 1)
        #expect(merged[0].start == a.start)
        #expect(merged[0].end == b.end)
    }

    @Test("Three per-stage events from one night collapse into one window")
    func realisticPerStageNightCollapses() {
        // Mirrors the production case the fix addresses: HealthKit hands back
        // separate samples per asleep* stage; without coalescing the overlay
        // renders three rectangles instead of one.
        let core = (start: d("2026-06-15T23:00:00"), end: d("2026-06-16T01:30:00"))
        let deep = (start: d("2026-06-16T01:30:00"), end: d("2026-06-16T03:15:00"))
        let rem = (start: d("2026-06-16T03:15:00"), end: d("2026-06-16T07:00:00"))

        let merged = SleepIntervalMerger.coalesce([core, deep, rem])

        #expect(merged.count == 1)
        #expect(merged[0].start == core.start)
        #expect(merged[0].end == rem.end)
    }

    private func d(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso + "Z")!
    }
}
