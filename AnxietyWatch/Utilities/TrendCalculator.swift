import Foundation

/// Computes trend direction by comparing the latest reading to the
/// 1-hour rolling average of prior readings.
enum TrendCalculator {

    enum Direction: String {
        case rising
        case stable
        case dropping

        var symbol: String {
            switch self {
            case .rising: "↗"
            case .stable: "→"
            case .dropping: "↘"
            }
        }

        var label: String {
            switch self {
            case .rising: "rising"
            case .stable: "stable"
            case .dropping: "dropping"
            }
        }
    }

    /// Returns the trend direction for a set of samples.
    /// Samples must be sorted by timestamp (any order — we sort internally).
    /// Returns nil if fewer than 2 samples.
    static func direction(
        samples: [HealthSample],
        threshold: Double,
        now: Date = .now
    ) -> Direction? {
        guard samples.count >= 2 else { return nil }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let latest = sorted.last!

        // Compute average of samples in the last hour, excluding the latest
        let oneHourAgo = now.addingTimeInterval(-3600)
        let priorInWindow = sorted.dropLast().filter { $0.timestamp >= oneHourAgo }

        guard !priorInWindow.isEmpty else { return nil }

        let avg = priorInWindow.map(\.value).reduce(0, +) / Double(priorInWindow.count)

        if latest.value > avg + threshold {
            return .rising
        } else if latest.value < avg - threshold {
            return .dropping
        } else {
            return .stable
        }
    }
}
