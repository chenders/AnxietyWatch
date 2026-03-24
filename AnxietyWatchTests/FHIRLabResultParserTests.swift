import Foundation
import Testing

@testable import AnxietyWatch

struct FHIRLabResultParserTests {

    // MARK: - Helpers

    /// Build a minimal FHIR Observation JSON for a tracked lab test.
    private func makeFHIRJSON(
        loincCode: String = "3016-3",
        display: String = "TSH",
        value: Double = 2.5,
        unit: String = "mIU/L",
        effectiveDateTime: String = "2025-11-15T08:30:00Z",
        refLow: Double? = 0.4,
        refHigh: Double? = 4.0,
        interpretation: String? = "N"
    ) -> Data {
        var json: [String: Any] = [
            "resourceType": "Observation",
            "code": [
                "coding": [
                    [
                        "system": "http://loinc.org",
                        "code": loincCode,
                        "display": display,
                    ] as [String: Any]
                ]
            ],
            "valueQuantity": [
                "value": value,
                "unit": unit,
            ] as [String: Any],
            "effectiveDateTime": effectiveDateTime,
        ]

        if refLow != nil || refHigh != nil {
            var range: [String: Any] = [:]
            if let low = refLow { range["low"] = ["value": low] }
            if let high = refHigh { range["high"] = ["value": high] }
            json["referenceRange"] = [range]
        }

        if let interp = interpretation {
            json["interpretation"] = [
                ["coding": [["code": interp]]]
            ]
        }

        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Valid Parsing

    @Test("Parses a valid TSH result")
    func parsesValidTSH() {
        let data = makeFHIRJSON()
        let result = FHIRLabResultParser.parse(fhirJSON: data)

        #expect(result != nil)
        #expect(result?.loincCode == "3016-3")
        #expect(result?.value == 2.5)
        #expect(result?.unit == "mIU/L")
        #expect(result?.referenceRangeLow == 0.4)
        #expect(result?.referenceRangeHigh == 4.0)
        #expect(result?.interpretation == "N")
    }

    @Test("Parses vitamin D result")
    func parsesVitaminD() {
        let data = makeFHIRJSON(
            loincCode: "14979-9",
            display: "25-Hydroxyvitamin D",
            value: 28.0,
            unit: "ng/mL",
            refLow: 30,
            refHigh: 100
        )
        let result = FHIRLabResultParser.parse(fhirJSON: data)

        #expect(result != nil)
        #expect(result?.loincCode == "14979-9")
        #expect(result?.value == 28.0)
    }

    @Test("Parses date-only effectiveDateTime")
    func parsesDateOnly() {
        let data = makeFHIRJSON(effectiveDateTime: "2025-06-15")
        let result = FHIRLabResultParser.parse(fhirJSON: data)

        #expect(result != nil)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: result!.effectiveDate)
        #expect(components.year == 2025)
        #expect(components.month == 6)
        #expect(components.day == 15)
    }

    // MARK: - Missing Fields

    @Test("Returns nil for missing value")
    func nilForMissingValue() {
        let json: [String: Any] = [
            "resourceType": "Observation",
            "code": [
                "coding": [
                    ["system": "http://loinc.org", "code": "3016-3", "display": "TSH"]
                ]
            ],
            "effectiveDateTime": "2025-11-15T08:30:00Z",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let result = FHIRLabResultParser.parse(fhirJSON: data)
        #expect(result == nil)
    }

    @Test("Returns nil for missing effectiveDateTime")
    func nilForMissingDate() {
        let json: [String: Any] = [
            "resourceType": "Observation",
            "code": [
                "coding": [
                    ["system": "http://loinc.org", "code": "3016-3"]
                ]
            ],
            "valueQuantity": ["value": 2.5, "unit": "mIU/L"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let result = FHIRLabResultParser.parse(fhirJSON: data)
        #expect(result == nil)
    }

    @Test("Handles missing reference range gracefully")
    func handlesNoRefRange() {
        let data = makeFHIRJSON(refLow: nil, refHigh: nil, interpretation: nil)
        let result = FHIRLabResultParser.parse(fhirJSON: data)

        #expect(result != nil)
        #expect(result?.referenceRangeLow == nil)
        #expect(result?.referenceRangeHigh == nil)
        #expect(result?.interpretation == nil)
    }

    // MARK: - Filtering

    @Test("Rejects non-LOINC coding systems")
    func rejectsNonLOINC() {
        let json: [String: Any] = [
            "resourceType": "Observation",
            "code": [
                "coding": [
                    ["system": "http://snomed.info/sct", "code": "3016-3"]
                ]
            ],
            "valueQuantity": ["value": 2.5, "unit": "mIU/L"],
            "effectiveDateTime": "2025-11-15T08:30:00Z",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let result = FHIRLabResultParser.parse(fhirJSON: data)
        #expect(result == nil)
    }

    @Test("Rejects untracked LOINC codes")
    func rejectsUntrackedCodes() {
        let data = makeFHIRJSON(loincCode: "9999-9", display: "Some Random Test")
        let result = FHIRLabResultParser.parse(fhirJSON: data)
        #expect(result == nil)
    }

    @Test("Rejects invalid JSON")
    func rejectsInvalidJSON() {
        let data = Data("not json".utf8)
        let result = FHIRLabResultParser.parse(fhirJSON: data)
        #expect(result == nil)
    }

    // MARK: - All tracked codes

    @Test("Parses all 12 tracked lab tests")
    func parsesAllTrackedTests() {
        let codes = Array(LabTestRegistry.trackedTests.keys)
        #expect(codes.count == 12)

        for code in codes {
            let def = LabTestRegistry.definition(for: code)!
            let data = makeFHIRJSON(
                loincCode: code,
                display: def.displayName,
                value: (def.normalRangeLow + def.normalRangeHigh) / 2,
                unit: def.unit
            )
            let result = FHIRLabResultParser.parse(fhirJSON: data)
            #expect(result != nil, "Failed to parse LOINC \(code) (\(def.shortName))")
            #expect(result?.loincCode == code)
        }
    }
}
