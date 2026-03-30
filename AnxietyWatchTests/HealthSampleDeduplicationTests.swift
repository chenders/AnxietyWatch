import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct HealthSampleDeduplicationTests {

    @Test("Inserting duplicate sample does not create second row")
    func duplicateInsertSkipped() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let type = "HKQuantityTypeIdentifierHeartRate"
        let source = "Test Apple Watch"

        context.insert(HealthSample(type: type, value: 72.0, timestamp: ts, source: source))
        try context.save()

        context.insert(HealthSample(type: type, value: 72.0, timestamp: ts, source: source))
        try context.save()

        let all = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(all.count == 1)
    }

    @Test("Samples with different timestamps are not deduped")
    func differentTimestampsKept() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let ts1 = Date(timeIntervalSince1970: 1_700_000_000)
        let ts2 = Date(timeIntervalSince1970: 1_700_000_600)
        let type = "HKQuantityTypeIdentifierHeartRate"

        context.insert(HealthSample(type: type, value: 72.0, timestamp: ts1, source: "Test Apple Watch"))
        context.insert(HealthSample(type: type, value: 75.0, timestamp: ts2, source: "Test Apple Watch"))
        try context.save()

        let all = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(all.count == 2)
    }

    @Test("Samples with different sources are not deduped")
    func differentSourcesKept() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let type = "HKQuantityTypeIdentifierHeartRate"

        context.insert(HealthSample(type: type, value: 72.0, timestamp: ts, source: "Test Apple Watch"))
        context.insert(HealthSample(type: type, value: 72.0, timestamp: ts, source: "Test iPhone"))
        try context.save()

        let all = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(all.count == 2)
    }

    @Test("Nil source samples are deduped separately")
    func nilSourceDeduped() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let type = "HKQuantityTypeIdentifierHeartRate"

        context.insert(HealthSample(type: type, value: 72.0, timestamp: ts, source: nil))
        context.insert(HealthSample(type: type, value: 72.0, timestamp: ts, source: nil))
        try context.save()

        let all = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(all.count == 1)
    }
}
