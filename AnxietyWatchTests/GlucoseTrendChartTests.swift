import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure-function helper that converts `[HealthSnapshot]` into the
/// chart's data array. SwiftUI view bodies are intentionally not exercised here
/// — the data-prep is what we care about for correctness.
@Suite("GlucoseTrendDatum builder")
struct GlucoseTrendChartTests {

    /// Fixed reference date so assertions about rolling means / counts are
    /// deterministic. Day-aligned to noon UTC to dodge time-zone rounding.
    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 12))!
    }()

    /// Build an n-day run of `HealthSnapshot` values starting `n - 1` days before
    /// the reference date, so the last snapshot lands on `referenceDate`.
    private func makeSnapshots(
        avgs: [Double?],
        cvs: [Double?]? = nil,
        dataQualities: [String?]? = nil
    ) -> [HealthSnapshot] {
        let cal = Calendar.current
        return avgs.enumerated().map { index, avg in
            let dayOffset = -(avgs.count - 1 - index)
            let day = cal.date(byAdding: .day, value: dayOffset, to: referenceDate)!
            let snap = HealthSnapshot(date: day)
            snap.bloodGlucoseAvg = avg
            if let cvs, index < cvs.count {
                snap.glucoseCV = cvs[index]
            }
            if let dataQualities, index < dataQualities.count {
                snap.dataQuality = dataQualities[index]
            }
            return snap
        }
    }

    @Test("buildsDatumsFromSnapshots: 7 snapshots produce 7 datums with matching avgs")
    func buildsDatumsFromSnapshots() {
        let avgs: [Double?] = [100, 110, 120, 130, 140, 150, 160]
        let snapshots = makeSnapshots(avgs: avgs)

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)

        #expect(datums.count == 7)
        #expect(datums.map { $0.avg } == [100, 110, 120, 130, 140, 150, 160])
    }

    @Test("excludesSnapshotsWithoutGlucose: nil bloodGlucoseAvg rows drop out")
    func excludesSnapshotsWithoutGlucose() {
        // 7 inputs, 2 with nil bloodGlucoseAvg → 5 datums out
        let avgs: [Double?] = [100, nil, 120, 130, nil, 150, 160]
        let snapshots = makeSnapshots(avgs: avgs)

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)

        #expect(datums.count == 5)
        #expect(datums.map { $0.avg } == [100, 120, 130, 150, 160])
    }

    @Test("flagsLowReliabilityDays: dataQuality.glucose.reliability == low marks the datum")
    func flagsLowReliabilityDays() {
        let lowJSON = #"{"glucose":{"reliability":"low","sources":{"com.apple.health":3}}}"#
        let highJSON = #"{"glucose":{"reliability":"high","sources":{"com.dexcom.stelo":288}}}"#
        let mediumJSON = #"{"glucose":{"reliability":"medium","sources":{"com.dexcom.stelo":50}}}"#

        let avgs: [Double?] = [100, 110, 120]
        let snapshots = makeSnapshots(
            avgs: avgs,
            dataQualities: [lowJSON, highJSON, mediumJSON]
        )

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)

        #expect(datums.count == 3)
        #expect(datums[0].isLowReliability == true)
        #expect(datums[1].isLowReliability == false)
        #expect(datums[2].isLowReliability == false)
    }

    @Test("computesRollingMean: arithmetic mean of the visible window")
    func computesRollingMean() {
        let avgs: [Double?] = [100, 110, 120, 130, 140, 150, 160]
        let snapshots = makeSnapshots(avgs: avgs)

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)
        let mean = GlucoseTrendDatum.rollingMean(datums)

        #expect(mean == 130)
    }

    @Test("rollingMean returns nil for empty input")
    func rollingMeanEmpty() {
        let mean = GlucoseTrendDatum.rollingMean([])
        #expect(mean == nil)
    }

    @Test("gracefullyHandlesNilDataQuality: missing dataQuality defaults isLowReliability=false")
    func gracefullyHandlesNilDataQuality() {
        let avgs: [Double?] = [100, 110]
        let snapshots = makeSnapshots(avgs: avgs, dataQualities: [nil, nil])

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)

        #expect(datums.count == 2)
        #expect(datums.allSatisfy { $0.isLowReliability == false })
    }

    @Test("gracefullyHandlesMalformedDataQuality: bad JSON does not crash, defaults to false")
    func gracefullyHandlesMalformedDataQuality() {
        let avgs: [Double?] = [100, 110]
        let snapshots = makeSnapshots(
            avgs: avgs,
            dataQualities: ["not a json", #"{"glucose":42}"#]
        )

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)

        #expect(datums.count == 2)
        #expect(datums.allSatisfy { $0.isLowReliability == false })
    }

    @Test("subtitleDisambiguatesAvgVsCVDayCount: shows 'Y of N' when the counts differ")
    func subtitleDisambiguatesAvgVsCVDayCount() {
        // 7 days have a glucose avg, but only 5 of them have CV (e.g. 2 recent
        // low-data days were excluded from CV). The subtitle must call out the
        // CV window separately so the user doesn't think CV averaged 7 days.
        let s = GlucoseTrendDatum.subtitle(meanCV: 25.4, avgDayCount: 7, cvDayCount: 5)
        #expect(s == "Daily avg · CV 25% over 5 of 7 days")
    }

    @Test("subtitleCollapsesWhenCountsMatch: no 'Y of N' when avg-day == cv-day")
    func subtitleCollapsesWhenCountsMatch() {
        let s = GlucoseTrendDatum.subtitle(meanCV: 30, avgDayCount: 7, cvDayCount: 7)
        #expect(s == "Daily avg · CV 30% over 7 days")
    }

    @Test("subtitleOmitsCVPhraseWhenNil: no CV at all → 'Daily avg over N days'")
    func subtitleOmitsCVPhraseWhenNil() {
        let s = GlucoseTrendDatum.subtitle(meanCV: nil, avgDayCount: 4, cvDayCount: 0)
        #expect(s == "Daily avg over 4 days")
    }

    @Test("meanCV averages the per-day CV values, ignoring nil-CV days")
    func meanCVAveragesPresentValues() {
        // 3 days with glucose, CV present on two of them (25, 45) → mean 35.
        let avgs: [Double?] = [100, 110, 120]
        let cvs: [Double?] = [25, nil, 45]
        let snapshots = makeSnapshots(avgs: avgs, cvs: cvs)

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)
        let mean = GlucoseTrendDatum.meanCV(datums)

        #expect(mean != nil)
        #expect(abs((mean ?? 0) - 35) < 0.0001)
    }

    @Test("meanCV returns nil when no day has a CV value")
    func meanCVNilWhenNoCV() {
        let avgs: [Double?] = [100, 110]
        let snapshots = makeSnapshots(avgs: avgs) // no cvs

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)
        #expect(GlucoseTrendDatum.meanCV(datums) == nil)
    }

    @Test("preservesCVValue: glucoseCV passes through to the datum when present")
    func preservesCVValue() {
        let avgs: [Double?] = [100, 110, 120]
        let cvs: [Double?] = [25, nil, 42]
        let snapshots = makeSnapshots(avgs: avgs, cvs: cvs)

        let datums = GlucoseTrendDatum.from(snapshots: snapshots)

        #expect(datums.count == 3)
        #expect(datums[0].cv == 25)
        #expect(datums[1].cv == nil)
        #expect(datums[2].cv == 42)
    }
}
