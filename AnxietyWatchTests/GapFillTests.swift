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

    @Test("2-day gap revisits the last snapshot day and fills the missed day")
    func twoDayGap() throws {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 22)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        // Gap: Mar 22 → Mar 24 = 2 days apart. Revisit Mar 22 (its row froze
        // at whatever state the last session left it in) and fill Mar 23.
        try #require(dates.count == 2)
        #expect(calendar.isDate(dates[0], inSameDayAs: date(2026, 3, 22)))
        #expect(calendar.isDate(dates[1], inSameDayAs: date(2026, 3, 23)))
    }

    @Test("5-day gap revisits the last snapshot day and fills 4 missed dates")
    func fiveDayGap() throws {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 19)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        // Gap: Mar 19 → Mar 24 = 5 days apart. Revisit Mar 19, fill Mar 20-23.
        try #require(dates.count == 5)
        #expect(calendar.isDate(dates[0], inSameDayAs: date(2026, 3, 19)))
        #expect(calendar.isDate(dates[4], inSameDayAs: date(2026, 3, 23)))
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

    @Test("Gap includes the last snapshot date so its late-landing fields heal")
    func gapIncludesLastSnapshot() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 20)
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today)

        // The last existing row froze at whatever state its last aggregation
        // saw — often a morning shell missing overnight sleep and the final
        // resting HR. A multi-day away-gap exceeds the trailing lookback
        // (recentAggregationLookbackDays), so gap-fill is the only path that
        // revisits it.
        #expect(dates.contains { calendar.isDate($0, inSameDayAs: lastSnapshot) })
    }

    // MARK: - Cap at maxDays

    @Test("Gap is capped at maxDays+1 dates (revisit day + 90 missed days) by default")
    func cappedAt90() {
        let today = date(2026, 3, 24)
        let longAgo = date(2025, 1, 1) // ~448 days ago
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: longAgo, today: today)

        #expect(dates.count == 91)
    }

    @Test("Custom maxDays cap is respected")
    func customCap() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 2, 1) // 51 days ago
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today, maxDays: 10)

        // Revisit day + 10 capped missed days.
        #expect(dates.count == 11)
    }

    @Test("Gap within maxDays is not truncated")
    func withinCap() {
        let today = date(2026, 3, 24)
        let lastSnapshot = date(2026, 3, 20) // 4 days ago
        let dates = HealthDataCoordinator.gapDates(lastSnapshotDate: lastSnapshot, today: today, maxDays: 90)

        // 4 days apart → revisit Mar 20 + fill Mar 21, 22, 23
        #expect(dates.count == 4)
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
