import Foundation

/// Format helpers that translate router results and errors into alert text.
/// Lives outside `CSVImportRouter` so the dispatch logic stays free of
/// presentation concerns; lives outside views so multiple entry points
/// (the CPAP list import button today, the share-sheet handler tomorrow)
/// don't duplicate message construction.

extension CSVImportRouter.Result {
    /// Human-readable summary of an import. CPAP imports report sessions
    /// inserted/updated; EMAY imports report individual samples added.
    var summarySentence: String {
        let head: String
        switch kind {
        case .cpap:
            if updated == 0 {
                head = "Imported \(inserted) session\(inserted == 1 ? "" : "s")."
            } else if inserted == 0 {
                head = "Updated \(updated) session\(updated == 1 ? "" : "s")."
            } else {
                let total = inserted + updated
                head = "Imported \(inserted) new, updated \(updated) existing (\(total) total)."
            }
        case .emay:
            if inserted == 0 {
                // Three paths land here that we can't distinguish without
                // additional tracking: (a) re-import where every parsed row
                // was deduped against existing samples, (b) a file where
                // every row's SpO2 and pulse values were zero (EMAY emits
                // zeros during signal dropout) and got dropped at parse
                // time, or (c) a file containing only sensor-disconnect
                // (blank SpO2 + PR) rows. Neutral wording is correct for
                // all three; the sensor-gap trailer below provides
                // additional context when (c) applies.
                head = "No new EMAY samples imported."
            } else {
                head = "Imported \(inserted) EMAY sample\(inserted == 1 ? "" : "s")."
            }
        }
        var trailers: [String] = []
        if sensorGapRowCount > 0 {
            // EMAY's own report flags these as "loose finger-probe contact"
            // and excludes them from clinical stats. Surface as a neutral
            // count, separate from skipped-as-malformed rows.
            trailers.append("\(sensorGapRowCount) sensor-disconnect row\(sensorGapRowCount == 1 ? "" : "s") (excluded by EMAY)")
        }
        if skippedRowCount > 0 {
            trailers.append("Skipped \(skippedRowCount) malformed row\(skippedRowCount == 1 ? "" : "s")")
        }
        if trailers.isEmpty {
            return head
        }
        return head + " " + trailers.joined(separator: "; ") + "."
    }

    /// Summary + warning lines for an alert body. Warnings are pre-capped at
    /// 5 + "and N more" by the importers.
    var alertMessage: String {
        guard !warnings.isEmpty else { return summarySentence }
        return summarySentence + "\n\n" + warnings.joined(separator: "\n")
    }
}

/// Composes alert title + message for a batch of imports that arrived together
/// (e.g. multi-file share sheet drop). Single-file batches collapse to the
/// same shape as the in-app import button so the UX stays consistent.
enum MultiFileImportAlert {
    /// Explicitly `Sendable` (with `CSVImportRouter.Result` already Sendable)
    /// so a batch's per-file outcomes can be returned from `Task.detached`.
    struct PerFileResult: Sendable {
        let filename: String
        let result: CSVImportRouter.Result
    }

    struct PerFileError: Sendable {
        let filename: String
        let message: String
    }

    static func compose(
        results: [PerFileResult],
        errors: [PerFileError]
    ) -> (title: String, message: String) {
        let total = results.count + errors.count

        // Single-file path: same wording as a one-tap in-app import.
        if total == 1 {
            if let only = results.first {
                return (
                    title: "Imported \(only.filename)",
                    message: only.result.alertMessage
                )
            }
            if let only = errors.first {
                return (
                    title: "Import Failed: \(only.filename)",
                    message: only.message
                )
            }
        }

        // Multi-file path: per-file lines so the user can see at a glance
        // which files succeeded and which failed.
        let title: String
        if errors.isEmpty {
            title = "Imported \(results.count) file\(results.count == 1 ? "" : "s")"
        } else if results.isEmpty {
            title = "Import Failed (\(errors.count) file\(errors.count == 1 ? "" : "s"))"
        } else {
            title = "Imported \(results.count) of \(total) files"
        }

        // Indent per-file warnings (success path) and per-file error
        // continuation lines (failure path) under their filename so
        // multi-file batches surface the same row-level diagnostics that
        // single-file imports already show. Importers cap warnings at
        // 5 + "and N more" per file, so a batch of N files produces at
        // most 6N lines of diagnostics.
        var lines: [String] = []
        for r in results {
            lines.append("\(r.filename): \(r.result.summarySentence)")
            for warning in r.result.warnings {
                lines.append("  " + warning)
            }
        }
        for e in errors {
            // `e.message` can be a single-line description or a multi-line
            // alert body (errorDescription + "\n\n" + warning lines). Split
            // and indent continuation lines so warnings stay attributed to
            // the correct file.
            let pieces = e.message
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let first = pieces.first {
                lines.append("\(e.filename): \(first)")
                for continuation in pieces.dropFirst() {
                    lines.append("  " + continuation)
                }
            } else {
                lines.append("\(e.filename):")
            }
        }
        return (title: title, message: lines.joined(separator: "\n"))
    }
}

extension CSVImportRouter.ImportError {
    /// Diagnostics from a router error, when the underlying importer recorded
    /// any. Lets the alert show row-level warnings even when every row was
    /// rejected.
    var warningsForAlert: [String] {
        switch self {
        case .cpapImport(.noData(_, let warnings)): return warnings
        case .emayImport(.noData(_, let warnings)): return warnings
        default: return []
        }
    }

    /// Error description plus warning lines, for display.
    var alertMessage: String {
        let head = errorDescription ?? "Import failed."
        let warnings = warningsForAlert
        guard !warnings.isEmpty else { return head }
        return head + "\n\n" + warnings.joined(separator: "\n")
    }
}
