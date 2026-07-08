import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

/// Source-precedence override layered on top of the HealthKit-direct
/// aggregation. When a high-fidelity device (EMAY for SpO2, Polar H10 for
/// HR/HRV) has SwiftData samples covering the window, the corresponding
/// snapshot field gets recomputed from that preferred subset and overwrites
/// the HK-direct value. When no high-fidelity samples exist, the override
/// is a no-op and the HK-direct value stays.
///
/// Tests in this suite seed `QuantityHealthSample` rows directly into the
/// in-memory store and verify the override fires (or doesn't) appropriately.
@Suite("SnapshotAggregator source-precedence override")
struct SnapshotAggregatorSourcePrecedenceTests {

    /// Use a UTC-anchored reference date so the overnight window
    /// (noon previous day → noon this day) lands at predictable instants
    /// regardless of the simulator's locale.
    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }()

    private func makeAggregator(mock: MockHealthKitDataSource, context: ModelContext) -> SnapshotAggregator {
        SnapshotAggregator(healthKit: mock, modelContext: context)
    }

    /// Seed a run of overnight SpO2 samples spaced 1s apart, all from the
    /// given source. `value` is the fraction (0.0–1.0) — matches the
    /// HealthKit convention the mirror preserves.
    private func seedOvernightSpO2(
        bundle: String,
        count: Int,
        value: Double,
        in context: ModelContext,
        startingAt start: Date
    ) {
        for i in 0..<count {
            context.insert(QuantityHealthSample(
                timestamp: start.addingTimeInterval(Double(i)),
                metricType: HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                value: value,
                unitString: "%",
                sourceBundleID: bundle,
                sourceName: bundle
            ))
        }
    }

    /// Anchor for "overnight" — the `SnapshotAggregator` computes the
    /// overnight window using `Calendar.current.startOfDay`, which is
    /// device-timezone-relative. To make the test independent of which
    /// timezone the simulator happens to be in, mirror that exact
    /// computation here: 02:00 on the local-calendar start of
    /// referenceDate, which always lands inside the noon-prev → noon-now
    /// overnight window.
    private var overnightAnchor: Date {
        let cal = Calendar.current
        let localStart = cal.startOfDay(for: referenceDate)
        return cal.date(byAdding: .hour, value: 2, to: localStart) ?? localStart
    }

    // MARK: - SpO2 precedence

    @Test("EMAY overnight samples override HealthKit-direct nadir/avg")
    func emayOverrideSpO2Aggregates() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        // HK mock simulates an Apple-Watch-only world: a low minimum from
        // a positional artifact (78%) plus an avg of 88%.
        await mock.setMinimum(.oxygenSaturation, value: 0.78)
        await mock.setAverage(.oxygenSaturation, value: 0.88)

        // EMAY seeds: 30 samples all at 0.92 — well above the 0.78 Watch
        // artifact and statistically clean.
        seedOvernightSpO2(
            bundle: "com.emay.SleepO2",
            count: 30,
            value: 0.92,
            in: context,
            startingAt: overnightAnchor
        )
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        try #require(snapshots.count == 1)
        // EMAY's 0.92 wins, not Apple Watch's 0.78. Stored as percent.
        #expect(abs((snapshots[0].spo2NadirOvernight ?? 0) - 92.0) < 0.001)
        #expect(abs((snapshots[0].spo2Avg ?? 0) - 92.0) < 0.001)
    }

    @Test("EMAY HealthKit bundle (com.emay.oximeter) is treated as preferred for SpO2")
    func emayHealthKitBundleOverrideSpO2() async throws {
        // Same scenario but the EMAY samples carry the HealthKit-side
        // bundle ID — must be classified identically.
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setMinimum(.oxygenSaturation, value: 0.78)

        seedOvernightSpO2(
            bundle: "com.emay.oximeter",
            count: 30,
            value: 0.93,
            in: context,
            startingAt: overnightAnchor
        )
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 93.0) < 0.001)
    }

    @Test("Apple Watch nadir captured in spo2NadirOpportunistic for chart's second line")
    func opportunisticNadirSeparatelyReported() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setMinimum(.oxygenSaturation, value: 0.78)

        // EMAY at 0.92 + Apple Watch at 0.78 in the same window.
        seedOvernightSpO2(
            bundle: "com.emay.SleepO2",
            count: 30,
            value: 0.92,
            in: context,
            startingAt: overnightAnchor
        )
        seedOvernightSpO2(
            bundle: "com.apple.health",
            count: 5,
            value: 0.78,
            in: context,
            startingAt: overnightAnchor.addingTimeInterval(30)
        )
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        // Primary nadir from EMAY (preferred).
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 92.0) < 0.001)
        // Opportunistic nadir from Apple Watch, always reported when any
        // opportunistic sample exists — feeds the chart's second line.
        #expect(abs((snap?.spo2NadirOpportunistic ?? 0) - 78.0) < 0.001)
    }

    @Test("No preferred samples → HK-direct nadir is kept; opportunistic captured separately")
    func noPreferredSourceNoOverride() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // HK has Apple-Watch-only data (89% min).
        await mock.setMinimum(.oxygenSaturation, value: 0.89)
        await mock.setAverage(.oxygenSaturation, value: 0.95)

        // No EMAY rows in SwiftData — only opportunistic Apple Watch.
        seedOvernightSpO2(
            bundle: "com.apple.health",
            count: 10,
            value: 0.89,
            in: context,
            startingAt: overnightAnchor
        )
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        // HK-direct value preserved (no preferred samples to override with).
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 89.0) < 0.001)
        // Opportunistic field reflects Apple Watch samples.
        #expect(abs((snap?.spo2NadirOpportunistic ?? 0) - 89.0) < 0.001)
    }

    @Test("Empty SwiftData for SpO2 → both override paths no-op, HK values stay")
    func emptySwiftDataLeavesHKValues() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setMinimum(.oxygenSaturation, value: 0.94)
        await mock.setAverage(.oxygenSaturation, value: 0.96)
        // Intentionally no QuantityHealthSample rows seeded.

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 94.0) < 0.001)
        #expect(abs((snap?.spo2Avg ?? 0) - 96.0) < 0.001)
        // Opportunistic field is nil when no opportunistic samples exist
        // in SwiftData — even if HK has data the mirror hasn't reflected.
        #expect(snap?.spo2NadirOpportunistic == nil)
    }

    /// Regression for the May 12 scenario: a fresh device install where the
    /// HealthKit→SwiftData mirror hasn't populated SpO2 yet, but HealthKit
    /// itself (iCloud-synced) has both an Apple Watch positional artifact
    /// (0.78) and the EMAY iOS app's overnight samples (≥0.90). Before the
    /// source-aware HK fallback the precedence override saw an empty
    /// `QuantityHealthSample` table, early-returned, and the HK-direct
    /// `minimumQuantity` (which mixes sources) surfaced the 0.78 artifact
    /// as the green "Oximeter" line on the trends chart.
    @Test("HK has EMAY + Apple Watch, SwiftData empty → precedence still picks EMAY nadir")
    func sourceAwareHKFallbackOverridesAppleWatchArtifact() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        // HK-direct min mixes sources (Apple Watch wins because 0.78 < 0.92).
        // This is what `minimumQuantity` returns in production and what the
        // override must clear when sourced samples are available.
        await mock.setMinimum(.oxygenSaturation, value: 0.78)
        await mock.setAverage(.oxygenSaturation, value: 0.93)

        // Source-tagged samples available to the new HK fallback path.
        // Same shape as `HKQuantitySample` would yield post-`HKSourceQuery`.
        let emaySamples: [SourcedQuantitySample] = (0..<30).map { i in
            SourcedQuantitySample(
                timestamp: overnightAnchor.addingTimeInterval(Double(i)),
                value: 0.92,
                sourceBundleID: "com.emay.oximeter",
                sourceName: "EMAY Oximeter",
                deviceModel: nil,
                hkUUID: UUID()
            )
        }
        let watchSamples: [SourcedQuantitySample] = (0..<3).map { i in
            SourcedQuantitySample(
                // After the EMAY block so the timestamps stay inside the window.
                timestamp: overnightAnchor.addingTimeInterval(Double(30 + i)),
                value: 0.78,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: nil,
                hkUUID: UUID()
            )
        }
        await mock.setQuantitySamplesWithSource(.oxygenSaturation, emaySamples + watchSamples)

        // No SwiftData mirror rows — that's the whole point of this test.

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        // Green Oximeter line: EMAY 0.92 — NOT the Apple Watch 0.78 artifact
        // that the HK-direct minimumQuantity returned.
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 92.0) < 0.001)
        // Orange Apple Watch line: 0.78 kept on its own series.
        #expect(abs((snap?.spo2NadirOpportunistic ?? 0) - 78.0) < 0.001)
        // Avg reflects EMAY-only (preferred), not the mixed HK-direct 0.93.
        #expect(abs((snap?.spo2Avg ?? 0) - 92.0) < 0.001)
    }

    /// When SwiftData already has HK-mirrored SpO2 rows for the window
    /// (any row with a non-CSV-only bundle ID), the precedence override
    /// does NOT issue a `quantitySamplesWithSource` query to HealthKit.
    /// The mirror pulls every HK sample for its lookback window, so any
    /// HK-attributed SwiftData coverage implies HK-row parity; the HK
    /// fallback is reserved for the empty-SwiftData or CSV-only cases.
    ///
    /// Pins this contract by setting up a scenario where the HK sample
    /// (if fetched) would change the result. HK has a "stale" 0.91
    /// reading with a *different* UUID than the SwiftData row, so a
    /// regression that drops the gate would mix both into the partition
    /// (avg = 93, nadir = 91) instead of returning the SwiftData-only
    /// 0.95. Using a distinct UUID is deliberate — the dedup-by-hkUUID
    /// in the merge step would mask the regression if the UUIDs matched.
    @Test("SwiftData has HK-mirrored coverage → skip HK round-trip; SwiftData value wins")
    func hkSwiftDataOverlapDedupedByUUID() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        // Distinct UUID so the unified-list dedup wouldn't mask a gate
        // regression. The HK sample's lower value (0.91) is the canary —
        // it should NEVER reach the partition because the gate prevents
        // the round trip.
        let staleFromHK = SourcedQuantitySample(
            timestamp: overnightAnchor,
            value: 0.91,
            sourceBundleID: "com.emay.oximeter",
            sourceName: "EMAY Oximeter",
            deviceModel: nil,
            hkUUID: UUID()
        )
        await mock.setQuantitySamplesWithSource(.oxygenSaturation, [staleFromHK])

        // SwiftData row at 0.95 tagged with the HK-app bundle ID
        // (`com.emay.oximeter`) so it counts as HK-mirrored coverage and
        // triggers the gate.
        context.insert(QuantityHealthSample(
            id: UUID(),
            timestamp: overnightAnchor,
            metricType: HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
            value: 0.95,
            unitString: "%",
            sourceBundleID: "com.emay.oximeter",
            sourceName: "EMAY Oximeter"
        ))
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        // Gate working → HK 0.91 never enters the partition → avg/nadir = 95.0.
        // Gate regressed → HK 0.91 mixes in → avg = 93.0, nadir = 91.0.
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 95.0) < 0.001)
        #expect(abs((snap?.spo2Avg ?? 0) - 95.0) < 0.001)
    }

    /// CSV-imported EMAY rows (`com.emay.SleepO2`) live only in SwiftData,
    /// never in HealthKit. If the lazy gate treated their presence as "the
    /// mirror has covered this window," it would suppress the HK fetch
    /// even when HK has Apple Watch / EMAY-iOS-app data the precedence
    /// override needs to surface on the opportunistic line. This test
    /// pins the tightened gate: CSV-only SwiftData coverage must still
    /// trigger the HK fallback.
    @Test(
        "CSV-only SwiftData coverage still triggers the HK fallback",
        arguments: ["com.emay.SleepO2", "com.emay.sleepo2"]
    )
    func csvOnlySwiftDataStillFetchesHK(csvBundleID: String) async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        // HK has the Apple Watch artifact we want surfaced on the
        // opportunistic line — only reachable via the HK fallback.
        let watchSamples: [SourcedQuantitySample] = (0..<3).map { i in
            SourcedQuantitySample(
                timestamp: overnightAnchor.addingTimeInterval(Double(i * 30)),
                value: 0.78,
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch",
                deviceModel: nil,
                hkUUID: UUID()
            )
        }
        await mock.setQuantitySamplesWithSource(.oxygenSaturation, watchSamples)

        // SwiftData has only CSV-imported EMAY samples. Parameterized over
        // both case variants — the importer writes upper-case, but the
        // lower-case variant exists in `overnightPulseOximeters` for
        // legacy attribution and must also be classified as CSV-only.
        seedOvernightSpO2(
            bundle: csvBundleID,
            count: 30,
            value: 0.92,
            in: context,
            startingAt: overnightAnchor
        )
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        // EMAY preferred wins for the green line.
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 92.0) < 0.001)
        // The HK-only Apple Watch reading must reach the opportunistic
        // field via the fallback fetch — would be nil if the gate had
        // suppressed the round trip.
        #expect(abs((snap?.spo2NadirOpportunistic ?? 0) - 78.0) < 0.001)
    }

    /// `HealthSnapshot.syncedToServer` must flip back to `false` whenever
    /// `aggregateDay` actually changes a value, so the next sync includes
    /// the row regardless of `lastSyncDate`. The pre-fix sync filter
    /// dropped past-day snapshots by their `date` field, which made
    /// "Rebuild All History" a no-op on the server — exactly the path the
    /// user hit on May 12.
    @Test("aggregateDay marks the snapshot dirty when an aggregate field changes")
    func aggregateDayMarksSnapshotDirty() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setMinimum(.oxygenSaturation, value: 0.95)

        // Pre-seed a "clean" snapshot to verify the flip back to false.
        let preexisting = HealthSnapshot(date: referenceDate)
        preexisting.syncedToServer = true
        context.insert(preexisting)
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(snap?.syncedToServer == false)
    }

    /// Counter-test for `aggregateDayMarksSnapshotDirty`: re-aggregating a
    /// snapshot whose inputs didn't change must NOT flip dirty. Without
    /// this guard, today's snapshot (which is re-aggregated on every
    /// observer trigger and app launch) would be re-uploaded on every
    /// sync — persistent extra traffic for unchanged days.
    @Test("aggregateDay leaves syncedToServer alone when no field changes")
    func aggregateDayStaysCleanWhenNothingChanged() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // First aggregation: writes initial values.
        await mock.setMinimum(.oxygenSaturation, value: 0.95)
        await mock.setAverage(.oxygenSaturation, value: 0.97)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        // Mark the row "synced" — simulating a successful upload, exactly
        // the state the next aggregation should respect.
        let snap = try #require(try context.fetch(FetchDescriptor<HealthSnapshot>()).first)
        snap.syncedToServer = true
        try context.save()

        // Second aggregation with identical mock inputs → no field
        // changes → `syncedToServer` must remain `true` (the row stays
        // clean / not-dirty), not flip back to `false`.
        try await aggregator.aggregateDay(referenceDate)

        let snapAfter = try #require(try context.fetch(FetchDescriptor<HealthSnapshot>()).first)
        #expect(snapAfter.syncedToServer == true,
                "No-op aggregation must not mark snapshot dirty")
    }

    // F-023: sparse preferred coverage must not discard the HK-direct
    // T90/desats that `aggregateDay` already computed against its own
    // sufficiency gate — the old nil-out understated hypoxic burden in the
    // clinician PDF for nights with adequate Watch coverage plus a briefly-
    // connected oximeter.
    @Test("Sparse preferred samples keep the already-sufficient HK-direct T90/desats")
    func sparsePreferredKeepsHKDirectT90Desats() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setMinimum(.oxygenSaturation, value: 0.88)
        // Sufficient HK-direct overnight coverage: 60 × 10s samples (600s
        // monitored ≥ 300s, count ≥ 30), 20 of them below 0.90 → T90 > 0.
        var hkSamples: [QuantitySample] = []
        for i in 0..<60 {
            let start = overnightAnchor.addingTimeInterval(Double(i) * 10)
            hkSamples.append(QuantitySample(
                start: start, end: start.addingTimeInterval(10),
                value: i < 20 ? 0.88 : 0.95
            ))
        }
        await mock.setQuantitySamples(.oxygenSaturation, hkSamples)

        // Only 5 EMAY samples — well below `minSamplesForOvernightStats`.
        seedOvernightSpO2(
            bundle: "com.emay.SleepO2",
            count: 5,
            value: 0.92,
            in: context,
            startingAt: overnightAnchor.addingTimeInterval(3600)
        )
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        // Nadir still overridden (single-sample min is always meaningful).
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 92.0) < 0.001)
        // T90/desats KEPT from the sufficient HK-direct computation — the
        // sparse preferred subset can't replace them, and must not nil them.
        #expect((snap?.spo2TimeBelow90Min ?? 0) >= 3)
        #expect(snap?.spo2DesatsCount != nil)
    }

    @Test("Sparse preferred with insufficient HK-direct coverage leaves T90/desats nil")
    func sparsePreferredWithNoHKDirectStaysNil() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // No HK sample stream → HK-direct T90/desats are nil.
        await mock.setMinimum(.oxygenSaturation, value: 0.90)
        seedOvernightSpO2(
            bundle: "com.emay.SleepO2",
            count: 5,
            value: 0.92,
            in: context,
            startingAt: overnightAnchor
        )
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(snap?.spo2TimeBelow90Min == nil)
        #expect(snap?.spo2DesatsCount == nil)
    }

    // MARK: - HRV precedence

    @Test("Polar HRV samples override HK-direct hrvAvg/hrvMin")
    func polarHRVOverride() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 28.0)  // Watch
        await mock.setMinimum(.heartRateVariabilitySDNN, value: 18.0)  // Watch

        // Polar Flow samples inside the overnight noon-to-noon window
        // (chest-strap precedence is night-attributed per F-046) — values
        // stored in ms by the HealthKit mirror.
        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        for offsetMin in stride(from: 0, through: 60, by: 5) {
            context.insert(QuantityHealthSample(
                timestamp: overnightAnchor.addingTimeInterval(Double(offsetMin * 60)),
                metricType: hrvType,
                value: 50.0,  // Polar-typical SDNN
                unitString: "ms",
                sourceBundleID: "fi.polar.polarflow",
                sourceName: "Polar Flow"
            ))
        }
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.hrvAvg ?? 0) - 50.0) < 0.001)
        #expect(abs((snap?.hrvMin ?? 0) - 50.0) < 0.001)
    }

    @Test("Polar HRV samples via app's BLE source label (polar_h10) also override")
    func polarH10TypedLabelHRVOverride() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 28.0)

        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        context.insert(QuantityHealthSample(
            timestamp: overnightAnchor.addingTimeInterval(3600),
            metricType: hrvType,
            value: 48.0,
            unitString: "ms",
            sourceBundleID: "polar_h10",
            sourceName: "Polar H10"
        ))
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.hrvAvg ?? 0) - 48.0) < 0.001)
    }

    @Test("No Polar samples → HK-direct HRV is preserved")
    func noPreferredHRVNoOverride() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 35.0)
        // No Polar rows seeded.

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.hrvAvg ?? 0) - 35.0) < 0.001)
    }

    @Test("Polar resting HR override")
    func polarRestingHROverride() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.restingHeartRate, value: 68.0)  // Watch

        context.insert(QuantityHealthSample(
            timestamp: overnightAnchor.addingTimeInterval(3600),
            metricType: HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            value: 56.0,  // Polar
            unitString: "count/min",
            sourceBundleID: "fi.polar.polarflow",
            sourceName: "Polar Flow"
        ))
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.restingHR ?? 0) - 56.0) < 0.001)
    }

    // MARK: - First-party BLE route (F-027) + night attribution (F-046)

    // F-027: the app's own Polar BLE pipeline writes HRVReading rows (never
    // QuantityHealthSample), so before the HRVReading branch existed,
    // first-party sessions could never win precedence over the Watch value.
    @Test("First-party HRVReading rows (polar_h10) override HK-direct hrvAvg/hrvMin")
    func bleHRVReadingsOverride() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 28.0)  // Watch
        await mock.setMinimum(.heartRateVariabilitySDNN, value: 18.0)  // Watch

        for (offset, sdnn) in [(0.0, 52.0), (60.0, 44.0)] {
            context.insert(HRVReading(
                timestamp: overnightAnchor.addingTimeInterval(offset),
                rmssd: 40, sdnn: sdnn, pnn50: 20,
                lfPower: 100, hfPower: 80, lfHfRatio: 1.25,
                sensorSessionID: UUID(), source: "polar_h10"
            ))
        }
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.hrvAvg ?? 0) - 48.0) < 0.001)  // mean(52, 44)
        #expect(abs((snap?.hrvMin ?? 0) - 44.0) < 0.001)
    }

    @Test("Non-chest-strap HRVReading rows do not override the Watch value")
    func nonStrapHRVReadingsNoOverride() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 28.0)

        context.insert(HRVReading(
            timestamp: overnightAnchor,
            rmssd: 40, sdnn: 60, pnn50: 20,
            lfPower: 100, hfPower: 80, lfHfRatio: 1.25,
            sensorSessionID: UUID(), source: "apple_watch_ppg"
        ))
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.hrvAvg ?? 0) - 28.0) < 0.001)
    }

    // F-046: chest-strap precedence is bucketed noon-to-noon like the sleep
    // fields, so a pre-midnight sample belongs to the morning-after snapshot
    // rather than being split at the calendar-day boundary.
    @Test("Pre-midnight chest-strap sample attributes to the morning-after snapshot")
    func preMidnightStrapSampleNightAttribution() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 28.0)

        // overnightAnchor is 02:00 local; -4h = 22:00 the previous evening —
        // inside the noon-to-noon window, outside the calendar day.
        let preMidnight = overnightAnchor.addingTimeInterval(-4 * 3600)
        context.insert(QuantityHealthSample(
            timestamp: preMidnight,
            metricType: HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
            value: 51.0,
            unitString: "ms",
            sourceBundleID: "fi.polar.polarflow",
            sourceName: "Polar Flow"
        ))
        try context.save()

        try await makeAggregator(mock: mock, context: context).aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>()).first
        #expect(abs((snap?.hrvAvg ?? 0) - 51.0) < 0.001,
                "22:00 sample must land in this night's snapshot, not yesterday's")
    }
}
