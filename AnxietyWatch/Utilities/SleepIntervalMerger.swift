import Foundation

/// Merges overlapping time intervals and returns total non-overlapping duration.
/// Used by HealthKitManager to deduplicate sleep samples from multiple sources.
/// `nonisolated` so HealthKitManager's actor-isolated query methods can call
/// `mergedMinutes` directly without a main-actor hop.
nonisolated enum SleepIntervalMerger {

    /// Returns total minutes covered by the given intervals after merging overlaps.
    static func mergedMinutes(_ intervals: [(Date, Date)]) -> Int {
        guard !intervals.isEmpty else { return 0 }

        let sorted = intervals.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = [sorted[0]]

        for interval in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.0 <= last.1 {
                // Overlapping or adjacent — extend the current interval
                merged[merged.count - 1] = (last.0, max(last.1, interval.1))
            } else {
                merged.append(interval)
            }
        }

        // Sum seconds across all merged intervals first, then convert once.
        // Per-interval Int truncation would undercount fragmented short
        // intervals (two 40-second runs would each truncate to 0 minutes
        // even though their total is 80 seconds).
        let totalSeconds = merged.reduce(0.0) { total, interval in
            total + interval.1.timeIntervalSince(interval.0)
        }
        return Int(totalSeconds / 60)
    }

    /// Coalesce intervals that overlap or are separated by a gap no greater than
    /// `gapTolerance` (default 5 minutes). Used by `DashboardView` to collapse
    /// many per-stage `SleepStageEvent` rows into a small number of contiguous
    /// asleep windows before passing them to `GlucoseDetailView` — the chart
    /// overlay renders one `RectangleMark` per interval, so per-stage
    /// granularity (often dozens per night) is wasted work.
    static func coalesce(
        _ intervals: [(start: Date, end: Date)],
        gapTolerance: TimeInterval = 5 * 60
    ) -> [(start: Date, end: Date)] {
        guard !intervals.isEmpty else { return [] }

        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = [sorted[0]]

        for interval in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            // Treat as adjacent if the gap from the last end to this start is
            // within tolerance. Negative gaps (overlap) always merge.
            if interval.start.timeIntervalSince(last.end) <= gapTolerance {
                merged[merged.count - 1] = (last.start, max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
