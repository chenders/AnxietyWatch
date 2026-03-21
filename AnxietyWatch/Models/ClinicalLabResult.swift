import Foundation
import SwiftData

/// A single clinical lab result imported from HealthKit Health Records.
/// Lab results are sparse (a few per year) and don't fit into the daily HealthSnapshot model.
@Model
final class ClinicalLabResult {
    var id: UUID
    #Unique<ClinicalLabResult>([\.healthKitSampleUUID])

    /// LOINC code identifying the test type (e.g., "3016-3" for TSH)
    var loincCode: String

    /// Human-readable test name from the FHIR record
    var testName: String

    /// Numeric result value
    var value: Double

    /// Unit of measurement (e.g., "mIU/L", "ng/mL")
    var unit: String

    /// When the specimen was collected / test was performed
    var effectiveDate: Date

    /// Lab-provided reference range bounds (may differ from our registry's population norms)
    var referenceRangeLow: Double?
    var referenceRangeHigh: Double?

    /// FHIR interpretation code (e.g., "N" normal, "H" high, "L" low)
    var interpretation: String?

    /// Name of the source institution (e.g., "Kaiser Permanente")
    var sourceName: String?

    /// UUID of the HKClinicalRecord sample — used for deduplication across imports
    var healthKitSampleUUID: String

    init(
        loincCode: String,
        testName: String,
        value: Double,
        unit: String,
        effectiveDate: Date,
        referenceRangeLow: Double? = nil,
        referenceRangeHigh: Double? = nil,
        interpretation: String? = nil,
        sourceName: String? = nil,
        healthKitSampleUUID: String
    ) {
        self.id = UUID()
        self.loincCode = loincCode
        self.testName = testName
        self.value = value
        self.unit = unit
        self.effectiveDate = effectiveDate
        self.referenceRangeLow = referenceRangeLow
        self.referenceRangeHigh = referenceRangeHigh
        self.interpretation = interpretation
        self.sourceName = sourceName
        self.healthKitSampleUUID = healthKitSampleUUID
    }
}
