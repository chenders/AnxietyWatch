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

    /// Outcome of attempting to parse a single FHIR Observation. Lets callers
    /// distinguish an *intentional* skip (the record isn't a lab test we track)
    /// from a *genuine* parse failure (a tracked result we should have imported
    /// but couldn't decode). Collapsing both to `nil` (as `parse` does) hid the
    /// latter — the importer surfaces `.unparseable` as a skip count so a
    /// provider emitting a shape we reject is no longer permanently invisible.
    enum ParseOutcome {
        /// Successfully parsed a tracked lab result.
        case parsed(ParsedResult)
        /// Decoded fine but isn't a LOINC test in our registry — skipping is correct.
        case untracked
        /// A record that should have yielded a tracked result but was malformed:
        /// undecodable JSON, missing numeric value, or an unparseable effective date.
        case unparseable
    }

    /// Parse a FHIR R4 Observation JSON blob into a `ParsedResult`.
    /// Returns nil if the record isn't a tracked lab test or can't be parsed.
    static func parse(fhirJSON data: Data) -> ParsedResult? {
        if case .parsed(let result) = parseOutcome(fhirJSON: data) { return result }
        return nil
    }

    static func parse(observation: FHIRObservation) -> ParsedResult? {
        if case .parsed(let result) = parseOutcome(observation: observation) { return result }
        return nil
    }

    /// Classifying variant of `parse(fhirJSON:)` — see `ParseOutcome`.
    static func parseOutcome(fhirJSON data: Data) -> ParseOutcome {
        guard let observation = try? JSONDecoder().decode(FHIRObservation.self, from: data) else {
            return .unparseable
        }
        return parseOutcome(observation: observation)
    }

    /// Classifying variant of `parse(observation:)` — see `ParseOutcome`.
    static func parseOutcome(observation: FHIRObservation) -> ParseOutcome {
        // Find the first LOINC coding we track. No tracked coding means this is
        // simply a test outside our registry — an intentional skip, not a failure.
        guard let coding = observation.code?.coding?.first(where: { coding in
            coding.system == "http://loinc.org" && LabTestRegistry.isTracked(coding.code ?? "")
        }),
        let loincCode = coding.code else {
            return .untracked
        }

        // From here the record IS a tracked test, so any failure to extract its
        // value or date is a genuine parse failure we must not silently drop.

        // Must have a numeric value
        guard let valueQuantity = observation.valueQuantity,
              let value = valueQuantity.value else {
            return .unparseable
        }

        // Parse the effective date
        guard let effectiveDate = effectiveDate(of: observation) else {
            return .unparseable
        }

        let unit = valueQuantity.unit ?? valueQuantity.code ?? ""
        let displayName = coding.display ?? LabTestRegistry.definition(for: loincCode)?.displayName ?? loincCode

        // Extract reference range if present
        let refRange = observation.referenceRange?.first
        let refLow = refRange?.low?.value
        let refHigh = refRange?.high?.value

        // Extract interpretation code (e.g., "N", "H", "L")
        let interpretation = observation.interpretation?.first?.coding?.first?.code

        return .parsed(ParsedResult(
            loincCode: loincCode,
            displayName: displayName,
            value: value,
            unit: unit,
            effectiveDate: effectiveDate,
            referenceRangeLow: refLow,
            referenceRangeHigh: refHigh,
            interpretation: interpretation
        ))
    }

    // MARK: - Date Parsing

    /// FHIR R4 `effective[x]` is a choice type: EHRs may emit either
    /// `effectiveDateTime` or `effectivePeriod` (a start/end window, common
    /// for collected-specimen labs). Accept both — requiring only
    /// `effectiveDateTime` silently dropped every Period-emitting EHR's labs.
    /// For a Period, the start is the clinically meaningful collection time;
    /// fall back to end when start is absent (Period requires at least one).
    private static func effectiveDate(of observation: FHIRObservation) -> Date? {
        if let dateString = observation.effectiveDateTime,
           let date = parseDate(dateString) {
            return date
        }
        if let period = observation.effectivePeriod {
            if let start = period.start, let date = parseDate(start) {
                return date
            }
            if let end = period.end, let date = parseDate(end) {
                return date
            }
        }
        return nil
    }

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
        // Pin to UTC so the parsed instant is independent of the device
        // timezone at import time (previously: local midnight, which made
        // the stored instant — and thus the displayed day — depend on where
        // the device happened to be when the record was imported).
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Seconds to shift a date-only parse from midnight UTC to noon UTC.
    private static let noonUTCOffset: TimeInterval = 12 * 3600

    private static func parseDate(_ string: String) -> Date? {
        if let dateTime = isoFormatter.date(from: string)
            ?? isoFormatterNoFraction.date(from: string) {
            return dateTime
        }
        // Date-only lab dates carry no time-of-day, but we must store an
        // instant. Anchor to *noon* UTC: noon is maximally distant from both
        // midnights, so the instant renders as the same calendar day at any
        // UTC offset in [-12h, +11h] — every offset except the UTC+12..+14
        // sliver (Line Islands/Tonga/Chatham), where the day rolls forward
        // one; acceptable for this app's US/Pacific deployment. A later
        // device-timezone change can no longer shift the lab's displayed
        // day. Midnight UTC would flip to the previous day anywhere west
        // of Greenwich.
        return dateOnlyFormatter.date(from: string)
            .map { $0.addingTimeInterval(noonUTCOffset) }
    }

    // MARK: - FHIR R4 Codable Structs (minimal)

    struct FHIRObservation: Codable {
        let resourceType: String?
        let code: FHIRCodeableConcept?
        let valueQuantity: FHIRQuantity?
        let effectiveDateTime: String?
        let effectivePeriod: FHIRPeriod?
        let referenceRange: [FHIRReferenceRange]?
        let interpretation: [FHIRCodeableConcept]?
    }

    /// FHIR R4 Period: at least one of start/end is present per the spec.
    struct FHIRPeriod: Codable {
        let start: String?
        let end: String?
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
