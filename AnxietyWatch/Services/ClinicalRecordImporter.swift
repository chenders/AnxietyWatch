import Foundation
import HealthKit
import os
import SwiftData

/// Imports anxiety-relevant clinical lab results from HealthKit Health Records.
/// Follows the same pattern as SnapshotAggregator: takes a HealthKitDataSource + ModelContext.
struct ClinicalRecordImporter {
    let healthKit: any HealthKitDataSource
    let modelContext: ModelContext

    /// Outcome of an import pass. `skipped` counts HealthKit records we could
    /// not turn into a lab result: a missing FHIR payload, or a payload/JSON
    /// we couldn't decode or parse (including one too corrupt to even tell
    /// whether its LOINC is tracked). It deliberately EXCLUDES records
    /// filtered out because their LOINC test isn't in our registry — those
    /// aren't failures. A persistently nonzero `skipped` across the hourly
    /// re-import means a provider is emitting a shape our parser rejects, which
    /// a settings view can surface instead of the result silently disappearing.
    struct ImportResult: Equatable {
        let imported: Int
        let skipped: Int
    }

    /// Queries HealthKit for clinical lab results, parses FHIR data, and inserts
    /// new results into SwiftData. Returns the counts of newly imported and
    /// skipped (unparseable) results.
    @discardableResult
    func importLabResults() async throws -> ImportResult {
        let records = try await healthKit.queryClinicalLabResults(since: nil)

        // Fetch only existing UUIDs for deduplication (avoids hydrating full objects)
        var descriptor = FetchDescriptor<ClinicalLabResult>()
        descriptor.propertiesToFetch = [\.healthKitSampleUUID]
        let existing = try modelContext.fetch(descriptor)
        var existingUUIDs = Set(existing.map(\.healthKitSampleUUID))

        var importedCount = 0
        var skippedCount = 0

        for record in records {
            let sampleUUID = record.uuid.uuidString

            guard !existingUUIDs.contains(sampleUUID) else { continue }

            // A lab record with no FHIR payload at all cannot be parsed.
            guard let fhirRecord = record.fhirResource else {
                skippedCount += 1
                continue
            }

            switch FHIRLabResultParser.parseOutcome(fhirJSON: fhirRecord.data) {
            case .untracked:
                // Not a lab test we track — an intentional skip, not a failure.
                continue
            case .unparseable:
                // A tracked result we should have imported but couldn't decode.
                skippedCount += 1
                continue
            case .parsed(let parsed):
                let labResult = ClinicalLabResult(
                    loincCode: parsed.loincCode,
                    testName: parsed.displayName,
                    value: parsed.value,
                    unit: parsed.unit,
                    effectiveDate: parsed.effectiveDate,
                    referenceRangeLow: parsed.referenceRangeLow,
                    referenceRangeHigh: parsed.referenceRangeHigh,
                    interpretation: parsed.interpretation,
                    sourceName: record.sourceRevision.source.name,
                    healthKitSampleUUID: sampleUUID
                )
                modelContext.insert(labResult)
                existingUUIDs.insert(sampleUUID)
                importedCount += 1
            }
        }

        if importedCount > 0 {
            try modelContext.save()
        }

        if skippedCount > 0 {
            // Log the count only — never record contents, which are lab values.
            Log.health.warning("ClinicalRecordImporter skipped \(skippedCount, privacy: .public) unparseable lab record(s)")
        }

        return ImportResult(imported: importedCount, skipped: skippedCount)
    }
}
