import Foundation
import Testing

@testable import AnxietyWatch

struct FHIRLabResultParserTests {

    // MARK: - Helpers

    /// Build a minimal FHIR Observation JSON for a tracked lab test.
    /// Pass `effectiveDateTime: nil` plus period fields to exercise the
    /// `effectivePeriod` variant of FHIR R4 effective[x].
    private func makeFHIRJSON(
        loincCode: String = "3016-3",
        display: String = "TSH",
        value: Double = 2.5,
        unit: String = "mIU/L",
        effectiveDateTime: String? = "2025-11-15T08:30:00Z",
        effectivePeriodStart: String? = nil,
        effectivePeriodEnd: String? = nil,
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
        ]

        if let effectiveDateTime {
            json["effectiveDateTime"] = effectiveDateTime
        }
        if effectivePeriodStart != nil || effectivePeriodEnd != nil {
            var period: [String: Any] = [:]
            if let start = effectivePeriodStart { period["start"] = start }
            if let end = effectivePeriodEnd { period["end"] = end }
            json["effectivePeriod"] = period
        }

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

    @Test("Parses date-only effectiveDateTime to noon UTC")
    func parsesDateOnly() throws {
        let data = makeFHIRJSON(effectiveDateTime: "2025-06-15")
        let result = try #require(FHIRLabResultParser.parse(fhirJSON: data))

        // Date-only labs are pinned to noon UTC (not device-local midnight),
        // so the stored instant is the same regardless of where the device
        // was at import time. Assert the exact instant, not just the day.
        let iso = ISO8601DateFormatter()
        let expected = try #require(iso.date(from: "2025-06-15T12:00:00Z"))
        #expect(abs(result.effectiveDate.timeIntervalSince(expected)) < 0.001)
    }

