import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests that CPAPSession dates are normalized to midnight,
/// matching HealthSnapshot behavior for consistent filtering.
struct CPAPSessionTests {

    /// Fixed reference date to avoid flaky behavior near midnight.
    private let referenceDate = ModelFactory.referenceDate

    // MARK: - Date normalization

    @Test("CPAPSession date is normalized to start of day")
    func dateNormalizedToMidnight() {
        // Create a session with a mid-afternoon timestamp
        let afternoon = Calendar.current.date(
            bySettingHour: 15, minute: 30, second: 0, of: referenceDate
        )!
        let session = CPAPSession(
            date: afternoon,
            ahi: 3.2,
            totalUsageMinutes: 420,
            leakRate95th: 12.0,
            pressureMin: 8.0,
            pressureMax: 14.0,
            pressureMean: 10.5,
            obstructiveEvents: 5,
            centralEvents: 2,
            hypopneaEvents: 8,
            importSource: "csv"
        )

        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: session.date)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("CPAPSession and HealthSnapshot for same day have matching dates")
    func cpapAndSnapshotDatesMatch() {
        let session = CPAPSession(
            date: referenceDate,
            ahi: 2.0,
            totalUsageMinutes: 360,
            leakRate95th: 8.0,
            pressureMin: 7.0,
            pressureMax: 12.0,
            pressureMean: 9.0,
            obstructiveEvents: 3,
            centralEvents: 1,
            hypopneaEvents: 4,
            importSource: "csv"
        )
        let snapshot = HealthSnapshot(date: referenceDate)

        #expect(session.date == snapshot.date)
    }

    @Test("CPAPSession date alignment with TrendsView filter")
    func cpapFilterAlignment() {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: referenceDate)!
        let session = CPAPSession(
            date: sevenDaysAgo,
            ahi: 4.0,
            totalUsageMinutes: 480,
            leakRate95th: 10.0,
            pressureMin: 8.0,
            pressureMax: 13.0,
            pressureMean: 10.0,
            obstructiveEvents: 6,
            centralEvents: 2,
            hypopneaEvents: 10,
            importSource: "csv"
        )

        // Replicate TrendsView.startDate (fixed version)
        let startDate = Calendar.current.startOfDay(for: sevenDaysAgo)

        #expect(session.date >= startDate)
    }
}
