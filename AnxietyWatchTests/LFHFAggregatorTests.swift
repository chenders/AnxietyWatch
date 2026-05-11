import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for LFHFAggregator — sentinel filtering, per-minute gap conversion,
/// and per-session mean aggregation for the Phase 3c LF/HF chart.
struct LFHFAggregatorTests {

    // MARK: - Helpers

    /// Fixed reference date — never use Date.now in tests.
    private let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 1
        components.hour = 23
        components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private func reading(
        minutesAfterReference: Int,
        lf: Double,
        hf: Double,
        ratio: Double? = nil,
        sessionID: UUID? = nil
    ) -> HRVReading {
        let ts = referenceDate.addingTimeInterval(Double(minutesAfterReference) * 60)
        let resolvedRatio: Double
        if let ratio {
            resolvedRatio = ratio
        } else if hf == 0 {
            resolvedRatio = 0
        } else {
            resolvedRatio = lf / hf
        }
        return HRVReading(
            timestamp: ts,
            rmssd: 40,
            sdnn: 50,
            pnn50: 10,
            lfPower: lf,
            hfPower: hf,
            lfHfRatio: resolvedRatio,
            sensorSessionID: sessionID,
            source: PolarHRMService.sourceLabel
        )
    }

    // MARK: - hasFrequencyData

    @Test("hasFrequencyData rejects a reading with both LF and HF zero (the <30 RR sentinel)")
    func rejectsBothZero() {
        let r = reading(minutesAfterReference: 0, lf: 0, hf: 0, ratio: 0)
        #expect(LFHFAggregator.hasFrequencyData(r) == false)
    }

    @Test("hasFrequencyData rejects a reading with only LF zero")
    func rejectsLFZero() {
        let r = reading(minutesAfterReference: 0, lf: 0, hf: 5, ratio: 0)
        #expect(LFHFAggregator.hasFrequencyData(r) == false)
    }

    @Test("hasFrequencyData rejects a reading with only HF zero")
    func rejectsHFZero() {
        let r = reading(minutesAfterReference: 0, lf: 5, hf: 0, ratio: 0)
        #expect(LFHFAggregator.hasFrequencyData(r) == false)
    }

    @Test("hasFrequencyData accepts a reading with both LF and HF positive")
    func acceptsBothPositive() {
        let r = reading(minutesAfterReference: 0, lf: 1.2, hf: 3.4)
        #expect(LFHFAggregator.hasFrequencyData(r) == true)
    }

    // MARK: - gappedPerMinutePoints

    @Test("gappedPerMinutePoints returns an empty array for empty input")
    func gappedEmptyInput() {
        let points = LFHFAggregator.gappedPerMinutePoints(from: [])
        #expect(points.isEmpty)
    }

    @Test("gappedPerMinutePoints preserves all readings, sorted by timestamp, with non-nil values when data is valid")
    func gappedAllValid() {
        let readings = [
            reading(minutesAfterReference: 2, lf: 2.0, hf: 4.0, ratio: 0.5),
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5),
            reading(minutesAfterReference: 1, lf: 1.5, hf: 3.0, ratio: 0.5),
        ]

        let points = LFHFAggregator.gappedPerMinutePoints(from: readings)

