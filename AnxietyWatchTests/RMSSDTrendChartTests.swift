import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure-function helper that flattens the Polar overnight
/// RMSSD series and anxiety entries into the RMSSDTrendChart datum array.
/// RMSSD is Polar-only — HealthKit does not surface RMSSD as a quantity type.
@Suite("RMSSDTrendDatum builder")
@MainActor
struct RMSSDTrendChartTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 12))!
    }()

    private func polarPoint(daysBefore: Int, rmssd: Double) -> LFHFAggregator.NightlyValue {
        let night = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return LFHFAggregator.NightlyValue(
            id: UUID(),
            night: night,
            value: rmssd,
            validWindowCount: 1
        )
    }

    private func entry(daysBefore: Int, severity: Int = 3) -> AnxietyEntry {
        let timestamp = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return AnxietyEntry(timestamp: timestamp, severity: severity)
    }

    @Test("from: emits a datum for each Polar point with a non-nil value")
    func happyPath() {
        let polar = [polarPoint(daysBefore: 1, rmssd: 40), polarPoint(daysBefore: 0, rmssd: 45)]
        let datums = RMSSDTrendDatum.from(polarSeries: polar, entries: [])
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(polarCount == 2)
    }

    @Test("from: skips Polar points whose value is nil (defensive — aggregator should already filter)")
    func skipsNilValue() {
        let polar = [
            LFHFAggregator.NightlyValue(id: UUID(), night: referenceDate, value: nil, validWindowCount: 0),
            polarPoint(daysBefore: 0, rmssd: 40),
        ]
        let datums = RMSSDTrendDatum.from(polarSeries: polar, entries: [])
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(polarCount == 1)
    }

    @Test("from: includes anxiety entries as context")
    func includesEntries() {
        let datums = RMSSDTrendDatum.from(
            polarSeries: [polarPoint(daysBefore: 0, rmssd: 40)],
            entries: [entry(daysBefore: 0, severity: 4)]
        )
        let entryCount = datums.filter { if case .entry = $0 { return true } else { return false } }.count
        #expect(entryCount == 1)
    }

    @Test("hasAnyData: false when polarSeries is empty or all-nil")
    func hasAnyDataEmpty() {
        #expect(RMSSDTrendDatum.hasAnyData(polarSeries: []) == false)
        let allNil = [LFHFAggregator.NightlyValue(id: UUID(), night: referenceDate, value: nil, validWindowCount: 0)]
        #expect(RMSSDTrendDatum.hasAnyData(polarSeries: allNil) == false)
    }

    @Test("hasAnyData: true when at least one point has a value")
    func hasAnyDataPositive() {
        #expect(RMSSDTrendDatum.hasAnyData(
            polarSeries: [polarPoint(daysBefore: 0, rmssd: 40)]
        ) == true)
    }
}
