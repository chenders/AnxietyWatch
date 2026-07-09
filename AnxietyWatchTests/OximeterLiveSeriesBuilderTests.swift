import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the pure display mapping behind the Trends "Oximeter (live
/// sessions)" card: stored-fraction → display-percent conversion, per-metric
/// splitting, same-minute duplicate merging, deterministic ordering,
/// session-gap segmentation, window-adaptive bucketing, and the stabilized
/// y-domain math.
struct OximeterLiveSeriesBuilderTests {

    /// Fixed reference instant divisible by 60, 900, AND 3600 so
    /// minute/15-minute/hourly bucket boundaries in assertions are exact.
    private let base = Date(timeIntervalSinceReferenceDate: 780_001_200)

    /// A one-hour window — keeps every legacy test at per-minute resolution.
    private let minuteWindow: TimeInterval = 3600

    private func sample(_ offset: TimeInterval, metricType: String, value: Double) -> QuantityHealthSample {
        QuantityHealthSample(
            timestamp: base.addingTimeInterval(offset),
            metricType: metricType,
            value: value,
            unitString: metricType == EMAYImporter.spo2MetricType ? "%" : "count/min",
            sourceBundleID: EMAYRealtimeService.liveSourceBundleID,
            sourceName: EMAYRealtimeService.liveSourceName
        )
    }

