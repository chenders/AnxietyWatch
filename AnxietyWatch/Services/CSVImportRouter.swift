import Foundation
import SwiftData

/// Sniffs a CSV's first non-empty line and dispatches to the matching importer.
/// Reads the file exactly once and hands the content to the chosen importer.
/// `nonisolated` because import work runs inside `Task.detached` from the
/// share-sheet entry point — keeping it off the main actor avoids UI stutter
/// on ~36k-row EMAY CSVs.
nonisolated enum CSVImportRouter {

    enum Kind: String, Sendable {
        case cpap
        case emay
    }

    /// Unified result so callers (the CPAP list view today, the share sheet
    /// tomorrow) don't need to know which importer ran. Counts roll up across
    /// formats: for CPAP, `inserted` and `updated` count sessions; for EMAY,
    /// `inserted` counts individual `QuantityHealthSample` rows and `updated`
    /// stays at zero.
    ///
    /// Explicitly `Sendable` so the type is safe to pass back from
    /// `Task.detached` (used by the share-sheet entry point to keep imports
    /// off the main actor).
    struct Result: Sendable {
        let kind: Kind
        let inserted: Int
        let updated: Int
        let dateRange: ClosedRange<Date>?
        let skippedRowCount: Int
        /// EMAY-only: rows the device itself flagged as sensor-disconnected
        /// (blank SpO2 + PR). Always 0 for CPAP imports. Surfaced separately
        /// in the import dialog so a long disconnect window doesn't read as
        /// a parse failure.
        let sensorGapRowCount: Int
        let warnings: [String]
    }

    enum ImportError: Error, LocalizedError {
        case unrecognizedFormat
        case readError(Error)
        case cpapImport(CPAPImporter.ImportError)
        case emayImport(EMAYImporter.ImportError)

        var errorDescription: String? {
            switch self {
            case .unrecognizedFormat:
                return "Unrecognized CSV format. Expected a CPAP CSV (simple, OSCAR Summary, "
                    + "or OSCAR by-session export) or an EMAY pulse oximeter CSV."
            case .readError(let underlying):
                return "Could not read file: \(underlying.localizedDescription)"
            case .cpapImport(let underlying):
                return underlying.errorDescription
            case .emayImport(let underlying):
                return underlying.errorDescription
            }
        }
    }

    static func importCSV(from url: URL, into context: ModelContext) throws -> Result {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ImportError.readError(error)
        }

        return try importContent(content, into: context)
    }

    /// Internal entry that takes pre-read content. Tests use this directly
    /// to avoid file-system round-trips.
    static func importContent(_ content: String, into context: ModelContext) throws -> Result {
        let header = firstNonEmptyLine(in: content) ?? ""

        if isEMAYFormat(header) {
            do {
                let result = try EMAYImporter.importContent(content, into: context)
                return Result(
                    kind: .emay,
                    inserted: result.inserted,
                    updated: 0,
                    dateRange: result.dateRange,
                    skippedRowCount: result.skippedRowCount,
                    sensorGapRowCount: result.sensorGapRowCount,
                    warnings: result.warnings
                )
            } catch let error as EMAYImporter.ImportError {
                throw ImportError.emayImport(error)
            }
        }

        if CPAPImporter.isCPAPFormat(header) {
            do {
                let result = try CPAPImporter.importContent(content, into: context)
                // Clock-reset detection surfaces as a warning string so it
                // flows through every alert path (in-app import button and
                // multi-file share sheet) without view-level special-casing.
                var warnings = result.warnings
                if let clockResetWarning = CPAPImporter.clockResetWarning(count: result.suspiciousDateCount) {
                    warnings.append(clockResetWarning)
                }
                return Result(
                    kind: .cpap,
                    inserted: result.inserted,
                    updated: result.updated,
                    dateRange: result.dateRange,
                    skippedRowCount: result.skippedRowCount,
                    sensorGapRowCount: 0,
                    warnings: warnings
                )
            } catch let error as CPAPImporter.ImportError {
                throw ImportError.cpapImport(error)
            }
        }

        throw ImportError.unrecognizedFormat
    }

    // MARK: - Format detection

    private static func firstNonEmptyLine(in content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func normalized(_ header: String) -> String {
        var result = header
        if result.hasPrefix("\u{feff}") { result.removeFirst() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Match the full EMAY oximeter header shape (`Date,Time,SpO2(%),PR(bpm)`)
    /// rather than just the `date,time,spo2` prefix. Without the `pr(bpm)`
    /// check, a different oximeter exporting e.g. `Date,Time,SpO2(%),HR(bpm)`
    /// would be mis-routed to EMAYImporter and produce misleading EMAY-
    /// specific errors instead of `unrecognizedFormat`.
    static func isEMAYFormat(_ header: String) -> Bool {
        let h = normalized(header)
        return h.hasPrefix("date,time,spo2") && h.contains("pr(bpm)")
    }
}
