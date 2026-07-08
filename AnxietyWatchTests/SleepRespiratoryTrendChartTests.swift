import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for SleepRespiratoryTrendChart's empty-state gate. Previously this gate
/// was an inline `let` in `body` and was the one trend chart whose empty-state
/// gate had no coverage (F-050); it is now a pure static helper.
struct SleepRespiratoryTrendChartTests {

    private let day = Date(timeIntervalSince1970: 1_760_000_000)

    private func cpap() -> CPAPSession {
        CPAPSession(
            date: day, ahi: 2.0, totalUsageMinutes: 420,
            pressureMin: 6, pressureMax: 12, pressureMean: 9,
            obstructiveEvents: 1, centralEvents: 0, hypopneaEvents: 1,
            importSource: "csv"
        )
    }

    private func snapshot(
        nadirOvernight: Double? = nil,
        nadirOpportunistic: Double? = nil,
        t90: Int? = nil
    ) -> HealthSnapshot {
        let s = HealthSnapshot(date: day)
        s.spo2NadirOvernight = nadirOvernight
        s.spo2NadirOpportunistic = nadirOpportunistic
        s.spo2TimeBelow90Min = t90
        return s
    }

    @Test("Empty inputs → no data")
    func emptyIsEmpty() {
        #expect(SleepRespiratoryTrendChart.hasAnyData(sessions: [], snapshots: []) == false)
        // Snapshots with no SpO₂/T90 fields also don't count.
        #expect(SleepRespiratoryTrendChart.hasAnyData(sessions: [], snapshots: [snapshot()]) == false)
    }

    @Test("A CPAP session alone counts as data")
    func cpapSessionCounts() {
        #expect(SleepRespiratoryTrendChart.hasAnyData(sessions: [cpap()], snapshots: []) == true)
    }

    @Test("An oximeter nadir alone counts as data")
    func oximeterNadirCounts() {
        #expect(SleepRespiratoryTrendChart.hasAnyData(
            sessions: [], snapshots: [snapshot(nadirOvernight: 88)]) == true)
    }

    @Test("An Apple Watch (opportunistic) nadir alone counts as data")
    func opportunisticNadirCounts() {
        #expect(SleepRespiratoryTrendChart.hasAnyData(
            sessions: [], snapshots: [snapshot(nadirOpportunistic: 90)]) == true)
    }

    @Test("A T90 value alone counts as data")
    func t90Counts() {
        #expect(SleepRespiratoryTrendChart.hasAnyData(
            sessions: [], snapshots: [snapshot(t90: 5)]) == true)
    }
}
