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

    @Test("Sparse preferred samples (below threshold) clear T90/desats rather than mix")
    func sparsePreferredClearsT90Desats() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // HK-direct T90 from Apple Watch is set by the mock indirectly via
        // quantitySamples — but the override path doesn't consult those
        // mock samples. Just verify the override clears T90 when preferred
        // is below threshold.
        await mock.setMinimum(.oxygenSaturation, value: 0.78)

        // Only 5 EMAY samples — well below `minSamplesForOvernightStats`.
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
        // Nadir still overridden (single-sample min is always meaningful).
        #expect(abs((snap?.spo2NadirOvernight ?? 0) - 92.0) < 0.001)
        // T90/desats cleared — the preferred subset didn't meet the
        // continuous-monitoring threshold, so mixing in HK-derived counts
        // would be wrong (they'd come from Apple Watch).
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

        // Polar Flow samples in the day window — values stored in ms by
        // the HealthKit mirror.
        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        for offsetMin in stride(from: 0, through: 60, by: 5) {
            context.insert(QuantityHealthSample(
                timestamp: referenceDate.addingTimeInterval(Double(offsetMin * 60)),
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
            timestamp: referenceDate.addingTimeInterval(3600),
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
            timestamp: referenceDate.addingTimeInterval(3600),
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
}
