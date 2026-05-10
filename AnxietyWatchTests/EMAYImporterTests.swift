import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct EMAYImporterTests {

    private func writeTempCSV(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func emaySamples(in context: ModelContext) throws -> [QuantityHealthSample] {
        let bundleID = EMAYImporter.sourceBundleID
        let predicate = #Predicate<QuantityHealthSample> { $0.sourceBundleID == bundleID }
        return try context.fetch(FetchDescriptor<QuantityHealthSample>(predicate: predicate))
    }

    // MARK: - Valid data

    @Test("Imports valid EMAY CSV producing two samples per data row")
    func importValidCSV() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        5/8/2026,4:46:59 PM,97,53
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try EMAYImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 4) // 2 rows × (SpO2 + HR)
        #expect(result.skippedRowCount == 0)
        #expect(result.warnings.isEmpty)
        #expect(result.dateRange != nil)

        let samples = try emaySamples(in: context)
        #expect(samples.count == 4)
        let metricTypes = Set(samples.map(\.metricType))
        #expect(metricTypes.contains(EMAYImporter.spo2MetricType))
        #expect(metricTypes.contains(EMAYImporter.heartRateMetricType))
    }

    @Test("Stores SpO2 as fraction matching HealthKit convention")
    func spo2StoredAsFraction() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        _ = try EMAYImporter.importCSV(from: url, into: context)
        let samples = try emaySamples(in: context)
        let spo2 = samples.first { $0.metricType == EMAYImporter.spo2MetricType }
        try #require(spo2 != nil)
        #expect(abs(spo2!.value - 0.98) < 0.0001)
        #expect(spo2!.unitString == "%")
    }

    @Test("Heart rate stored in count/min")
    func heartRateUnit() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        _ = try EMAYImporter.importCSV(from: url, into: context)
        let samples = try emaySamples(in: context)
        let hr = samples.first { $0.metricType == EMAYImporter.heartRateMetricType }
        try #require(hr != nil)
        #expect(hr!.value == 52)
        #expect(hr!.unitString == "count/min")
    }

    // MARK: - Idempotency

    @Test("Re-importing the same file is a successful no-op, not an error")
    func reimportIsIdempotent() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        5/8/2026,4:46:59 PM,97,53
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let first = try EMAYImporter.importCSV(from: url, into: context)
        #expect(first.inserted == 4)

        // Second import: file parses cleanly but every row is already present.
        // This should succeed with inserted=0, not throw — the user's CSV
        // wasn't malformed, it was just redundant.
        let second = try EMAYImporter.importCSV(from: url, into: context)
        #expect(second.inserted == 0)
        #expect(second.skippedRowCount == 0)
        #expect(second.warnings.isEmpty)

        let samples = try emaySamples(in: context)
        #expect(samples.count == 4) // unchanged
    }

    @Test("File with only malformed rows still throws noData")
    func allRowsMalformedThrows() throws {
        // Distinct from re-import: nothing parsed cleanly, so this is a true
        // "no data" error rather than a redundant import.
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        bad-date,bad-time,bad,bad
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        do {
            _ = try EMAYImporter.importCSV(from: url, into: context)
            Issue.record("Expected noData throw")
        } catch EMAYImporter.ImportError.noData(let skipped, _) {
            #expect(skipped == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Partial overlap inserts only new timestamps")
    func partialOverlap() throws {
        let csv1 = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        """
        let csv2 = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        5/8/2026,4:46:59 PM,97,53
        """
        let url1 = try writeTempCSV(csv1)
        let url2 = try writeTempCSV(csv2)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        _ = try EMAYImporter.importCSV(from: url1, into: context)
        let second = try EMAYImporter.importCSV(from: url2, into: context)
        #expect(second.inserted == 2) // only the new timestamp's two samples

        let samples = try emaySamples(in: context)
        #expect(samples.count == 4)
    }

    // MARK: - Skip diagnostics

    @Test("Bad rows produce field-aware warnings via shared tracker")
    func skipDiagnostics() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        bad-date,4:46:58 PM,98,52
        5/8/2026,4:46:59 PM,not-a-number,53
        5/8/2026,4:47:00 PM,97,54
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try EMAYImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 2) // only the third row's pair
        #expect(result.skippedRowCount == 2)
        try #require(result.warnings.count == 2)
        #expect(result.warnings[0].contains("Row 2"))
        #expect(result.warnings[1].contains("Row 3"))
    }

    @Test("Drops zero values without skipping the row")
    func zeroValuesDropped() throws {
        // SpO2=0 should drop just the SpO2 sample but keep heart rate.
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,0,52
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try EMAYImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 1)
        #expect(result.skippedRowCount == 0) // zero is data, not malformed

        let samples = try emaySamples(in: context)
        #expect(samples.count == 1)
        #expect(samples.first?.metricType == EMAYImporter.heartRateMetricType)
    }

    @Test("Throws noData on header-only file")
    func headerOnly() throws {
        let csv = "Date,Time,SpO2(%),PR(bpm)\n"
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        do {
            _ = try EMAYImporter.importCSV(from: url, into: context)
            Issue.record("Expected noData throw")
        } catch EMAYImporter.ImportError.noData(let skipped, let warnings) {
            #expect(skipped == 0)
            #expect(warnings.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Source attribution uses the EMAY constants")
    func sourceAttribution() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,4:46:58 PM,98,52
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        _ = try EMAYImporter.importCSV(from: url, into: context)
        let samples = try emaySamples(in: context)
        try #require(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.sourceBundleID == EMAYImporter.sourceBundleID })
        #expect(samples.allSatisfy { $0.sourceName == EMAYImporter.sourceName })
    }
}