    @Test("Date-only lab keeps its calendar day across display timezones")
    func dateOnlyDayStableAcrossTimezones() throws {
        let data = makeFHIRJSON(effectiveDateTime: "2025-06-15")
        let result = try #require(FHIRLabResultParser.parse(fhirJSON: data))

        // Noon UTC renders as June 15 at any offset within ±12h — spot-check
        // the far west and far east of the commonly inhabited range. (Local
        // midnight, the old behavior, flipped to June 14 anywhere west of the
        // importing device.)
        for zoneID in ["Pacific/Pago_Pago", "America/Los_Angeles", "UTC", "Asia/Tokyo"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zoneID))
            let components = calendar.dateComponents([.year, .month, .day], from: result.effectiveDate)
            #expect(components.year == 2025, "wrong year in \(zoneID)")
            #expect(components.month == 6, "wrong month in \(zoneID)")
            #expect(components.day == 15, "wrong day in \(zoneID)")
        }
    }

    @Test("Full effectiveDateTime still parses to its exact instant")
    func fullDateTimeUnchanged() throws {
        // Guard against the date-only noon shift leaking into full datetimes.
        let data = makeFHIRJSON(effectiveDateTime: "2025-11-15T08:30:00Z")
        let result = try #require(FHIRLabResultParser.parse(fhirJSON: data))

        let iso = ISO8601DateFormatter()
        let expected = try #require(iso.date(from: "2025-11-15T08:30:00Z"))
        #expect(abs(result.effectiveDate.timeIntervalSince(expected)) < 0.001)
    }

    // MARK: - effectivePeriod (FHIR R4 effective[x] variant)

    @Test("Parses Observation with effectivePeriod using its start")
    func parsesEffectivePeriodStart() throws {
        let data = makeFHIRJSON(
            effectiveDateTime: nil,
            effectivePeriodStart: "2025-09-01T07:15:00Z",
            effectivePeriodEnd: "2025-09-01T07:45:00Z"
        )
        let result = try #require(FHIRLabResultParser.parse(fhirJSON: data))

        // The start is the specimen-collection time — the clinically
        // meaningful date for a lab.
        let iso = ISO8601DateFormatter()
        let expected = try #require(iso.date(from: "2025-09-01T07:15:00Z"))
        #expect(abs(result.effectiveDate.timeIntervalSince(expected)) < 0.001)
        #expect(result.loincCode == "3016-3")
    }

    @Test("Falls back to effectivePeriod end when start is missing")
    func parsesEffectivePeriodEndOnly() throws {
        let data = makeFHIRJSON(
            effectiveDateTime: nil,
            effectivePeriodEnd: "2025-09-01T07:45:00Z"
        )
        let result = try #require(FHIRLabResultParser.parse(fhirJSON: data))

        let iso = ISO8601DateFormatter()
        let expected = try #require(iso.date(from: "2025-09-01T07:45:00Z"))
        #expect(abs(result.effectiveDate.timeIntervalSince(expected)) < 0.001)
    }

    @Test("Date-only effectivePeriod start pins to noon UTC like effectiveDateTime")
    func parsesDateOnlyEffectivePeriod() throws {
        let data = makeFHIRJSON(
            effectiveDateTime: nil,
            effectivePeriodStart: "2025-09-01"
        )
        let result = try #require(FHIRLabResultParser.parse(fhirJSON: data))

        let iso = ISO8601DateFormatter()
        let expected = try #require(iso.date(from: "2025-09-01T12:00:00Z"))
        #expect(abs(result.effectiveDate.timeIntervalSince(expected)) < 0.001)
    }

    @Test("Returns nil when neither effectiveDateTime nor effectivePeriod is present")
    func nilForNoEffectiveVariant() {
        let data = makeFHIRJSON(effectiveDateTime: nil)
        let result = FHIRLabResultParser.parse(fhirJSON: data)
        #expect(result == nil)
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

    // MARK: - Parse Outcome Classification (F-081)

    @Test("Outcome is .parsed for a valid tracked result")
    func outcomeParsedForValid() {
        let data = makeFHIRJSON()
        guard case .parsed(let result) = FHIRLabResultParser.parseOutcome(fhirJSON: data) else {
            Issue.record("Expected .parsed")
            return
        }
        #expect(result.loincCode == "3016-3")
    }

    @Test("Outcome is .untracked for a LOINC test outside the registry")
    func outcomeUntrackedForUnknownCode() {
        // Intentional skip — not a failure — so it must NOT be counted as a drop.
        let data = makeFHIRJSON(loincCode: "9999-9", display: "Some Random Test")
        guard case .untracked = FHIRLabResultParser.parseOutcome(fhirJSON: data) else {
            Issue.record("Expected .untracked")
            return
        }
    }

    @Test("Outcome is .untracked for a non-LOINC coding system")
    func outcomeUntrackedForNonLOINC() {
        let json: [String: Any] = [
            "resourceType": "Observation",
            "code": ["coding": [["system": "http://snomed.info/sct", "code": "3016-3"]]],
            "valueQuantity": ["value": 2.5, "unit": "mIU/L"],
            "effectiveDateTime": "2025-11-15T08:30:00Z",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .untracked = FHIRLabResultParser.parseOutcome(fhirJSON: data) else {
            Issue.record("Expected .untracked")
            return
        }
    }

    @Test("Outcome is .unparseable for undecodable JSON")
    func outcomeUnparseableForBadJSON() {
        let data = Data("not json".utf8)
        guard case .unparseable = FHIRLabResultParser.parseOutcome(fhirJSON: data) else {
            Issue.record("Expected .unparseable")
            return
        }
    }

    @Test("Outcome is .unparseable for a tracked test missing its value")
    func outcomeUnparseableForMissingValue() {
        // Tracked LOINC but no numeric value: a result we *should* have imported
        // but couldn't — the silent-drop case F-081 makes visible.
        let json: [String: Any] = [
            "resourceType": "Observation",
            "code": ["coding": [["system": "http://loinc.org", "code": "3016-3", "display": "TSH"]]],
            "effectiveDateTime": "2025-11-15T08:30:00Z",
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        guard case .unparseable = FHIRLabResultParser.parseOutcome(fhirJSON: data) else {
            Issue.record("Expected .unparseable")
            return
        }
    }

    @Test("Outcome is .unparseable for a tracked test with no effective date")
    func outcomeUnparseableForMissingDate() {
        let data = makeFHIRJSON(effectiveDateTime: nil)
        guard case .unparseable = FHIRLabResultParser.parseOutcome(fhirJSON: data) else {
            Issue.record("Expected .unparseable")
            return
        }
    }
}
