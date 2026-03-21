import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests that date filtering in TrendsView correctly includes boundary-day data.
/// These validate the fix for the critical startDate off-by-one bug where
/// HealthSnapshots normalized to midnight were excluded by a mid-day cutoff.
struct TrendsDateFilteringTests {

    // MARK: - Helpers

    /// Creates an in-memory model container for isolated tests.
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: HealthSnapshot.self, AnxietyEntry.self, CPAPSession.self, BarometricReading.self,
            configurations: config
        )
    }

    /// Creates a HealthSnapshot for N days ago (normalized to midnight).
    private func makeSnapshot(daysAgo: Int, hrvAvg: Double? = 42.0) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.hrvAvg = hrvAvg
        return snapshot
    }

    /// Replicates TrendsView.startDate logic (the fixed version).
    private func computeStartDate(daysBack: Int) -> Date {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -daysBack, to: .now)!
        return Calendar.current.startOfDay(for: daysAgo)
    }

    // MARK: - startDate normalization

    @Test("startDate is always start of day regardless of current time")
    func startDateIsStartOfDay() {
        let startDate = computeStartDate(daysBack: 7)
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: startDate)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("7-day window includes snapshot from exactly 7 days ago")
    func sevenDayWindowIncludesBoundary() throws {
        let startDate = computeStartDate(daysBack: 7)
        let boundarySnapshot = makeSnapshot(daysAgo: 7)

        // The snapshot's date (midnight 7 days ago) should be >= startDate (also midnight 7 days ago)
        #expect(boundarySnapshot.date >= startDate)
    }

    @Test("30-day window includes snapshot from exactly 30 days ago")
    func thirtyDayWindowIncludesBoundary() throws {
        let startDate = computeStartDate(daysBack: 30)
        let boundarySnapshot = makeSnapshot(daysAgo: 30)

        #expect(boundarySnapshot.date >= startDate)
    }

    @Test("Snapshot from 8 days ago is excluded from 7-day window")
    func outsideBoundaryExcluded() throws {
        let startDate = computeStartDate(daysBack: 7)
        let oldSnapshot = makeSnapshot(daysAgo: 8)

        #expect(oldSnapshot.date < startDate)
    }

    // MARK: - Filtering with SwiftData

    @Test("SwiftData filter returns correct count for 7-day window")
    func swiftDataFilterCorrectCount() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Insert snapshots for days 0 through 9
        for day in 0...9 {
            let snapshot = makeSnapshot(daysAgo: day, hrvAvg: Double(40 + day))
            context.insert(snapshot)
        }
        try context.save()

        let startDate = computeStartDate(daysBack: 7)
        let descriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { $0.date >= startDate },
            sortBy: [SortDescriptor(\.date)]
        )
        let results = try context.fetch(descriptor)

        // Days 0–7 = 8 snapshots (today + 7 days back)
        #expect(results.count == 8)
    }

    // MARK: - AnxietyEntry filtering

    @Test("AnxietyEntry with exact timestamp is included in range")
    func anxietyEntryTimestampIncluded() {
        let startDate = computeStartDate(daysBack: 7)
        // Entry logged at 3 PM, 5 days ago
        let entryDate = Calendar.current.date(byAdding: .day, value: -5, to: .now)!
        let entry = AnxietyEntry(timestamp: entryDate, severity: 7)

        #expect(entry.timestamp >= startDate)
    }

    @Test("AnxietyEntry at start of boundary day is included")
    func anxietyEntryAtMidnightBoundary() {
        let startDate = computeStartDate(daysBack: 7)
        let midnight7DaysAgo = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        )
        let entry = AnxietyEntry(timestamp: midnight7DaysAgo, severity: 3)

        #expect(entry.timestamp >= startDate)
    }
}
