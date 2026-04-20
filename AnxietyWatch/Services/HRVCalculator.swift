// AnxietyWatch/Services/HRVCalculator.swift
import Foundation
import Accelerate

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

    struct FrequencyDomainResult {
        let lfPower: Double     // 0.04–0.15 Hz (sympathetic + parasympathetic)
        let hfPower: Double     // 0.15–0.40 Hz (parasympathetic / respiratory)
        let lfHfRatio: Double   // Sympathovagal balance
        let totalPower: Double  // LF + HF
    }

    /// Compute frequency-domain HRV via Welch's method.
    /// Resamples irregular RR intervals to 4Hz, applies FFT, integrates LF/HF bands.
    /// Requires >= 30 RR intervals for meaningful spectral analysis.
    static func frequencyDomain(rrIntervals: [Double]) -> FrequencyDomainResult? {
        guard rrIntervals.count >= 30 else { return nil }

        guard var resampled = resampleRRIntervals(rrIntervals, targetRateHz: 4.0),
              resampled.count >= 16 else { return nil }

        // Detrend: remove mean so DC doesn't dominate spectrum
        let mean = resampled.reduce(0, +) / Float(resampled.count)
        resampled = resampled.map { $0 - mean }

        guard let psd = SpectralAnalyzer.computePSD(
            signal: resampled, sampleRate: 4.0
        ) else { return nil }

        let lf = Double(SpectralAnalyzer.bandPower(psd, lowHz: 0.04, highHz: 0.15))
        let hf = Double(SpectralAnalyzer.bandPower(psd, lowHz: 0.15, highHz: 0.40))
        let ratio = hf > 0 ? lf / hf : 0

        return FrequencyDomainResult(
            lfPower: lf,
            hfPower: hf,
            lfHfRatio: ratio,
            totalPower: lf + hf
        )
    }

    /// Resample irregularly-spaced RR intervals to a uniform time series.
    /// Uses linear interpolation on the tachogram (cumulative time → RR value).
    /// Returns nil if total duration is too short for meaningful resampling.
    static func resampleRRIntervals(
        _ rrIntervals: [Double],
        targetRateHz: Double
    ) -> [Float]? {
        guard rrIntervals.count >= 3 else { return nil }

        // Build tachogram: cumulative time (ms) of each R-peak
        var cumulativeTime = [Double](repeating: 0, count: rrIntervals.count)
        for i in 1..<rrIntervals.count {
            cumulativeTime[i] = cumulativeTime[i - 1] + rrIntervals[i - 1]
        }
        let totalDurationMs = cumulativeTime.last! + rrIntervals.last!

        // Uniform resample at targetRateHz
        let resampleIntervalMs = 1000.0 / targetRateHz
        let sampleCount = Int(totalDurationMs / resampleIntervalMs)
        guard sampleCount >= 16 else { return nil }

        var resampled = [Float](repeating: 0, count: sampleCount)
        var srcIdx = 0

        for i in 0..<sampleCount {
            let t = Double(i) * resampleIntervalMs
            // Advance source index to bracket time t
            while srcIdx < cumulativeTime.count - 1 && cumulativeTime[srcIdx + 1] <= t {
                srcIdx += 1
            }
            if srcIdx >= cumulativeTime.count - 1 {
                resampled[i] = Float(rrIntervals.last!)
            } else {
                // Linear interpolation between adjacent RR values
                let t0 = cumulativeTime[srcIdx]
                let t1 = cumulativeTime[srcIdx + 1]
                let v0 = rrIntervals[srcIdx]
                let v1 = rrIntervals[srcIdx + 1]
                let frac = (t - t0) / (t1 - t0)
                resampled[i] = Float(v0 + frac * (v1 - v0))
            }
        }

        return resampled
    }
}
