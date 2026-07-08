import UIKit
import Vision

/// Stateless service for OCR scanning and parsing of prescription bottle labels.
enum PrescriptionLabelScanner {

    /// One OCR-recognized line of text paired with Vision's confidence for that
    /// line's top candidate. Confidence is normalized 0.0–1.0.
    struct RecognizedLine: Equatable {
        let text: String
        let confidence: Float
    }

    /// A parsed field of the label. Used to key per-field OCR confidence so the
    /// review UI can flag a low-confidence read (e.g. a misread dose digit)
    /// rather than presenting every field with identical visual weight.
    enum Field: Hashable {
        case rxNumber, medicationName, dose, quantity, refillsRemaining, pharmacyName, dateFilled
    }

    /// Vision's `VNRecognizedText.confidence` is normalized 0.0–1.0. For the
    /// `.accurate` recognition path used here, readings below this threshold are
    /// unreliable enough that the user should verify them against the bottle.
    /// 0.5 is a deliberately conservative midpoint: high enough to catch glare/
    /// blur misreads of a dose or Rx digit, low enough not to flag ordinary
    /// clean reads. Kept as a named constant so the gate is documented and
    /// testable rather than a buried literal.
    static let lowConfidenceThreshold: Float = 0.5

    /// Pure confidence-gating decision, extracted for testability. A `nil`
    /// confidence (e.g. a field parsed from a plain `[String]` with no OCR
    /// metadata) is treated as NOT low — we only flag readings we have positive
    /// evidence to distrust.
    static func isLowConfidence(_ confidence: Float?) -> Bool {
        guard let confidence else { return false }
        return confidence < lowConfidenceThreshold
    }

    struct ScannedPrescriptionData {
        var rxNumber: String?
        var medicationName: String?
        var dose: String?
        var quantity: Int?
        var refillsRemaining: Int?
        var pharmacyName: String?
        var dateFilled: Date?
        /// All recognized lines for user review
        var rawText: [String]
        /// OCR confidence for each field that was parsed from a recognized line.
        /// Absent for fields parsed without OCR metadata (the `[String]` path).
        var fieldConfidence: [Field: Float] = [:]

        /// Whether the given field was read with low OCR confidence and should
        /// be flagged to the user for verification.
        func isLowConfidence(_ field: Field) -> Bool {
            PrescriptionLabelScanner.isLowConfidence(fieldConfidence[field])
        }

        /// True if any parsed field was read with low OCR confidence.
        var hasLowConfidenceField: Bool {
            fieldConfidence.values.contains { PrescriptionLabelScanner.isLowConfidence($0) }
        }
    }

    enum ScanError: Error, LocalizedError {
        case invalidImage
        case recognitionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "Could not process the image"
            case .recognitionFailed(let error):
                return "Text recognition failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Public API

    /// Perform OCR on a photo of a prescription label and parse the results.
    static func scan(image: UIImage) async throws -> ScannedPrescriptionData {
        guard let cgImage = image.cgImage else {
            throw ScanError.invalidImage
        }

        let recognizedLines = try await recognizeText(in: cgImage)
        return parse(recognizedLines: recognizedLines)
    }

    /// Pure parsing function — extracts structured prescription data from OCR text lines.
    /// Fully testable with hardcoded input. Fields parsed via this overload carry
    /// NO OCR confidence: `fieldConfidence` is cleared so a non-OCR caller
    /// (tests, programmatic input) isn't misreported as a "high confidence"
    /// read, which would suppress the low-confidence review warning
    /// (Copilot review of #164).
    static func parse(lines: [String]) -> ScannedPrescriptionData {
        var result = parse(recognizedLines: lines.map { RecognizedLine(text: $0, confidence: 1.0) })
        result.fieldConfidence = [:]
        return result
    }

