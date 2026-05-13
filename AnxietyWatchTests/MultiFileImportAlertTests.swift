import Foundation
import Testing

@testable import AnxietyWatch

struct MultiFileImportAlertTests {

    private func cpapResult(inserted: Int, updated: Int = 0, skipped: Int = 0, warnings: [String] = []) -> CSVImportRouter.Result {
        CSVImportRouter.Result(
            kind: .cpap,
            inserted: inserted,
            updated: updated,
            dateRange: nil,
            skippedRowCount: skipped,
            sensorGapRowCount: 0,
            warnings: warnings
        )
    }

    private func emayResult(
        inserted: Int,
        skipped: Int = 0,
        sensorGaps: Int = 0,
        warnings: [String] = []
    ) -> CSVImportRouter.Result {
        CSVImportRouter.Result(
            kind: .emay,
            inserted: inserted,
            updated: 0,
            dateRange: nil,
            skippedRowCount: skipped,
            sensorGapRowCount: sensorGaps,
            warnings: warnings
        )
    }

    @Test("Single-file success uses filename in title and detailed alert message in body")
    func singleFileSuccess() {
        let alert = MultiFileImportAlert.compose(
            results: [.init(filename: "night.csv", result: cpapResult(inserted: 3))],
            errors: []
        )
        #expect(alert.title == "Imported night.csv")
        #expect(alert.message.contains("Imported 3 sessions"))
    }

    @Test("Single-file failure puts filename in title")
    func singleFileFailure() {
        let alert = MultiFileImportAlert.compose(
            results: [],
            errors: [.init(filename: "broken.csv", message: "Unrecognized CSV format.")]
        )
        #expect(alert.title == "Import Failed: broken.csv")
        #expect(alert.message == "Unrecognized CSV format.")
    }

    @Test("All-success multi-file batch lists each file on its own line")
    func multiSuccess() {
        let alert = MultiFileImportAlert.compose(
            results: [
                .init(filename: "a.csv", result: cpapResult(inserted: 2)),
                .init(filename: "b.csv", result: emayResult(inserted: 18000))
            ],
            errors: []
        )
        #expect(alert.title == "Imported 2 files")
        #expect(alert.message.contains("a.csv: Imported 2 sessions"))
        #expect(alert.message.contains("b.csv: Imported 18000 EMAY samples"))
    }

    @Test("Multi-file batch surfaces per-file warnings indented under each file")
    func multiFileWarnings() throws {
        let alert = MultiFileImportAlert.compose(
            results: [
                .init(filename: "good.csv", result: cpapResult(inserted: 1)),
                .init(filename: "partial.csv", result: cpapResult(
                    inserted: 1,
                    skipped: 2,
                    warnings: ["Row 2: invalid date 'bad'", "Row 3: invalid ahi 'x'"]
                ))
            ],
            errors: []
        )
        #expect(alert.message.contains("partial.csv: Imported 1 session"))
        #expect(alert.message.contains("\n  Row 2: invalid date 'bad'"))
        #expect(alert.message.contains("\n  Row 3: invalid ahi 'x'"))
        // The clean file should have no indented lines under it. Use
        // range-of probes (with try #require) instead of subscripting the
        // result of components(separatedBy:), which would trap if the
        // delimiter wasn't present.
        let goodRange = try #require(alert.message.range(of: "good.csv:"))
        let partialRange = try #require(alert.message.range(of: "partial.csv:"))
        let goodSection = alert.message[goodRange.upperBound..<partialRange.lowerBound]
        #expect(!goodSection.contains("  Row"))
    }

    @Test("Multi-line error messages are split and indented under their file")
    func multiFileErrorIndentation() {
        let multiLine = "No valid sessions found in file (2 rows skipped)\n\nRow 2: invalid date 'bad'\nRow 3: invalid ahi 'x'"
        let alert = MultiFileImportAlert.compose(
            results: [.init(filename: "good.csv", result: cpapResult(inserted: 1))],
            errors: [.init(filename: "broken.csv", message: multiLine)]
        )
        // First line of the error gets the filename prefix.
        #expect(alert.message.contains("broken.csv: No valid sessions found in file (2 rows skipped)"))
        // Continuation lines (warnings) get the same two-space indent as
        // success-path warnings, so they stay attributed to the right file.
        #expect(alert.message.contains("\n  Row 2: invalid date 'bad'"))
        #expect(alert.message.contains("\n  Row 3: invalid ahi 'x'"))
        // No bare warning lines without indentation.
        #expect(!alert.message.contains("\nRow 2:"))
    }

    @Test("Mixed success and failure title shows both counts")
    func mixedBatch() {
        let alert = MultiFileImportAlert.compose(
            results: [.init(filename: "good.csv", result: cpapResult(inserted: 1))],
            errors: [.init(filename: "bad.csv", message: "Unrecognized CSV format.")]
        )
        #expect(alert.title == "Imported 1 of 2 files")
        #expect(alert.message.contains("good.csv: Imported 1 session"))
        #expect(alert.message.contains("bad.csv: Unrecognized CSV format."))
    }

    @Test("All-failure batch reports failure count")
    func allFailure() {
        let alert = MultiFileImportAlert.compose(
            results: [],
            errors: [
                .init(filename: "x.csv", message: "msg one"),
                .init(filename: "y.csv", message: "msg two")
            ]
        )
        #expect(alert.title == "Import Failed (2 files)")
        #expect(alert.message.contains("x.csv: msg one"))
        #expect(alert.message.contains("y.csv: msg two"))
    }

    @Test("Empty batch returns no-file phrasing rather than crashing")
    func emptyBatch() {
        let alert = MultiFileImportAlert.compose(results: [], errors: [])
        #expect(alert.title == "Imported 0 files")
        #expect(alert.message.isEmpty)
    }
}
