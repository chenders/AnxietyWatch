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
        windowDays: Int = Constants.baselineWindowDays,
        anchorDate: Date = .now
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: anchorDate)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap(\.hrvAvg)

        return baseline(from: values)
    }

    /// Compute resting HR baseline.
    static func restingHRBaseline(
        from snapshots: [HealthSnapshot],
        windowDays: Int = Constants.baselineWindowDays,
        anchorDate: Date = .now
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: anchorDate)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap(\.restingHR)

        return baseline(from: values)
    }

    /// Compute sleep duration baseline (in minutes).
    static func sleepBaseline(
        from snapshots: [HealthSnapshot],
        windowDays: Int = Constants.baselineWindowDays,
        anchorDate: Date = .now
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: anchorDate)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap { $0.sleepDurationMin.map(Double.init) }

        return baseline(from: values)
    }

    /// Compute respiratory rate baseline.
    static func respiratoryRateBaseline(
        from snapshots: [HealthSnapshot],
        windowDays: Int = Constants.baselineWindowDays,
        anchorDate: Date = .now
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: anchorDate)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap(\.respiratoryRate)

        return baseline(from: values)
    }

    /// Compute CPAP AHI baseline.
    static func cpapAHIBaseline(
        from snapshots: [HealthSnapshot],
        windowDays: Int = Constants.baselineWindowDays,
        anchorDate: Date = .now
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: anchorDate)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap(\.cpapAHI)

        return baseline(from: values)
    }

    /// Compute barometric pressure baseline.
    static func barometricPressureBaseline(
        from snapshots: [HealthSnapshot],
        windowDays: Int = Constants.baselineWindowDays,
        anchorDate: Date = .now
    ) -> BaselineResult? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: anchorDate)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap(\.barometricPressureAvgKPa)

        return baseline(from: values)
    }

    /// Average of the most recent N days for a given metric.
    static func recentAverage(
        from snapshots: [HealthSnapshot],
        days: Int = 3,
        keyPath: KeyPath<HealthSnapshot, Double?>,
        anchorDate: Date = .now
    ) -> Double? {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -days, to: anchorDate)!
        let cutoff = Calendar.current.startOfDay(for: daysAgo)
        let values = snapshots
            .filter { $0.date >= cutoff }
            .compactMap { $0[keyPath: keyPath] }

        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Check if the 3-day rolling HRV average is below baseline.
    static func isHRVBelowBaseline(snapshots: [HealthSnapshot], anchorDate: Date = .now) -> Bool {
        guard let baseline = hrvBaseline(from: snapshots, anchorDate: anchorDate),
              let recent = recentAverage(from: snapshots, days: 3, keyPath: \.hrvAvg, anchorDate: anchorDate)
        else { return false }

        return recent < baseline.lowerBound
    }

    // MARK: - Private

    /// Minimum data points required for a meaningful baseline. With fewer than 14
    /// days of data, rolling statistics are too noisy to be clinically useful.
    private static let minimumSampleCount = 14

    private static func baseline(from values: [Double]) -> BaselineResult? {
        guard values.count >= minimumSampleCount else { return nil }

        // Trim outliers using median absolute deviation (MAD).
        // The median is robust to the outliers we're trying to remove.
        let sorted = values.sorted()
        let median = sorted.count % 2 == 0
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
            : sorted[sorted.count / 2]
        let absoluteDeviations = values.map { abs($0 - median) }.sorted()
        let mad = absoluteDeviations.count % 2 == 0
            ? (absoluteDeviations[absoluteDeviations.count / 2 - 1] + absoluteDeviations[absoluteDeviations.count / 2]) / 2.0
            : absoluteDeviations[absoluteDeviations.count / 2]

        // 2.5 * MAD * 1.4826 (scale factor for normal distribution equivalence).
        // When MAD is 0 (most values identical), trim values that deviate from the
        // median, which allows removing extreme outliers from a constant cluster.
        let trimThreshold = 2.5 * mad * 1.4826
        let trimmed: [Double]
        if trimThreshold > 0 {
            trimmed = values.filter { abs($0 - median) <= trimThreshold }
        } else {
            // MAD is 0 — keep only values equal to the median if that gives enough samples
            let atMedian = values.filter { $0 == median }
            trimmed = atMedian.count >= minimumSampleCount ? atMedian : values
        }
        // Fall back to untrimmed if too many values were removed
        let effective = trimmed.count >= minimumSampleCount ? trimmed : values

        let mean = effective.reduce(0, +) / Double(effective.count)
        // Sample variance (N-1) for correctness with finite samples
        let variance = effective.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(effective.count - 1)
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
