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

    @Test("Current 7-day window ends at now")
    func currentWeekEnd() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        #expect(w.end == now)
    }

    @Test("Current 7-day window start is at midnight, periodDays before now")
    func currentWeekStart() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let expectedStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -7, to: now)!)
        #expect(w.start == expectedStart)
    }

    @Test("Current window start is always at midnight")
    func currentStartIsMidnight() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let c = calendar.dateComponents([.hour, .minute, .second], from: w.start)
        #expect(c.hour == 0 && c.minute == 0 && c.second == 0)
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

    @Test("Snapshot from 7 days ago is included in current 7-day window")
    func sevenDaysAgoIncluded() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let sevenDaysAgo = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -7, to: now)!)
        #expect(sevenDaysAgo >= w.start)
    }

    @Test("Snapshot from 8 days ago is excluded from 7-day window")
    func eightDaysAgoExcluded() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        let eightDaysAgo = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -8, to: now)!)
        #expect(eightDaysAgo < w.start)
    }

    // MARK: - Previous period (offset -1)

    @Test("Previous 7-day window spans exactly 7 days")
    func previousWeekSpan() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: -1)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 7)
    }

    @Test("Past windows are contiguous with each other")
    func pastWindowsContiguous() {
        for offset in -5 ..< -1 {
            let w = TrendWindow(now: now, periodDays: 7, pageOffset: offset)
            let next = TrendWindow(now: now, periodDays: 7, pageOffset: offset + 1)
            #expect(w.end == next.start, "Gap between offset \(offset) and \(offset + 1)")
        }
    }

    @Test("Past window 30-day spans exactly 30 days")
    func pastMonthSpan() {
        let w = TrendWindow(now: now, periodDays: 30, pageOffset: -1)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 30)
    }

    @Test("Past window 90-day spans exactly 90 days")
    func pastQuarterSpan() {
        let w = TrendWindow(now: now, periodDays: 90, pageOffset: -1)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 90)
    }

    // MARK: - Boundary snapping for past windows

    @Test("Past window start is always at midnight")
    func pastStartIsMidnight() {
        for offset in -3 ... -1 {
            let w = TrendWindow(now: now, periodDays: 7, pageOffset: offset)
            let c = calendar.dateComponents([.hour, .minute, .second], from: w.start)
            #expect(c.hour == 0 && c.minute == 0 && c.second == 0,
                    "Start not midnight for offset \(offset)")
        }
    }

    @Test("Past window end is always at midnight")
    func pastEndIsMidnight() {
        for offset in -3 ... -1 {
            let w = TrendWindow(now: now, periodDays: 7, pageOffset: offset)
            let c = calendar.dateComponents([.hour, .minute, .second], from: w.end)
            #expect(c.hour == 0 && c.minute == 0 && c.second == 0,
                    "End not midnight for offset \(offset)")
        }
    }

    // MARK: - Future prevention

    @Test("Current window end is exactly now, not in the future")
    func currentWindowEndsAtNow() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 0)
        #expect(w.end == now)
    }

    @Test("Positive offsets are prevented by UI but still produce valid windows")
    func positiveOffsetStillValid() {
        let w = TrendWindow(now: now, periodDays: 7, pageOffset: 1)
        let days = calendar.dateComponents([.day], from: w.start, to: w.end).day!
        #expect(days == 7)
    }

    // MARK: - Different times of day

    @Test("Current window start is the same regardless of time of day")
    func startConsistentAcrossTimeOfDay() {
        var earlyC = DateComponents()
        earlyC.year = 2026; earlyC.month = 3; earlyC.day = 24; earlyC.hour = 0; earlyC.minute = 1
        let earlyMorning = calendar.date(from: earlyC)!

        var lateC = DateComponents()
        lateC.year = 2026; lateC.month = 3; lateC.day = 24; lateC.hour = 23; lateC.minute = 59
        let lateNight = calendar.date(from: lateC)!

        let wEarly = TrendWindow(now: earlyMorning, periodDays: 7, pageOffset: 0)
        let wLate = TrendWindow(now: lateNight, periodDays: 7, pageOffset: 0)

        // Start should be the same (both anchor to startOfDay minus periodDays)
        #expect(wEarly.start == wLate.start)
        // End differs (it's "now" in each case)
        #expect(wEarly.end == earlyMorning)
        #expect(wLate.end == lateNight)
    }
}
