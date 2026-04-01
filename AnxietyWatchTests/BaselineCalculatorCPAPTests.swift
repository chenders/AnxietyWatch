import Foundation
import Testing

@testable import AnxietyWatch

struct BaselineCalculatorCPAPTests {

    /// Fixed reference date at noon UTC for deterministic tests — never use Date.now.
    private let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private func makeSnapshotWithAHI(daysAgo: Int, ahi: Double?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.cpapAHI = ahi
        return snapshot
    }

    private func makeSnapshotWithPressure(daysAgo: Int, pressure: Double?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.barometricPressureAvgKPa = pressure
        return snapshot
    }

    // MARK: - AHI Baseline

    @Test("AHI baseline requires 14+ data points")
    func ahiBaselineRequiresMinimum() {
        let snapshots = (0..<13).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        #expect(BaselineCalculator.cpapAHIBaseline(from: snapshots, anchorDate: referenceDate) == nil)
    }

    @Test("AHI baseline computed with enough data")
    func ahiBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 2.5) < 0.01)
    }

    @Test("AHI baseline excludes snapshots outside window")
    func ahiBaselineWindowFilter() {
        var snapshots = [makeSnapshotWithAHI(daysAgo: 31, ahi: 20.0)]
        snapshots += (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 3.0) }
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots, windowDays: 30, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 3.0) < 0.01)
    }

    @Test("AHI baseline ignores nil cpapAHI snapshots")
    func ahiBaselineIgnoresNil() {
        var snapshots = (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        snapshots.append(makeSnapshotWithAHI(daysAgo: 14, ahi: nil))
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 2.5) < 0.01)
    }

    @Test("AHI outlier trimming handles mask-off night")
    func ahiOutlierTrimming() {
        var snapshots = (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        snapshots.append(makeSnapshotWithAHI(daysAgo: 14, ahi: 40.0))
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(result!.mean < 5.0)
    }

    // MARK: - Barometric Pressure Baseline

    @Test("Barometric baseline requires 14+ data points")
    func barometricBaselineRequiresMinimum() {
        let snapshots = (0..<13).map { makeSnapshotWithPressure(daysAgo: $0, pressure: 101.3) }
        #expect(BaselineCalculator.barometricPressureBaseline(from: snapshots, anchorDate: referenceDate) == nil)
    }

    @Test("Barometric baseline computed with enough data")
    func barometricBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshotWithPressure(daysAgo: $0, pressure: 101.3) }
        let result = BaselineCalculator.barometricPressureBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 101.3) < 0.01)
    }

    @Test("Barometric baseline excludes snapshots outside window")
    func barometricBaselineWindowFilter() {
        var snapshots = [makeSnapshotWithPressure(daysAgo: 31, pressure: 95.0)]
        snapshots += (0..<14).map { makeSnapshotWithPressure(daysAgo: $0, pressure: 101.3) }
        let result = BaselineCalculator.barometricPressureBaseline(from: snapshots, windowDays: 30, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 101.3) < 0.01)
    }
}
