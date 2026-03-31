import Foundation
import SwiftData

/// Parses CPAP session data from CSV files.
/// Auto-detects two formats:
/// - Simple: date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
/// - OSCAR Summary: 42-column export from OSCAR (Open Source CPAP Analysis Reporter)
enum CPAPImporter {

    enum ImportError: Error, LocalizedError {
        case invalidFormat
        case noData
        case fileAccessDenied

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Unrecognized CSV format. Expected a simple CPAP CSV or an OSCAR Summary export."
            case .noData: return "No valid sessions found in file"
            case .fileAccessDenied: return "Could not access the selected file"
            }
        }
    }

    /// Import CPAP sessions from a CSV file. Returns the number of sessions imported.
    static func importCSV(from url: URL, into context: ModelContext) throws -> Int {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { throw ImportError.noData }

        let header = lines[0]
        let dataLines = Array(lines.dropFirst())

        if isOSCARFormat(header) {
            return try importOSCAR(dataLines, into: context)
        } else if isSimpleFormat(header) {
            return try importSimple(dataLines, into: context)
        } else {
            throw ImportError.invalidFormat
        }
    }

    // MARK: - Format Detection

    /// Normalize header for resilient format detection: strip BOM, whitespace, lowercase.
    private static func normalizedHeader(_ header: String) -> String {
        var result = header
        if result.hasPrefix("\u{feff}") { result.removeFirst() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isOSCARFormat(_ header: String) -> Bool {
        normalizedHeader(header).hasPrefix("date,session count,start,end,total time,ahi")
    }

    private static func isSimpleFormat(_ header: String) -> Bool {
        normalizedHeader(header).hasPrefix("date,ahi,usage_minutes")
    }

    // MARK: - Simple Format Parser

    private static func importSimple(_ lines: [String], into context: ModelContext) throws -> Int {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var imported = 0

        for line in lines {
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

    // MARK: - OSCAR Summary Format Parser

    /// OSCAR Summary CSV column indices:
    /// 0: Date, 4: Total Time (HH:MM:SS), 5: AHI
    /// 6: CA Count, 8: OA Count, 9: H Count
    /// 22: Median Pressure, 36: 99.5% Pressure
    private static func importOSCAR(_ lines: [String], into context: ModelContext) throws -> Int {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var imported = 0

        for line in lines {
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 37 else { continue }

            guard let date = dateFormatter.date(from: fields[0]),
                  let ahi = Double(fields[5]),
                  let centralEvents = Int(fields[6]),
                  let obstructiveEvents = Int(fields[8]),
                  let hypopneaEvents = Int(fields[9]),
                  let medianPressure = Double(fields[22]),
                  let pressure995 = Double(fields[36])
            else { continue }

            let usageMinutes = parseHHMMSS(fields[4])
            guard usageMinutes > 0 else { continue }

            let session = CPAPSession(
                date: date,
                ahi: ahi,
                totalUsageMinutes: usageMinutes,
                leakRate95th: nil,
                pressureMin: medianPressure,
                pressureMax: pressure995,
                pressureMean: medianPressure,
                obstructiveEvents: obstructiveEvents,
                centralEvents: centralEvents,
                hypopneaEvents: hypopneaEvents,
                importSource: "oscar"
            )
            context.insert(session)
            imported += 1
        }

        guard imported > 0 else { throw ImportError.noData }
        try context.save()
        return imported
    }

    /// Parse "HH:MM:SS" to total minutes (truncating seconds).
    private static func parseHHMMSS(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