    /// Pure parsing function that also threads each recognized line's OCR
    /// confidence through to the parsed fields, so a low-confidence misread can
    /// be flagged in the review UI instead of being shown with the same weight
    /// as a clean read.
    static func parse(recognizedLines: [RecognizedLine]) -> ScannedPrescriptionData {
        var result = ScannedPrescriptionData(rawText: recognizedLines.map(\.text))

        for line in recognizedLines {
            let text = line.text

            // Rx number: 5–12 digit number following "Rx" prefix
            if result.rxNumber == nil, let match = text.firstMatch(of: /[Rr][Xx]\s*#?\s*:?\s*(\d{5,12})/) {
                result.rxNumber = String(match.1)
                result.fieldConfidence[.rxNumber] = line.confidence
            }

            // Quantity: number following "Qty" or "Quantity"
            if result.quantity == nil, let match = text.firstMatch(of: /[Qq](?:ty|uantity)\s*:?\s*#?\s*(\d+)/) {
                result.quantity = Int(match.1)
                result.fieldConfidence[.quantity] = line.confidence
            }

            // Refills: number following "Refill" or "Refills"
            if result.refillsRemaining == nil, let match = text.firstMatch(of: /[Rr]efills?\s*:?\s*(\d+)/) {
                result.refillsRemaining = Int(match.1)
                result.fieldConfidence[.refillsRemaining] = line.confidence
            }

            // Dose: numeric value followed by a unit
            if result.dose == nil, let match = text.firstMatch(of: /(\d+\.?\d*)\s*(mg|mcg|mL|ml|tablet|cap|capsule)/
                .ignoresCase()
            ) {
                result.dose = String(match.0)
                result.fieldConfidence[.dose] = line.confidence
            }

            // Date filled: MM/dd/yyyy or MM-dd-yyyy variants
            if result.dateFilled == nil, let parsed = parseDate(from: text) {
                result.dateFilled = parsed
                result.fieldConfidence[.dateFilled] = line.confidence
            }
        }

        // Pharmacy name — check first 3 lines for known chains or uppercase text
        if let pharmacy = detectPharmacyName(lines: recognizedLines) {
            result.pharmacyName = pharmacy.name
            result.fieldConfidence[.pharmacyName] = pharmacy.confidence
        }

        // Medication name — heuristic: longest "content" line not claimed by other fields
        if let medication = detectMedicationName(lines: recognizedLines, alreadyParsed: result) {
            result.medicationName = medication.name
            result.fieldConfidence[.medicationName] = medication.confidence
        }

        return result
    }

    // MARK: - OCR Engine

