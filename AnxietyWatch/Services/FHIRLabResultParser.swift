import Foundation

/// Parses FHIR R4 Observation resources from HealthKit clinical records.
/// Only extracts the fields needed for anxiety-relevant lab results.
enum FHIRLabResultParser {

    struct ParsedResult {
        let loincCode: String
        let displayName: String
        let value: Double
        let unit: String
        let effectiveDate: Date
        let referenceRangeLow: Double?
        let referenceRangeHigh: Double?
        let interpretation: String?
    }

    /// Parse a FHIR R4 Observation JSON blob into a `ParsedResult`.
    /// Returns nil if the record isn't a tracked lab test or can't be parsed.
    static func parse(fhirJSON data: Data) -> ParsedResult? {
        guard let observation = try? JSONDecoder().decode(FHIRObservation.self, from: data) else {
            return nil
        }
        return parse(observation: observation)
    }

    static func parse(observation: FHIRObservation) -> ParsedResult? {
        // Find the first LOINC coding we track
        guard let coding = observation.code?.coding?.first(where: { coding in
            coding.system == "http://loinc.org" && LabTestRegistry.isTracked(coding.code ?? "")
        }),
        let loincCode = coding.code else {
            return nil
        }

        // Must have a numeric value
        guard let valueQuantity = observation.valueQuantity,
              let value = valueQuantity.value else {
            return nil
        }

        // Parse the effective date
        guard let dateString = observation.effectiveDateTime,
              let effectiveDate = parseDate(dateString) else {
            return nil
        }

        let unit = valueQuantity.unit ?? valueQuantity.code ?? ""
        let displayName = coding.display ?? LabTestRegistry.definition(for: loincCode)?.displayName ?? loincCode

        // Extract reference range if present
        let refRange = observation.referenceRange?.first
        let refLow = refRange?.low?.value
        let refHigh = refRange?.high?.value

        // Extract interpretation code (e.g., "N", "H", "L")
        let interpretation = observation.interpretation?.first?.coding?.first?.code

        return ParsedResult(
            loincCode: loincCode,
            displayName: displayName,
            value: value,
            unit: unit,
            effectiveDate: effectiveDate,
            referenceRangeLow: refLow,
            referenceRangeHigh: refHigh,
            interpretation: interpretation
        )
    }

    // MARK: - Date Parsing

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string)
            ?? isoFormatterNoFraction.date(from: string)
            ?? dateOnlyFormatter.date(from: string)
    }

    // MARK: - FHIR R4 Codable Structs (minimal)

    struct FHIRObservation: Codable {
        let resourceType: String?
        let code: FHIRCodeableConcept?
        let valueQuantity: FHIRQuantity?
        let effectiveDateTime: String?
        let referenceRange: [FHIRReferenceRange]?
        let interpretation: [FHIRCodeableConcept]?
    }

    struct FHIRCodeableConcept: Codable {
        let coding: [FHIRCoding]?
        let text: String?
    }

    struct FHIRCoding: Codable {
        let system: String?
        let code: String?
        let display: String?
    }

    struct FHIRQuantity: Codable {
        let value: Double?
        let unit: String?
        let system: String?
        let code: String?
    }

    struct FHIRReferenceRange: Codable {
        let low: FHIRQuantity?
        let high: FHIRQuantity?
        let text: String?
    }
}
