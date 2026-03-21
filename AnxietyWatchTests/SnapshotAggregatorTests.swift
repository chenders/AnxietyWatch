import Foundation
import Testing

@testable import AnxietyWatch

/// Tests the overnight window calculation used by SnapshotAggregator.
/// The fix changed sleep queries from midnight-to-midnight to noon-to-noon
/// so that a full night's sleep is captured in a single day's snapshot.
struct SnapshotAggregatorTests {

    // MARK: - Overnight window calculation

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
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 14
        let march14 = calendar.date(from: components)!

        guard let window = overnightWindow(for: march14) else {
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
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 14
        let march14 = calendar.date(from: components)!

        guard let window = overnightWindow(for: march14) else {
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
        let calendar = Calendar.current
        // Sleep started at 11 PM on March 13
        var sleepComponents = DateComponents()
        sleepComponents.year = 2026
        sleepComponents.month = 3
        sleepComponents.day = 13
        sleepComponents.hour = 23
        let sleepStart = calendar.date(from: sleepComponents)!

        // The snapshot is for March 14 (the "morning of" date)
        var dayComponents = DateComponents()
        dayComponents.year = 2026
        dayComponents.month = 3
        dayComponents.day = 14
        let snapshotDate = calendar.date(from: dayComponents)!

        guard let window = overnightWindow(for: snapshotDate) else {
            Issue.record("Failed to compute overnight window")
            return
        }

        #expect(sleepStart >= window.start && sleepStart < window.end,
                "11 PM sleep start should be within noon-to-noon window")
    }

    @Test("7 AM wake-up falls within overnight window")
    func morningWakeUpCaptured() {
        let calendar = Calendar.current
        // Woke up at 7 AM on March 14
        var wakeComponents = DateComponents()
        wakeComponents.year = 2026
        wakeComponents.month = 3
        wakeComponents.day = 14
        wakeComponents.hour = 7
        let wakeUp = calendar.date(from: wakeComponents)!

        var dayComponents = DateComponents()
        dayComponents.year = 2026
        dayComponents.month = 3
        dayComponents.day = 14
        let snapshotDate = calendar.date(from: dayComponents)!

        guard let window = overnightWindow(for: snapshotDate) else {
            Issue.record("Failed to compute overnight window")
            return
        }

        #expect(wakeUp >= window.start && wakeUp < window.end,
                "7 AM wake-up should be within noon-to-noon window")
    }

    @Test("Midnight-to-midnight would miss post-midnight sleep (regression check)")
    func midnightWindowMissesMorningSleep() {
        let calendar = Calendar.current
        // Old broken behavior: midnight Mar 14 to midnight Mar 15
        var dayComponents = DateComponents()
        dayComponents.year = 2026
        dayComponents.month = 3
        dayComponents.day = 14
        let day = calendar.date(from: dayComponents)!
        let oldStart = calendar.startOfDay(for: day)
        let oldEnd = calendar.date(byAdding: .day, value: 1, to: oldStart)!

        // Sleep at 11 PM Mar 13 — OUTSIDE the old midnight-to-midnight window for Mar 14
        var sleepComponents = DateComponents()
        sleepComponents.year = 2026
        sleepComponents.month = 3
        sleepComponents.day = 13
        sleepComponents.hour = 23
        let sleepStart = calendar.date(from: sleepComponents)!

        #expect(sleepStart < oldStart,
                "Old midnight window excludes pre-midnight sleep — this was the bug")
    }

    // MARK: - Daytime window stays midnight-to-midnight

    @Test("Daytime metrics still use midnight-to-midnight")
    func daytimeWindowUnchanged() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        // Use calendar components instead of raw seconds (avoids DST flakiness)
        let dayDiff = calendar.dateComponents([.day], from: today, to: tomorrow)
        #expect(dayDiff.day == 1, "Midnight-to-midnight should span 1 calendar day")

        // Steps logged at 2 PM today are within the daytime window
        let afternoon = calendar.date(byAdding: .hour, value: 14, to: today)!
        #expect(afternoon >= today && afternoon < tomorrow)
    }
}
