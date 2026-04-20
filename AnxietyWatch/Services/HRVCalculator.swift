// AnxietyWatch/Services/HRVCalculator.swift
import Foundation

/// Computes heart rate variability metrics from RR intervals.
/// Pure computation — no hardware dependencies.
enum HRVCalculator {

    struct TimeDomainResult {
        let rmssd: Double       // Root mean square of successive differences (ms)
        let sdnn: Double        // Standard deviation of NN intervals (ms)
        let pnn50: Double       // % of successive diffs > 50ms
        let meanRR: Double      // Mean RR interval (ms)
        let count: Int          // Number of RR intervals used
    }

    /// Compute time-domain HRV from RR intervals in milliseconds.
    /// Returns nil if fewer than 2 intervals.
    static func timeDomain(rrIntervals: [Double]) -> TimeDomainResult? {
        guard rrIntervals.count >= 2 else { return nil }

        let n = Double(rrIntervals.count)
        let mean = rrIntervals.reduce(0, +) / n

        // SDNN: sample standard deviation of all NN intervals
        let variance = rrIntervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        let sdnn = sqrt(variance)

        // Successive differences: RR[i+1] - RR[i]
        let diffs = zip(rrIntervals.dropFirst(), rrIntervals).map { $0 - $1 }

        // RMSSD: root mean square of successive differences
        let sumSquaredDiffs = diffs.reduce(0) { $0 + $1 * $1 }
        let rmssd = sqrt(sumSquaredDiffs / Double(diffs.count))

        // pNN50: percentage of successive diffs whose absolute value exceeds 50ms
        let nn50Count = diffs.filter { abs($0) > 50.0 }.count
        let pnn50 = Double(nn50Count) / Double(diffs.count) * 100.0

        return TimeDomainResult(
            rmssd: rmssd,
            sdnn: sdnn,
            pnn50: pnn50,
            meanRR: mean,
            count: rrIntervals.count
        )
    }
}
