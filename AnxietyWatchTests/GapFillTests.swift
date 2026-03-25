import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for HealthDataCoordinator.gapDates — the pure calculation that
/// determines which dates need gap-filling between the last snapshot and today.
struct GapFillTests {

    private let calendar = Calendar.current

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return calendar.date(from: c)!
    }

    // MARK: - No gap

    @Test("No gap when last snapshot is yesterday")
    func noGapYesterday() {
        let today = date(2026, 3, 24)
        let yesterday = date(2026, 3, 23)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: yesterday, today: today)
        #expect(dates.isEmpty)
    }

    @Test("No gap when last snapshot is today")
    func noGapToday() {
        let today = date(2026, 3, 24)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: today, today: today)
        #expect(dates.isEmpty)
    }

    @Test("No gap when lastSnapshotDate is nil")
    func noGapNil() {
        let today = date(2026, 3, 24)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: nil, today: today)
        #expect(dates.isEmpty)
    }

    // MARK: - Gap detection

    @Test("2-day gap fills 1 date")
    func twoDayGap() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 22)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        // Gap: Mar 22 → Mar 24 = 2 days apart, fill Mar 23
        #expect(dates.count == 1)
        #expect(calendar.isDate(dates[0], inSameDayAs: date(2026, 3, 23)))
    }

    @Test("5-day gap fills 4 dates")
    func fiveDayGap() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 19)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        // Gap: Mar 19 → Mar 24 = 5 days apart, fill Mar 20, 21, 22, 23
        #expect(dates.count == 4)
        #expect(calendar.isDate(dates[0], inSameDayAs: date(2026, 3, 20)))
        #expect(calendar.isDate(dates[3], inSameDayAs: date(2026, 3, 23)))
    }

    @Test("Gap does not include today (handled by observers)")
    func gapExcludesToday() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 20)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        for d in dates {
            #expect(!calendar.isDate(d, inSameDayAs: today), "Today should not be in gap dates")
        }
    }

    @Test("Gap does not include the last snapshot date")
    func gapExcludesLastSnapshot() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 20)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        for d in dates {
            #expect(!calendar.isDate(d, inSameDayAs: lastSnapshot), "Last snapshot date should not be in gap")
        }
    }

    // MARK: - Cap at maxDays

    @Test("Gap is capped at 90 days by default")
    func cappedAt90() {
        let today = date(2026, 3, 24)
        let longAgo = date(2025, 1, 1) // ~448 days ago
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: longAgo, today: today)

        #expect(dates.count == 90)
    }

    @Test("Custom maxDays cap is respected")
    func customCap() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 2, 1) // 51 days ago
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today, maxDays: 10)

        #expect(dates.count == 10)
    }

    @Test("Gap within maxDays is not truncated")
    func withinCap() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 20) // 4 days ago
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today, maxDays: 90)

        // 4 days apart → 3 gap dates (Mar 21, 22, 23)
        #expect(dates.count == 3)
    }

    // MARK: - Dates are in order

    @Test("Gap dates are in chronological order")
    func chronologicalOrder() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 14)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        for i in 1..<dates.count {
            #expect(dates[i] > dates[i - 1], "Dates should be ascending")
        }
    }
}
