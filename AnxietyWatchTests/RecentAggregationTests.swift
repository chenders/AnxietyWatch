import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for trailing-day re-aggregation. HealthKit data for a calendar day
/// keeps arriving AFTER that day's last aggregation — the Watch syncs last
/// night's sleep/respiratory rate minutes-to-hours after wake, and Apple
/// writes a day's final resting-HR sample near midnight. Before this fix,
/// every refresh path aggregated `.now` only, so any field arriving later
/// than the day's last app-open was frozen out of that day's snapshot
/// forever (the 2026-07 "Trends empty" investigation: RHR/sleep/respiratory
/// rate were NULL on every snapshot for three months).
@MainActor
struct RecentAggregationTests {

    private let calendar = Calendar.current

    /// 10:00 AM local on a fixed date — mid-morning, the typical "first open
    /// of the day" moment the bug bit.
    private var referenceNow: Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 15, hour: 10)
        )!
    }

    // MARK: - recentAggregationDays (pure)

    @Test("Returns today plus two trailing days, oldest first, day-aligned")
    func threeDaysOldestFirst() {
        let days = SnapshotAggregator.recentAggregationDays(endingAt: referenceNow)
        #expect(days.count == 3)
        let expected = [-2, -1, 0].map { offset in
            calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: offset, to: referenceNow)!
            )
        }
        #expect(days == expected)
    }

    @Test("Crosses a month boundary correctly")
    func monthBoundary() {
        let july1 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 9))!
        let days = SnapshotAggregator.recentAggregationDays(endingAt: july1)
        let expectedComponents = [(6, 29), (6, 30), (7, 1)]
        #expect(days.count == 3)
        for (day, (month, dayOfMonth)) in zip(days, expectedComponents) {
            let c = calendar.dateComponents([.month, .day], from: day)
            #expect(c.month == month)
            #expect(c.day == dayOfMonth)
        }
    }

    @Test("Zero lookback returns only today")
    func zeroLookback() {
        let days = SnapshotAggregator.recentAggregationDays(endingAt: referenceNow, lookbackDays: 0)
        #expect(days == [calendar.startOfDay(for: referenceNow)])
    }

    // MARK: - aggregateRecentDays

    @Test("Aggregates snapshots for all trailing days")
    func aggregatesAllTrailingDays() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.restingHeartRate, value: 60.0)
        let aggregator = SnapshotAggregator(
            healthKit: mock, modelContext: context,
            defaults: TestHelpers.gateResolvedDefaults()
        )
        try await aggregator.aggregateRecentDays(endingAt: referenceNow)

        let rows = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.restingHR == 60.0 })
    }

    @Test("Late-arriving data reaches yesterday's snapshot and re-dirties it")
    func lateArrivingDataBackfillsYesterday() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let aggregator = SnapshotAggregator(
            healthKit: mock, modelContext: context,
            defaults: TestHelpers.gateResolvedDefaults()
        )

        // Yesterday morning: the app aggregates yesterday before the Watch
        // has delivered anything — resting HR comes up empty.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceNow)!
        try await aggregator.aggregateDay(yesterday)

        // The empty row syncs; the server now holds the morning shell.
        let yesterdayStart = calendar.startOfDay(for: yesterday)
        let shell = try #require(
            try context.fetch(FetchDescriptor<HealthSnapshot>()).first {
                $0.date == yesterdayStart
            }
        )
        #expect(shell.restingHR == nil)
        shell.syncedToServer = true
        try context.save()

        // Overnight, HealthKit received yesterday's final resting HR.
        await mock.setAverage(.restingHeartRate, value: 55.0)

        // This morning's refresh must revisit yesterday, pick the value up,
        // and mark the row dirty so the next sync re-uploads it.
        try await aggregator.aggregateRecentDays(endingAt: referenceNow)

        let healed = try #require(
            try context.fetch(FetchDescriptor<HealthSnapshot>()).first {
                $0.date == yesterdayStart
            }
        )
        #expect(healed.restingHR == 55.0)
        #expect(!healed.syncedToServer)
    }
}
