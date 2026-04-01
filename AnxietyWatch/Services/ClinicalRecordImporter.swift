import Foundation
import HealthKit
import SwiftData

/// Imports anxiety-relevant clinical lab results from HealthKit Health Records.
/// Follows the same pattern as SnapshotAggregator: takes a HealthKitManager + ModelContext.
struct ClinicalRecordImporter {
    let healthKit: any HealthKitDataSource
    let modelContext: ModelContext

    /// Queries HealthKit for clinical lab results, parses FHIR data, and inserts
    /// new results into SwiftData. Returns the number of newly imported results.
    @discardableResult
    func importLabResults() async throws -> Int {
        let records = try await healthKit.queryClinicalLabResults(since: nil)

        // Fetch only existing UUIDs for deduplication (avoids hydrating full objects)
        var descriptor = FetchDescriptor<ClinicalLabResult>()
        descriptor.propertiesToFetch = [\.healthKitSampleUUID]
        let existing = try modelContext.fetch(descriptor)
        var existingUUIDs = Set(existing.map(\.healthKitSampleUUID))

        var importedCount = 0

        for record in records {
            let sampleUUID = record.uuid.uuidString

            guard !existingUUIDs.contains(sampleUUID) else { continue }

            guard let fhirRecord = record.fhirResource,
                  let parsed = FHIRLabResultParser.parse(fhirJSON: fhirRecord.data) else {
                continue
            }

            let labResult = ClinicalLabResult(
                loincCode: parsed.loincCode,
                testName: parsed.displayName,
                value: parsed.value,
                unit: parsed.unit,
                effectiveDate: parsed.effectiveDate,
                referenceRangeLow: parsed.referenceRangeLow,
                referenceRangeHigh: parsed.referenceRangeHigh,
                interpretation: parsed.interpretation,
                sourceName: record.source.name,
                healthKitSampleUUID: sampleUUID
            )
            modelContext.insert(labResult)
            existingUUIDs.insert(sampleUUID)
            importedCount += 1
        }

        if importedCount > 0 {
            try modelContext.save()
        }

        return importedCount
    }
}
