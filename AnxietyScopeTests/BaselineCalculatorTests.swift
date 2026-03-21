import Foundation
import SwiftData
import Testing

@testable import AnxietyScope

/// Tests for BaselineCalculator — rolling baselines, deviation detection,
/// and the startOfDay cutoff fix.
struct BaselineCalculatorTests {

    // MARK: - Helpers

    private func makeSnapshot(daysAgo: Int, hrvAvg: Double?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.hrvAvg = hrvAvg
        return snapshot
    }

    private func makeSnapshotsWithHRV(_ values: [(daysAgo: Int, hrv: Double)]) -> [HealthSnapshot] {
        values.map { makeSnapshot(daysAgo: $0.daysAgo, hrvAvg: $0.hrv) }
    }

    // MARK: - Baseline calculation

    @Test("Baseline requires at least 3 data points")
    func baselineRequiresMinimumData() {
        let snapshots = [
            makeSnapshot(daysAgo: 0, hrvAvg: 40),
            makeSnapshot(daysAgo: 1, hrvAvg: 45),
        ]
        let result = BaselineCalculator.hrvBaseline(from: snapshots)
        #expect(result == nil)
    }

    @Test("Baseline is computed with 3+ data points")
    func baselineComputedWithEnoughData() {
        let snapshots = makeSnapshotsWithHRV([
            (0, 40), (1, 45), (2, 50),
        ])
        let result = BaselineCalculator.hrvBaseline(from: snapshots)
        #expect(result != nil)
    }

    @Test("Baseline mean is correct")
    func baselineMeanCorrect() {
        let snapshots = makeSnapshotsWithHRV([
            (0, 40), (1, 50), (2, 60),
        ])
        let result = BaselineCalculator.hrvBaseline(from: snapshots)!
        #expect(abs(result.mean - 50.0) < 0.01)
    }

    @Test("Baseline standard deviation is correct")
    func baselineStdDevCorrect() {
        // Values: 40, 50, 60 → mean=50, variance=((100+0+100)/3)=66.67, stddev≈8.165
        let snapshots = makeSnapshotsWithHRV([
            (0, 40), (1, 50), (2, 60),
        ])
        let result = BaselineCalculator.hrvBaseline(from: snapshots)!
        let expectedStdDev = (200.0 / 3.0).squareRoot() // ≈8.165
        #expect(abs(result.standardDeviation - expectedStdDev) < 0.01)
    }

    @Test("Lower bound is mean minus threshold * stddev")
    func lowerBoundCorrect() {
        let snapshots = makeSnapshotsWithHRV([
            (0, 40), (1, 50), (2, 60),
        ])
        let result = BaselineCalculator.hrvBaseline(from: snapshots)!
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

        let result = BaselineCalculator.hrvBaseline(from: snapshots, windowDays: 30)
        #expect(result != nil)
        // All 31 values should be included (days 0–30)
        #expect(abs(result!.mean - 45.0) < 0.01)
    }

    @Test("Snapshots outside the window are excluded")
    func outsideWindowExcluded() {
        // Only one snapshot at day 31 (outside 30-day window), three within
        let snapshots = [
            makeSnapshot(daysAgo: 31, hrvAvg: 100), // outside
            makeSnapshot(daysAgo: 0, hrvAvg: 40),
            makeSnapshot(daysAgo: 1, hrvAvg: 40),
            makeSnapshot(daysAgo: 2, hrvAvg: 40),
        ]
        let result = BaselineCalculator.hrvBaseline(from: snapshots, windowDays: 30)
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

        let isBelow = BaselineCalculator.isHRVBelowBaseline(snapshots: snapshots)
        #expect(isBelow == true)
    }

    @Test("Normal HRV is not flagged")
    func normalHRVNotFlagged() {
        let snapshots = makeSnapshotsWithHRV(
            (0...29).map { ($0, 50.0) }
        )
        let isBelow = BaselineCalculator.isHRVBelowBaseline(snapshots: snapshots)
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
        let avg = BaselineCalculator.recentAverage(from: snapshots, days: 3, keyPath: \.hrvAvg)
        #expect(avg != nil)
        #expect(abs(avg! - 50.0) < 0.01)
    }

    @Test("Recent average returns nil when no data in window")
    func recentAverageNilWhenEmpty() {
        let snapshots = [
            makeSnapshot(daysAgo: 10, hrvAvg: 50),
        ]
        let avg = BaselineCalculator.recentAverage(from: snapshots, days: 3, keyPath: \.hrvAvg)
        #expect(avg == nil)
    }
}
