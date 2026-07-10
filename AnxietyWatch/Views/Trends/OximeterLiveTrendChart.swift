import Charts
import SwiftData
import SwiftUI

/// Per-minute SpO₂ + pulse from live EMAY BLE sessions (the rows
/// `EMAYRealtimeService` persists under its `liveSourceBundleID`).
///
/// This data is per-instant (one mean per minute), NOT day-normalized like
/// most Trends cards, so it pairs naturally with the 1D and Custom windows.
/// SpO₂ and pulse render as two stacked charts inside one card rather than
/// sharing an axis: the units differ (% vs bpm) and a shared scale would
/// misrepresent both.
struct OximeterLiveTrendChart: View {
    /// Window-filtered live-bundle samples (both metrics mixed; split by
    /// `metricType` in `OximeterLiveSeriesBuilder`).
    let samples: [QuantityHealthSample]
    let dateRange: ClosedRange<Date>

    var body: some View {
        // Built once per body evaluation — the per-render-recomputation
        // pitfall: both sub-charts read from this single derivation.
        let windowDuration = dateRange.upperBound.timeIntervalSince(dateRange.lowerBound)
        let series = OximeterLiveSeriesBuilder.series(from: samples, windowDuration: windowDuration)
        ChartCard(
            title: "Oximeter (live sessions)",
            subtitle: "Per-minute means streamed over Bluetooth",
            isEmpty: samples.isEmpty
        ) {
            VStack(alignment: .leading, spacing: 12) {
                seriesChart(
                    points: series.spo2,
                    name: "SpO₂",
                    color: ChartPalette.oximeterSpO2,
                    yAxisLabel: "SpO₂ %",
                    yDomain: OximeterLiveSeriesBuilder.spo2Domain(
                        observedMin: series.spo2.map(\.value).min()
                    ),
                    accessibilityLabel: "Live oximeter SpO2 averages"
                )
                seriesChart(
                    points: series.pulse,
                    name: "Pulse",
                    color: ChartPalette.oximeterPulse,
                    yAxisLabel: "bpm",
                    yDomain: OximeterLiveSeriesBuilder.pulseDomain(
                        observedMin: series.pulse.map(\.value).min(),
                        observedMax: series.pulse.map(\.value).max()
                    ),
                    accessibilityLabel: "Live oximeter pulse rate averages"
                )
            }
        }
    }

    /// One metric's line chart. Points carry a `segment` index that breaks
    /// the line across session gaps so hours between live sessions aren't
    /// bridged by a misleading interpolated stroke. The y-domain is a
    /// stabilized anchor (never auto-fit) — see the domain helpers on
    /// `OximeterLiveSeriesBuilder`. Fixing the domain is safe against the
    /// `chartYScale(domain:) + .nan` pitfall because these series never
    /// contain NaN values (gaps are expressed via segments, not NaN marks).
    private func seriesChart(
        points: [OximeterLiveSeriesBuilder.Point],
        name: String,
        color: Color,
        yAxisLabel: String,
        yDomain: ClosedRange<Double>,
        accessibilityLabel: String
    ) -> some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.timestamp, unit: .minute),
                y: .value(name, point.value),
                series: .value("Session", "\(name)-\(point.segment)")
            )
            .foregroundStyle(color)
        }
        .chartXScale(domain: dateRange)
        .chartYScale(domain: yDomain)
        .chartYAxisLabel(yAxisLabel)
        .accessibilityLabel(accessibilityLabel)
        .frame(height: 130)
    }
}

