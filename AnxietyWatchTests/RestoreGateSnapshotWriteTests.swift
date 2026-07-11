import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

/// Regression suite for the bug that made "Restore from Server" *permanently
/// unusable on a fresh install* — the exact scenario it exists for.
///
/// The sequence, observed for real after the bundle-ID rename:
///
/// 1. Fresh install. `RestoreMigrationGate` correctly defers `setupIfNeeded()`
///    and shows the "Restore or Start Fresh?" prompt.
/// 2. Something else — an observer/refresh path, not the deferred setup — calls
///    `SnapshotAggregator.aggregateDay`, which writes a `HealthSnapshot`.
/// 3. `HealthSnapshot` is one of the tables `restoreGuardTablesAreEmpty` checks.
///    The store is now "non-empty".
/// 4. Every restore attempt fails with "Local store already contains data" on a
///    store the user has never touched. There is no way out but deleting the app.
///
/// The fix is that deferring *setup* is not sufficient — the *write* has to be
/// gated too. A single row is enough to brick the restore, so this is not a
/// "mostly works" situation: it either writes zero rows pre-decision or the
/// feature is dead.
@MainActor
struct RestoreGateSnapshotWriteTests {

    private static let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }()

    /// The core regression: with the decision still pending, aggregation must
    /// write nothing — even though HealthKit has data to offer.
    @Test("aggregateDay writes NO snapshot while the restore decision is unresolved")
    func aggregateDayIsInertBeforeDecision() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 45.0)

        let aggregator = SnapshotAggregator(
            healthKit: mock,
            modelContext: context,
            defaults: TestHelpers.gateUnresolvedDefaults()
        )
        try await aggregator.aggregateDay(Self.referenceDate)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.isEmpty, "a pre-decision snapshot write permanently blocks restore")
    }

    /// …and the consequence that actually bit the user: the guard must still
    /// consider the store restorable. This is the assertion that would have
    /// caught the bug — the one above only proves a row wasn't written; this
    /// proves the *restore path stays open*, which is the property we care about.
    @Test("store remains restorable after an aggregation attempt pre-decision")
    func storeStaysRestorableAfterPreDecisionAggregation() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 45.0)
        await mock.setAverage(.restingHeartRate, value: 62.0)

        let aggregator = SnapshotAggregator(
            healthKit: mock,
            modelContext: context,
            defaults: TestHelpers.gateUnresolvedDefaults()
        )
        try await aggregator.aggregateDay(Self.referenceDate)

        #expect(
            SyncService.restoreGuardBlockers(context).isEmpty,
            "restore must remain possible on a store the user never touched"
        )
    }

    /// The gate must not be a permanent mute: once the decision resolves (via
    /// "Start Fresh", a completed restore, or an already-populated store at
    /// launch), aggregation writes normally. Without this, the fix for the bug
    /// would simply be a different, quieter bug — no snapshots, ever.
    @Test("aggregateDay writes normally once the decision is resolved")
    func aggregateDayResumesAfterDecision() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 45.0)

        let defaults = TestHelpers.gateUnresolvedDefaults()
        let aggregator = SnapshotAggregator(
            healthKit: mock, modelContext: context, defaults: defaults
        )

        try await aggregator.aggregateDay(Self.referenceDate)
        #expect(try context.fetch(FetchDescriptor<HealthSnapshot>()).isEmpty)

        // User taps "Start Fresh" (or a restore completes).
        RestoreMigrationGate.resolve(defaults: defaults)

        try await aggregator.aggregateDay(Self.referenceDate)
        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots[0].hrvAvg == 45.0)
    }

    // MARK: - Blocker diagnostics

    /// The guard fails closed, which is correct — but failing closed *silently*
    /// made it undiagnosable. A thrown fetch was coerced to `Int.max` and
    /// surfaced as "store already contains data" on a demonstrably empty store,
    /// with no way to tell which of the 14 types was at fault or whether it even
    /// had rows. Naming the blocker is the difference between a five-minute fix
    /// and an hour of guessing (it cost an hour).
    @Test("blockers name the offending table and its row count")
    func blockersNameTheOffendingTable() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        context.insert(HealthSnapshot(date: Self.referenceDate))
        context.insert(HealthSnapshot(date: Self.referenceDate.addingTimeInterval(86_400)))
        try context.save()

        let blockers = SyncService.restoreGuardBlockers(context)
        #expect(blockers == ["HealthSnapshot=2"])
    }

    @Test("no blockers on a fresh store")
    func noBlockersOnFreshStore() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        #expect(SyncService.restoreGuardBlockers(context).isEmpty)
    }

    /// Multiple offenders are all reported, not just the first. The real failure
    /// reported `HealthSnapshot=91, BarometricReading=1` — truncating to the
    /// first would have hidden that a second table was also implicated.
    @Test("every blocking table is reported, not just the first")
    func allBlockersReported() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        context.insert(HealthSnapshot(date: Self.referenceDate))
        context.insert(BarometricReading(
            timestamp: Self.referenceDate, pressureKPa: 101.3, relativeAltitudeM: 0
        ))
        try context.save()

        let blockers = SyncService.restoreGuardBlockers(context)
        #expect(blockers.contains("HealthSnapshot=1"))
        #expect(blockers.contains("BarometricReading=1"))
        #expect(blockers.count == 2)
    }

    /// `restoreGuardTablesAreEmpty` is now derived from `restoreGuardBlockers`.
    /// Pin that they cannot disagree — a future edit that adds a table to one
    /// and forgets the other would silently reopen the duplication hole.
    @Test("restoreGuardTablesAreEmpty agrees with restoreGuardBlockers")
    func guardAndBlockersAgree() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        #expect(SyncService.restoreGuardTablesAreEmpty(context))

        context.insert(AnxietyEntry(timestamp: Self.referenceDate, severity: 5, notes: "", tags: []))
        try context.save()

        #expect(!SyncService.restoreGuardTablesAreEmpty(context))
        #expect(SyncService.restoreGuardBlockers(context) == ["AnxietyEntry=1"])
    }

    /// The error must actually surface the blockers to the user — carrying them
    /// in the associated value but dropping them from `errorDescription` would
    /// reproduce the original "undiagnosable" failure exactly.
    @Test("storeNotEmpty error text names the blockers")
    func errorTextNamesBlockers() throws {
        let error = RestoreError.storeNotEmpty(["HealthSnapshot=91", "BarometricReading=1"])
        let text = try #require(error.errorDescription)

        #expect(text.contains("HealthSnapshot=91"))
        #expect(text.contains("BarometricReading=1"))
    }
}
