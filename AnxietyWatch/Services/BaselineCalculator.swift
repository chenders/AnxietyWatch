import Foundation

/// Calculates rolling baselines and flags deviations from personal norms.
enum BaselineCalculator {

    struct BaselineResult {
        let mean: Double
        let standardDeviation: Double
        /// mean - (deviationThreshold * stddev)
        let lowerBound: Double
        let upperBound: Double
    }

    /// Compute HRV baseline from the last `windowDays` of snapshots.
    static func hrvBaseline(
        from snapshots: [HealthSnapshot],
        windowDays: Int = Constants.baselineWindowDays
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap(\.hrvAvg)

        return baseline(from: values)
    }

    /// Compute resting HR baseline.
    static func restingHRBaseline(
        from snapshots: [HealthSnapshot],
        windowDays: Int = Constants.baselineWindowDays
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap(\.restingHR)

        return baseline(from: values)
    }

    /// Average of the most recent N days for a given metric.
    static func recentAverage(
        from snapshots: [HealthSnapshot],
        days: Int = 3,
        keyPath: KeyPath<HealthSnapshot, Double?>
    ) -> Double? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap { $0[keyPath: keyPath] }

        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Check if the 3-day rolling HRV average is below baseline.
    static func isHRVBelowBaseline(snapshots: [HealthSnapshot]) -> Bool {
        guard let baseline = hrvBaseline(from: snapshots),
              let recent = recentAverage(from: snapshots, days: 3, keyPath: \.hrvAvg)
        else { return false }

        return recent < baseline.lowerBound
    }

    // MARK: - Private

    private static func baseline(from values: [Double]) -> BaselineResult? {
        guard values.count >= 3 else { return nil }

        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let stddev = variance.squareRoot()
        let threshold = Constants.deviationThreshold

        return BaselineResult(
            mean: mean,
            standardDeviation: stddev,
            lowerBound: mean - threshold * stddev,
            upperBound: mean + threshold * stddev
        )
    }
}
