import Foundation
import SwiftData

/// Parses EMAY pulse oximeter CSV exports (1 Hz SpO2 + pulse rate samples).
/// Produces two `QuantityHealthSample` rows per CSV row (one for SpO2, one
/// for heart rate) tagged with a stable `sourceBundleID` so re-imports of
/// the same file are idempotent via `(timestamp, metricType)` dedup.
///
/// Expected format:
///   Date,Time,SpO2(%),PR(bpm)
///   5/8/2026,4:46:58 PM,98,52
///
/// `nonisolated` so `CSVImportRouter` can dispatch into us from a detached
/// task (large EMAY CSVs would stutter the UI on the main actor).
nonisolated enum EMAYImporter {

    struct ImportResult {
        let inserted: Int
        /// Rows we couldn't make sense of — malformed dates, non-numeric values,
        /// wrong column count. These produce user-visible `warnings`.
        let skippedRowCount: Int
        /// Rows where EMAY itself reported "no reading" by leaving both SpO2 and
        /// PR blank. EMAY's summary report explicitly excludes these from its
        /// clinical stats ("loose contact with finger probe"), so we track them
        /// separately from genuine parse failures and surface them with neutral
        /// wording in the import dialog.
        let sensorGapRowCount: Int
        let dateRange: ClosedRange<Date>?
        let warnings: [String]
    }

    enum ImportError: Error, LocalizedError {
        case noData(skippedRowCount: Int, warnings: [String])
        case persistenceError(Error)

        var errorDescription: String? {
            switch self {
            case .noData(let skipped, _):
                return skipped == 0
                    ? "No EMAY samples found in file"
                    : "No valid EMAY samples found in file (\(skipped) row\(skipped == 1 ? "" : "s") skipped)"
            case .persistenceError(let underlying):
                return "Persistence error: \(underlying.localizedDescription)"
            }
        }
    }

    /// Stable identifier used to attribute samples to the EMAY SleepO2 oximeter
    /// and to scope dedup queries on re-import. Matches the bundle ID used by
    /// `DeviceProvenance.overnightPulseOximeters`, so CSV-imported samples get
    /// the same reliability classification ("dedicated overnight oximeter")
    /// and display name as samples written by the EMAY iOS app to HealthKit.
    static let sourceBundleID = "com.emay.SleepO2"
    static let sourceName = "EMAY SleepO2"
    static let spo2MetricType = "HKQuantityTypeIdentifierOxygenSaturation"
    static let heartRateMetricType = "HKQuantityTypeIdentifierHeartRate"

    static func importCSV(from url: URL, into context: ModelContext) throws -> ImportResult {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let content = try String(contentsOf: url, encoding: .utf8)
        return try importContent(content, into: context)
    }

    /// Internal entry that takes pre-read content. Used by `CSVImportRouter`
    /// to avoid reading large EMAY files twice (once for sniffing, once for parsing).
    static func importContent(_ content: String, into context: ModelContext) throws -> ImportResult {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else {
            throw ImportError.noData(skippedRowCount: 0, warnings: [])
        }

        let dataLines = Array(lines.dropFirst())
        return try importLines(dataLines, into: context)
    }

    private static func importLines(_ lines: [String], into context: ModelContext) throws -> ImportResult {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        // Pass 1: parse rows and collect the timestamp window. Holding parsed
        // structs (~48 bytes × ~36k rows for an overnight EMAY session ≈ 2 MB)
        // is cheap compared to scanning the entire QuantityHealthSample table
        // for dedup keys on every import.
        var tracker = ImportSkipTracker()
        var sensorGapCount = 0
        var parsed: [ParsedEMAYRow] = []
        parsed.reserveCapacity(lines.count)
        var minDate: Date?
        var maxDate: Date?

        for (index, line) in lines.enumerated() {
            // Header is Row 1; first data line is Row 2.
            let rowNumber = index + 2
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            switch parseRow(fields, using: formatter) {
            case .parsed(let row):
                if minDate == nil || row.timestamp < minDate! { minDate = row.timestamp }
                if maxDate == nil || row.timestamp > maxDate! { maxDate = row.timestamp }
                parsed.append(row)
            case .sensorGap:
                sensorGapCount += 1
            case .skip(let reason):
                tracker.record(row: rowNumber, reason: reason)
            }
        }

        // Window-scoped prefetch: only existing samples whose timestamps overlap
        // the incoming file's range can possibly collide. Combined with
        // QuantityHealthSample's @Index(sourceBundleID, timestamp), the lookup
        // is an index range scan whose cost scales with the imported window,
        // not with total historical EMAY samples.
        var existingKeys: Set<DedupKey> = []
        if let lower = minDate, let upper = maxDate {
            existingKeys = try prefetchExistingKeys(in: context, range: lower...upper)
        }

        // Pass 2: insert dedup'd.
        var inserted = 0
        for row in parsed {
            inserted += insertSamples(row: row, existingKeys: &existingKeys, into: context)
        }

        // Distinguish "file had nothing parseable" (true error) from "file's
        // rows were all already imported" (success with zero new inserts).
        // Re-importing a clean file should not look like a parse failure.
        guard !parsed.isEmpty else {
            // A file containing only sensor-disconnect rows is a valid but
            // empty parse — not a failure. Return a zero-insert result so the
            // dialog surfaces the gap count instead of an opaque "no data"
            // error. The same path also catches mostly-gap files with a few
            // malformed rows: the gap count is still informative even if some
            // rows were unparseable.
            if sensorGapCount > 0 {
                return ImportResult(
                    inserted: 0,
                    skippedRowCount: tracker.count,
                    sensorGapRowCount: sensorGapCount,
                    dateRange: nil,
                    warnings: tracker.warnings
                )
            }
            throw ImportError.noData(skippedRowCount: tracker.count, warnings: tracker.warnings)
        }

        if inserted > 0 {
            do {
                try context.save()
            } catch {
                throw ImportError.persistenceError(error)
            }
        }

        let dateRange: ClosedRange<Date>? = if let min = minDate, let max = maxDate {
            min...max
        } else {
            nil
        }
        return ImportResult(
            inserted: inserted,
            skippedRowCount: tracker.count,
            sensorGapRowCount: sensorGapCount,
            dateRange: dateRange,
            warnings: tracker.warnings
        )
    }

    // MARK: - Row parsing

    private struct ParsedEMAYRow {
        let timestamp: Date
        let spo2Fraction: Double?
        let pulseBPM: Double?
    }

    private enum ParseOutcome {
        case parsed(ParsedEMAYRow)
        /// EMAY emits a row per second even when the finger probe is off; in
        /// those rows both SpO2 and PR fields are blank. The device's own
        /// report excludes these from clinical stats — we drop them silently
        /// (separately counted) rather than reporting them as parse errors.
        case sensorGap
        case skip(reason: String)
    }

    private static func parseRow(_ fields: [String], using formatter: DateFormatter) -> ParseOutcome {
        guard fields.count >= 4 else {
            return .skip(reason: "expected 4 columns, found \(fields.count)")
        }
        let combined = "\(fields[0]) \(fields[1])"
        guard let timestamp = formatter.date(from: combined) else {
            return .skip(reason: "invalid date/time '\(combined)'")
        }
        if fields[2].isEmpty && fields[3].isEmpty {
            return .sensorGap
        }
        guard let spo2Pct = Double(fields[2]) else {
            return .skip(reason: "invalid SpO2 '\(fields[2])'")
        }
        guard let pulse = Double(fields[3]) else {
            return .skip(reason: "invalid pulse rate '\(fields[3])'")
        }
        // EMAY reports 0 for "no reading" gaps. Drop those rather than store
        // physiologically impossible zeros.
        return .parsed(ParsedEMAYRow(
            timestamp: timestamp,
            spo2Fraction: spo2Pct > 0 ? spo2Pct / 100.0 : nil,
            pulseBPM: pulse > 0 ? pulse : nil
        ))
    }

    // MARK: - Insert + dedup

    /// Composite key for `(timestamp, metricType)` dedup. Stored `Date` values
    /// hash and compare against the in-file `Date` directly, avoiding the
    /// `timeIntervalSince1970` string-interpolation round-trip.
    private struct DedupKey: Hashable {
        let timestamp: Date
        let metricType: String
    }

    /// Prefetch dedup keys for samples already attributed to the EMAY source
    /// whose timestamps fall inside `range`. Re-importing the same CSV (or an
    /// overlapping window) produces no duplicates without scanning unrelated
    /// historical samples.
    private static func prefetchExistingKeys(
        in context: ModelContext,
        range: ClosedRange<Date>
    ) throws -> Set<DedupKey> {
        let bundleID = sourceBundleID
        let lower = range.lowerBound
        let upper = range.upperBound
        let predicate = #Predicate<QuantityHealthSample> { sample in
            sample.sourceBundleID == bundleID
                && sample.timestamp >= lower
                && sample.timestamp <= upper
        }
        let descriptor = FetchDescriptor<QuantityHealthSample>(predicate: predicate)
        let existing = try context.fetch(descriptor)
        var keys = Set<DedupKey>()
        keys.reserveCapacity(existing.count * 2)
        for sample in existing {
            keys.insert(DedupKey(timestamp: sample.timestamp, metricType: sample.metricType))
        }
        return keys
    }

    private static func insertSamples(
        row: ParsedEMAYRow,
        existingKeys: inout Set<DedupKey>,
        into context: ModelContext
    ) -> Int {
        var added = 0
        if let spo2 = row.spo2Fraction {
            added += insertIfNew(
                timestamp: row.timestamp,
                metricType: spo2MetricType,
                value: spo2,
                unitString: "%",
                existingKeys: &existingKeys,
                into: context
            )
        }
        if let bpm = row.pulseBPM {
            added += insertIfNew(
                timestamp: row.timestamp,
                metricType: heartRateMetricType,
                value: bpm,
                unitString: "count/min",
                existingKeys: &existingKeys,
                into: context
            )
        }
        return added
    }

    private static func insertIfNew(
        timestamp: Date,
        metricType: String,
        value: Double,
        unitString: String,
        existingKeys: inout Set<DedupKey>,
        into context: ModelContext
    ) -> Int {
        let composite = DedupKey(timestamp: timestamp, metricType: metricType)
        guard !existingKeys.contains(composite) else { return 0 }
        let sample = QuantityHealthSample(
            timestamp: timestamp,
            metricType: metricType,
            value: value,
            unitString: unitString,
            sourceBundleID: sourceBundleID,
            sourceName: sourceName
        )
        context.insert(sample)
        existingKeys.insert(composite)
        return 1
    }
}
