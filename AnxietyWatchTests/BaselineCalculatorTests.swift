import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for BaselineCalculator — rolling baselines, deviation detection,
/// and the startOfDay cutoff fix.
struct BaselineCalculatorTests {

    // MARK: - Helpers

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

    private func makeSnapshot(daysAgo: Int, hrvAvg: Double?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.hrvAvg = hrvAvg
        return snapshot
    }

    private func makeSnapshotsWithHRV(_ values: [(daysAgo: Int, hrv: Double)]) -> [HealthSnapshot] {
        values.map { makeSnapshot(daysAgo: $0.daysAgo, hrvAvg: $0.hrv) }
    }

    // MARK: - Baseline calculation

    @Test("Baseline requires at least 14 data points")
    func baselineRequiresMinimumData() {
        let snapshots = makeSnapshotsWithHRV(
            (0..<13).map { ($0, 45.0) }
        )
        let result = BaselineCalculator.hrvBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result == nil)
    }

    @Test("Baseline is computed with 14+ data points")
    func baselineComputedWithEnoughData() {
        let snapshots = makeSnapshotsWithHRV(
            (0..<14).map { ($0, 45.0) }
        )
        let result = BaselineCalculator.hrvBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
    }

    @Test("Baseline mean is correct")
    func baselineMeanCorrect() {
        // 14 values alternating 40 and 60 → mean = 50
        let snapshots = makeSnapshotsWithHRV(
            (0..<14).map { ($0, $0 % 2 == 0 ? 40.0 : 60.0) }
        )
        let result = BaselineCalculator.hrvBaseline(from: snapshots, anchorDate: referenceDate)!
        #expect(abs(result.mean - 50.0) < 0.01)
    }

    @Test("Baseline uses sample standard deviation (N-1)")
    func baselineStdDevCorrect() {
        // 14 values alternating 40 and 60 → mean=50
        // Sum of squared deviations = 14 * 100 = 1400
        // Sample variance (N-1) = 1400 / 13 ≈ 107.69, stddev ≈ 10.38
        let snapshots = makeSnapshotsWithHRV(
            (0..<14).map { ($0, $0 % 2 == 0 ? 40.0 : 60.0) }
        )
        let result = BaselineCalculator.hrvBaseline(from: snapshots, anchorDate: referenceDate)!
        let expectedStdDev = (1400.0 / 13.0).squareRoot() // ≈10.38
        #expect(abs(result.standardDeviation - expectedStdDev) < 0.01)
    }

    @Test("Lower bound is mean minus threshold * stddev")
    func lowerBoundCorrect() {
        let snapshots = makeSnapshotsWithHRV(
            (0..<14).map { ($0, $0 % 2 == 0 ? 40.0 : 60.0) }
        )
        let result = BaselineCalculator.hrvBaseline(from: snapshots, anchorDate: referenceDate)!
        let expected = result.mean - Constants.deviationThreshold * result.standardDeviation
        #expect(abs(result.lowerBound - expected) < 0.01)
    }

    // MARK: - Cutoff includes boundary day

    @Test("Snapshots on the boundary day are included in baseline")
    func boundaryDayIncluded() {
        // Create snapshots for exactly 30 days back through today
        var snapshots: [HealthSnapshot] = []
        for day in 0...30 {
            snapshots.append(makeSnapshot(daysAgo: day, hrvAvg: 45))
        }

        let result = BaselineCalculator.hrvBaseline(from: snapshots, windowDays: 30, anchorDate: referenceDate)
        #expect(result != nil)
        // All 31 values should be included (days 0–30)
        #expect(abs(result!.mean - 45.0) < 0.01)
    }

    @Test("Snapshots outside the window are excluded")
    func outsideWindowExcluded() {
        // One snapshot at day 31 (outside 30-day window), 14 within
        var snapshots = [makeSnapshot(daysAgo: 31, hrvAvg: 100)] // outside
        snapshots += (0..<14).map { makeSnapshot(daysAgo: $0, hrvAvg: 40) }

        let result = BaselineCalculator.hrvBaseline(from: snapshots, windowDays: 30, anchorDate: referenceDate)
        #expect(result != nil)
        // Mean should be 40 (the outlier at 100 should be excluded)
        #expect(abs(result!.mean - 40.0) < 0.01)
    }

    // MARK: - Below baseline detection

    @Test("Detects HRV below baseline")
    func detectsBelowBaseline() {
        // 30 days of HRV at 50, then last 3 days drop to 30
        var snapshots: [HealthSnapshot] = []
        for day in 3...29 {
            snapshots.append(makeSnapshot(daysAgo: day, hrvAvg: 50))
        }
        for day in 0...2 {
            snapshots.append(makeSnapshot(daysAgo: day, hrvAvg: 30))
        }

        let isBelow = BaselineCalculator.isHRVBelowBaseline(snapshots: snapshots, anchorDate: referenceDate)
        #expect(isBelow == true)
    }

    @Test("Normal HRV is not flagged")
    func normalHRVNotFlagged() {
        let snapshots = makeSnapshotsWithHRV(
            (0...29).map { ($0, 50.0) }
        )
        let isBelow = BaselineCalculator.isHRVBelowBaseline(snapshots: snapshots, anchorDate: referenceDate)
        #expect(isBelow == false)
    }

    // MARK: - Recent average

    @Test("Recent average computes correctly for 3 days")
    func recentAverageCorrect() {
        let snapshots = [
            makeSnapshot(daysAgo: 0, hrvAvg: 40),
            makeSnapshot(daysAgo: 1, hrvAvg: 50),
            makeSnapshot(daysAgo: 2, hrvAvg: 60),
            makeSnapshot(daysAgo: 10, hrvAvg: 100), // outside 3-day window
        ]
        let avg = BaselineCalculator.recentAverage(from: snapshots, days: 3, keyPath: \.hrvAvg, anchorDate: referenceDate)
        #expect(avg != nil)
        #expect(abs(avg! - 50.0) < 0.01)
    }

    @Test("Recent average returns nil when no data in window")
    func recentAverageNilWhenEmpty() {
        let snapshots = [
            makeSnapshot(daysAgo: 10, hrvAvg: 50),
        ]
        let avg = BaselineCalculator.recentAverage(from: snapshots, days: 3, keyPath: \.hrvAvg, anchorDate: referenceDate)
        #expect(avg == nil)
    }

    // MARK: - Sleep baseline

    private func makeSnapshotWithSleep(daysAgo: Int, sleepMin: Int?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.sleepDurationMin = sleepMin
        return snapshot
    }

    @Test("Sleep baseline requires 14+ data points")
    func sleepBaselineRequiresMinimum() {
        let snapshots = (0..<13).map { makeSnapshotWithSleep(daysAgo: $0, sleepMin: 420) }
        #expect(BaselineCalculator.sleepBaseline(from: snapshots, anchorDate: referenceDate) == nil)
    }

    @Test("Sleep baseline computed with enough data")
    func sleepBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshotWithSleep(daysAgo: $0, sleepMin: 420) }
        let result = BaselineCalculator.sleepBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 420.0) < 0.01)
    }

    @Test("Sleep baseline excludes snapshots outside window")
    func sleepBaselineWindowFilter() {
        var snapshots = [makeSnapshotWithSleep(daysAgo: 31, sleepMin: 600)] // outside
        snapshots += (0..<14).map { makeSnapshotWithSleep(daysAgo: $0, sleepMin: 400) }
        let result = BaselineCalculator.sleepBaseline(from: snapshots, windowDays: 30, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 400.0) < 0.01)
    }

    @Test("Sleep baseline ignores snapshots with nil sleep")
    func sleepBaselineIgnoresNil() {
        var snapshots = (0..<14).map { makeSnapshotWithSleep(daysAgo: $0, sleepMin: 420) }
        snapshots.append(makeSnapshotWithSleep(daysAgo: 14, sleepMin: nil))
        let result = BaselineCalculator.sleepBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 420.0) < 0.01)
    }

    // MARK: - Outlier trimming

    @Test("Single extreme outlier does not skew baseline mean")
    func outlierDoesNotSkewMean() {
        // 14 values at 50, plus 1 extreme outlier at 200
        var snapshots = (0..<14).map { makeSnapshot(daysAgo: $0, hrvAvg: 50.0) }
        snapshots.append(makeSnapshot(daysAgo: 14, hrvAvg: 200.0))

        let result = BaselineCalculator.hrvBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        // Mean should be close to 50, not pulled toward 200
        #expect(result!.mean < 55.0)
    }

    @Test("Outlier trimming preserves normal variance")
    func outlierTrimmingPreservesNormalVariance() {
        // 14 values with normal spread (40-60), no outliers
        let snapshots = makeSnapshotsWithHRV(
            (0..<14).map { ($0, 40.0 + Double($0 % 3) * 10.0) }
        )
        let result = BaselineCalculator.hrvBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        // All values are within normal range — none should be trimmed
        // Mean of [40,50,60,40,50,60,40,50,60,40,50,60,40,50] ≈ 49.3
        #expect(abs(result!.mean - 49.286) < 0.01)
    }

    // MARK: - Respiratory rate baseline

    private func makeSnapshotWithRR(daysAgo: Int, rr: Double?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.respiratoryRate = rr
        return snapshot
    }

    @Test("Respiratory rate baseline requires 14+ data points")
    func respiratoryRateBaselineRequiresMinimum() {
        let snapshots = (0..<13).map { makeSnapshotWithRR(daysAgo: $0, rr: 15.0) }
        #expect(BaselineCalculator.respiratoryRateBaseline(from: snapshots, anchorDate: referenceDate) == nil)
    }

    @Test("Respiratory rate baseline computed with enough data")
    func respiratoryRateBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshotWithRR(daysAgo: $0, rr: 15.0) }
        let result = BaselineCalculator.respiratoryRateBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 15.0) < 0.01)
    }

    @Test("Respiratory rate baseline excludes snapshots outside window")
    func respiratoryRateBaselineWindowFilter() {
        var snapshots = [makeSnapshotWithRR(daysAgo: 31, rr: 25.0)] // outside
        snapshots += (0..<14).map { makeSnapshotWithRR(daysAgo: $0, rr: 14.0) }
        let result = BaselineCalculator.respiratoryRateBaseline(from: snapshots, windowDays: 30, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 14.0) < 0.01)
    }

    @Test("Respiratory rate baseline uses sample variance (N-1)")
    func respiratoryRateBaselineVariance() {
        // 14 values alternating 12 and 18 → mean = 15
        let snapshots = (0..<14).map { makeSnapshotWithRR(daysAgo: $0, rr: $0 % 2 == 0 ? 12.0 : 18.0) }
        let result = BaselineCalculator.respiratoryRateBaseline(from: snapshots, anchorDate: referenceDate)!
        // Sum of squared deviations = 14 * 9 = 126, sample variance = 126/13
        let expectedStdDev = (126.0 / 13.0).squareRoot()
        #expect(abs(result.standardDeviation - expectedStdDev) < 0.01)
    }
}
