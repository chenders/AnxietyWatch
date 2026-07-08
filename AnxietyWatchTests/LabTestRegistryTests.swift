import Foundation
import Testing

@testable import AnxietyWatch

struct LabTestRegistryTests {

    @Test("Registry contains 12 tracked tests")
    func registrySize() {
        #expect(LabTestRegistry.trackedTests.count == 12)
    }

    @Test("isTracked returns true for known LOINC codes")
    func isTrackedKnownCodes() {
        #expect(LabTestRegistry.isTracked("3016-3") == true)   // TSH
        #expect(LabTestRegistry.isTracked("14979-9") == true)  // Vitamin D
        #expect(LabTestRegistry.isTracked("2143-6") == true)   // Cortisol
        #expect(LabTestRegistry.isTracked("30522-7") == true)  // hs-CRP
    }

    @Test("isTracked returns false for unknown LOINC codes")
    func isTrackedUnknownCodes() {
        #expect(LabTestRegistry.isTracked("9999-9") == false)
        #expect(LabTestRegistry.isTracked("") == false)
        #expect(LabTestRegistry.isTracked("TSH") == false)  // Not a LOINC code
    }

    @Test("definition(for:) returns correct test for TSH")
    func definitionForTSH() {
        let def = LabTestRegistry.definition(for: "3016-3")
        #expect(def != nil)
        #expect(def?.shortName == "TSH")
        #expect(def?.unit == "mIU/L")
        #expect(def?.normalRangeLow == 0.4)
        #expect(def?.normalRangeHigh == 4.0)
        #expect(def?.category == .thyroid)
    }

    @Test("definition(for:) returns nil for unknown code")
    func definitionForUnknown() {
        #expect(LabTestRegistry.definition(for: "0000-0") == nil)
    }

    @Test("All categories have at least one test")
    func allCategoriesHaveTests() {
        for category in LabTestRegistry.TestCategory.allCases {
            let defs = LabTestRegistry.definitions(in: category)
            #expect(!defs.isEmpty, "Category \(category.rawValue) has no tests")
        }
    }

    @Test("Every test has a non-empty rationale")
    func allTestsHaveRationale() {
        for (_, def) in LabTestRegistry.trackedTests {
            #expect(!def.rationale.isEmpty, "\(def.shortName) has empty rationale")
        }
    }

    @Test("Normal ranges are valid (low < high)")
    func normalRangesValid() {
        for (_, def) in LabTestRegistry.trackedTests {
            #expect(def.normalRangeLow <= def.normalRangeHigh,
                    "\(def.shortName) has invalid range: \(def.normalRangeLow) > \(def.normalRangeHigh)")
        }
    }

    @Test("Category-specific tests are correctly grouped")
    func categoryGrouping() {
        let thyroid = LabTestRegistry.definitions(in: .thyroid)
        let thyroidNames = Set(thyroid.map(\.shortName))
        #expect(thyroidNames.contains("TSH"))
        #expect(thyroidNames.contains("Free T4"))
        #expect(thyroidNames.contains("TPO Ab"))

        let nutritional = LabTestRegistry.definitions(in: .nutritional)
        let nutritionalNames = Set(nutritional.map(\.shortName))
        #expect(nutritionalNames.contains("Vitamin D"))
        #expect(nutritionalNames.contains("B12"))
        #expect(nutritionalNames.contains("Mg"))
        #expect(nutritionalNames.contains("Ferritin"))
    }

    // MARK: - applicableRange / unit compatibility (F-008)

    private func result(
        loinc: String, value: Double, unit: String,
        refLow: Double? = nil, refHigh: Double? = nil
    ) -> ClinicalLabResult {
        ClinicalLabResult(
            loincCode: loinc, testName: "Test", value: value, unit: unit,
            effectiveDate: Date(timeIntervalSince1970: 1_700_000_000),
            referenceRangeLow: refLow, referenceRangeHigh: refHigh,
            healthKitSampleUUID: "test-uuid-\(loinc)-\(unit)"
        )
    }

    @Test("Registry range applies when the lab reports the registry unit")
    func registryRangeAppliesOnMatchingUnit() throws {
        // Fasting glucose in mg/dL — the registry's own unit.
        let range = try #require(LabTestRegistry.applicableRange(for: result(loinc: "2345-7", value: 85, unit: "mg/dL")))
        #expect(range.low == 70)
        #expect(range.high == 100)
    }

    @Test("Registry range does NOT apply to a different reported unit")
    func registryRangeWithheldOnUnitMismatch() {
        // A normal 5.5 mmol/L glucose must not be judged against 70–100
        // mg/dL — that's the exact false-LOW in the clinician PDF (F-008).
        let mmol = result(loinc: "2345-7", value: 5.5, unit: "mmol/L")
        #expect(LabTestRegistry.applicableRange(for: mmol) == nil)
    }

    @Test("Lab-supplied reference range always wins, in any unit")
    func fhirRangeHonoredRegardlessOfUnit() throws {
        let mmol = result(loinc: "2345-7", value: 5.5, unit: "mmol/L", refLow: 3.9, refHigh: 5.6)
        let range = try #require(LabTestRegistry.applicableRange(for: mmol))
        #expect(range.low == 3.9)
        #expect(range.high == 5.6)
    }

    @Test("Partial FHIR range in a foreign unit is not backfilled from the registry")
    func partialForeignRangeNotBackfilled() throws {
        let mmol = result(loinc: "2345-7", value: 5.5, unit: "mmol/L", refHigh: 5.6)
        let range = try #require(LabTestRegistry.applicableRange(for: mmol))
        #expect(range.low == nil)   // NOT the registry's 70 mg/dL
        #expect(range.high == 5.6)
    }

    @Test("Unit synonyms normalize: mcg ↔ µg, UCUM 10*3 ↔ K, case/whitespace")
    func unitSynonymsCompatible() {
        #expect(LabTestRegistry.unitsAreCompatible("mcg/dL", "µg/dL"))
        #expect(LabTestRegistry.unitsAreCompatible("K/uL", "10*3/uL"))
        #expect(LabTestRegistry.unitsAreCompatible("MG/DL", "mg/dL"))
        #expect(LabTestRegistry.unitsAreCompatible("ng/mL ", "ng/mL"))
        #expect(!LabTestRegistry.unitsAreCompatible("mg/dL", "mmol/L"))
        #expect(!LabTestRegistry.unitsAreCompatible("ng/dL", "pmol/L"))
        // Missing unit → can't verify → not compatible (no flag beats a wrong flag).
        #expect(!LabTestRegistry.unitsAreCompatible("", "mg/dL"))
    }

    @Test("Untracked LOINC with no FHIR range has no applicable range")
    func untrackedWithoutFHIRRangeHasNone() {
        #expect(LabTestRegistry.applicableRange(for: result(loinc: "0000-0", value: 1, unit: "mg/dL")) == nil)
    }
}
