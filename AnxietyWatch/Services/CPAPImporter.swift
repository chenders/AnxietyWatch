import Foundation
import SwiftData

/// Parses CPAP session data from CSV files.
/// Auto-detects three formats:
/// - Simple: date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
/// - OSCAR Summary: 42-column daily export from OSCAR (Open Source CPAP Analysis Reporter)
/// - OSCAR by-session: 22-column per-session export (Date,Start,AHI,RDI,OA,UA,H,CA,RERA,
///   Pressure_Avg/Min/Max/95th,Leak_Avg/Max/95th,SpO2_Avg/Min,Pulse_Avg,Hours,Hours_Used,Machine)
///   — aggregated per sleep-date before insert (see `importOSCARBySession`)
///
/// `nonisolated` so `CSVImportRouter` can dispatch into us from a detached
/// task without a main-actor hop.
nonisolated enum CPAPImporter {

    struct ImportResult {
        let inserted: Int
        let updated: Int
        /// Range of PLAUSIBLE session dates only — clock-reset artifact rows
        /// (before `earliestPlausibleDate`) still import but are excluded
        /// here, because callers walk this range with one `aggregateDay` per
        /// day and a ~2009 epoch-reset row would stretch it across decades
        /// (F-028). Nil when no plausible-dated rows imported.
        let dateRange: ClosedRange<Date>?
        let skippedRowCount: Int
        let warnings: [String]
        /// Sessions whose date predates `earliestPlausibleDate`, suggesting the CPAP machine's
        /// internal clock had reset to its epoch (~Jan 2009 on AirSense firmware).
        let suspiciousDateCount: Int
        var total: Int { inserted + updated }

        init(
            inserted: Int,
            updated: Int,
            dateRange: ClosedRange<Date>?,
            skippedRowCount: Int = 0,
            warnings: [String] = [],
            suspiciousDateCount: Int = 0
        ) {
            self.inserted = inserted
            self.updated = updated
            self.dateRange = dateRange
            self.skippedRowCount = skippedRowCount
            self.warnings = warnings
            self.suspiciousDateCount = suspiciousDateCount
        }
    }

    /// Sessions dated before this are flagged (not blocked) as a likely CPAP-clock-reset
    /// symptom. AirSense machines fall back to a ~Jan 2009 epoch when their internal clock
    /// loses state; 2015 leaves generous margin around that cluster. Imports of genuinely
    /// old OSCAR archives still succeed — they just carry a warning the user can ignore.
    /// Fixed Gregorian calendar: the boundary is a device-firmware artifact, not a
    /// user-locale concept, so it must not shift under non-Gregorian system calendars.
    static let earliestPlausibleDate: Date = {
        var components = DateComponents()
        components.year = 2015
        components.month = 1
        components.day = 1
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }()

    /// User-facing warning for `ImportResult.suspiciousDateCount`, nil when the
    /// count is zero. Lives here (not in the view) so both the in-app import
    /// alert and the share-sheet batch alert render identical wording.
    static func clockResetWarning(count: Int) -> String? {
        guard count > 0 else { return nil }
        let sessions = count == 1 ? "1 session has" : "\(count) sessions have"
        return "Note: \(sessions) an implausibly old date, which may mean the CPAP machine's "
            + "internal clock has reset. Check the date/time setting on the device."
    }

    enum ImportError: Error, LocalizedError {
        case invalidFormat
        case noData(skippedRowCount: Int, warnings: [String])
        case persistenceError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Unrecognized CSV format. Expected a simple CPAP CSV, an OSCAR Summary export, "
                    + "or an OSCAR by-session export."
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
        } else if isOSCARBySessionFormat(header) {
            return try importOSCARBySession(dataLines, into: context)
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
        isSimpleFormat(header) || isOSCARFormat(header) || isOSCARBySessionFormat(header)
    }

    // MARK: - Upsert Helpers

    /// Bundle of mutable per-session fields the importer writes onto either
    /// a freshly-inserted CPAPSession row or an existing one during replay.
    /// Extracted into a struct so the upsert call sites don't blow past
    /// SwiftLint's function-parameter-count rule (and so the field list
    /// has a single source of truth).
    struct ImportedFields {
        /// Nil only from the by-session path, when no session in the day
        /// reported any scored event count — "couldn't compute", not 0.
        /// Simple/OSCAR daily rows always carry a parsed AHI.
        let ahi: Double?
        let totalUsageMinutes: Int
        let leakRate95th: Double?
        let pressureMin: Double
        let pressureMax: Double
        let pressureMean: Double
        let obstructiveEvents: Int
        let centralEvents: Int
        let hypopneaEvents: Int
        /// Present only for the by-session format, which is the only source
        /// that reports these eight fields. Nil (daily formats) means "this
        /// import knows nothing about them" — `updateSession` leaves any
        /// previously-imported values untouched rather than nil-ing them out.
        let bySession: BySessionFields?

        init(
            ahi: Double?,
            totalUsageMinutes: Int,
            leakRate95th: Double?,
            pressureMin: Double,
            pressureMax: Double,
            pressureMean: Double,
            obstructiveEvents: Int,
            centralEvents: Int,
            hypopneaEvents: Int,
            bySession: BySessionFields? = nil
        ) {
            self.ahi = ahi
            self.totalUsageMinutes = totalUsageMinutes
            self.leakRate95th = leakRate95th
            self.pressureMin = pressureMin
            self.pressureMax = pressureMax
            self.pressureMean = pressureMean
            self.obstructiveEvents = obstructiveEvents
            self.centralEvents = centralEvents
            self.hypopneaEvents = hypopneaEvents
            self.bySession = bySession
        }
    }

    /// The eight fields only the by-session export reports. Inner nils are
    /// meaningful ("source reported no value" — e.g. no machine-attached
    /// oximeter) and ARE written through on update: the by-session file is
    /// authoritative for every field it defines.
    struct BySessionFields {
        let rdiEvents: Double?
        let reraEvents: Int?
        let spo2Avg: Double?
        let spo2Min: Double?
        let pulseAvg: Double?
        let pressure95th: Double?
        let leakAvg: Double?
        let leakMax: Double?
    }

    /// Update an existing session's fields with new values.
    ///
    /// `importSource` is deliberately NOT overwritten: it records how the
    /// session FIRST entered the store. A CSV/OSCAR re-import that happens
    /// to cover the same calendar date must not relabel a manually-entered
    /// ("manual") or server-restored ("resmed_cloud", "edf") session's
    /// provenance — the views display it as "Source" and a fabricated label
    /// misrepresents where the numbers came from (F-040).
    private static func updateSession(_ session: CPAPSession, fields: ImportedFields) {
        // Don't downgrade a real, previously-stored AHI to "unknown" when a
        // re-import recomputes nil for the date. Only the by-session path can
        // produce a nil AHI (an unscored day); daily formats always carry a
        // measured AHI, so this guard is a no-op for them. Same principle as
        // the pressure guard below and the server's COALESCE-on-ahi: a
        // blank-derived nil must not clobber real clinical data on update.
        if let newAHI = fields.ahi {
            session.ahi = newAHI
        }
        session.totalUsageMinutes = fields.totalUsageMinutes
        session.leakRate95th = fields.leakRate95th
        if let bySession = fields.bySession {
            // By-session import: a date whose pressure columns were wholly
            // blank yields `pressureUnavailableSentinel` for all three
            // non-optional pressure fields. Don't let that fabricated 0
            // overwrite a real historical pressure captured by an earlier
            // import — keep the stored value when the new one is the sentinel.
            session.pressureMin = preservingRealPressure(new: fields.pressureMin, existing: session.pressureMin)
            session.pressureMax = preservingRealPressure(new: fields.pressureMax, existing: session.pressureMax)
            session.pressureMean = preservingRealPressure(new: fields.pressureMean, existing: session.pressureMean)
            // Event counts, same clobber class as the AHI guard above: an
            // UNSCORED incoming day (fields.ahi == nil — no session reported
            // any OA/UA/H/CA) aggregates to 0/0/0 events and nil RERA. Writing
            // those would leave the row with a preserved real AHI but zeroed
            // events — internally contradictory (a nonzero AHI implies events
            // occurred). Mirror the AHI guard exactly: preserve the stored
            // counts unless the incoming day was actually scored. A genuinely
            // scored re-import (real, possibly-zero events) updates normally.
            if fields.ahi != nil {
                session.obstructiveEvents = fields.obstructiveEvents
                session.centralEvents = fields.centralEvents
                session.hypopneaEvents = fields.hypopneaEvents
                session.reraEvents = bySession.reraEvents
            }
            // The remaining optional fields are independent of scoring and
            // follow the "by-session file is authoritative" contract — inner
            // nils write through so a stale value can't linger. (RDI is a
            // reported column, not a scored-event derivation, so it is not
            // gated by the unscored guard.)
            session.rdiEvents = bySession.rdiEvents
            session.spo2Avg = bySession.spo2Avg
            session.spo2Min = bySession.spo2Min
            session.pulseAvg = bySession.pulseAvg
            session.pressure95th = bySession.pressure95th
            session.leakAvg = bySession.leakAvg
            session.leakMax = bySession.leakMax
        } else {
            // Daily formats: keep the established overwrite contract, incl.
            // writing the sentinel into OSCAR-daily's structurally-absent
            // pressureMin (see `oscarPressureMinUnavailable`).
            session.pressureMin = fields.pressureMin
            session.pressureMax = fields.pressureMax
            session.pressureMean = fields.pressureMean
            session.obstructiveEvents = fields.obstructiveEvents
            session.centralEvents = fields.centralEvents
            session.hypopneaEvents = fields.hypopneaEvents
        }
    }

    /// Returns `new` unless it is the "pressure unavailable" sentinel, in
    /// which case the existing stored value is kept — so a by-session
    /// re-import with blank pressure columns never overwrites a real
    /// historical reading with a fabricated 0.
    private static func preservingRealPressure(new: Double, existing: Double) -> Double {
        new == pressureUnavailableSentinel ? existing : new
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

    /// OSCAR "by session" export: one row per mask-on/mask-off session, 22 columns.
    /// Internal (not private) so tests can pin the detection contract directly.
    static func isOSCARBySessionFormat(_ header: String) -> Bool {
        normalizedHeader(header).hasPrefix("date,start,ahi,rdi,oa")
    }

    // MARK: - Simple Format Parser

    /// Prefetch all existing CPAPSessions into a dictionary keyed by normalized date
    /// so import loops can do O(1) lookups instead of one fetch per row.
    /// When duplicates exist for a date, keeps the deterministic winner (highest usage, then lowest AHI)
    /// to match SnapshotAggregator's selection logic.
    private static func prefetchSessions(in context: ModelContext) throws -> [Date: CPAPSession] {
        sessionsByDate(try context.fetch(FetchDescriptor<CPAPSession>()))
    }

    /// Index an already-fetched session list by normalized date (split out of
    /// `prefetchSessions` so the by-session importer, which also needs the flat
    /// list for the cross-date dedupe, fetches exactly once).
    private static func sessionsByDate(_ all: [CPAPSession]) -> [Date: CPAPSession] {
        return Dictionary(all.map { ($0.date, $0) }, uniquingKeysWith: { existing, new in
            if new.totalUsageMinutes > existing.totalUsageMinutes { return new }
            // Tie on usage → keep the lower AHI. An unknown AHI (nil, F-094)
            // ranks as +∞ so a scored night is preferred over an unscored one;
            // comparison-only, never stored. (Local imports always carry a real
            // AHI, so nil only appears for server-restored EDF-only nights.)
            if new.totalUsageMinutes == existing.totalUsageMinutes
                && (new.ahi ?? .infinity) < (existing.ahi ?? .infinity) { return new }
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
        var suspiciousDates = 0
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
            if normalized < Self.earliestPlausibleDate {
                // Clock-reset artifact (see `earliestPlausibleDate`): count it
                // for the warning but keep it OUT of the returned dateRange.
                // The range drives the callers' per-day aggregateDay backfill
                // loop, and a single ~2009 epoch-reset row would otherwise
                // stretch it across two decades — thousands of sequential
                // aggregateDay calls and near-empty snapshots for one bad
                // row (F-028). The session row itself still imports.
                suspiciousDates += 1
            } else {
                if minDate == nil || normalized < minDate! { minDate = normalized }
                if maxDate == nil || normalized > maxDate! { maxDate = normalized }
            }

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
                    hypopneaEvents: parsed.hypopnea
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
            warnings: tracker.warnings,
            suspiciousDateCount: suspiciousDates
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

    /// OSCAR Summary exports carry no minimum-pressure column — only median and
    /// high-percentile pressures — so there is no honest value to store in the
    /// non-optional `CPAPSession.pressureMin`. We store this sentinel rather than
    /// mislabeling the median as a minimum (the UI's "Min" row was previously
    /// showing the median). Matches the `?? 0` fallback `RestoreFromServer` uses
    /// when a server row lacks `pressure_min`. Internal (not private) so tests
    /// can assert against it.
    static let oscarPressureMinUnavailable: Double = 0

    /// Sentinel for any non-optional pressure field (`pressureMin`,
    /// `pressureMax`, `pressureMean`) when the by-session export left the
    /// whole column empty for a day. Same value and rationale as
    /// `oscarPressureMinUnavailable` — named separately so the by-session
    /// call site reads as a deliberate "pressure unavailable" marker rather
    /// than a magic 0, and so a future migration to optional pressure fields
    /// has a single grep target. Consumers should treat a stored 0 cmH2O as
    /// "unavailable" (a real CPAP never runs at 0). Internal so tests can
    /// assert against it.
    static let pressureUnavailableSentinel: Double = 0

    /// OSCAR Summary CSV column indices:
    /// 0: Date, 4: Total Time (HH:MM:SS), 5: AHI
    /// 6: CA Count, 8: OA Count, 9: H Count
    /// 22: Median Pressure, 36: 99.5% Pressure
    ///
    /// Field mapping caveats: OSCAR has no minimum-pressure column, so
    /// `pressureMin` gets `oscarPressureMinUnavailable`; `pressureMean` carries
    /// the *median* pressure (the closest central-tendency value OSCAR exports,
    /// not a true arithmetic mean); `pressureMax` carries the 99.5th percentile.
    private static func importOSCAR(_ lines: [String], into context: ModelContext) throws -> ImportResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var existingByDate = try prefetchSessions(in: context)
        var inserted = 0
        var updated = 0
        var suspiciousDates = 0
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
            if normalized < Self.earliestPlausibleDate {
                // Clock-reset artifact (see `earliestPlausibleDate`): count it
                // for the warning but keep it OUT of the returned dateRange.
                // The range drives the callers' per-day aggregateDay backfill
                // loop, and a single ~2009 epoch-reset row would otherwise
                // stretch it across two decades — thousands of sequential
                // aggregateDay calls and near-empty snapshots for one bad
                // row (F-028). The session row itself still imports.
                suspiciousDates += 1
            } else {
                if minDate == nil || normalized < minDate! { minDate = normalized }
                if maxDate == nil || normalized > maxDate! { maxDate = normalized }
            }

            if let existing = existingByDate[normalized] {
                updateSession(existing, fields: ImportedFields(
                    ahi: parsed.ahi,
                    totalUsageMinutes: parsed.usageMinutes,
                    leakRate95th: nil,
                    // No minimum-pressure column in OSCAR exports; see
                    // `oscarPressureMinUnavailable`. pressureMean carries the
                    // median (closest central value OSCAR supplies).
                    pressureMin: oscarPressureMinUnavailable,
                    pressureMax: parsed.pressure995,
                    pressureMean: parsed.medianPressure,
                    obstructiveEvents: parsed.obstructiveEvents,
                    centralEvents: parsed.centralEvents,
                    hypopneaEvents: parsed.hypopneaEvents
                ))
                updated += 1
            } else {
                let session = CPAPSession(
                    date: parsed.date,
                    ahi: parsed.ahi,
                    totalUsageMinutes: parsed.usageMinutes,
                    leakRate95th: nil,
                    // No minimum-pressure column in OSCAR exports; see
                    // `oscarPressureMinUnavailable`. pressureMean carries the
                    // median (closest central value OSCAR supplies).
                    pressureMin: oscarPressureMinUnavailable,
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
            warnings: tracker.warnings,
            suspiciousDateCount: suspiciousDates
        )
    }

    // MARK: - OSCAR By-Session Format Parser

    /// One parsed row of the 22-column by-session export. Column indices:
    /// 0 Date (sleep-date; OSCAR already applies its noon-to-noon convention),
    /// 1 Start, 2 AHI (events/h), 3 RDI (events/h), 4 OA, 5 UA, 6 H, 7 CA,
    /// 8 RERA (counts), 9 Pressure_Avg, 10 Pressure_Min, 11 Pressure_Max,
    /// 12 Pressure_95th (cmH2O), 13 Leak_Avg, 14 Leak_Max, 15 Leak_95th (L/min),
    /// 16 SpO2_Avg, 17 SpO2_Min (%), 18 Pulse_Avg (bpm), 19 Hours (span),
    /// 20 Hours_Used (therapy time), 21 Machine.
    ///
    /// Every field except `date` and `hoursUsed` is optional: an empty cell
    /// means "the machine didn't report this" (e.g. no attached oximeter) and
    /// must stay nil — never 0 (F-068/F-094 null-honesty contract).
    private struct ParsedBySessionRow {
        let date: Date
        let ahi: Double?
        let rdi: Double?
        let oa: Int?
        let ua: Int?
        let h: Int?
        let ca: Int?
        let rera: Int?
        let pressureAvg: Double?
        let pressureMin: Double?
        let pressureMax: Double?
        let pressure95th: Double?
        let leakAvg: Double?
        let leakMax: Double?
        let leak95th: Double?
        let spo2Avg: Double?
        let spo2Min: Double?
        let pulseAvg: Double?
        /// Therapy hours for this session — the weighting basis for every
        /// per-day aggregate and the clock-integrity quarantine input.
        let hoursUsed: Double
    }

    private static func parseBySessionRow(
        _ fields: [String],
        using dateFormatter: DateFormatter
    ) -> ParseOutcome<ParsedBySessionRow> {
        // Machine (col 21) is informational; everything through Hours_Used
        // (col 20) must be present for the row to be usable.
        guard fields.count >= 21 else {
            return .skip(reason: "expected at least 21 columns, found \(fields.count)")
        }
        guard let date = dateFormatter.date(from: fields[0]) else {
            return .skip(reason: "invalid date '\(fields[0])'")
        }
        // `.isFinite` rejects "inf"/"nan"/"infinity", which `Double(_:)` parses
        // happily — a non-finite hoursUsed would trap in the later
        // `Int((totalHours * 60).rounded())`. Treat it as a corrupt row.
        guard let hoursUsed = Double(fields[20]), hoursUsed.isFinite, hoursUsed >= 0 else {
            return .skip(reason: "invalid Hours_Used '\(fields[20])'")
        }

        // Empty cell = "not reported" → nil. A non-empty cell that fails to
        // parse is corruption: skip the row rather than silently coercing a
        // garbled value to "not reported".
        var badCell: (name: String, value: String)?
        func dbl(_ index: Int, _ name: String) -> Double? {
            let cell = fields[index]
            if cell.isEmpty { return nil }
            // `Double(_:)` accepts "inf"/"nan"/"infinity". A non-finite value
            // must NOT leak through: `int()` would trap in `Int(_.rounded())`
            // (Int(Double.infinity) is a non-catchable Swift runtime trap that
            // crashes the whole app), and a non-finite Double in ahi / rdi /
            // pressure / spo2 would poison every downstream aggregate. Treat a
            // non-finite parse as a corrupt cell, exactly like unparseable text.
            if let value = Double(cell), value.isFinite { return value }
            if badCell == nil { badCell = (name, cell) }
            return nil
        }
        // Event counts can export as "3.0"; parse as Double and round.
        func int(_ index: Int, _ name: String) -> Int? {
            dbl(index, name).map { Int($0.rounded()) }
        }

        let row = ParsedBySessionRow(
            date: date,
            ahi: dbl(2, "AHI"), rdi: dbl(3, "RDI"),
            oa: int(4, "OA"), ua: int(5, "UA"), h: int(6, "H"), ca: int(7, "CA"),
            rera: int(8, "RERA"),
            pressureAvg: dbl(9, "Pressure_Avg"), pressureMin: dbl(10, "Pressure_Min"),
            pressureMax: dbl(11, "Pressure_Max"), pressure95th: dbl(12, "Pressure_95th"),
            leakAvg: dbl(13, "Leak_Avg"), leakMax: dbl(14, "Leak_Max"), leak95th: dbl(15, "Leak_95th"),
            spo2Avg: dbl(16, "SpO2_Avg"), spo2Min: dbl(17, "SpO2_Min"),
            pulseAvg: dbl(18, "Pulse_Avg"),
            hoursUsed: hoursUsed
        )
        if let bad = badCell {
            return .skip(reason: "invalid \(bad.name) '\(bad.value)'")
        }
        return .parsed(row)
    }

    /// Usage-weighted mean of `value` over only the sessions that report it —
    /// nil when none do. If every reporting session has zero recorded usage
    /// (0.0-hour mask-bump sessions), falls back to the unweighted mean
    /// rather than dividing by zero.
    private static func usageWeightedMean(
        _ rows: [ParsedBySessionRow],
        _ value: (ParsedBySessionRow) -> Double?
    ) -> Double? {
        let pairs = rows.compactMap { row in value(row).map { ($0, row.hoursUsed) } }
        guard !pairs.isEmpty else { return nil }
        let totalWeight = pairs.reduce(0.0) { $0 + $1.1 }
        guard totalWeight > 0 else {
            return pairs.reduce(0.0) { $0 + $1.0 } / Double(pairs.count)
        }
        return pairs.reduce(0.0) { $0 + $1.0 * $1.1 } / totalWeight
    }

    /// Aggregate one sleep-date's session rows into daily fields. Null-honest:
    /// every optional aggregate is nil when NO session reported the value;
    /// when only some sessions report it, means are weighted over just those
    /// sessions (each by its own Hours_Used).
    private static func aggregateBySessionDay(_ rows: [ParsedBySessionRow]) -> ImportedFields {
        let totalHours = rows.reduce(0.0) { $0 + $1.hoursUsed }

        // Daily AHI = total scored events / total SCORED therapy hours — NOT
        // the mean of per-session AHIs (which would over-weight short
        // sessions), and NOT events / total-hours (which would let an
        // unscored session's hours dilute the denominator while contributing
        // zero events, silently understating AHI). Only sessions that
        // reported at least one of OA/UA/H/CA count toward BOTH the event sum
        // and the hour denominator; a session with usage but no scored events
        // (nil across all four) is excluded from the ratio entirely — its
        // "unknown" state must not be laundered into a fake zero-event
        // contribution. On a single scored session this reduces to
        // (OA+UA+H+CA)/Hours_Used, exactly how OSCAR computes the per-session
        // AHI column (pinned by a unit test). Nil when NO session was scored:
        // an unscored day, not a perfect zero.
        let scoredRows = rows.filter { $0.oa != nil || $0.ua != nil || $0.h != nil || $0.ca != nil }
        let scoredHours = scoredRows.reduce(0.0) { $0 + $1.hoursUsed }
        let scoredEventTotal = scoredRows.reduce(0) {
            $0 + ($1.oa ?? 0) + ($1.ua ?? 0) + ($1.h ?? 0) + ($1.ca ?? 0)
        }
        let ahi: Double? = (scoredRows.isEmpty || scoredHours <= 0)
            ? nil
            : Double(scoredEventTotal) / scoredHours

        // UA (unclassified apnea) folds into obstructiveEvents — the model has
        // no separate UA column and OSCAR's convention treats unclassified
        // apneas as obstructive for index purposes. The event counters are
        // non-optional Ints, so unreported cells contribute 0 to the sums;
        // the day's "unscored" state is carried by ahi == nil above.
        let obstructive = rows.reduce(0) { $0 + ($1.oa ?? 0) + ($1.ua ?? 0) }
        let central = rows.reduce(0) { $0 + ($1.ca ?? 0) }
        let hypopnea = rows.reduce(0) { $0 + ($1.h ?? 0) }

        // RERA is a count: sum, nil when no session reported it.
        let reraCells = rows.compactMap(\.rera)
        let rera: Int? = reraCells.isEmpty ? nil : reraCells.reduce(0, +)

        // Combining percentiles across sessions exactly would need the raw
        // signal; the usage-weighted mean of per-session 95th percentiles is
        // the standard approximation (applies to Pressure_95th and Leak_95th).
        // NOTE this is a session-weighted average of percentiles, NOT a true
        // percentile of pooled data — any UI/report label must say so.
        //
        // Field-semantics caveat (pre-existing, now three-way): `pressureMean`
        // carries a *usage-weighted true arithmetic mean* here, whereas the
        // OSCAR-daily path stores the *median* and the simple format stores a
        // plain arithmetic mean in the same model field. Re-importing one date
        // via different formats silently changes what the stored number means;
        // `updateSession` overwrites unconditionally. Acceptable for now (the
        // by-session file is this user's authoritative source) but flagged for
        // a future "pressure statistic provenance" tracking issue.
        //
        // pressureMin/Max/Mean are non-optional on the model, so a day whose
        // export left every pressure column empty has no honest value to
        // store. All three fall back to `pressureUnavailableSentinel` (0) —
        // the same sentinel the OSCAR-daily path uses for pressureMin and the
        // `?? 0` the server-restore path uses. A fabricated 0 cmH2O is
        // physically nonsensical, so downstream consumers should treat a
        // pressure of exactly 0 as "unavailable", not a real reading. This is
        // a near-impossible case (pressure is core CPAP data, ~never blank),
        // but the sentinel keeps the contract explicit rather than silently
        // materializing a 0.
        return ImportedFields(
            ahi: ahi,
            totalUsageMinutes: Int((totalHours * 60).rounded()),
            leakRate95th: usageWeightedMean(rows, \.leak95th),
            pressureMin: rows.compactMap(\.pressureMin).min() ?? pressureUnavailableSentinel,
            pressureMax: rows.compactMap(\.pressureMax).max() ?? pressureUnavailableSentinel,
            pressureMean: usageWeightedMean(rows, \.pressureAvg) ?? pressureUnavailableSentinel,
            obstructiveEvents: obstructive,
            centralEvents: central,
            hypopneaEvents: hypopnea,
            bySession: BySessionFields(
                rdiEvents: usageWeightedMean(rows, \.rdi),
                reraEvents: rera,
                spo2Avg: usageWeightedMean(rows, \.spo2Avg),
                spo2Min: rows.compactMap(\.spo2Min).min(),
                pulseAvg: usageWeightedMean(rows, \.pulseAvg),
                pressure95th: usageWeightedMean(rows, \.pressure95th),
                leakAvg: usageWeightedMean(rows, \.leakAvg),
                leakMax: rows.compactMap(\.leakMax).max()
            )
        )
    }

    /// A sleep-date whose summed Hours_Used exceeds this is physically
    /// impossible — the AirSense clock reset and compressed several real days
    /// onto one date. Many sessions and high totals (up to exactly 24 h,
    /// e.g. continuous use) are legitimate; only MORE than 24 h quarantines.
    static let bySessionMaxPlausibleDailyHours = 24.0
    /// Absorbs binary-float summing error so a sum that is mathematically
    /// exactly 24.0 (e.g. 8.1 + 8.1 + 7.8) never quarantines spuriously.
    private static let hoursSumEpsilon = 0.0001

    /// AHI tolerance (events/h) for the cross-date duplicate check.
    static let bySessionDedupeAHITolerance = 0.05
    /// Usage tolerance (minutes) for the cross-date duplicate check.
    static let bySessionDedupeUsageToleranceMinutes = 2
    /// Mean-pressure tolerance (cmH2O) for the cross-date duplicate check.
    /// A truly re-imported night yields byte-identical aggregates, so this
    /// tolerance only has to absorb float-summing noise; it stays tight so it
    /// still discriminates two genuinely different nights whose coarse tuple
    /// (AHI/usage/events) happens to collide.
    static let bySessionDedupePressureTolerance = 0.1

    /// True when an existing session's values match an incoming day closely
    /// enough to be the SAME physical night re-imported under a different
    /// sleep-date (the clock-reset duplication mode). Deliberately biased
    /// toward NOT matching, because a false positive silently drops a real
    /// night's clinical record with no recovery path:
    ///
    /// - AHI must be present on BOTH sides and match within
    ///   `bySessionDedupeAHITolerance`. Two unscored days (nil AHI) are NEVER
    ///   treated as duplicates — an unscored day re-importing is harmless,
    ///   but collapsing two distinct unscored nights into one is data loss.
    /// - Usage within `bySessionDedupeUsageToleranceMinutes`, event counts
    ///   (obstructive incl. UA, central, hypopnea) exactly equal.
    /// - Mean pressure, when BOTH sides carry a real (non-sentinel) value,
    ///   must match within `bySessionDedupePressureTolerance`. This is the
    ///   discriminator that separates two different well-controlled nights
    ///   (AHI≈0, 0/0/0 events, similar usage) — their coarse tuple collides
    ///   but their pressure curves don't. A truly duplicated night has an
    ///   identical pressure aggregate, so this never rejects a real
    ///   duplicate. When either side lacks pressure (sentinel 0 / different
    ///   provenance), this clause is skipped rather than forcing a match.
    private static func isValueDuplicate(_ existing: CPAPSession, of day: ImportedFields) -> Bool {
        guard let existingAHI = existing.ahi, let dayAHI = day.ahi,
              abs(existingAHI - dayAHI) <= bySessionDedupeAHITolerance else {
            return false
        }
        guard abs(existing.totalUsageMinutes - day.totalUsageMinutes) <= bySessionDedupeUsageToleranceMinutes,
              existing.obstructiveEvents == day.obstructiveEvents,
              existing.centralEvents == day.centralEvents,
              existing.hypopneaEvents == day.hypopneaEvents else {
            return false
        }
        // Both carry a real mean pressure → require it to match too. A
        // sentinel (0) on either side means "pressure unavailable", so we
        // can't use it to disambiguate and fall back to the tuple match.
        if existing.pressureMean != pressureUnavailableSentinel
            && day.pressureMean != pressureUnavailableSentinel
            && abs(existing.pressureMean - day.pressureMean) > bySessionDedupePressureTolerance {
            return false
        }
        return true
    }

    /// Import the OSCAR by-session export: parse per-session rows, group them
    /// by sleep-date (the Date column already carries OSCAR's noon-to-noon
    /// assignment), quarantine physically impossible dates, aggregate the
    /// rest into one CPAPSession per day, and upsert with the same by-date
    /// semantics as `importOSCAR` plus a cross-date value-match dedupe.
    private static func importOSCARBySession(_ lines: [String], into context: ModelContext) throws -> ImportResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var tracker = ImportSkipTracker()
        var rowsByDay: [Date: [ParsedBySessionRow]] = [:]

        for (index, line) in lines.enumerated() {
            // Header is Row 1; first data line is Row 2.
            let rowNumber = index + 2
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch parseBySessionRow(fields, using: dateFormatter) {
            case .parsed(let row):
                let day = Calendar.current.startOfDay(for: row.date)
                rowsByDay[day, default: []].append(row)
            case .skip(let reason):
                tracker.record(row: rowNumber, reason: reason)
            }
        }

        // Clock-integrity quarantine: a date whose summed Hours_Used exceeds
        // 24 h had several real days compressed onto it by a clock reset. The
        // per-session split across those real days is unrecoverable, so the
        // WHOLE date is excluded — a partial import would attribute another
        // day's events to this date's denominator and fabricate a wrong AHI.
        var quarantinedDays: [Date] = []
        var importableDays: [(day: Date, fields: ImportedFields)] = []
        for (day, rows) in rowsByDay.sorted(by: { $0.key < $1.key }) {
            let totalHours = rows.reduce(0.0) { $0 + $1.hoursUsed }
            if totalHours > bySessionMaxPlausibleDailyHours + hoursSumEpsilon {
                quarantinedDays.append(day)
            } else {
                importableDays.append((day, aggregateBySessionDay(rows)))
            }
        }

        // One fetch seeds the by-date upsert index. The cross-date dedupe
        // scans `existingByDate.values` (NOT a frozen snapshot) so that a day
        // inserted earlier in THIS loop is visible to later days — two dates
        // within the same file that aggregate to the same physical night (the
        // clock-reset duplication this feature exists to catch) must not both
        // insert and double-count the night.
        var existingByDate = try sessionsByDate(context.fetch(FetchDescriptor<CPAPSession>()))

        var inserted = 0
        var updated = 0
        var suspiciousDates = 0
        var dedupeSkippedDays: [Date] = []
        var minDate: Date?
        var maxDate: Date?

        for (day, fields) in importableDays {
            if let existing = existingByDate[day] {
                // Same-date row: keep importOSCAR's upsert semantics (update
                // in place; a value-identical re-import is a no-op update).
                updateSession(existing, fields: fields)
                updated += 1
            } else if existingByDate.values.contains(where: { $0.date != day && isValueDuplicate($0, of: fields) }) {
                // Same values already stored under a DIFFERENT date — either a
                // prior import or a different date earlier in THIS file: the
                // same physical night appears twice (clock-reset duplication).
                // Skip rather than double-count the night.
                dedupeSkippedDays.append(day)
                continue
            } else {
                let session = CPAPSession(
                    date: day,
                    ahi: fields.ahi,
                    totalUsageMinutes: fields.totalUsageMinutes,
                    leakRate95th: fields.leakRate95th,
                    pressureMin: fields.pressureMin,
                    pressureMax: fields.pressureMax,
                    pressureMean: fields.pressureMean,
                    obstructiveEvents: fields.obstructiveEvents,
                    centralEvents: fields.centralEvents,
                    hypopneaEvents: fields.hypopneaEvents,
                    importSource: "oscar",
                    rdiEvents: fields.bySession?.rdiEvents,
                    reraEvents: fields.bySession?.reraEvents,
                    spo2Avg: fields.bySession?.spo2Avg,
                    spo2Min: fields.bySession?.spo2Min,
                    pulseAvg: fields.bySession?.pulseAvg,
                    pressure95th: fields.bySession?.pressure95th,
                    leakAvg: fields.bySession?.leakAvg,
                    leakMax: fields.bySession?.leakMax
                )
                context.insert(session)
                existingByDate[day] = session
                inserted += 1
            }

            if day < Self.earliestPlausibleDate {
                // Same clock-reset flagging as the other importers: the day
                // imports but stays out of dateRange (F-028).
                suspiciousDates += 1
            } else {
                if minDate == nil || day < minDate! { minDate = day }
                if maxDate == nil || day > maxDate! { maxDate = day }
            }
        }

        var warnings = tracker.warnings
        if !quarantinedDays.isEmpty {
            let list = quarantinedDays.map { dateFormatter.string(from: $0) }.joined(separator: ", ")
            let dates = quarantinedDays.count == 1 ? "date" : "dates"
            warnings.append("quarantined \(quarantinedDays.count) impossible \(dates) (clock reset?): \(list)")
        }
        if !dedupeSkippedDays.isEmpty {
            let list = dedupeSkippedDays.map { dateFormatter.string(from: $0) }.joined(separator: ", ")
            let dates = dedupeSkippedDays.count == 1 ? "date" : "dates"
            warnings.append(
                "skipped \(dedupeSkippedDays.count) \(dates) already imported under a different date: \(list)"
            )
        }

        // Unlike the other formats, "nothing imported" here can mean "every
        // day was deliberately quarantined or dedupe-skipped" — that's a
        // successful import of zero days whose warnings explain why, not a
        // garbage file, so only throw noData when no day was even parseable.
        guard inserted + updated > 0 || !quarantinedDays.isEmpty || !dedupeSkippedDays.isEmpty else {
            throw ImportError.noData(skippedRowCount: tracker.count, warnings: warnings)
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
            warnings: warnings,
            suspiciousDateCount: suspiciousDates
        )
    }

    /// Parse "HH:MM:SS" to total minutes (truncating seconds).
    private static func parseHHMMSS(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