/// Pure display mapping from stored `QuantityHealthSample` rows to chart
/// points, plus the stabilized y-domain math. Extracted from the view per
/// the testability rule — covered by `OximeterLiveSeriesBuilderTests`.
nonisolated enum OximeterLiveSeriesBuilder {
    struct Point: Identifiable, Equatable {
        /// Bucket start: the stored per-minute timestamp, or the
        /// window-adaptive aggregate bucket for wider windows.
        let timestamp: Date
        /// Display value: SpO₂ in **percent** (stored fraction × 100 — the
        /// documented percent-vs-fraction pitfall), pulse in bpm as stored.
        let value: Double
        /// Session-gap segment index: consecutive points further apart than
        /// the (bucket-scaled) connected-gap threshold belong to different
        /// live sessions and get distinct segments so the chart doesn't
        /// draw a line across the gap.
        let segment: Int
        /// Bucket starts are unique per metric after grouping.
        var id: Date { timestamp }
    }

    /// Two stored minutes further apart than this are separate sessions —
    /// don't connect them. 5 min tolerates brief BLE dropouts mid-session
    /// (the service auto-reconnects) without bridging genuinely distinct
    /// sessions hours apart. Scaled up for wider aggregation buckets via
    /// `connectedGap(forBucketDuration:)`.
    ///
    /// Since continuous streaming shipped, this tolerance also absorbs
    /// jetsam-recovery gaps: an overnight app kill + state-restoration
    /// reconnect inside 5 minutes draws as one segment even though the
    /// process died in between. That's a straight line between two genuine
    /// means (no fabricated points — the dead minutes simply have no data),
    /// but a reader inferring "no interruption" from an unbroken segment
    /// would be wrong at minute granularity.
    static let maxConnectedGap: TimeInterval = 5 * 60

    // MARK: - Window-adaptive bucketing

    /// Widest visible window that keeps per-minute resolution. Beyond it,
    /// points aggregate to 15-minute means; per-minute marks across a
    /// 90-day window would be tens of thousands of LineMarks on a 130 pt
    /// chart — illegible, and expensive under Swift Charts' documented
    /// per-mark layout cost.
    static let minuteResolutionMaxWindow: TimeInterval = 2 * 24 * 3600
    /// Widest visible window that keeps 15-minute resolution. Beyond it,
    /// points aggregate to hourly means (≤ ~2.2k marks at 90 days).
    static let quarterHourResolutionMaxWindow: TimeInterval = 14 * 24 * 3600

    /// Display bucket width for a visible window: minute / 15-minute /
    /// hourly. Pure function of the window duration so it's unit-testable.
    static func bucketDuration(forWindowDuration duration: TimeInterval) -> TimeInterval {
        if duration <= minuteResolutionMaxWindow { return 60 }
        if duration <= quarterHourResolutionMaxWindow { return 15 * 60 }
        return 3600
    }

    /// Segment-break threshold scaled to the bucket width: at hourly
    /// buckets, consecutive in-session points are already 1 h apart, so the
    /// raw 5-minute gap would fragment one session into per-point segments.
    /// Two empty buckets in a row read as a real gap at any resolution.
    static func connectedGap(forBucketDuration bucket: TimeInterval) -> TimeInterval {
        max(maxConnectedGap, 2 * bucket)
    }

    /// Floor to the containing bucket. Epoch arithmetic — safe at sub-day
    /// granularity (see `EMAYLiveDownsampler.minuteStart`); bucket
    /// boundaries are epoch-aligned rather than wall-clock-aligned, which
    /// is harmless for a line-chart mean (unlike day-granularity math).
    static func bucketStart(for date: Date, bucketDuration: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / bucketDuration).rounded(.down) * bucketDuration)
    }

    // MARK: - Stabilized y-domains

    /// Anchored SpO₂ y-domain (sibling convention: SleepRespiratoryTrendChart's
    /// `nadirDomainFloor`). Anchoring the floor at 70% keeps a benign 96–99%
    /// wobble from auto-fitting to fill the frame and reading as a dramatic
    /// desaturation; `min` lets a genuine desat below 70% widen the domain
    /// instead of being clipped out of frame — clipping would be a
    /// false-reassurance hazard on a clinical surface.
    static func spo2Domain(observedMin: Double?) -> ClosedRange<Double> {
        guard let observedMin else { return 70...100 }
        return min(70, observedMin - 2)...100
    }

    /// Anchored pulse y-domain: a resting 55–75 bpm stretch renders inside a
    /// stable 50–100 frame instead of auto-fitting its wobble; genuine
    /// bradycardia/tachycardia widens the domain (never clips). An empty
    /// series gets the plain anchored frame (no padding to pad from).
    static func pulseDomain(observedMin: Double?, observedMax: Double?) -> ClosedRange<Double> {
        let lower = observedMin.map { min(50, $0 - 5) } ?? 50
        let upper = observedMax.map { max(100, $0 + 5) } ?? 100
        return lower...upper
    }

    // MARK: - Series construction

    /// Split mixed-metric rows into display-ready SpO₂ and pulse series,
    /// aggregated to the window-adaptive bucket width.
    static func series(
        from samples: [QuantityHealthSample],
        windowDuration: TimeInterval
    ) -> (spo2: [Point], pulse: [Point]) {
        let bucket = bucketDuration(forWindowDuration: windowDuration)
        return (
            spo2: points(
                from: samples, metricType: EMAYImporter.spo2MetricType,
                displayScale: 100.0, bucketDuration: bucket
            ),
            pulse: points(
                from: samples, metricType: EMAYImporter.heartRateMetricType,
                displayScale: 1.0, bucketDuration: bucket
            )
        )
    }

    private static func points(
        from samples: [QuantityHealthSample],
        metricType: String,
        displayScale: Double,
        bucketDuration: TimeInterval
    ) -> [Point] {
        let rows = samples.filter { $0.metricType == metricType }
        // One grouping pass covers both concerns: window-adaptive
        // aggregation (15-min/hourly means for wide windows) and the
        // same-minute merge at 60 s buckets — persist-time dedup is
        // first-write-wins now, but a rare duplicate that slips through a
        // failed existence check still merges here (defense-in-depth).
        let byBucket = Dictionary(grouping: rows) {
            bucketStart(for: $0.timestamp, bucketDuration: bucketDuration)
        }
        // Dictionary order is arbitrary — sort before sequential segment
        // assignment (the deterministic-ordering pitfall).
        let buckets = byBucket.keys.sorted()
        let gapThreshold = connectedGap(forBucketDuration: bucketDuration)
        var result: [Point] = []
        result.reserveCapacity(buckets.count)
        var segment = 0
        var previous: Date?
        for bucket in buckets {
            let values = byBucket[bucket, default: []].map(\.value)
            guard !values.isEmpty else { continue }
            let mean = values.reduce(0, +) / Double(values.count)
            if let previous, bucket.timeIntervalSince(previous) > gapThreshold {
                segment += 1
            }
            result.append(Point(timestamp: bucket, value: mean * displayScale, segment: segment))
            previous = bucket
        }
        return result
    }
}
