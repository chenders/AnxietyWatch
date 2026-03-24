import Foundation
import SwiftData

/// Parses CPAP session data from CSV files.
/// CSV format: date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
enum CPAPImporter {

    enum ImportError: Error, LocalizedError {
        case invalidFormat
        case noData
        case fileAccessDenied

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Invalid CSV format. Expected: date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea"
            case .noData: return "No valid sessions found in file"
            case .fileAccessDenied: return "Could not access the selected file"
            }
        }
    }

    /// Import CPAP sessions from a CSV file. Returns the number of sessions imported.
    static func importCSV(from url: URL, into context: ModelContext) throws -> Int {
        // Opportunistic: only stop accessing if we successfully started (non-security-scoped
        // URLs like temp files return false but are still readable).
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { throw ImportError.noData }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var imported = 0

        // Skip header row
        for line in lines.dropFirst() {
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 10 else { continue }

            guard let date = dateFormatter.date(from: fields[0]),
                  let ahi = Double(fields[1]),
                  let usage = Int(fields[2]),
                  let leak = Double(fields[3]),
                  let pMin = Double(fields[4]),
                  let pMax = Double(fields[5]),
                  let pMean = Double(fields[6]),
                  let obstructive = Int(fields[7]),
                  let central = Int(fields[8]),
                  let hypopnea = Int(fields[9])
            else { continue }

            let session = CPAPSession(
                date: date,
                ahi: ahi,
                totalUsageMinutes: usage,
                leakRate95th: leak,
                pressureMin: pMin,
                pressureMax: pMax,
                pressureMean: pMean,
                obstructiveEvents: obstructive,
                centralEvents: central,
                hypopneaEvents: hypopnea,
                importSource: "csv"
            )
            context.insert(session)
            imported += 1
        }

        guard imported > 0 else { throw ImportError.noData }
        try context.save()
        return imported
    }
}
