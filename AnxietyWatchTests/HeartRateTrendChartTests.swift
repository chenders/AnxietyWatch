import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure-function helper that flattens HealthKit `HealthSnapshot`
/// resting-HR rows, anxiety entries, and Polar overnight-mean HR points
/// (`NightlyValue`) into the chart's combined datum array.
@Suite("HeartRateTrendDatum builder")
@MainActor
struct HeartRateTrendChartTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 12))!
    }()

    private func snapshot(daysBefore: Int, restingHR: Double?) -> HealthSnapshot {
        let day = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        let snap = HealthSnapshot(date: day)
        snap.restingHR = restingHR
        return snap
    }

    private func entry(daysBefore: Int, severity: Int = 3) -> AnxietyEntry {
        let timestamp = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return AnxietyEntry(timestamp: timestamp, severity: severity)
    }

    private func polarPoint(daysBefore: Int, hrMean: Double) -> LFHFAggregator.NightlyValue {
        let night = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return LFHFAggregator.NightlyValue(
            id: UUID(),
            night: night,
            value: hrMean,
            validWindowCount: 1
        )
    }

    @Test("from: emits only HK datums when polarSeries is empty")
    func hkOnly() {
        let snapshots = [snapshot(daysBefore: 1, restingHR: 60), snapshot(daysBefore: 0, restingHR: 62)]
        let datums = HeartRateTrendDatum.from(snapshots: snapshots, entries: [], polarSeries: [])
        let snapshotCount = datums.filter { if case .snapshot = $0 { return true } else { return false } }.count
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(snapshotCount == 2)
        #expect(polarCount == 0)
    }

    @Test("from: emits only Polar datums when snapshots have no restingHR")
    func polarOnly() {
        let snapshots = [snapshot(daysBefore: 1, restingHR: nil)]
        let polar = [polarPoint(daysBefore: 1, hrMean: 64), polarPoint(daysBefore: 0, hrMean: 66)]
        let datums = HeartRateTrendDatum.from(snapshots: snapshots, entries: [], polarSeries: polar)
        let snapshotCount = datums.filter { if case .snapshot = $0 { return true } else { return false } }.count
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(snapshotCount == 0)
        #expect(polarCount == 2)
    }

    @Test("from: excludes snapshots whose restingHR is nil")
    func filtersOutNilRestingHR() {
        let snapshots = [
            snapshot(daysBefore: 2, restingHR: 60),
            snapshot(daysBefore: 1, restingHR: nil),
            snapshot(daysBefore: 0, restingHR: 62),
        ]
        let datums = HeartRateTrendDatum.from(snapshots: snapshots, entries: [], polarSeries: [])
        let snapshotCount = datums.filter { if case .snapshot = $0 { return true } else { return false } }.count
        #expect(snapshotCount == 2)
    }

    @Test("from: skips Polar points whose value is nil (defensive — aggregator should already filter)")
    func skipsNilPolarValue() {
        let polar = [
            LFHFAggregator.NightlyValue(id: UUID(), night: referenceDate, value: nil, validWindowCount: 0),
            polarPoint(daysBefore: 0, hrMean: 64),
        ]
        let datums = HeartRateTrendDatum.from(snapshots: [], entries: [], polarSeries: polar)
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(polarCount == 1)
    }

    @Test("from: combines HK snapshots, anxiety entries, and Polar points in a single array")
    func combinesAllThree() {
        let snapshots = [snapshot(daysBefore: 1, restingHR: 60)]
        let entries = [entry(daysBefore: 0, severity: 4)]
        let polar = [polarPoint(daysBefore: 0, hrMean: 65)]
        let datums = HeartRateTrendDatum.from(
            snapshots: snapshots,
            entries: entries,
            polarSeries: polar
        )
        let snapshotCount = datums.filter { if case .snapshot = $0 { return true } else { return false } }.count
        let entryCount = datums.filter { if case .entry = $0 { return true } else { return false } }.count
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(snapshotCount == 1)
        #expect(entryCount == 1)
        #expect(polarCount == 1)
    }

    @Test("hasAnyData: false when no HK restingHR and no Polar points")
    func hasAnyDataEmpty() {
        #expect(HeartRateTrendDatum.hasAnyData(snapshots: [], polarSeries: []) == false)
        let allNil = [snapshot(daysBefore: 0, restingHR: nil)]
        #expect(HeartRateTrendDatum.hasAnyData(snapshots: allNil, polarSeries: []) == false)
    }

    @Test("hasAnyData: true when only Polar series has values")
    func hasAnyDataPolarOnly() {
        #expect(HeartRateTrendDatum.hasAnyData(
            snapshots: [],
            polarSeries: [polarPoint(daysBefore: 0, hrMean: 64)]
        ) == true)
    }
}
