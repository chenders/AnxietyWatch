import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Integration tests that verify the full HealthKit -> SnapshotAggregator -> HealthSnapshot pipeline
/// on a physical device with real data.
/// Note: These tests require HealthKit authorization. Run the app on Theodore and grant
/// Health permissions before running these tests.
struct SnapshotAggregatorIntegrationTests {

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            AnxietyEntry.self, MedicationDefinition.self, MedicationDose.self,
            CPAPSession.self, BarometricReading.self, HealthSnapshot.self,
            ClinicalLabResult.self, Pharmacy.self, Prescription.self,
            PharmacyCallLog.self, HealthSample.self,
        ])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
    }

    /// Ensure HealthKit authorization before tests run.
    private static func ensureAuthorization() async throws {
        try await HealthKitManager.shared.requestAuthorization()
    }

    @Test("Aggregating yesterday produces a snapshot with HRV data")
    func yesterdaySnapshotHasHRV() async throws {

        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        try await aggregator.aggregateDay(yesterday)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots[0].hrvAvg != nil, "Expected HRV data from Apple Watch")
    }

    @Test("Aggregating yesterday produces reasonable sleep duration")
    func yesterdaySnapshotHasSleep() async throws {

        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        try await aggregator.aggregateDay(yesterday)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        if let sleep = s.sleepDurationMin {
            #expect(sleep > 0 && sleep < 1440, "Sleep duration \(sleep) min outside reasonable range")
        }
    }

    @Test("Aggregating 7 days produces HRV values")
    func weekHasHRVData() async throws {

        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        for day in 1...7 {
            let date = Calendar.current.date(byAdding: .day, value: -day, to: .now)!
            try await aggregator.aggregateDay(date)
        }

        let snapshots = try context.fetch(
            FetchDescriptor<HealthSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        )
        let hrvValues = snapshots.compactMap(\.hrvAvg)
        #expect(!hrvValues.isEmpty, "Expected at least some HRV values from 7 days of data")
    }

    @Test("Aggregating same day twice does not create duplicates")
    func noDuplicates() async throws {

        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        try await aggregator.aggregateDay(yesterday)
        try await aggregator.aggregateDay(yesterday)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1, "Running twice should update, not duplicate")
    }
}
