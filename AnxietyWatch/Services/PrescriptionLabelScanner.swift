import UIKit
import Vision

/// Stateless service for OCR scanning and parsing of prescription bottle labels.
enum PrescriptionLabelScanner {

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
        return parse(lines: recognizedLines)
    }

    /// Pure parsing function — extracts structured prescription data from OCR text lines.
    /// Fully testable with hardcoded input.
    static func parse(lines: [String]) -> ScannedPrescriptionData {
        var result = ScannedPrescriptionData(rawText: lines)

        for line in lines {
            // Rx number: 5–12 digit number following "Rx" prefix
            if result.rxNumber == nil, let match = line.firstMatch(of: /[Rr][Xx]\s*#?\s*:?\s*(\d{5,12})/) {
                result.rxNumber = String(match.1)
            }

            // Quantity: number following "Qty" or "Quantity"
            if result.quantity == nil, let match = line.firstMatch(of: /[Qq](?:ty|uantity)\s*:?\s*#?\s*(\d+)/) {
                result.quantity = Int(match.1)
            }

            // Refills: number following "Refill" or "Refills"
            if result.refillsRemaining == nil, let match = line.firstMatch(of: /[Rr]efills?\s*:?\s*(\d+)/) {
                result.refillsRemaining = Int(match.1)
            }

            // Dose: numeric value followed by a unit
            if result.dose == nil, let match = line.firstMatch(of: /(\d+\.?\d*)\s*(mg|mcg|mL|ml|tablet|cap|capsule)/
                .ignoresCase()
            ) {
                result.dose = String(match.0)
            }

            // Date filled: MM/dd/yyyy or MM-dd-yyyy variants
            if result.dateFilled == nil {
                result.dateFilled = parseDate(from: line)
            }
        }

        // Pharmacy name — check first 3 lines for known chains or uppercase text
        result.pharmacyName = detectPharmacyName(lines: lines)

        // Medication name — heuristic: longest "content" line not claimed by other fields
        result.medicationName = detectMedicationName(lines: lines, alreadyParsed: result)

        return result
    }

    // MARK: - OCR Engine

    private static func recognizeText(in cgImage: CGImage) async throws -> [String] {
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

                let lines = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
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

    /// Detect pharmacy name from the first few lines of label text.
    private static func detectPharmacyName(lines: [String]) -> String? {
        let linesToCheck = Array(lines.prefix(3))

        // First pass: look for known pharmacy chains
        for line in linesToCheck {
            let upper = line.uppercased()
            for name in knownPharmacyNames {
                if upper.contains(name) {
                    return line.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Second pass: pick the first line that is mostly uppercase and doesn't
        // look like an Rx number, quantity, or date
        for line in linesToCheck {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let letters = trimmed.filter(\.isLetter)
            guard !letters.isEmpty else { continue }

            let uppercaseRatio = Double(letters.filter(\.isUppercase).count) / Double(letters.count)
            let looksLikeDataField = trimmed.firstMatch(of: /[Rr][Xx]\s*#?\s*:?\s*\d/) != nil
                || trimmed.firstMatch(of: /[Qq](?:ty|uantity)\s*:?/) != nil
                || trimmed.firstMatch(of: /[Rr]efills?\s*:?/) != nil
                || trimmed.firstMatch(of: /\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}/) != nil

            if uppercaseRatio > 0.7 && !looksLikeDataField {
                return trimmed
            }
        }

        return nil
    }

    /// Detect the medication name by finding the longest content line not already
    /// claimed by other parsed fields.
    private static func detectMedicationName(
        lines: [String],
        alreadyParsed: ScannedPrescriptionData
    ) -> String? {
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

        var bestCandidate: String?
        var bestLength = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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
                bestCandidate = trimmed
            }
        }

        return bestCandidate
    }
}
