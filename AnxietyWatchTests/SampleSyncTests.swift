import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests for `HealthDataCoordinator.mirrorHealthKitSamples()` — the per-metric
/// date-anchored pull that mirrors HealthKit `HKQuantitySample` and sleep-stage
/// rows into local SwiftData (`QuantityHealthSample` / `SleepStageEvent`).
///
/// The tests use:
///   - an in-memory ModelContainer (full schema, including the new sample models)
///   - a `MockHealthKitDataSource` returning canned `SourcedQuantitySample` /
///     `SourcedSleepStageEvent` arrays
///   - a fresh `UserDefaults(suiteName:)` per test so anchor state is isolated
@Suite("HealthDataCoordinator sample mirroring")
struct SampleSyncTests {

    // MARK: - Helpers

    /// Make a UserDefaults suite scoped to a single test run. Clears any prior
    /// anchor state so test order can't bleed.
    private func makeIsolatedDefaults(name: String = #function) -> UserDefaults {
        let suite = "SampleSyncTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeCoordinator(
        container: ModelContainer,
        mock: MockHealthKitDataSource,
        defaults: UserDefaults
    ) -> HealthDataCoordinator {
        HealthDataCoordinator(
            modelContainer: container,
            healthKit: mock,
            defaults: defaults
        )
    }

    private func sample(
        timestamp: Date,
        value: Double,
        bundleID: String = "com.dexcom.stelo",
        sourceName: String = "Stelo",
        deviceModel: String? = nil,
        hkUUID: UUID = UUID()
    ) -> SourcedQuantitySample {
        SourcedQuantitySample(
            timestamp: timestamp,
            value: value,
            sourceBundleID: bundleID,
            sourceName: sourceName,
            deviceModel: deviceModel,
            hkUUID: hkUUID
        )
    }

    // MARK: - Mirroring quantity samples

