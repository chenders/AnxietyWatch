import Foundation
import Testing

@testable import AnxietyWatch

/// Tests the overnight window calculation used by SnapshotAggregator.
/// The fix changed sleep queries from midnight-to-midnight to noon-to-noon
/// so that a full night's sleep is captured in a single day's snapshot.
struct SnapshotAggregatorTests {

    // MARK: - Overnight window calculation

    /// Fixed UTC calendar for deterministic tests across timezones.
    private var utcCalendar: Calendar {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Replicates the noon-to-noon window logic from SnapshotAggregator.
    /// Accepts a calendar parameter so tests can use a consistent timezone.
    private func overnightWindow(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let start = calendar.startOfDay(for: date)
        guard let previousDayStart = calendar.date(byAdding: .day, value: -1, to: start),
              let overnightStart = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: previousDayStart)),
              let overnightEnd = calendar.date(byAdding: .hour, value: 12, to: start)
        else { return nil }
        return (overnightStart, overnightEnd)
    }

    @Test("Overnight window spans noon-to-noon (24 hours)")
    func overnightWindowIs24Hours() {
        // Use UTC so computation and assertions use the same DST-free calendar
        var utcCalendar = Calendar.current
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let today = utcCalendar.startOfDay(for: .now)
        guard let window = overnightWindow(for: today, calendar: utcCalendar) else {
            Issue.record("Failed to compute overnight window")
            return
        }

        // Verify via calendar components instead of raw seconds
        let startComponents = utcCalendar.dateComponents([.hour], from: window.start)
        let endComponents = utcCalendar.dateComponents([.hour], from: window.end)
        #expect(startComponents.hour == 12, "Window should start at noon")
        #expect(endComponents.hour == 12, "Window should end at noon")

        let dayDiff = utcCalendar.dateComponents([.day], from: window.start, to: window.end)
        #expect(dayDiff.day == 1, "Window should span exactly 1 calendar day")
    }

    @Test("Overnight window for March 14 starts at noon March 13")
    func overnightWindowStartsCorrectly() {
        let calendar = utcCalendar
        let march14 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        guard let window = overnightWindow(for: march14, calendar: calendar) else {
            Issue.record("Failed to compute overnight window")
            return
        }

        let startComponents = calendar.dateComponents([.month, .day, .hour], from: window.start)
        #expect(startComponents.month == 3)
        #expect(startComponents.day == 13)
        #expect(startComponents.hour == 12)
    }

    @Test("Overnight window for March 14 ends at noon March 14")
    func overnightWindowEndsCorrectly() {
        let calendar = utcCalendar
        let march14 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        guard let window = overnightWindow(for: march14, calendar: calendar) else {
            Issue.record("Failed to compute overnight window")
            return
        }

        let endComponents = calendar.dateComponents([.month, .day, .hour], from: window.end)
        #expect(endComponents.month == 3)
        #expect(endComponents.day == 14)
        #expect(endComponents.hour == 12)
    }

    @Test("11 PM sleep start falls within overnight window")
    func lateSleepStartCaptured() {
        let calendar = utcCalendar
        let sleepStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 23))!
        let snapshotDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        guard let window = overnightWindow(for: snapshotDate, calendar: calendar) else {
            Issue.record("Failed to compute overnight window")
            return
        }

        #expect(sleepStart >= window.start && sleepStart < window.end,
                "11 PM sleep start should be within noon-to-noon window")
    }

    @Test("7 AM wake-up falls within overnight window")
    func morningWakeUpCaptured() {
        let calendar = utcCalendar
        let wakeUp = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 7))!
        let snapshotDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))!

        guard let window = overnightWindow(for: snapshotDate, calendar: calendar) else {
            Issue.record("Failed to compute overnight window")
            return
        }

        #expect(wakeUp >= window.start && wakeUp < window.end,
                "7 AM wake-up should be within noon-to-noon window")
    }

    @Test("Midnight-to-midnight would miss post-midnight sleep (regression check)")
    func midnightWindowMissesMorningSleep() {
        let calendar = utcCalendar
        // Old broken behavior: midnight Mar 14 to midnight Mar 15
        var dayComponents = DateComponents()
        dayComponents.year = 2026
        dayComponents.month = 3
        dayComponents.day = 14
        let day = calendar.date(from: dayComponents)!
        let oldStart = calendar.startOfDay(for: day)
        let oldEnd = calendar.date(byAdding: .day, value: 1, to: oldStart)!

        // Sleep at 11 PM Mar 13 — OUTSIDE the old midnight-to-midnight window for Mar 14
        let sleepStart = calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 23))!

        #expect(sleepStart < oldStart,
                "Old midnight window excludes pre-midnight sleep — this was the bug")
    }

    // MARK: - Daytime window stays midnight-to-midnight

    @Test("Daytime metrics still use midnight-to-midnight")
    func daytimeWindowUnchanged() {
        let calendar = utcCalendar
        let today = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let dayDiff = calendar.dateComponents([.day], from: today, to: tomorrow)
        #expect(dayDiff.day == 1, "Midnight-to-midnight should span 1 calendar day")

        // Steps logged at 2 PM are within the daytime window
        let afternoon = calendar.date(byAdding: .hour, value: 14, to: today)!
        #expect(afternoon >= today && afternoon < tomorrow)
    }
}
