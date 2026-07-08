// AnxietyWatch/Services/RRArchiveAggregator.swift
import Foundation

/// Pure helpers that turn one or more `.rr` archive files into the per-minute
/// HR series and awake-interval count consumed by `PolarSessionHRDetailView`.
///
/// No SwiftUI, SwiftData, or HealthKit imports. The view layer is responsible
/// for resolving `SensorSession` IDs to `RRArchiveWriter.archiveURL(...)` and
/// for filtering `SourcedSleepStageEvent`s down to the `.awake` stage before
/// calling `awakeIntervalCount` — that keeps this type unit-testable from
/// fixture files alone.
enum RRArchiveAggregator {

    /// One point in the per-minute HR series. `bpm == nil` marks a gap
    /// (either BLE was disconnected, the minute had no in-range RR, or the
    /// pre-clip rejected the mean as a physiologically-implausible artifact).
    /// Callers MUST derive `id` deterministically from `timestamp` (so Swift
    /// Charts doesn't re-animate identical input across renders). The
    /// `perMinuteHR` aggregator does this; ad-hoc construction does not
    /// enforce it.
    struct HRMinutePoint: Identifiable, Equatable, Sendable {
        let id: UUID
        let timestamp: Date
        let bpm: Double?
    }

    // MARK: - Constants

    /// Inclusive RR range we trust as physiological. Outside this we drop
    /// the RR from per-minute aggregation (artifact, ectopic, or PPG noise).
    /// Delegates to the shared `HRVCalculator.physiologicalRRRangeMs`
    /// (250 ms → 240 bpm, 2000 ms → 30 bpm) so the HR detail chart excludes
    /// exactly the same artifact set as the tick filter, session recovery,
    /// and archive record counting.
    nonisolated static let rrLowerMs: Double = HRVCalculator.physiologicalRRRangeMs.lowerBound
    nonisolated static let rrUpperMs: Double = HRVCalculator.physiologicalRRRangeMs.upperBound

    /// Pre-clip on the bucketed BPM mean to defend against a freak cluster
    /// of in-range RR (still possible during PPG dropout reconnects). We
    /// emit `nil` rather than render a 250+ BPM spike that would compress
    /// the rest of the chart's y-axis.
    nonisolated static let bpmLowerBound: Double = 30
    nonisolated static let bpmUpperBound: Double = 220

    // MARK: - Public API

    /// Read each `.rr` archive synchronously, bucket all in-window RR
    /// samples into per-minute mean BPM, and emit one `HRMinutePoint` per
    /// minute spanning `window`. Buckets cover `[bucketStart, bucketEnd)`
    /// (half-open). Bucket count is computed with a ceiling so a session
    /// whose duration isn't an exact multiple of 60s gets a trailing
    /// partial-minute bucket rather than silently dropping its tail. A
    /// sample at exactly `window.upperBound` still falls outside all
    /// generated buckets (at most one beat). Performs file I/O; call from
    /// a background task.
    nonisolated static func perMinuteHR(
        rrFiles: [URL],
        window: ClosedRange<Date>
    ) -> [HRMinutePoint] {
        // 1. Read all RR samples from all member files. Skip files that can't
        //    be read (missing, corrupt, truncated) so a single bad archive
        //    doesn't take down a multi-member coalesced night.
        var allSamples: [RRIntervalSample] = []
        for url in rrFiles {
            guard let samples = try? RRArchiveWriter.read(url: url) else { continue }
            allSamples.append(contentsOf: samples)
        }

        // 2. Window-clamp and artifact-filter before bucketing. Sorting by
        //    timestamp ensures deterministic bucket order when archives from
        //    multiple BLE-reconnect members are concatenated.
        let inWindow = allSamples
            .filter { window.contains($0.timestamp) }
            .filter { $0.rrMs >= rrLowerMs && $0.rrMs <= rrUpperMs }
            .sorted { $0.timestamp < $1.timestamp }

        // 3. Iterate every minute in `window` (start-aligned). Buckets with
        //    zero in-window RR emit a nil-bpm point so Swift Charts draws a
        //    line break instead of connecting across the gap.
        let durationSec = window.upperBound.timeIntervalSince(window.lowerBound)
        let minuteCount = max(0, Int((durationSec / 60).rounded(.up)))
        var sampleIndex = 0
        var out: [HRMinutePoint] = []
        out.reserveCapacity(minuteCount)
        for minuteIndex in 0..<minuteCount {
            let bucketStart = window.lowerBound.addingTimeInterval(Double(minuteIndex) * 60)
            let bucketEnd = bucketStart.addingTimeInterval(60)
            var sum: Double = 0
            var count: Int = 0
            while sampleIndex < inWindow.count,
                  inWindow[sampleIndex].timestamp < bucketEnd {
                if inWindow[sampleIndex].timestamp >= bucketStart {
                    sum += inWindow[sampleIndex].rrMs
                    count += 1
                }
                sampleIndex += 1
            }
            let bpm: Double?
            if count > 0 {
                let meanRR = sum / Double(count)
                let candidate = 60_000.0 / meanRR
                bpm = (candidate >= bpmLowerBound && candidate <= bpmUpperBound) ? candidate : nil
            } else {
                bpm = nil
            }
            out.append(HRMinutePoint(
                id: deterministicID(from: bucketStart),
                timestamp: bucketStart,
                bpm: bpm
            ))
        }
        return out
    }

    nonisolated static func awakeIntervalCount(
        intervals: [(start: Date, end: Date)],
        in window: ClosedRange<Date>
    ) -> Int {
        intervals.reduce(0) { acc, interval in
            // Standard half-open interval overlap: two ranges intersect iff
            // each one's start is before the other's end. Counts an interval
            // that even partially overlaps the window — a wake event that
            // straddled the bedtime boundary is still a wake event for the
            // night.
            let overlaps = interval.start < window.upperBound
                && interval.end > window.lowerBound
            return acc + (overlaps ? 1 : 0)
        }
    }

    // MARK: - Private

    /// Derive a stable UUID from `timestamp` so identical buckets across renders
    /// keep the same `Identifiable` id. Avoids Swift Charts re-animating every
    /// recompute, which would re-trigger the LineMark draw cost on each parent
    /// body re-run.
    nonisolated private static func deterministicID(from timestamp: Date) -> UUID {
        let ms = UInt64(max(0, timestamp.timeIntervalSince1970 * 1000))
        let hi = ms &* 0x9E3779B97F4A7C15  // golden-ratio splitmix step
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: ms.bigEndian) { src in
            for i in 0..<8 { bytes[i] = src[i] }
        }
        withUnsafeBytes(of: hi.bigEndian) { src in
            for i in 0..<8 { bytes[8 + i] = src[i] }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
