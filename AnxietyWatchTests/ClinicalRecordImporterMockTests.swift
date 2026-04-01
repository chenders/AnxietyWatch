import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct ClinicalRecordImporterMockTests {

    @Test("Returns 0 when no clinical records available")
    func noRecordsReturnsZero() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let importer = ClinicalRecordImporter(healthKit: mock, modelContext: context)
        let count = try await importer.importLabResults()
        #expect(count == 0)
    }

    @Test("No save when zero records imported")
    func noSaveOnZeroImports() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let importer = ClinicalRecordImporter(healthKit: mock, modelContext: context)
        _ = try await importer.importLabResults()
        let results = try context.fetch(FetchDescriptor<ClinicalLabResult>())
        #expect(results.isEmpty)
    }

    @Test("Existing lab results are not duplicated on reimport")
    func existingResultsNotDuplicated() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let existing = ModelFactory.clinicalLabResult(healthKitSampleUUID: "existing-uuid-1")
        context.insert(existing)
        try context.save()
        let importer = ClinicalRecordImporter(healthKit: mock, modelContext: context)
        let count = try await importer.importLabResults()
        #expect(count == 0)
        let results = try context.fetch(FetchDescriptor<ClinicalLabResult>())
        #expect(results.count == 1)
    }
}