    private static func recognizeText(in cgImage: CGImage) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: ScanError.recognitionFailed(error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                // Keep Vision's per-candidate confidence so downstream parsing
                // can flag low-confidence reads instead of discarding it.
                let lines = observations.compactMap { observation -> RecognizedLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedLine(text: candidate.string, confidence: candidate.confidence)
                }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: ScanError.recognitionFailed(error))
            }
        }
    }

    // MARK: - Parsing Helpers

    /// Attempt to parse a date from a line using common prescription label formats.
    private static func parseDate(from line: String) -> Date? {
        guard let match = line.firstMatch(of: /(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})/) else {
            return nil
        }

        let dateString = String(match.0)

        // Try common date formats
        let formats = ["MM/dd/yyyy", "MM-dd-yyyy", "MM/dd/yy", "MM-dd-yy", "M/d/yyyy", "M-d-yyyy", "M/d/yy", "M-d-yy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                return date
            }
        }
        return nil
    }

    /// Known pharmacy chain names to look for in label text.
    private static let knownPharmacyNames = [
        "CVS", "WALGREENS", "RITE AID", "WALMART", "COSTCO", "SAM'S CLUB",
        "KROGER", "PUBLIX", "H-E-B", "HEB", "SAFEWAY", "ALBERTSONS",
        "RITE-AID", "TARGET", "AMAZON PHARMACY", "CAPSULE", "ALTO",
        "EXPRESS SCRIPTS", "OPTUMRX", "CAREMARK", "MAIL ORDER",
        "WEGMANS", "GIANT", "STOP & SHOP", "MEIJER", "WINN-DIXIE"
    ]

    /// Detect pharmacy name from the first few lines of label text, returning
    /// the trimmed name alongside the source line's OCR confidence.
    private static func detectPharmacyName(lines: [RecognizedLine]) -> (name: String, confidence: Float)? {
        let linesToCheck = Array(lines.prefix(3))

        // First pass: look for known pharmacy chains
        for line in linesToCheck {
            let upper = line.text.uppercased()
            for name in knownPharmacyNames {
                if upper.contains(name) {
                    return (line.text.trimmingCharacters(in: .whitespaces), line.confidence)
                }
            }
        }

        // Second pass: pick the first line that is mostly uppercase and doesn't
        // look like an Rx number, quantity, or date
        for line in linesToCheck {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let letters = trimmed.filter(\.isLetter)
            guard !letters.isEmpty else { continue }

            let uppercaseRatio = Double(letters.filter(\.isUppercase).count) / Double(letters.count)
            let looksLikeDataField = trimmed.firstMatch(of: /[Rr][Xx]\s*#?\s*:?\s*\d/) != nil
                || trimmed.firstMatch(of: /[Qq](?:ty|uantity)\s*:?/) != nil
                || trimmed.firstMatch(of: /[Rr]efills?\s*:?/) != nil
                || trimmed.firstMatch(of: /\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}/) != nil

            if uppercaseRatio > 0.7 && !looksLikeDataField {
                return (trimmed, line.confidence)
            }
        }

        return nil
    }

    /// Detect the medication name by finding the longest content line not already
    /// claimed by other parsed fields.
    private static func detectMedicationName(
        lines: [RecognizedLine],
        alreadyParsed: ScannedPrescriptionData
    ) -> (name: String, confidence: Float)? {
        // Lines that were identified as pharmacy name — skip them
        let pharmacyUpper = alreadyParsed.pharmacyName?.uppercased()

        // Patterns that indicate a non-medication line
        let excludePatterns: [Regex<AnyRegexOutput>] = [
            try! Regex("[Rr][Xx]\\s*#?\\s*:?\\s*\\d{5,12}"),
            try! Regex("[Qq](?:ty|uantity)\\s*:?\\s*#?\\s*\\d+"),
            try! Regex("[Rr]efills?\\s*:?\\s*\\d+"),
            try! Regex("\\d{1,2}[/\\-]\\d{1,2}[/\\-]\\d{2,4}"),
            try! Regex("^\\d+$"),
        ]

        // Address-like patterns (street numbers, state abbreviations + zip)
        let addressPatterns: [Regex<AnyRegexOutput>] = [
            try! Regex("(?i)\\d+\\s+\\w+\\s+(St|Ave|Blvd|Rd|Dr|Ln|Way|Ct|Pl|Pkwy|Hwy)\\b"),
            try! Regex("[A-Z]{2}\\s+\\d{5}"),
        ]

        var bestCandidate: (name: String, confidence: Float)?
        var bestLength = 0

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Must contain at least one letter
            guard trimmed.contains(where: \.isLetter) else { continue }

            // Skip if this is the pharmacy name line
            if let pharmacyUpper, trimmed.uppercased() == pharmacyUpper {
                continue
            }

            // Skip lines matching data-field patterns
            let matchesExclude = excludePatterns.contains { pattern in
                trimmed.firstMatch(of: pattern) != nil
            }
            if matchesExclude { continue }

            // Skip address-like lines
            let matchesAddress = addressPatterns.contains { pattern in
                trimmed.firstMatch(of: pattern) != nil
            }
            if matchesAddress { continue }

            // Prefer the longest remaining line as the medication name
            if trimmed.count > bestLength {
                bestLength = trimmed.count
                bestCandidate = (trimmed, line.confidence)
            }
        }

        return bestCandidate
    }
}
