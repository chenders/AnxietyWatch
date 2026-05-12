import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure-function helper that flattens HealthKit SDNN snapshots,
/// a `BaselineCalculator.BaselineResult`, anxiety entries, and the new Polar
/// overnight SDNN series into the chart's combined datum array. The chart's
/// existing baseline mean/lower-bound rule marks stay HK-only.
@Suite("HRVTrendDatum builder")
@MainActor
struct HRVTrendChartTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 12))!
    }()

    private func snapshot(daysBefore: Int, hrvAvg: Double?) -> HealthSnapshot {
        let day = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        let snap = HealthSnapshot(date: day)
        snap.hrvAvg = hrvAvg
        return snap
    }

    private func entry(daysBefore: Int, severity: Int = 3) -> AnxietyEntry {
        let timestamp = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return AnxietyEntry(timestamp: timestamp, severity: severity)
    }

    private func polarPoint(daysBefore: Int, sdnn: Double) -> LFHFAggregator.NightlyValue {
        let night = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return LFHFAggregator.NightlyValue(
            id: UUID(),
            night: night,
            value: sdnn,
            validWindowCount: 1
        )
    }

    @Test("from: emits only HK snapshot datums when polarSeries is empty")
    func hkOnly() {
        let snapshots = [snapshot(daysBefore: 1, hrvAvg: 45), snapshot(daysBefore: 0, hrvAvg: 50)]
        let datums = HRVTrendDatum.from(
            snapshots: snapshots,
            entries: [],
            baseline: nil,
            polarSeries: []
        )
        let snapshotCount = datums.filter { if case .snapshot = $0 { return true } else { return false } }.count
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(snapshotCount == 2)
        #expect(polarCount == 0)
    }

    @Test("from: emits Polar datums when polarSeries has values, with HK-empty data")
    func polarOnly() {
        let polar = [polarPoint(daysBefore: 1, sdnn: 55), polarPoint(daysBefore: 0, sdnn: 58)]
        let datums = HRVTrendDatum.from(
            snapshots: [],
            entries: [],
            baseline: nil,
            polarSeries: polar
        )
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(polarCount == 2)
    }

    @Test("from: filters out HK snapshots whose hrvAvg is nil")
    func filtersNilHrvAvg() {
        let snapshots = [
            snapshot(daysBefore: 2, hrvAvg: 40),
            snapshot(daysBefore: 1, hrvAvg: nil),
            snapshot(daysBefore: 0, hrvAvg: 50),
        ]
        let datums = HRVTrendDatum.from(
            snapshots: snapshots,
            entries: [],
            baseline: nil,
            polarSeries: []
        )
        let snapshotCount = datums.filter { if case .snapshot = $0 { return true } else { return false } }.count
        #expect(snapshotCount == 2)
    }

    @Test("from: skips Polar points whose value is nil")
    func skipsNilPolarValue() {
        let polar = [
            LFHFAggregator.NightlyValue(id: UUID(), night: referenceDate, value: nil, validWindowCount: 0),
            polarPoint(daysBefore: 0, sdnn: 50),
        ]
        let datums = HRVTrendDatum.from(
            snapshots: [],
            entries: [],
            baseline: nil,
            polarSeries: polar
        )
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(polarCount == 1)
    }

    @Test("from: includes baseline mean and lower-bound datums when baseline is non-nil")
    func includesBaseline() {
        let baseline = BaselineCalculator.BaselineResult(
            mean: 50,
            standardDeviation: 5,
            lowerBound: 40,
            upperBound: 60
        )
        let datums = HRVTrendDatum.from(
            snapshots: [snapshot(daysBefore: 0, hrvAvg: 50)],
            entries: [],
            baseline: baseline,
            polarSeries: []
        )
        let hasMean = datums.contains { if case .baselineMean = $0 { return true } else { return false } }
        let hasLower = datums.contains { if case .baselineLower = $0 { return true } else { return false } }
        #expect(hasMean)
        #expect(hasLower)
    }

    @Test("from: omits baseline datums when baseline is nil")
    func omitsBaselineWhenNil() {
        let datums = HRVTrendDatum.from(
            snapshots: [snapshot(daysBefore: 0, hrvAvg: 50)],
            entries: [],
            baseline: nil,
            polarSeries: []
        )
        let hasMean = datums.contains { if case .baselineMean = $0 { return true } else { return false } }
        let hasLower = datums.contains { if case .baselineLower = $0 { return true } else { return false } }
        #expect(!hasMean)
        #expect(!hasLower)
    }

    @Test("hasAnyData: false when no HK hrvAvg and no Polar SDNN")
    func hasAnyDataEmpty() {
        #expect(HRVTrendDatum.hasAnyData(snapshots: [], polarSeries: []) == false)
        #expect(HRVTrendDatum.hasAnyData(
            snapshots: [snapshot(daysBefore: 0, hrvAvg: nil)],
            polarSeries: []
        ) == false)
    }

    @Test("hasAnyData: true when only Polar series has values")
    func hasAnyDataPolarOnly() {
        #expect(HRVTrendDatum.hasAnyData(
            snapshots: [],
            polarSeries: [polarPoint(daysBefore: 0, sdnn: 50)]
        ) == true)
    }
}
