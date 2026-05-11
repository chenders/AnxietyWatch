import Foundation
import SwiftData

/// Parses CPAP session data from CSV files.
/// Auto-detects two formats:
/// - Simple: date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
/// - OSCAR Summary: 42-column export from OSCAR (Open Source CPAP Analysis Reporter)
///
/// `nonisolated` so `CSVImportRouter` can dispatch into us from a detached
/// task without a main-actor hop.
nonisolated enum CPAPImporter {

    struct ImportResult {
        let inserted: Int
        let updated: Int
        let dateRange: ClosedRange<Date>?
        let skippedRowCount: Int
        let warnings: [String]
        var total: Int { inserted + updated }

        init(
            inserted: Int,
            updated: Int,
            dateRange: ClosedRange<Date>?,
            skippedRowCount: Int = 0,
            warnings: [String] = []
        ) {
            self.inserted = inserted
            self.updated = updated
            self.dateRange = dateRange
            self.skippedRowCount = skippedRowCount
            self.warnings = warnings
        }
    }

    enum ImportError: Error, LocalizedError {
        case invalidFormat
        case noData(skippedRowCount: Int, warnings: [String])
        case persistenceError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Unrecognized CSV format. Expected a simple CPAP CSV or an OSCAR Summary export."
            case .noData(let skipped, _):
                return skipped == 0
                    ? "No valid sessions found in file"
                    : "No valid sessions found in file (\(skipped) row\(skipped == 1 ? "" : "s") skipped)"
            case .persistenceError(let underlying):
                return "Persistence error: \(underlying.localizedDescription)"
            }
        }
    }

    /// Import CPAP sessions from a CSV file. Returns an `ImportResult` with inserted/updated counts and date range.
    static func importCSV(from url: URL, into context: ModelContext) throws -> ImportResult {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let content = try String(contentsOf: url, encoding: .utf8)
        return try importContent(content, into: context)
    }

    /// Internal entry that takes pre-read content. Used by `CSVImportRouter`
    /// so the file is read exactly once when dispatching across formats.
    static func importContent(_ content: String, into context: ModelContext) throws -> ImportResult {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { throw ImportError.noData(skippedRowCount: 0, warnings: []) }

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

    /// True if `header` matches one of the CPAP CSV variants this importer
    /// understands. Exposed so `CSVImportRouter` can dispatch to the right
    /// importer without owning a second copy of the format detection rules.
    static func isCPAPFormat(_ header: String) -> Bool {
        isSimpleFormat(header) || isOSCARFormat(header)
    }

    // MARK: - Upsert Helpers

    /// Bundle of mutable per-session fields the importer writes onto either
    /// a freshly-inserted CPAPSession row or an existing one during replay.
    /// Extracted into a struct so the upsert call sites don't blow past
    /// SwiftLint's function-parameter-count rule (and so the field list
    /// has a single source of truth).
    struct ImportedFields {
        let ahi: Double
        let totalUsageMinutes: Int
        let leakRate95th: Double?
        let pressureMin: Double
        let pressureMax: Double
        let pressureMean: Double
        let obstructiveEvents: Int
        let centralEvents: Int
        let hypopneaEvents: Int
        let importSource: String
    }

    /// Update an existing session's fields with new values.
    private static func updateSession(_ session: CPAPSession, fields: ImportedFields) {
        session.ahi = fields.ahi
        session.totalUsageMinutes = fields.totalUsageMinutes
        session.leakRate95th = fields.leakRate95th
        session.pressureMin = fields.pressureMin
        session.pressureMax = fields.pressureMax
        session.pressureMean = fields.pressureMean
        session.obstructiveEvents = fields.obstructiveEvents
        session.centralEvents = fields.centralEvents
        session.hypopneaEvents = fields.hypopneaEvents
        session.importSource = fields.importSource
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

    private enum ParseOutcome<T> {
        case parsed(T)
        case skip(reason: String)
    }

    private struct ParsedSimpleRow {
        let date: Date
        let ahi: Double
        let usage: Int
        let leak: Double
        let pMin: Double
        let pMax: Double
        let pMean: Double
        let obstructive: Int
        let central: Int
        let hypopnea: Int
    }

    private static func parseSimpleRow(
        _ fields: [String],
        using dateFormatter: DateFormatter
    ) -> ParseOutcome<ParsedSimpleRow> {
        guard fields.count >= 10 else {
            return .skip(reason: "expected 10 columns, found \(fields.count)")
        }
        guard let date = dateFormatter.date(from: fields[0]) else {
            return .skip(reason: "invalid date '\(fields[0])'")
        }
        guard let ahi = Double(fields[1]) else {
            return .skip(reason: "invalid ahi '\(fields[1])'")
        }
        guard let usage = Int(fields[2]) else {
            return .skip(reason: "invalid usage_minutes '\(fields[2])'")
        }
        guard let leak = Double(fields[3]) else {
            return .skip(reason: "invalid leak_95th '\(fields[3])'")
        }
        guard let pMin = Double(fields[4]) else {
            return .skip(reason: "invalid p_min '\(fields[4])'")
        }
        guard let pMax = Double(fields[5]) else {
            return .skip(reason: "invalid p_max '\(fields[5])'")
        }
        guard let pMean = Double(fields[6]) else {
            return .skip(reason: "invalid p_mean '\(fields[6])'")
        }
        guard let obstructive = Int(fields[7]) else {
            return .skip(reason: "invalid obstructive '\(fields[7])'")
        }
        guard let central = Int(fields[8]) else {
            return .skip(reason: "invalid central '\(fields[8])'")
        }
        guard let hypopnea = Int(fields[9]) else {
            return .skip(reason: "invalid hypopnea '\(fields[9])'")
        }
        return .parsed(ParsedSimpleRow(
            date: date, ahi: ahi, usage: usage, leak: leak,
            pMin: pMin, pMax: pMax, pMean: pMean,
            obstructive: obstructive, central: central, hypopnea: hypopnea
        ))
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
        var tracker = ImportSkipTracker()

        for (index, line) in lines.enumerated() {
            // Header is Row 1; first data line is Row 2.
            let rowNumber = index + 2
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            let parsed: ParsedSimpleRow
            switch parseSimpleRow(fields, using: dateFormatter) {
            case .parsed(let row):
                parsed = row
            case .skip(let reason):
                tracker.record(row: rowNumber, reason: reason)
                continue
            }

            let normalized = Calendar.current.startOfDay(for: parsed.date)
            if minDate == nil || normalized < minDate! { minDate = normalized }
            if maxDate == nil || normalized > maxDate! { maxDate = normalized }

            if let existing = existingByDate[normalized] {
                updateSession(existing, fields: ImportedFields(
                    ahi: parsed.ahi,
                    totalUsageMinutes: parsed.usage,
                    leakRate95th: parsed.leak,
                    pressureMin: parsed.pMin,
                    pressureMax: parsed.pMax,
                    pressureMean: parsed.pMean,
                    obstructiveEvents: parsed.obstructive,
                    centralEvents: parsed.central,
                    hypopneaEvents: parsed.hypopnea,
                    importSource: "csv"
                ))
                updated += 1
            } else {
                let session = CPAPSession(
                    date: parsed.date,
                    ahi: parsed.ahi,
                    totalUsageMinutes: parsed.usage,
                    leakRate95th: parsed.leak,
                    pressureMin: parsed.pMin,
                    pressureMax: parsed.pMax,
                    pressureMean: parsed.pMean,
                    obstructiveEvents: parsed.obstructive,
                    centralEvents: parsed.central,
                    hypopneaEvents: parsed.hypopnea,
                    importSource: "csv"
                )
                context.insert(session)
                existingByDate[normalized] = session
                inserted += 1
            }
        }

        guard inserted + updated > 0 else {
            throw ImportError.noData(skippedRowCount: tracker.count, warnings: tracker.warnings)
        }
        do { try context.save() } catch { throw ImportError.persistenceError(error) }

        let dateRange: ClosedRange<Date>? = if let min = minDate, let max = maxDate {
            min...max
        } else {
            nil
        }
        return ImportResult(
            inserted: inserted,
            updated: updated,
            dateRange: dateRange,
            skippedRowCount: tracker.count,
            warnings: tracker.warnings
        )
    }

    // MARK: - OSCAR Summary Format Parser

    private struct ParsedOSCARRow {
        let date: Date
        let ahi: Double
        let centralEvents: Int
        let obstructiveEvents: Int
        let hypopneaEvents: Int
        let medianPressure: Double
        let pressure995: Double
        let usageMinutes: Int
    }

    private static func parseOSCARRow(
        _ fields: [String],
        using dateFormatter: DateFormatter
    ) -> ParseOutcome<ParsedOSCARRow> {
        guard fields.count >= 37 else {
            return .skip(reason: "expected at least 37 columns, found \(fields.count)")
        }
        guard let date = dateFormatter.date(from: fields[0]) else {
            return .skip(reason: "invalid date '\(fields[0])'")
        }
        guard let ahi = Double(fields[5]) else {
            return .skip(reason: "invalid AHI '\(fields[5])'")
        }
        // OSCAR exports per-session-averaged event counts as decimals when
        // Session Count > 1; parse as Double and round so multi-session
        // nights aren't silently skipped.
        guard let centralRaw = Double(fields[6]) else {
            return .skip(reason: "invalid central count '\(fields[6])'")
        }
        guard let obstructiveRaw = Double(fields[8]) else {
            return .skip(reason: "invalid obstructive count '\(fields[8])'")
        }
        guard let hypopneaRaw = Double(fields[9]) else {
            return .skip(reason: "invalid hypopnea count '\(fields[9])'")
        }
        guard let medianPressure = Double(fields[22]) else {
            return .skip(reason: "invalid median pressure '\(fields[22])'")
        }
        guard let pressure995 = Double(fields[36]) else {
            return .skip(reason: "invalid 99.5% pressure '\(fields[36])'")
        }
        let usageMinutes = parseHHMMSS(fields[4])
        guard usageMinutes > 0 else {
            return .skip(reason: "invalid total time '\(fields[4])'")
        }
        return .parsed(ParsedOSCARRow(
            date: date,
            ahi: ahi,
            centralEvents: Int(centralRaw.rounded()),
            obstructiveEvents: Int(obstructiveRaw.rounded()),
            hypopneaEvents: Int(hypopneaRaw.rounded()),
            medianPressure: medianPressure,
            pressure995: pressure995,
            usageMinutes: usageMinutes
        ))
    }

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
        var tracker = ImportSkipTracker()

        for (index, line) in lines.enumerated() {
            // Header is Row 1; first data line is Row 2.
            let rowNumber = index + 2
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            let parsed: ParsedOSCARRow
            switch parseOSCARRow(fields, using: dateFormatter) {
            case .parsed(let row):
                parsed = row
            case .skip(let reason):
                tracker.record(row: rowNumber, reason: reason)
                continue
            }

            let normalized = Calendar.current.startOfDay(for: parsed.date)
            if minDate == nil || normalized < minDate! { minDate = normalized }
            if maxDate == nil || normalized > maxDate! { maxDate = normalized }

            if let existing = existingByDate[normalized] {
                updateSession(existing, fields: ImportedFields(
                    ahi: parsed.ahi,
                    totalUsageMinutes: parsed.usageMinutes,
                    leakRate95th: nil,
                    pressureMin: parsed.medianPressure,
                    pressureMax: parsed.pressure995,
                    pressureMean: parsed.medianPressure,
                    obstructiveEvents: parsed.obstructiveEvents,
                    centralEvents: parsed.centralEvents,
                    hypopneaEvents: parsed.hypopneaEvents,
                    importSource: "oscar"
                ))
                updated += 1
            } else {
                let session = CPAPSession(
                    date: parsed.date,
                    ahi: parsed.ahi,
                    totalUsageMinutes: parsed.usageMinutes,
                    leakRate95th: nil,
                    pressureMin: parsed.medianPressure,
                    pressureMax: parsed.pressure995,
                    pressureMean: parsed.medianPressure,
                    obstructiveEvents: parsed.obstructiveEvents,
                    centralEvents: parsed.centralEvents,
                    hypopneaEvents: parsed.hypopneaEvents,
                    importSource: "oscar"
                )
                context.insert(session)
                existingByDate[normalized] = session
                inserted += 1
            }
        }

        guard inserted + updated > 0 else {
            throw ImportError.noData(skippedRowCount: tracker.count, warnings: tracker.warnings)
        }
        do { try context.save() } catch { throw ImportError.persistenceError(error) }

        let dateRange: ClosedRange<Date>? = if let min = minDate, let max = maxDate {
            min...max
        } else {
            nil
        }
        return ImportResult(
            inserted: inserted,
            updated: updated,
            dateRange: dateRange,
            skippedRowCount: tracker.count,
            warnings: tracker.warnings
        )
    }

    /// Parse "HH:MM:SS" to total minutes (truncating seconds).
    private static func parseHHMMSS(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
