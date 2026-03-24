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
}
