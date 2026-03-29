import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct HealthSampleTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([HealthSample.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("HealthSample stores type, value, timestamp, and source")
    func basicCreation() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HealthSample(type: "HKQuantityTypeIdentifierHeartRate", value: 72.0, timestamp: ts, source: "Apple Watch")
        context.insert(sample)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(fetched.count == 1)
        #expect(fetched[0].type == "HKQuantityTypeIdentifierHeartRate")
        #expect(fetched[0].value == 72.0)
        #expect(fetched[0].timestamp == ts)
        #expect(fetched[0].source == "Apple Watch")
    }

    @Test("Query samples by type and date range")
    func queryByTypeAndRange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hrType = "HKQuantityTypeIdentifierHeartRate"
        let hrvType = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"

        for i in 0..<3 {
            let sample = HealthSample(
                type: hrType,
                value: 70 + Double(i),
                timestamp: now.addingTimeInterval(Double(i) * 600)
            )
            context.insert(sample)
        }
        context.insert(HealthSample(type: hrvType, value: 42, timestamp: now))
        try context.save()

        let descriptor = FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { $0.type == hrType },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let results = try context.fetch(descriptor)
        #expect(results.count == 3)
        #expect(results[0].value == 70)
        #expect(results[2].value == 72)
    }

    @Test("Prune deletes samples older than retention period")
    func pruneOldSamples() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let eightDaysAgo = now.addingTimeInterval(-8 * 86400)
        let sixDaysAgo = now.addingTimeInterval(-6 * 86400)

        context.insert(HealthSample(type: "hr", value: 70, timestamp: eightDaysAgo))
        context.insert(HealthSample(type: "hr", value: 72, timestamp: sixDaysAgo))
        context.insert(HealthSample(type: "hr", value: 75, timestamp: now))
        try context.save()

        let cutoff = now.addingTimeInterval(-7 * 86400)
        let old = try context.fetch(FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { $0.timestamp < cutoff }
        ))
        for sample in old { context.delete(sample) }
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(remaining.count == 2)
    }
}