    @Test("Stored SpO2 fraction is displayed as percent; pulse passes through in bpm")
    func displayScaling() throws {
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.95),
            sample(0, metricType: EMAYImporter.heartRateMetricType, value: 62.0),
        ], windowDuration: minuteWindow)
        let spo2 = try #require(series.spo2.first)
        #expect(abs(spo2.value - 95.0) < 0.001)
        let pulse = try #require(series.pulse.first)
        #expect(abs(pulse.value - 62.0) < 0.001)
    }

    @Test("Metrics are split into their own series")
    func metricSplit() {
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.95),
            sample(60, metricType: EMAYImporter.heartRateMetricType, value: 62.0),
        ], windowDuration: minuteWindow)
        #expect(series.spo2.count == 1)
        #expect(series.pulse.count == 1)
    }

    @Test("Two rows in the same minute (stop→start restart) merge to one mean point")
    func sameMinuteDuplicatesMerged() throws {
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.90),
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.94),
        ], windowDuration: minuteWindow)
        #expect(series.spo2.count == 1)
        let merged = try #require(series.spo2.first)
        #expect(abs(merged.value - 92.0) < 0.001)
    }

    @Test("Points come out time-sorted regardless of input order")
    func deterministicOrdering() {
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(120, metricType: EMAYImporter.spo2MetricType, value: 0.93),
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.95),
            sample(60, metricType: EMAYImporter.spo2MetricType, value: 0.94),
        ], windowDuration: minuteWindow)
        #expect(series.spo2.map(\.timestamp) == [
            base, base.addingTimeInterval(60), base.addingTimeInterval(120),
        ])
    }

    @Test("Gaps wider than maxConnectedGap start a new line segment; narrower ones don't")
    func sessionGapSegmentation() {
        let gap = OximeterLiveSeriesBuilder.maxConnectedGap
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.95),
            sample(60, metricType: EMAYImporter.spo2MetricType, value: 0.94),
            // Exactly at the threshold: still the same segment (> not >=).
            sample(60 + gap, metricType: EMAYImporter.spo2MetricType, value: 0.93),
            // Past the threshold: a separate live session — new segment.
            sample(60 + gap + gap + 60, metricType: EMAYImporter.spo2MetricType, value: 0.96),
        ], windowDuration: minuteWindow)
        #expect(series.spo2.map(\.segment) == [0, 0, 0, 1])
    }

    // MARK: - Window-adaptive bucketing

    @Test("Bucket width follows the visible window: minute up to 2 days, 15-min to 14 days, hourly beyond")
    func bucketDurationSelection() {
        let day: TimeInterval = 24 * 3600
        #expect(OximeterLiveSeriesBuilder.bucketDuration(forWindowDuration: 3600) == 60)
        // Boundaries are inclusive on the finer side.
        #expect(OximeterLiveSeriesBuilder.bucketDuration(forWindowDuration: 2 * day) == 60)
        #expect(OximeterLiveSeriesBuilder.bucketDuration(forWindowDuration: 2 * day + 1) == 15 * 60)
        #expect(OximeterLiveSeriesBuilder.bucketDuration(forWindowDuration: 14 * day) == 15 * 60)
        #expect(OximeterLiveSeriesBuilder.bucketDuration(forWindowDuration: 14 * day + 1) == 3600)
        #expect(OximeterLiveSeriesBuilder.bucketDuration(forWindowDuration: 90 * day) == 3600)
    }

    @Test("A multi-day window aggregates per-minute rows to 15-minute means")
    func fifteenMinuteAggregation() throws {
        let threeDays: TimeInterval = 3 * 24 * 3600
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.90),
            sample(60, metricType: EMAYImporter.spo2MetricType, value: 0.94),
            sample(900, metricType: EMAYImporter.spo2MetricType, value: 0.92),
        ], windowDuration: threeDays)
        #expect(series.spo2.count == 2)
        let first = try #require(series.spo2.first)
        // Mean of the two rows inside the first 15-minute bucket.
        #expect(first.timestamp == base)
        #expect(abs(first.value - 92.0) < 0.001)
        let second = try #require(series.spo2.last)
        #expect(second.timestamp == base.addingTimeInterval(900))
        #expect(abs(second.value - 92.0) < 0.001)
    }

    @Test("A window past 14 days aggregates to hourly means")
    func hourlyAggregation() throws {
        let twentyDays: TimeInterval = 20 * 24 * 3600
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(0, metricType: EMAYImporter.heartRateMetricType, value: 60),
            sample(1800, metricType: EMAYImporter.heartRateMetricType, value: 70),
        ], windowDuration: twentyDays)
        #expect(series.pulse.count == 1)
        let only = try #require(series.pulse.first)
        #expect(only.timestamp == base)
        #expect(abs(only.value - 65.0) < 0.001)
    }

    @Test("Segment gap scales with the bucket so hourly buckets don't fragment one session")
    func scaledSegmentation() {
        let twentyDays: TimeInterval = 20 * 24 * 3600
        let series = OximeterLiveSeriesBuilder.series(from: [
            sample(0, metricType: EMAYImporter.spo2MetricType, value: 0.95),
            // The next hourly bucket: 1 h apart — within 2× the bucket, so
            // still one session (the raw 5-min gap would have split it).
            sample(3600, metricType: EMAYImporter.spo2MetricType, value: 0.94),
            // Three hours later: past the scaled threshold — new segment.
            sample(3 * 3600 + 3600, metricType: EMAYImporter.spo2MetricType, value: 0.96),
        ], windowDuration: twentyDays)
        #expect(series.spo2.map(\.segment) == [0, 0, 1])
    }

    // MARK: - Stabilized y-domains

    @Test("SpO2 domain anchors at 70-100 for benign values and widens (never clips) for real desats")
    func spo2DomainMath() {
        // Benign 96% minimum: the floor stays anchored at 70 so a small
        // wobble doesn't fill the frame and read as a desaturation.
        let benign = OximeterLiveSeriesBuilder.spo2Domain(observedMin: 96)
        #expect(abs(benign.lowerBound - 70.0) < 0.001)
        #expect(abs(benign.upperBound - 100.0) < 0.001)
        // Severe desat to 60%: the domain widens below the observed value —
        // clipping it out of frame would be a false-reassurance hazard.
        let desat = OximeterLiveSeriesBuilder.spo2Domain(observedMin: 60)
        #expect(abs(desat.lowerBound - 58.0) < 0.001)
        #expect(abs(desat.upperBound - 100.0) < 0.001)
        // Empty series: the plain anchored frame.
        let empty = OximeterLiveSeriesBuilder.spo2Domain(observedMin: nil)
        #expect(abs(empty.lowerBound - 70.0) < 0.001)
        #expect(abs(empty.upperBound - 100.0) < 0.001)
    }

    @Test("Pulse domain anchors at 50-100 and expands for bradycardia/tachycardia")
    func pulseDomainMath() {
        // Resting 55-75 bpm renders inside the stable anchored frame.
        let resting = OximeterLiveSeriesBuilder.pulseDomain(observedMin: 55, observedMax: 75)
        #expect(abs(resting.lowerBound - 50.0) < 0.001)
        #expect(abs(resting.upperBound - 100.0) < 0.001)
        // Genuine extremes widen the domain instead of clipping.
        let extremes = OximeterLiveSeriesBuilder.pulseDomain(observedMin: 40, observedMax: 130)
        #expect(abs(extremes.lowerBound - 35.0) < 0.001)
        #expect(abs(extremes.upperBound - 135.0) < 0.001)
        // Empty series: the plain anchored frame.
        let empty = OximeterLiveSeriesBuilder.pulseDomain(observedMin: nil, observedMax: nil)
        #expect(abs(empty.lowerBound - 50.0) < 0.001)
        #expect(abs(empty.upperBound - 100.0) < 0.001)
    }
}
