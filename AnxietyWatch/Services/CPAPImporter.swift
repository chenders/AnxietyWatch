import Foundation
import SwiftData

/// Parses CPAP session data from CSV files.
/// Auto-detects two formats:
/// - Simple: date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
/// - OSCAR Summary: 42-column export from OSCAR (Open Source CPAP Analysis Reporter)
enum CPAPImporter {

    struct ImportResult {
        let inserted: Int
        let updated: Int
        let dateRange: ClosedRange<Date>?
        var total: Int { inserted + updated }
    }

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

    /// Import CPAP sessions from a CSV file. Returns an `ImportResult` with inserted/updated counts and date range.
    static func importCSV(from url: URL, into context: ModelContext) throws -> ImportResult {
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

    // MARK: - Upsert Helpers

    /// Update an existing session's fields with new values.
    private static func updateSession(
        _ session: CPAPSession,
        ahi: Double,
        totalUsageMinutes: Int,
        leakRate95th: Double?,
        pressureMin: Double,
        pressureMax: Double,
        pressureMean: Double,
        obstructiveEvents: Int,
        centralEvents: Int,
        hypopneaEvents: Int,
        importSource: String
    ) {
        session.ahi = ahi
        session.totalUsageMinutes = totalUsageMinutes
        session.leakRate95th = leakRate95th
        session.pressureMin = pressureMin
        session.pressureMax = pressureMax
        session.pressureMean = pressureMean
        session.obstructiveEvents = obstructiveEvents
        session.centralEvents = centralEvents
        session.hypopneaEvents = hypopneaEvents
        session.importSource = importSource
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

    /// Prefetch all existing CPAPSessions into a dictionary keyed by normalized date
    /// so import loops can do O(1) lookups instead of one fetch per row.
    /// When duplicates exist for a date, keeps the deterministic winner (highest usage, then lowest AHI)
    /// to match SnapshotAggregator's selection logic.
    private static func prefetchSessions(in context: ModelContext) throws -> [Date: CPAPSession] {
        let all = try context.fetch(FetchDescriptor<CPAPSession>())
        return Dictionary(all.map { ($0.date, $0) }, uniquingKeysWith: { existing, new in
            if new.totalUsageMinutes > existing.totalUsageMinutes { return new }
            if new.totalUsageMinutes == existing.totalUsageMinutes && new.ahi < existing.ahi { return new }
            return existing
        })
    }

    private static func importSimple(_ lines: [String], into context: ModelContext) throws -> ImportResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var existingByDate = try prefetchSessions(in: context)
        var inserted = 0
        var updated = 0
        var minDate: Date?
        var maxDate: Date?

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

            let normalized = Calendar.current.startOfDay(for: date)
            if minDate == nil || normalized < minDate! { minDate = normalized }
            if maxDate == nil || normalized > maxDate! { maxDate = normalized }

            if let existing = existingByDate[normalized] {
                updateSession(existing, ahi: ahi, totalUsageMinutes: usage,
                              leakRate95th: leak, pressureMin: pMin, pressureMax: pMax,
                              pressureMean: pMean, obstructiveEvents: obstructive,
                              centralEvents: central, hypopneaEvents: hypopnea,
                              importSource: "csv")
                updated += 1
            } else {
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
                existingByDate[normalized] = session
                inserted += 1
            }
        }

        guard inserted + updated > 0 else { throw ImportError.noData }
        try context.save()

        let dateRange: ClosedRange<Date>? = if let min = minDate, let max = maxDate {
            min...max
        } else {
            nil
        }
        return ImportResult(inserted: inserted, updated: updated, dateRange: dateRange)
    }

    // MARK: - OSCAR Summary Format Parser

    /// OSCAR Summary CSV column indices:
    /// 0: Date, 4: Total Time (HH:MM:SS), 5: AHI
    /// 6: CA Count, 8: OA Count, 9: H Count
    /// 22: Median Pressure, 36: 99.5% Pressure
    private static func importOSCAR(_ lines: [String], into context: ModelContext) throws -> ImportResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var existingByDate = try prefetchSessions(in: context)
        var inserted = 0
        var updated = 0
        var minDate: Date?
        var maxDate: Date?

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

            let normalized = Calendar.current.startOfDay(for: date)
            if minDate == nil || normalized < minDate! { minDate = normalized }
            if maxDate == nil || normalized > maxDate! { maxDate = normalized }

            if let existing = existingByDate[normalized] {
                updateSession(existing, ahi: ahi, totalUsageMinutes: usageMinutes,
                              leakRate95th: nil, pressureMin: medianPressure,
                              pressureMax: pressure995, pressureMean: medianPressure,
                              obstructiveEvents: obstructiveEvents,
                              centralEvents: centralEvents,
                              hypopneaEvents: hypopneaEvents,
                              importSource: "oscar")
                updated += 1
            } else {
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
                existingByDate[normalized] = session
                inserted += 1
            }
        }

        guard inserted + updated > 0 else { throw ImportError.noData }
        try context.save()

        let dateRange: ClosedRange<Date>? = if let min = minDate, let max = maxDate {
            min...max
        } else {
            nil
        }
        return ImportResult(inserted: inserted, updated: updated, dateRange: dateRange)
    }

    /// Parse "HH:MM:SS" to total minutes (truncating seconds).
    private static func parseHHMMSS(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