    @Test("Mirrors HealthKit quantity samples into SwiftData")
    func mirrorsQuantitySamplesIntoSwiftData() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let samples = (0..<5).map { i in
            sample(
                timestamp: now.addingTimeInterval(Double(-60 * (i + 1))),
                value: 70 + Double(i),
                bundleID: "com.apple.health",
                sourceName: "Apple Watch"
            )
        }
        await mock.setQuantitySamplesWithSource(.heartRate, samples)

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierHeartRate"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { $0.sourceBundleID == "com.apple.health" })
        #expect(rows.allSatisfy { $0.sourceName == "Apple Watch" })
    }

    // MARK: - Anchor advancement

    @Test("Anchor advances after a successful pull; second pass with no new data inserts no rows")
    func advancesAnchorAfterSuccessfulPull() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: now.addingTimeInterval(-60),
                value: 72,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch"
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // Anchor should have been written, beyond the initial epoch fallback.
        let anchorKey = "sampleAnchor.HKQuantityTypeIdentifierHeartRate"
        let firstAnchor = defaults.double(forKey: anchorKey)
        #expect(firstAnchor > 0)

        // Now drain the mock so a second mirroring pass returns no samples.
        await mock.setQuantitySamplesWithSource(.heartRate, [])
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierHeartRate"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 1)

        // Anchor should have advanced again on the second pass.
        let secondAnchor = defaults.double(forKey: anchorKey)
        #expect(secondAnchor >= firstAnchor)
    }

    // MARK: - Idempotency

    @Test("Replaying samples (same hkUUID) does not produce duplicate rows")
    func idempotentReplay() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUIDs = [UUID(), UUID(), UUID()]
        let samples = stableUUIDs.enumerated().map { index, id in
            sample(
                timestamp: now.addingTimeInterval(Double(-60 * (index + 1))),
                value: 95 + Double(index),
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: id
            )
        }
        await mock.setQuantitySamplesWithSource(.heartRate, samples)

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // Reset the anchor so the second pull re-fetches the same window.
        defaults.removeObject(forKey: "sampleAnchor.HKQuantityTypeIdentifierHeartRate")

        // Same samples (same hkUUID) re-arrive on the second pass.
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierHeartRate"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 3)
    }

    // MARK: - Sleep stage events

    @Test("Mirrors HealthKit sleep stage events into SwiftData")
    func mirrorsSleepStageEvents() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let events: [SourcedSleepStageEvent] = [
            SourcedSleepStageEvent(
                start: now.addingTimeInterval(-3600 * 8),
                end: now.addingTimeInterval(-3600 * 6),
                stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: UUID()
            ),
            SourcedSleepStageEvent(
                start: now.addingTimeInterval(-3600 * 6),
                end: now.addingTimeInterval(-3600 * 5),
                stage: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: UUID()
            )
        ]
        await mock.setSleepStageEvents(events)

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.sourceName == "Apple Watch" })
    }

    // MARK: - Lifecycle wiring

    /// Smoke test: calling the public foreground-refresh entrypoint
    /// (`setupIfNeeded()`) must end up running `mirrorHealthKitSamples()` so
    /// `QuantityHealthSample` rows are populated. Without this wiring, the
    /// SwiftData mirror stays empty in production no matter how much data
    /// HealthKit has.
    @Test("setupIfNeeded runs mirrorHealthKitSamples (smoke test)")
    func setupIfNeededRunsMirror() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        // Pre-mark backfill complete so setupIfNeeded skips the per-day loop;
        // we only care that the mirror call site fires. We restore the prior
        // value at the end so we don't pollute UserDefaults.standard for
        // other tests in the suite.
        let backfillKey = "hasBackfilledSnapshots_v3"
        let priorBackfillValue = UserDefaults.standard.object(forKey: backfillKey)
        UserDefaults.standard.set(true, forKey: backfillKey)
        defer {
            if let priorBackfillValue {
                UserDefaults.standard.set(priorBackfillValue, forKey: backfillKey)
            } else {
                UserDefaults.standard.removeObject(forKey: backfillKey)
            }
        }

        let now = Date()
        let samples = (0..<3).map { i in
            sample(
                timestamp: now.addingTimeInterval(Double(-60 * (i + 1))),
                value: 70 + Double(i),
                bundleID: "com.apple.health",
                sourceName: "Apple Watch"
            )
        }
        await mock.setQuantitySamplesWithSource(.heartRate, samples)

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.setupIfNeeded()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierHeartRate"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 3, "setupIfNeeded must invoke mirrorHealthKitSamples — wiring is load-bearing")
    }

    // MARK: - Upsert by UUID (retroactive HealthKit corrections)

    @Test("Quantity sample with same UUID and corrected timestamp updates the existing row")
    func quantitySampleUpsertOnRetroactiveTimestampCorrection() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let stableUUID = UUID()
        let now = Date()
        let originalTimestamp = now.addingTimeInterval(-3600)
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: originalTimestamp,
                value: 72,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // HealthKit "corrects" the same UUID with a new timestamp/value/source.
        // This timestamp falls *outside* the original mirror window — the bug
        // we're regression-testing. Reset the anchor so the second pull
        // includes both the old and new windows; the upsert must update the
        // existing row in place rather than skip it.
        let correctedTimestamp = now.addingTimeInterval(-60)
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: correctedTimestamp,
                value: 88,
                bundleID: "com.dexcom.G7",
                sourceName: "Dexcom G7",
                hkUUID: stableUUID
            )
        ])
        defaults.removeObject(forKey: "sampleAnchor.HKQuantityTypeIdentifierHeartRate")
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierHeartRate"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 1, "Same UUID must not produce a duplicate row")
        let row = try #require(rows.first)
        #expect(row.id == stableUUID)
        #expect(row.value == 88, "Updated value must be persisted")
        #expect(row.timestamp == correctedTimestamp, "Corrected timestamp must overwrite the original")
        #expect(row.sourceBundleID == "com.dexcom.G7", "Updated source must be persisted")
        #expect(row.sourceName == "Dexcom G7")
    }

    @Test("Sleep stage event with same UUID and corrected times updates the existing row")
    func sleepStageEventUpsertOnRetroactiveCorrection() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let stableUUID = UUID()
        let now = Date()
        let originalStart = now.addingTimeInterval(-3600 * 8)
        let originalEnd = now.addingTimeInterval(-3600 * 7)
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: originalStart,
                end: originalEnd,
                stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // HealthKit revises the same sleep event — different start/end/stage.
        let correctedStart = now.addingTimeInterval(-3600 * 6)
        let correctedEnd = now.addingTimeInterval(-3600 * 5)
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: correctedStart,
                end: correctedEnd,
                stage: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])
        defaults.removeObject(forKey: "sampleAnchor.sleep")
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(rows.count == 1, "Same UUID must not produce a duplicate sleep event row")
        let row = try #require(rows.first)
        #expect(row.id == stableUUID)
        #expect(row.startTime == correctedStart, "Corrected startTime must overwrite the original")
        #expect(row.endTime == correctedEnd, "Corrected endTime must overwrite the original")
        #expect(row.stage == "asleepREM", "Corrected stage must overwrite the original")
    }

    // MARK: - BP groupID handling

    /// The HealthKit protocol's `quantitySamplesWithSource(...)` does not currently
    /// surface `HKCorrelation` linkage between systolic and diastolic samples — they
    /// arrive as independent rows with distinct `hkUUID`s. groupID is intentionally
    /// nil until HKCorrelationQuery wiring lands; this test pins that contract so the
    /// TODO is visible if/when correlation linkage is added.
    @Test("Blood pressure rows are persisted with groupID=nil pending correlation linkage")
    func bloodPressureRowsHaveNilGroupIDPendingCorrelation() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let systolic = sample(
            timestamp: now,
            value: 128,
            bundleID: "com.withings.wiscale2",
            sourceName: "Withings"
        )
        let diastolic = sample(
            timestamp: now,
            value: 82,
            bundleID: "com.withings.wiscale2",
            sourceName: "Withings"
        )
        await mock.setQuantitySamplesWithSource(.bloodPressureSystolic, [systolic])
        await mock.setQuantitySamplesWithSource(.bloodPressureDiastolic, [diastolic])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let bpPredicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierBloodPressureSystolic"
                || $0.metricType == "HKQuantityTypeIdentifierBloodPressureDiastolic"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: bpPredicate))
        #expect(rows.count == 2)
        // TODO: once HKCorrelationQuery is wired up in HealthKitManager, both rows
        // should share a non-nil groupID. Until then groupID stays nil.
        #expect(rows.allSatisfy { $0.groupID == nil })
    }

    // MARK: - Concurrent mirror serialization

    /// Regression: two concurrent `mirrorHealthKitSamples()` calls must not
    /// produce duplicate rows or trip SwiftData's unique-constraint guard on
    /// `QuantityHealthSample.id`. The serialization guard (`isMirroring`)
    /// makes the second caller a no-op while the first is still in flight —
    /// the next anchor advance covers anything the no-op'd run would have
    /// pulled, so this is safe.
    @Test("Concurrent mirror calls do not duplicate rows or crash")
    func concurrentMirrorCallsDoNotDuplicateRows() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUIDs = (0..<10).map { _ in UUID() }
        let samples = stableUUIDs.enumerated().map { index, id in
            sample(
                timestamp: now.addingTimeInterval(Double(-60 * (index + 1))),
                value: 70 + Double(index),
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: id
            )
        }
        await mock.setQuantitySamplesWithSource(.heartRate, samples)

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)

        // Kick off two concurrent mirror calls. Without serialization, both
        // would prefetch the same UUID set into separate ModelContexts and
        // race their inserts → save failures and/or duplicate rows.
        async let a: Void = coordinator.mirrorHealthKitSamples()
        async let b: Void = coordinator.mirrorHealthKitSamples()
        _ = await (a, b)

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierHeartRate"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == stableUUIDs.count, "Concurrent runs must not produce duplicate rows")
        #expect(Set(rows.map(\.id)) == Set(stableUUIDs), "All incoming UUIDs must be persisted exactly once")
    }

    /// Smoke test for the prefetch error-path defensive fix: when the
    /// existing-rows prefetch in `mirrorQuantityMetric` succeeds (the normal
    /// case), the mirror still inserts rows and advances the anchor. Mocking a
    /// SwiftData `context.fetch` failure isn't tractable without a
    /// context-injection seam, so the negative case (anchor must NOT advance
    /// on prefetch failure) is currently asserted only by code review of the
    /// `do/catch` + early-return added in `HealthDataCoordinator`.
    @Test("Quantity mirror prefetch success path still advances anchor and inserts rows")
    func quantityMirrorPrefetchSuccessAdvancesAnchorAndInsertsRows() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: now.addingTimeInterval(-60),
                value: 72,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> { $0.id == stableUUID }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 1, "Successful prefetch path must still insert the new row")

        // Anchor must have advanced past the initial epoch fallback.
        let anchorKey = "sampleAnchor.HKQuantityTypeIdentifierHeartRate"
        #expect(defaults.double(forKey: anchorKey) > 0, "Anchor must advance on the success path")
    }

    /// Companion smoke test for the sleep-event prefetch error-path defensive
    /// fix. Same caveat: SwiftData fetch failure can't be mocked here without a
    /// context-injection seam, so this test pins the success path only.
    @Test("Sleep mirror prefetch success path still advances anchor and inserts rows")
    func sleepMirrorPrefetchSuccessAdvancesAnchorAndInsertsRows() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: now.addingTimeInterval(-3600 * 2),
                end: now.addingTimeInterval(-3600),
                stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: UUID()
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(rows.count == 1, "Successful prefetch path must still insert sleep events")

        // Sleep anchor must have advanced.
        #expect(defaults.double(forKey: "sampleAnchor.sleep") > 0, "Sleep anchor must advance on the success path")
    }

    /// Regression: the upsert path in `mirrorQuantityMetric` must NOT clobber
    /// `groupID` on update. Incoming HKSamples currently always carry
    /// `groupID = nil` (correlation linkage isn't wired yet), so writing the
    /// incoming nil unconditionally would wipe any previously-established
    /// linkage. Pin the COALESCE-style behaviour: leave `groupID` untouched
    /// when re-mirroring an existing UUID.
    @Test("Mirroring a sample with the same UUID preserves an existing non-nil groupID")
    func mirrorPreservesExistingGroupIDOnUpsert() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        // Seed an existing row with a non-nil groupID — simulating linkage that
        // a (future) correlation pass already established.
        let stableUUID = UUID()
        let preservedGroupID = UUID()
        let originalTimestamp = Date().addingTimeInterval(-3600)
        let context = ModelContext(container)
        let seeded = QuantityHealthSample(
            id: stableUUID,
            timestamp: originalTimestamp,
            metricType: "HKQuantityTypeIdentifierBloodPressureSystolic",
            value: 120,
            unitString: "mmHg",
            sourceBundleID: "com.withings.wiscale2",
            sourceName: "Withings",
            groupID: preservedGroupID
        )
        context.insert(seeded)
        try context.save()

        // Mirror an HKSample with the same UUID — incoming groupID is implicitly
        // nil (the protocol does not surface correlation linkage yet).
        await mock.setQuantitySamplesWithSource(.bloodPressureSystolic, [
            sample(
                timestamp: originalTimestamp.addingTimeInterval(60),
                value: 122,
                bundleID: "com.withings.wiscale2",
                sourceName: "Withings",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let verifyContext = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> { $0.id == stableUUID }
        let rows = try verifyContext.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        // Other fields should reflect the update path being exercised.
        #expect(row.value == 122, "Update path must run (sanity check)")
        // The load-bearing assertion: groupID must NOT be wiped.
        #expect(row.groupID == preservedGroupID, "Upsert must not clobber an existing non-nil groupID")
    }

    // MARK: - SQLite parameter-limit chunking

    /// Regression: a 7-day initial CGM lookback produces ~2000 incoming
    /// samples per pass. Without chunking, the prefetch's
    /// `Set.contains($0.id)` predicate lowers to a SQLite IN-list that exceeds
    /// the default 999-parameter limit, the fetch fails, and the mirror bails
    /// for the whole window — producing perpetual mirror failure on busy
    /// users. Pin the chunked-prefetch behaviour: 2000+ unique UUIDs must
    /// land in SwiftData with no fetch failure and no duplicates.
    @Test("Quantity mirror handles >2000 incoming samples without exceeding SQLite parameter limit")
    func quantityMirrorChunksLargeIncomingSet() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        // 2016 = 288 samples/day × 7 days, mirroring the production CGM
        // first-run lookback that triggered the original bug.
        let count = 2016
        let now = Date()
        let stableUUIDs = (0..<count).map { _ in UUID() }
        let samples = stableUUIDs.enumerated().map { index, id in
            sample(
                timestamp: now.addingTimeInterval(Double(-60 * (index + 1))),
                value: 70 + Double(index % 50),
                bundleID: "com.dexcom.stelo",
                sourceName: "Stelo",
                hkUUID: id
            )
        }
        await mock.setQuantitySamplesWithSource(.bloodGlucose, samples)

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> {
            $0.metricType == "HKQuantityTypeIdentifierBloodGlucose"
        }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == count, "All \(count) incoming samples must be inserted")
        #expect(Set(rows.map(\.id)) == Set(stableUUIDs), "Every incoming UUID must be present exactly once")

        // Replay (anchor reset) — exercises the *prefetch* path itself with
        // the full UUID set, which is what would have tripped the SQLite
        // limit before chunking. Same UUIDs must update in place rather than
        // duplicate.
        defaults.removeObject(forKey: "sampleAnchor.HKQuantityTypeIdentifierBloodGlucose")
        await coordinator.mirrorHealthKitSamples()

        let replayContext = ModelContext(container)
        let replayRows = try replayContext.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(replayRows.count == count, "Replay must not duplicate rows")
    }

    /// Companion regression for the sleep-event prefetch path. Less likely to
    /// hit 1000+ events in practice, but the chunking guard must apply here
    /// too — pin it so a future change can't quietly regress only this site.
    @Test("Sleep mirror handles >1000 incoming events without exceeding SQLite parameter limit")
    func sleepMirrorChunksLargeIncomingSet() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let count = 1100
        let now = Date()
        let stableUUIDs = (0..<count).map { _ in UUID() }
        let events: [SourcedSleepStageEvent] = stableUUIDs.enumerated().map { index, id in
            SourcedSleepStageEvent(
                start: now.addingTimeInterval(Double(-60 * (index * 2 + 2))),
                end: now.addingTimeInterval(Double(-60 * (index * 2 + 1))),
                stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: id
            )
        }
        await mock.setSleepStageEvents(events)

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(rows.count == count, "All \(count) sleep events must be inserted")
        #expect(Set(rows.map(\.id)) == Set(stableUUIDs))

        // Replay to exercise the chunked prefetch path with all UUIDs hot.
        defaults.removeObject(forKey: "sampleAnchor.sleep")
        await coordinator.mirrorHealthKitSamples()

        let replayContext = ModelContext(container)
        let replayRows = try replayContext.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(replayRows.count == count, "Replay must not duplicate sleep events")
    }

    // MARK: - Rolling look-back for retroactive HealthKit corrections

    /// Regression: HealthKit allows retroactive corrections to existing samples
    /// (CGM backfill, recalibration adjusting yesterday's values, sleep edits
    /// applied the next day). Once the per-metric anchor advances past a
    /// sample's timestamp, a naive `(anchor, now)` query window would never
    /// re-fetch that sample even if HealthKit later corrects it. Pin the
    /// rolling-look-back behaviour: each pass queries
    /// `(max(anchor - mirrorLookbackInterval, epoch), now)`, so corrections
    /// within 48 hours are picked up while the anchor still advances to `now`.
    @Test("Retroactive correction within 48h look-back updates the existing row")
    func quantityMirrorPicksUpRetroactiveCorrectionWithinLookbackWindow() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        let originalTimestamp = now.addingTimeInterval(-30 * 3600) // T-30h
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: originalTimestamp,
                value: 100,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // Anchor has now advanced past T-30h, so a `(anchor, now)`-only query
        // would never see a correction at T-30h again. Manually pin the anchor
        // to "now" to simulate the scenario where the anchor has already moved
        // past the original sample.
        let anchorKey = "sampleAnchor.HKQuantityTypeIdentifierHeartRate"
        defaults.set(Date().timeIntervalSince1970, forKey: anchorKey)

        // HealthKit "corrects" the same UUID — same timestamp, different value
        // and source. Mock filters by `(start, end)`, so this sample is only
        // visible to a query whose start reaches back to T-30h. With the 48h
        // look-back, it should.
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: originalTimestamp,
                value: 120,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> { $0.id == stableUUID }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 1, "Same UUID must not produce a duplicate row")
        let row = try #require(rows.first)
        #expect(
            row.value == 120,
            "Retroactive correction within the 48h look-back must propagate to the local row"
        )
    }

    /// Companion: a correction OUTSIDE the look-back window must NOT propagate.
    /// This documents the look-back boundary — corrections older than 48 hours
    /// are intentionally not re-fetched (a tradeoff that bounds per-pass data
    /// volume). If the boundary is later relaxed, this test should be updated
    /// rather than silently passing.
    @Test("Retroactive correction outside 48h look-back is NOT picked up")
    func quantityMirrorIgnoresRetroactiveCorrectionOutsideLookbackWindow() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        // T-72h is well outside the 48h look-back window.
        let oldTimestamp = now.addingTimeInterval(-72 * 3600)
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: oldTimestamp,
                value: 100,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // Pin the anchor to "now" so the next query's window is
        // `(now - 48h, now)` — and T-72h falls outside it.
        let anchorKey = "sampleAnchor.HKQuantityTypeIdentifierHeartRate"
        defaults.set(Date().timeIntervalSince1970, forKey: anchorKey)

        // "Correct" the same UUID with a new value, still at T-72h. The mock
        // filters by `(start, end)` so this sample is invisible to any query
        // whose start is later than T-72h.
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: oldTimestamp,
                value: 120,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> { $0.id == stableUUID }
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(
            row.value == 100,
            "Correction at T-72h falls outside the 48h look-back; the row must remain unchanged"
        )
    }

    /// Same retroactive-correction scenario, but on the sleep-event path.
    /// Apple Watch can revise sleep stages the morning after; without the
    /// rolling look-back, a corrected stage applied to an event whose start
    /// time precedes the anchor would be invisible forever.
    @Test("Retroactive sleep correction within 48h look-back updates the existing row")
    func sleepMirrorPicksUpRetroactiveCorrectionWithinLookbackWindow() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        let originalStart = now.addingTimeInterval(-30 * 3600)
        let originalEnd = originalStart.addingTimeInterval(3600)
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: originalStart,
                end: originalEnd,
                stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // Pin sleep anchor to "now" — without the rolling look-back, the next
        // pass's `(anchor, now)` window would not see anything at T-30h.
        defaults.set(Date().timeIntervalSince1970, forKey: "sampleAnchor.sleep")

        // Revise the stage on the same UUID. Mock filters by event.start, so
        // this is only visible to a query whose start reaches back to T-30h.
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: originalStart,
                end: originalEnd,
                stage: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(
            row.stage == "asleepREM",
            "Retroactive sleep correction within the 48h look-back must propagate"
        )
    }

    /// Companion sleep test for the look-back boundary — a correction whose
    /// event.start is older than 48h must not propagate.
    @Test("Retroactive sleep correction outside 48h look-back is NOT picked up")
    func sleepMirrorIgnoresRetroactiveCorrectionOutsideLookbackWindow() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        let oldStart = now.addingTimeInterval(-72 * 3600)
        let oldEnd = oldStart.addingTimeInterval(3600)
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: oldStart,
                end: oldEnd,
                stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        defaults.set(Date().timeIntervalSince1970, forKey: "sampleAnchor.sleep")

        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: oldStart,
                end: oldEnd,
                stage: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(
            row.stage == "asleepCore",
            "Correction at T-72h falls outside the 48h look-back; sleep row must remain unchanged"
        )
    }

    // MARK: - syncedToServer reset on retroactive correction

    /// Regression: when an existing `QuantityHealthSample` is updated in place
    /// because HealthKit retroactively corrected the underlying HKSample
    /// (same UUID, new timestamp/value/source), the row's `syncedToServer`
    /// flag must be reset to `false` so the corrected data is re-uploaded
    /// to the sync server. Without this, a row uploaded with the original
    /// (now-stale) values would stay marked synced forever and the server
    /// mirror would never see the correction.
    @Test("Quantity row whose fields change on re-mirror has syncedToServer reset to false")
    func quantityMirrorResetsSyncedToServerOnRetroactiveCorrection() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        let originalTimestamp = now.addingTimeInterval(-30 * 3600)
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: originalTimestamp,
                value: 100,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        // Simulate a successful upload: mark the row synced.
        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> { $0.id == stableUUID }
        let inserted = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        try #require(inserted.count == 1)
        inserted[0].syncedToServer = true
        try context.save()

        // Pin the anchor forward so the rolling-look-back is what re-fetches
        // this sample. HealthKit "corrects" the same UUID with a new value.
        defaults.set(Date().timeIntervalSince1970, forKey: "sampleAnchor.HKQuantityTypeIdentifierHeartRate")
        await mock.setQuantitySamplesWithSource(.heartRate, [
            sample(
                timestamp: originalTimestamp,
                value: 120,
                bundleID: "com.apple.health",
                sourceName: "Apple Watch",
                hkUUID: stableUUID
            )
        ])
        await coordinator.mirrorHealthKitSamples()

        let after = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(after.count == 1)
        let row = try #require(after.first)
        #expect(row.value == 120, "Updated value must be persisted")
        #expect(
            row.syncedToServer == false,
            "Retroactive correction must reset syncedToServer so the corrected row is re-uploaded"
        )
    }

    /// Companion: when re-mirroring a sample whose mirrored fields are
    /// unchanged (the common rolling-look-back overlap case), an already-
    /// synced row must STAY synced. Otherwise every pass would dirty
    /// already-uploaded rows and trigger a spurious re-upload storm.
    @Test("Quantity row with unchanged fields on re-mirror keeps syncedToServer = true")
    func quantityMirrorPreservesSyncedToServerWhenFieldsUnchanged() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        let timestamp = now.addingTimeInterval(-30 * 3600)
        let original = sample(
            timestamp: timestamp,
            value: 100,
            bundleID: "com.apple.health",
            sourceName: "Apple Watch",
            hkUUID: stableUUID
        )
        await mock.setQuantitySamplesWithSource(.heartRate, [original])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<QuantityHealthSample> { $0.id == stableUUID }
        let inserted = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        try #require(inserted.count == 1)
        inserted[0].syncedToServer = true
        try context.save()

        // Pin the anchor forward and re-mirror the IDENTICAL sample. The
        // rolling-look-back will re-fetch it; the upsert branch must detect
        // no field-level change and leave `syncedToServer` alone.
        defaults.set(Date().timeIntervalSince1970, forKey: "sampleAnchor.HKQuantityTypeIdentifierHeartRate")
        await mock.setQuantitySamplesWithSource(.heartRate, [original])
        await coordinator.mirrorHealthKitSamples()

        let after = try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
        #expect(after.count == 1)
        let row = try #require(after.first)
        #expect(
            row.syncedToServer == true,
            "Re-mirroring an unchanged sample must NOT reset syncedToServer (avoids spurious re-upload)"
        )
    }

    /// Same regression for sleep-stage events: a retroactively revised sleep
    /// stage (e.g. Apple Watch updating the morning after) on an
    /// already-uploaded `SleepStageEvent` row must reset `syncedToServer`
    /// so the server mirror sees the corrected stage.
    @Test("Sleep row whose fields change on re-mirror has syncedToServer reset to false")
    func sleepMirrorResetsSyncedToServerOnRetroactiveCorrection() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        let originalStart = now.addingTimeInterval(-30 * 3600)
        let originalEnd = originalStart.addingTimeInterval(3600)
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: originalStart,
                end: originalEnd,
                stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<SleepStageEvent> { $0.id == stableUUID }
        let inserted = try context.fetch(FetchDescriptor<SleepStageEvent>(predicate: predicate))
        try #require(inserted.count == 1)
        inserted[0].syncedToServer = true
        try context.save()

        defaults.set(Date().timeIntervalSince1970, forKey: "sampleAnchor.sleep")
        await mock.setSleepStageEvents([
            SourcedSleepStageEvent(
                start: originalStart,
                end: originalEnd,
                stage: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: "Watch",
                hkUUID: stableUUID
            )
        ])
        await coordinator.mirrorHealthKitSamples()

        let after = try context.fetch(FetchDescriptor<SleepStageEvent>(predicate: predicate))
        #expect(after.count == 1)
        let row = try #require(after.first)
        #expect(row.stage == "asleepREM", "Updated stage must be persisted")
        #expect(
            row.syncedToServer == false,
            "Retroactive sleep correction must reset syncedToServer so the corrected row is re-uploaded"
        )
    }

    /// Companion: a sleep event re-mirrored with identical fields must keep
    /// `syncedToServer = true` so the rolling-look-back overlap doesn't
    /// trigger a spurious re-upload storm.
    @Test("Sleep row with unchanged fields on re-mirror keeps syncedToServer = true")
    func sleepMirrorPreservesSyncedToServerWhenFieldsUnchanged() async throws {
        let container = try TestHelpers.makeFullContainer()
        let mock = MockHealthKitDataSource()
        let defaults = makeIsolatedDefaults()

        let now = Date()
        let stableUUID = UUID()
        let originalStart = now.addingTimeInterval(-30 * 3600)
        let originalEnd = originalStart.addingTimeInterval(3600)
        let event = SourcedSleepStageEvent(
            start: originalStart,
            end: originalEnd,
            stage: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            sourceBundleID: "com.apple.health",
            sourceName: "Apple Watch",
            deviceModel: "Watch",
            hkUUID: stableUUID
        )
        await mock.setSleepStageEvents([event])

        let coordinator = makeCoordinator(container: container, mock: mock, defaults: defaults)
        await coordinator.mirrorHealthKitSamples()

        let context = ModelContext(container)
        let predicate = #Predicate<SleepStageEvent> { $0.id == stableUUID }
        let inserted = try context.fetch(FetchDescriptor<SleepStageEvent>(predicate: predicate))
        try #require(inserted.count == 1)
        inserted[0].syncedToServer = true
        try context.save()

        defaults.set(Date().timeIntervalSince1970, forKey: "sampleAnchor.sleep")
        await mock.setSleepStageEvents([event])
        await coordinator.mirrorHealthKitSamples()

        let after = try context.fetch(FetchDescriptor<SleepStageEvent>(predicate: predicate))
        #expect(after.count == 1)
        let row = try #require(after.first)
        #expect(
            row.syncedToServer == true,
            "Re-mirroring an unchanged sleep event must NOT reset syncedToServer (avoids spurious re-upload)"
        )
    }
}
