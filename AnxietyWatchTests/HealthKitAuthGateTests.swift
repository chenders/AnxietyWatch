import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for the never-authorized HealthKit gate — the state a fresh install
/// (or a bundle-ID rename, which iOS treats as a brand-new app) starts in.
/// While authorization has never been REQUESTED, every HealthKit read errors
/// with code 5 (authorizationNotDetermined), which the query layer coerces to
/// nil. Without these gates that state is indistinguishable from "no data":
/// the aggregator shreds restored snapshot values with nils, and the backfill
/// marks itself done having read nothing — both real post-rename incidents
/// (2026-07 "Trends empty" investigation).
@MainActor
struct HealthKitAuthGateTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }()

    private func isolatedDefaults(_ function: String = #function) -> UserDefaults {
        let suite = "HealthKitAuthGateTests-\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - requestAuthorizationIfNeeded

    @Test("Requests authorization when the sheet has never been shown")
    func requestsWhenNeeded() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(true)
        let coordinator = HealthDataCoordinator(
            modelContainer: container, healthKit: mock, defaults: isolatedDefaults()
        )
        await coordinator.requestAuthorizationIfNeeded()
        #expect(await mock.authorizationRequestCount == 1)
    }

    @Test("Auth gate reads the injected defaults, not process-global state")
    func requestGateIsIsolatedFromGlobalFlag() async throws {
        // Reproduces the parallel-runner flake: another test (or the host app's
        // own launch-time request) sets the process-global "already asked" flag
        // in `.standard`. The coordinator must consult its INJECTED defaults, so
        // an isolated suite that never set the flag still requests.
        let globalKey = HealthKitManager.didRequestAuthorizationKey
        let previous = UserDefaults.standard.object(forKey: globalKey)
        UserDefaults.standard.set(true, forKey: globalKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: globalKey)
            } else {
                UserDefaults.standard.removeObject(forKey: globalKey)
            }
        }

        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(true)
        let coordinator = HealthDataCoordinator(
            modelContainer: container, healthKit: mock, defaults: isolatedDefaults()
        )
        await coordinator.requestAuthorizationIfNeeded()
        #expect(await mock.authorizationRequestCount == 1)
    }

    @Test("Does not re-request once authorization has been determined")
    func skipsWhenAlreadyDetermined() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        let coordinator = HealthDataCoordinator(
            modelContainer: container, healthKit: mock, defaults: isolatedDefaults()
        )
        await coordinator.requestAuthorizationIfNeeded()
        #expect(await mock.authorizationRequestCount == 0)
    }

    // MARK: - backfillIfNeeded auth gate

    @Test("Backfill without authorization neither runs nor sets the done-flag")
    func backfillSkipsAndStaysPendingWhenUnauthorized() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(true)
        await mock.setOldestDate(referenceDate)
        let defaults = isolatedDefaults()
        let coordinator = HealthDataCoordinator(
            modelContainer: container, healthKit: mock, defaults: defaults
        )
        await coordinator.backfillIfNeeded()

        // The done-flag must stay unset so the FIRST authorized launch still
        // runs the real backfill — the original bug marked it done after
        // aggregating 90 days of nothing.
        #expect(!defaults.bool(forKey: "hasBackfilledSnapshots_v3"))
        let rows = try ModelContext(container).fetch(FetchDescriptor<HealthSnapshot>())
        #expect(rows.isEmpty)
    }

    @Test("Backfill with authorization determined runs and sets the done-flag")
    func backfillRunsWhenAuthorized() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        // Two days of history keeps the walk short.
        await mock.setOldestDate(referenceDate.addingTimeInterval(-86_400))
        let defaults = isolatedDefaults()
        let coordinator = HealthDataCoordinator(
            modelContainer: container, healthKit: mock, defaults: defaults
        )
        await coordinator.backfillIfNeeded()
        #expect(defaults.bool(forKey: "hasBackfilledSnapshots_v3"))
    }

    // MARK: - aggregateDay auth gate

    @Test("aggregateDay preserves HealthKit-derived fields while authorization was never requested")
    func aggregateDayPreservesHealthKitFieldsWhenUnauthorized() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // A restored snapshot with real values, already synced.
        let existing = HealthSnapshot(date: referenceDate)
        existing.restingHR = 55
        existing.sleepDurationMin = 420
        existing.syncedToServer = true
        context.insert(existing)
        try context.save()

        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(true)
        let aggregator = SnapshotAggregator(
            healthKit: mock, modelContext: context,
            defaults: TestHelpers.gateResolvedDefaults()
        )
        try await aggregator.aggregateDay(referenceDate)

        let rows = try context.fetch(FetchDescriptor<HealthSnapshot>())
        try #require(rows.count == 1)
        // The unauthorized reads all coerce to nil; without the gate they
        // would shred these to nil. (`syncedToServer` is deliberately NOT
        // asserted: the non-HealthKit stitching that still runs — CPAP,
        // barometric, dataQuality — may legitimately dirty the row.)
        #expect(rows[0].restingHR == 55)
        #expect(rows[0].sleepDurationMin == 420)
    }

    @Test("CPAP data still reaches the snapshot while unauthorized")
    func cpapStillAggregatesWhenUnauthorized() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // CPAP comes from the SD-card import, not HealthKit — a user whose
        // HealthKit sheet is still unanswered (backgrounded mid-prompt) must
        // not lose CPAP/barometric aggregation while in that state.
        let session = CPAPSession(
            date: referenceDate, ahi: 3.2, totalUsageMinutes: 420,
            pressureMin: 6.0, pressureMax: 12.0, pressureMean: 8.5,
            obstructiveEvents: 4, centralEvents: 1, hypopneaEvents: 7,
            importSource: "oscar"
        )
        context.insert(session)
        try context.save()

        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(true)
        let aggregator = SnapshotAggregator(
            healthKit: mock, modelContext: context,
            defaults: TestHelpers.gateResolvedDefaults()
        )
        try await aggregator.aggregateDay(referenceDate)

        let rows = try context.fetch(FetchDescriptor<HealthSnapshot>())
        try #require(rows.count == 1)
        #expect(rows[0].cpapAHI == 3.2)
        #expect(rows[0].cpapUsageMinutes == 420)
        // HealthKit-derived fields stay untouched (nil — never aggregated).
        #expect(rows[0].restingHR == nil)
    }

    @Test("aggregateDay proceeds normally once authorization is determined")
    func aggregateDayRunsWhenAuthorized() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        await mock.setAverage(.restingHeartRate, value: 58.0)
        let aggregator = SnapshotAggregator(
            healthKit: mock, modelContext: context,
            defaults: TestHelpers.gateResolvedDefaults()
        )
        try await aggregator.aggregateDay(referenceDate)
        let rows = try context.fetch(FetchDescriptor<HealthSnapshot>())
        try #require(rows.count == 1)
        #expect(rows[0].restingHR == 58.0)
    }
}
