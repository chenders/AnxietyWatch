import Foundation

/// Merges overlapping time intervals and returns total non-overlapping duration.
/// Used by HealthKitManager to deduplicate sleep samples from multiple sources.
enum SleepIntervalMerger {

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

        return merged.reduce(0) { total, interval in
            total + Int(interval.1.timeIntervalSince(interval.0) / 60)
        }
    }
}
