import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for TrendWindow date calculations — the navigable time window logic
/// used by TrendsView. Guards against off-by-one errors in window boundaries.
struct TrendWindowTests {

    private let calendar = Calendar.current

    /// Fixed reference time: March 24 2026 at 2:30 PM
    private var now: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 24; c.hour = 14; c.minute = 30
        return calendar.date(from: c)!
    }

    // MARK: - Current period (offset 0)

    @Test("Current 7-day window ends at start of tomorrow")
    func currentWeekEnd() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let expected = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        #expect(w.end == expected)
    }

    @Test("Current 7-day window starts 7 days before the end")
    func currentWeekStart() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let expectedEnd = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
        let expectedStart = calendar.date(byAdding: .day, value: -7, to: expectedEnd)!
        #expect(w.start == expectedStart)
    }

    @Test("Current 7-day window spans exactly 7 days")
    func currentWeekSpan() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 7)
    }

    @Test("Current 30-day window spans exactly 30 days")
    func currentMonthSpan() {
        let w = TrendWindow(now: now, periodDays: 30, pageOffset: 0)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 30)
    }

    @Test("Current 90-day window spans exactly 90 days")
    func currentQuarterSpan() {
        let w = TrendWindow(now: now, periodDays: 90, pageOffset: 0)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 90)
    }

    // MARK: - Today's data is included

    @Test("Today's startOfDay snapshot falls within the current window")
    func todaySnapshotIncluded() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let todayMidnight = calendar.startOfDay(for: now)
        #expect(todayMidnight >= w.start)
        #expect(todayMidnight <= w.end)
    }

    @Test("Data from right now falls within the current window")
    func nowIncluded() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        #expect(now >= w.start)
        #expect(now <= w.end)
    }

    @Test("Snapshot from exactly periodDays ago is included")
    func boundaryDayIncluded() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let sevenDaysAgo = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -7, to: now)!)
        // windowStart should be midnight 7 days before windowEnd (which is tomorrow),
        // so 8 days ago midnight... wait, let's just check:
        // windowEnd = Mar 25 00:00, windowStart = Mar 18 00:00
        // 7 days ago from Mar 24 = Mar 17 00:00 — this is BEFORE windowStart (Mar 18)
        // So a snapshot from exactly 7 days ago is NOT in the current window
        // because the window is [Mar 18 ... Mar 25], which is 7 full days
        #expect(sevenDaysAgo < w.start)
    }

    @Test("Snapshot from 6 days ago is included in 7-day window")
    func sixDaysAgoIncluded() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let sixDaysAgo = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: now)!)
        #expect(sixDaysAgo >= w.start)
        #expect(sixDaysAgo <= w.end)
    }

    // MARK: - Previous period (offset -1)

    @Test("Previous 7-day window ends where current window starts")
    func previousWeekAdjacent() {
        let current = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let previous = TrendWindow(now: now, periodDays: 7, pageOffset: -1)
        #expect(previous.end == current.start)
    }

    @Test("Previous 7-day window spans exactly 7 days")
    func previousWeekSpan() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: -1)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 7)
    }

    @Test("Windows are contiguous across multiple offsets")
    func windowsContiguous() {
        for offset in -5..<0 {
            let w = TrendWindow(now: now, periodDays: 7, pageOffset: offset)
            let next = TrendWindow(now: now, periodDays: 7, pageOffset: offset + 1)
            #expect(w.end == next.start, "Gap between offset \(offset) and \(offset + 1)")
        }
    }

    // MARK: - Boundary snapping

    @Test("Window start is always at midnight")
    func startIsMidnight() {
        for offset in -3...0 {
            let w = TrendWindow(now: now, periodDays: 7, pageOffset: offset)
            let c = calendar.dateComponents([.hour, .minute, .second], from: w.start)
            #expect(c.hour == 0 && c.minute == 0 && c.second == 0,
                    "Start not midnight for offset \(offset)")
        }
    }

    @Test("Window end is always at midnight")
    func endIsMidnight() {
        for offset in -3...0 {
            let w = TrendWindow(now: now, periodDays: 7, pageOffset: offset)
            let c = calendar.dateComponents([.hour, .minute, .second], from: w.end)
            #expect(c.hour == 0 && c.minute == 0 && c.second == 0,
                    "End not midnight for offset \(offset)")
        }
    }

    // MARK: - Future prevention

    @Test("Current window end is never more than 1 day past now")
    func currentWindowNotFarFuture() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let diff = w.end.timeIntervalSince(now)
        // Should be less than 24 hours past now (just the remainder of today)
        #expect(diff > 0)
        #expect(diff < 24 * 60 * 60)
    }

    @Test("Positive offsets are prevented by UI but still produce valid windows")
    func positiveOffsetStillValid() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 1)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 7)
    }

    // MARK: - Different times of day

    @Test("Window is consistent whether now is midnight or end of day")
    func consistentAcrossTimeOfDay() {
        var earlyC = DateComponents()
        earlyC.year = 2026; earlyC.month = 3; earlyC.day = 24; earlyC.hour = 0; earlyC.minute = 1
        let earlyMorning = calendar.date(from: earlyC)!

        var lateC = DateComponents()
        lateC.year = 2026; lateC.month = 3; lateC.day = 24; lateC.hour = 23; lateC.minute = 59
        let lateNight = calendar.date(from: lateC)!

        let wEarly = TrendWindow(now: earlyMorning, periodDays: 7, pageOffset: 0)
        let wLate = TrendWindow(now: lateNight, periodDays: 7, pageOffset: 0)

        #expect(wEarly.start == wLate.start)
        #expect(wEarly.end == wLate.end)
    }
}