        #expect(points.count == 3)
        let timestamps = points.map(\.timestamp)
        #expect(timestamps == timestamps.sorted())
        for point in points {
            #expect(point.lfPower != nil)
            #expect(point.hfPower != nil)
            #expect(point.lfHfRatio != nil)
        }
    }

    @Test("gappedPerMinutePoints renders a zero-sentinel reading as a gap (nil fields) without dropping the timestamp")
    func gappedMidSequenceGap() {
        let readings = [
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5),
            reading(minutesAfterReference: 1, lf: 0, hf: 0, ratio: 0),
            reading(minutesAfterReference: 2, lf: 1.5, hf: 3.0, ratio: 0.5),
        ]

        let points = LFHFAggregator.gappedPerMinutePoints(from: readings)

        #expect(points.count == 3)
        #expect(points[0].lfPower != nil)
        #expect(points[1].lfPower == nil)
        #expect(points[1].hfPower == nil)
        #expect(points[1].lfHfRatio == nil)
        #expect(points[2].lfPower != nil)
    }

    @Test("gappedPerMinutePoints returns all-nil points when every reading is a zero sentinel")
    func gappedAllZero() {
        let readings = (0..<3).map { reading(minutesAfterReference: $0, lf: 0, hf: 0, ratio: 0) }

        let points = LFHFAggregator.gappedPerMinutePoints(from: readings)

        #expect(points.count == 3)
        #expect(points.allSatisfy { $0.lfPower == nil && $0.hfPower == nil && $0.lfHfRatio == nil })
    }

    // MARK: - nightlyMeans

    @Test("nightlyMeans returns an empty array for empty input")
    func nightlyEmpty() {
        let means = LFHFAggregator.nightlyMeans(from: [])
        #expect(means.isEmpty)
    }

    @Test("nightlyMeans drops readings missing a sensorSessionID")
    func nightlyDropsUngrouped() {
        let readings = [
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: nil),
            reading(minutesAfterReference: 1, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: nil),
        ]
        let means = LFHFAggregator.nightlyMeans(from: readings)
        #expect(means.isEmpty)
    }

    @Test("nightlyMeans groups valid readings by sensorSessionID and computes the mean")
    func nightlyMeansForOneSession() {
        let sessionID = UUID()
        let readings = [
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: sessionID),
            reading(minutesAfterReference: 1, lf: 2.0, hf: 4.0, ratio: 0.5, sessionID: sessionID),
            reading(minutesAfterReference: 2, lf: 3.0, hf: 6.0, ratio: 0.5, sessionID: sessionID),
        ]

        let means = LFHFAggregator.nightlyMeans(from: readings)

        #expect(means.count == 1)
        let mean = means[0]
        #expect(mean.id == sessionID)
        #expect(mean.lfMean == 2.0)
        #expect(mean.hfMean == 4.0)
        #expect(mean.lfHfMean == 0.5)
        #expect(mean.validWindowCount == 3)
    }

    @Test("nightlyMeans ignores zero-sentinel readings when computing the mean")
    func nightlyMeansIgnoresSentinels() {
        let sessionID = UUID()
        let readings = [
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: sessionID),
            reading(minutesAfterReference: 1, lf: 0, hf: 0, ratio: 0, sessionID: sessionID),
            reading(minutesAfterReference: 2, lf: 3.0, hf: 6.0, ratio: 0.5, sessionID: sessionID),
            reading(minutesAfterReference: 3, lf: 0, hf: 5, ratio: 0, sessionID: sessionID),
        ]

        let means = LFHFAggregator.nightlyMeans(from: readings)

        #expect(means.count == 1)
        let mean = means[0]
        #expect(mean.lfMean == 2.0)
        #expect(mean.hfMean == 4.0)
        #expect(mean.lfHfMean == 0.5)
        #expect(mean.validWindowCount == 2)
    }

    @Test("nightlyMeans returns nil means and zero count for a session of only zero sentinels")
    func nightlyMeansAllSentinel() {
        let sessionID = UUID()
        let readings = (0..<5).map {
            reading(minutesAfterReference: $0, lf: 0, hf: 0, ratio: 0, sessionID: sessionID)
        }

        let means = LFHFAggregator.nightlyMeans(from: readings)

        #expect(means.count == 1)
        let mean = means[0]
        #expect(mean.id == sessionID)
        #expect(mean.lfMean == nil)
        #expect(mean.hfMean == nil)
        #expect(mean.lfHfMean == nil)
        #expect(mean.validWindowCount == 0)
    }

    @Test("nightlyMeans separates readings from different sensor sessions")
    func nightlyMeansAcrossSessions() {
        let sessionA = UUID()
        let sessionB = UUID()
        let readings = [
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: sessionA),
            reading(minutesAfterReference: 1, lf: 3.0, hf: 6.0, ratio: 0.5, sessionID: sessionA),
            reading(minutesAfterReference: 600, lf: 4.0, hf: 8.0, ratio: 0.5, sessionID: sessionB),
        ]

        let means = LFHFAggregator.nightlyMeans(from: readings)

        #expect(means.count == 2)
        let a = means.first { $0.id == sessionA }
        let b = means.first { $0.id == sessionB }
        #expect(a?.lfMean == 2.0)
        #expect(a?.hfMean == 4.0)
        #expect(a?.validWindowCount == 2)
        #expect(b?.lfMean == 4.0)
        #expect(b?.hfMean == 8.0)
        #expect(b?.validWindowCount == 1)
    }

    // MARK: - hfBaseline

    private func nightlyMean(
        daysBeforeAnchor: Double,
        hfMean: Double?,
        anchor: Date
    ) -> LFHFAggregator.NightlyMean {
        LFHFAggregator.NightlyMean(
            id: UUID(),
            night: anchor.addingTimeInterval(-daysBeforeAnchor * 86_400),
            hfMean: hfMean,
            lfMean: hfMean,
            lfHfMean: hfMean,
            validWindowCount: hfMean == nil ? 0 : 200
        )
    }

    @Test("hfBaseline returns nil when no sessions are in the lookback window")
    func hfBaselineEmpty() {
        let result = LFHFAggregator.hfBaseline(from: [], anchor: referenceDate)
        #expect(result == nil)
    }

    @Test("hfBaseline returns nil when fewer than minimumNights are available")
    func hfBaselineBelowMinimum() {
        let means = [
            nightlyMean(daysBeforeAnchor: 1, hfMean: 100, anchor: referenceDate),
            nightlyMean(daysBeforeAnchor: 3, hfMean: 200, anchor: referenceDate),
        ]
        let result = LFHFAggregator.hfBaseline(from: means, anchor: referenceDate)
        #expect(result == nil)
    }

    @Test("hfBaseline averages valid sessions when at least minimumNights exist in window")
    func hfBaselineHappyPath() {
        let means = [
            nightlyMean(daysBeforeAnchor: 1, hfMean: 100, anchor: referenceDate),
            nightlyMean(daysBeforeAnchor: 5, hfMean: 200, anchor: referenceDate),
            nightlyMean(daysBeforeAnchor: 10, hfMean: 300, anchor: referenceDate),
        ]
        let result = LFHFAggregator.hfBaseline(from: means, anchor: referenceDate) ?? 0
        #expect(abs(result - 200) < 0.0001)
    }

    @Test("hfBaseline excludes sessions outside the lookback window")
    func hfBaselineExcludesOutside() {
        let means = [
            nightlyMean(daysBeforeAnchor: 1, hfMean: 100, anchor: referenceDate),
            nightlyMean(daysBeforeAnchor: 5, hfMean: 200, anchor: referenceDate),
            // Outside 30-day lookback — must be excluded
            nightlyMean(daysBeforeAnchor: 60, hfMean: 10_000, anchor: referenceDate),
            nightlyMean(daysBeforeAnchor: 10, hfMean: 300, anchor: referenceDate),
        ]
        let result = LFHFAggregator.hfBaseline(from: means, anchor: referenceDate) ?? 0
        #expect(abs(result - 200) < 0.0001)
    }

    @Test("hfBaseline cutoff is day-aligned so a session early on the cutoff day is still included")
    func hfBaselineCutoffDayAlignment() {
        // A session whose night sits at the *start* of the cutoff day (i.e.,
        // just slightly before 30 * 86400 seconds ago) used to fall outside
        // the raw-timestamp cutoff. With startOfDay-aligned cutoff it stays
        // included.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let cutoffDayStart = cal.startOfDay(
            for: cal.date(byAdding: .day, value: -30, to: referenceDate)!
        )
        let means = [
            LFHFAggregator.NightlyMean(
                id: UUID(),
                night: cutoffDayStart.addingTimeInterval(60), // 1 minute into the cutoff day
                hfMean: 100,
                lfMean: 100,
                lfHfMean: 100,
                validWindowCount: 200
            ),
            nightlyMean(daysBeforeAnchor: 1, hfMean: 200, anchor: referenceDate),
            nightlyMean(daysBeforeAnchor: 5, hfMean: 300, anchor: referenceDate),
        ]
        let result = LFHFAggregator.hfBaseline(
            from: means,
            anchor: referenceDate,
            calendar: cal
        ) ?? 0
        #expect(abs(result - 200) < 0.0001)
    }

    // MARK: - robustUpperBound

    @Test("robustUpperBound returns 1 when there is no positive data")
    func robustUpperBoundEmpty() {
        #expect(LFHFAggregator.robustUpperBound(of: []) == 1)
        #expect(LFHFAggregator.robustUpperBound(of: [0, 0]) == 1)
    }

    @Test("robustUpperBound clips well below an extreme outlier")
    func robustUpperBoundClipsOutlier() {
        // 99 modest values + 1 huge spike — bound should sit near the modest
        // values plus headroom, not anywhere near the spike.
        let modest: [Double] = Array(repeating: 500, count: 99)
        let spike: [Double] = [65_000]
        let bound = LFHFAggregator.robustUpperBound(of: modest + spike)
        #expect(bound < 5_000)
        #expect(bound >= 500)
    }

    @Test("robustUpperBound leaves modest data with headroom")
    func robustUpperBoundHeadroom() {
        let bound = LFHFAggregator.robustUpperBound(of: [100, 200, 300, 400, 500])
        #expect(bound > 500)
        #expect(bound < 600)
    }

    @Test("robustUpperBound stays below the max even at small sample sizes")
    func robustUpperBoundSmallSample() {
        // 19 modest + 1 spike = 20 values. A naive `Int(count * 0.95)` would
        // round up to index 19 (the max) and defeat the clip; the corrected
        // `(count - 1) * 0.95` formula picks index 18 (second-to-last).
        let modest: [Double] = Array(repeating: 100, count: 19)
        let spike: [Double] = [10_000]
        let bound = LFHFAggregator.robustUpperBound(of: modest + spike)
        #expect(bound < 1_000)
        #expect(bound >= 100)
    }

    // MARK: - outlierTrimmedMean

    @Test("outlierTrimmedMean returns nil when no positive data")
    func outlierTrimmedMeanEmpty() {
        #expect(LFHFAggregator.outlierTrimmedMean(of: []) == nil)
        #expect(LFHFAggregator.outlierTrimmedMean(of: [0]) == nil)
    }

    @Test("outlierTrimmedMean ignores extreme outliers when computing the mean")
    func outlierTrimmedMeanIgnoresOutlier() {
        let modest: [Double] = Array(repeating: 500, count: 99)
        let spike: [Double] = [65_000]
        let trimmed = LFHFAggregator.outlierTrimmedMean(of: modest + spike) ?? 0
        let arithmetic = (Double(99 * 500) + 65_000) / 100
        #expect(trimmed < arithmetic * 0.5)
        #expect(abs(trimmed - 500) < 50)
    }

    @Test("outlierTrimmedMean returns the arithmetic mean when there are no outliers")
    func outlierTrimmedMeanNoOutliers() {
        let trimmed = LFHFAggregator.outlierTrimmedMean(of: [400, 450, 500, 550, 600]) ?? 0
        #expect(abs(trimmed - 500) < 1)
    }

    // MARK: - relativeDelta

    @Test("relativeDelta returns nil for non-positive baseline")
    func relativeDeltaZeroBaseline() {
        #expect(LFHFAggregator.relativeDelta(value: 100, baseline: 0) == nil)
        #expect(LFHFAggregator.relativeDelta(value: 100, baseline: -5) == nil)
    }

    @Test("relativeDelta computes the signed fractional delta against baseline")
    func relativeDeltaSigned() {
        // Tolerance-based instead of exact == because some of these
        // expected fractions (e.g., -0.18) aren't exactly representable
        // in IEEE 754.
        let tolerance = 1e-9
        let below = LFHFAggregator.relativeDelta(value: 82, baseline: 100) ?? .nan
        #expect(abs(below - -0.18) < tolerance)
        let above = LFHFAggregator.relativeDelta(value: 125, baseline: 100) ?? .nan
        #expect(abs(above - 0.25) < tolerance)
        let equal = LFHFAggregator.relativeDelta(value: 100, baseline: 100) ?? .nan
        #expect(abs(equal - 0) < tolerance)
    }

    @Test("nightlyMeans returns sessions sorted ascending by night so LineMark connects in order")
    func nightlyMeansSortedAscending() {
        let oldID = UUID()
        let newID = UUID()
        // Submit in reverse-night order to confirm output is re-sorted, not just preserved.
        let readings = [
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: newID),
            reading(minutesAfterReference: -1440, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: oldID),
        ]

        let means = LFHFAggregator.nightlyMeans(from: readings)

        #expect(means.count == 2)
        #expect(means[0].id == oldID)
        #expect(means[1].id == newID)
        #expect(means[0].night < means[1].night)
    }

    @Test("nightlyMeans uses provided session start time when available, bypassing reading-timestamp lag")
    func nightlyMeansSessionStartOverride() {
        let sessionID = UUID()
        // Session started 1 minute before the first reading — the recorder
        // can lag the session start by up to ~60s.
        let sessionStart = referenceDate.addingTimeInterval(-60)
        let readings = [
            reading(minutesAfterReference: 0, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: sessionID),
            reading(minutesAfterReference: 1, lf: 1.0, hf: 2.0, ratio: 0.5, sessionID: sessionID),
        ]

        let means = LFHFAggregator.nightlyMeans(
            from: readings,
            sessionStartTimes: [sessionID: sessionStart]
        )

        #expect(means.count == 1)
        #expect(means[0].night == sessionStart)
    }

    @Test("nightlyMeans anchors each session to its earliest reading timestamp")
    func nightlyMeansAnchorTimestamp() {
        let sessionID = UUID()
        let earliest = referenceDate
        let later = referenceDate.addingTimeInterval(120)
        let readings = [
            HRVReading(
                timestamp: later,
                rmssd: 40, sdnn: 50, pnn50: 10,
                lfPower: 2, hfPower: 4, lfHfRatio: 0.5,
                sensorSessionID: sessionID, source: PolarHRMService.sourceLabel
            ),
            HRVReading(
                timestamp: earliest,
                rmssd: 40, sdnn: 50, pnn50: 10,
                lfPower: 1, hfPower: 2, lfHfRatio: 0.5,
                sensorSessionID: sessionID, source: PolarHRMService.sourceLabel
            ),
        ]

        let means = LFHFAggregator.nightlyMeans(from: readings)

        #expect(means.count == 1)
        #expect(means[0].night == earliest)
    }
}
