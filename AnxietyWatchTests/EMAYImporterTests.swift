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

    @Test("Sensor-gap rows (blank SpO2 + PR) are counted separately from skips")
    func sensorGapRowsCountedSeparately() throws {
        // EMAY emits a per-second row even when the finger probe is off; in
        // those rows SpO2 and PR are both blank. Those rows must NOT inflate
        // skippedRowCount (the user-facing "malformed row" counter) and must
        // NOT generate "invalid SpO2 ''" warnings — they're documented sensor
        // gaps that the device itself excludes from its clinical stats.
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/10/2026,5:10:28 AM,94,90
        5/10/2026,5:10:29 AM,95,90
        5/10/2026,5:10:30 AM,,
        5/10/2026,5:10:31 AM,,
        5/10/2026,5:10:32 AM,,
        5/10/2026,5:10:33 AM,96,91
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try EMAYImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 6)              // 3 valid rows × (SpO2 + HR)
        #expect(result.skippedRowCount == 0)       // no malformed rows
        #expect(result.sensorGapRowCount == 3)     // three probe-off rows
        #expect(result.warnings.isEmpty)           // gaps don't generate warnings
    }

    @Test("All-sensor-gap file returns a zero-insert result instead of throwing noData")
    func sensorGapOnlyFileReturnsZeroInsertResult() throws {
        // A file that's entirely sensor-disconnect rows isn't a parse failure
        // — it's a valid but empty capture. The dialog needs the gap count to
        // explain "your file was 100% probe-off"; throwing noData hides it
        // and surfaces a misleading "no data" error instead.
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/10/2026,5:10:30 AM,,
        5/10/2026,5:10:31 AM,,
        5/10/2026,5:10:32 AM,,
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try EMAYImporter.importCSV(from: url, into: context)
        #expect(result.inserted == 0)
        #expect(result.skippedRowCount == 0)
        #expect(result.sensorGapRowCount == 3)
        #expect(result.warnings.isEmpty)
        #expect(result.dateRange == nil)  // no valid rows → no range to report
    }

    // MARK: - DST fall-back fold correction

    // The corrector is a pure sequential function; coverage tests it directly
    // with an INJECTED DST-observing zone so the transition cross-check (a
    // fold correction only fires when the zone really set clocks back nearby)
    // is deterministic regardless of the simulator's timezone. `foldBase` is
    // derived from the zone's own transition table (one second before a real
    // clocks-back instant), not hardcoded — no Date.now, no magic epoch.
    private static let foldZone = TimeZone(identifier: "America/Los_Angeles")!

    /// One second before a real fall-back transition in `foldZone` — the
    /// last naive-parse-correct instant before the repeated hour.
    private static let foldBase: Date = {
        // Start the search mid-2026 so the found transition is the November
        // clocks-back one (the March transition is spring-forward).
        var search = Date(timeIntervalSince1970: 1_782_000_000)  // mid-2026
        for _ in 0..<4 {
            guard let t = foldZone.nextDaylightSavingTimeTransition(after: search) else { break }
            let before = foldZone.secondsFromGMT(for: t.addingTimeInterval(-1))
            let after = foldZone.secondsFromGMT(for: t)
            if after < before { return t.addingTimeInterval(-1) }
            search = t.addingTimeInterval(1)
        }
        fatalError("No clocks-back transition found in America/Los_Angeles")
    }()

    @Test("Fold corrector shifts the repeated hour forward and stays monotonic")
    func foldCorrectorMapsRepeatedHourForward() {
        var corrector = EMAYImporter.DSTFoldCorrector(timeZone: Self.foldZone)
        let base = Self.foldBase

        // Approaching the fold: 1:59:58, 1:59:59 (naive parse = physical time).
        #expect(corrector.corrected(base) == base)
        #expect(corrector.corrected(base.addingTimeInterval(1)) == base.addingTimeInterval(1))

        // Fold: wall clock repeats the hour, so the naive parse jumps
        // backward 3599s. Physically this row is 1s after the previous one.
        let refolded = base.addingTimeInterval(1 - 3599)
        #expect(corrector.corrected(refolded) == base.addingTimeInterval(2))

        // Subsequent rows in the repeated hour keep parsing an hour early;
        // the offset must keep applying.
        let nextInFold = refolded.addingTimeInterval(1)
        #expect(corrector.corrected(nextInFold) == base.addingTimeInterval(3))
    }

    @Test("Fold corrector drops the offset once wall clock passes the transition")
    func foldCorrectorResetsAfterTransition() {
        var corrector = EMAYImporter.DSTFoldCorrector(timeZone: Self.foldZone)
        let base = Self.foldBase

        // Simulated fold night, using naive-parse values as a formatter in
        // the fold's timezone would produce them:
        //   wall 1:59:59 (1st occurrence) → naive X        physical X
        //   wall 1:00:00 (2nd occurrence) → naive X-3599   physical X+1
        //   wall 1:59:59 (2nd occurrence) → naive X        physical X+3600
        //   wall 2:00:00 (unambiguous)    → naive X+3601   physical X+3601
        _ = corrector.corrected(base)
        let foldStart = base.addingTimeInterval(-3599)
        #expect(corrector.corrected(foldStart) == base.addingTimeInterval(1))
        // Last second of the repeated hour still parses an hour early.
        #expect(corrector.corrected(base) == base.addingTimeInterval(3600))

        // At 2:00:00 the formatter is past the ambiguity and the naive parse
        // is physically correct again — the offset must reset here, or we'd
        // push the rest of the night an hour into the future.
        let pastFold = base.addingTimeInterval(3601)
        #expect(corrector.corrected(pastFold) == pastFold)
        // And stay reset for ordinary rows after.
        let next = pastFold.addingTimeInterval(1)
        #expect(corrector.corrected(next) == next)
    }

    @Test("Fold corrector handles a probe-off gap spanning the transition")
    func foldCorrectorHandlesGapAcrossFold() {
        var corrector = EMAYImporter.DSTFoldCorrector(timeZone: Self.foldZone)
        let base = Self.foldBase

        _ = corrector.corrected(base)
        // A gap swallowed part of the repeated hour: the next timestamp
        // regresses only 900s, not ~3600s. Still a fold (only a backward
        // jump can produce this in a sequential file), still +1h.
        let afterGap = base.addingTimeInterval(-900)
        #expect(corrector.corrected(afterGap) == base.addingTimeInterval(2700))
    }

    @Test("Fold corrector leaves duplicate and near-duplicate timestamps alone")
    func foldCorrectorIgnoresDuplicates() {
        var corrector = EMAYImporter.DSTFoldCorrector(timeZone: Self.foldZone)
        let base = Self.foldBase

        _ = corrector.corrected(base)
        // Exact duplicate: not a fold — leave it for the normal dedup path.
        #expect(corrector.corrected(base) == base)
        // Tiny regression (clock jitter): also not a fold.
        let jitter = base.addingTimeInterval(-2)
        #expect(corrector.corrected(jitter) == jitter)
    }

    @Test("Fold corrector ignores backward jumps too large to be a fold")
    func foldCorrectorIgnoresLargeBackwardJumps() {
        var corrector = EMAYImporter.DSTFoldCorrector(timeZone: Self.foldZone)
        let base = Self.foldBase

        _ = corrector.corrected(base)
        // A 3h regression can't be a DST fold (folds are at most 1h) — treat
        // it as a genuine discontinuity (device clock reset) and don't touch it.
        let clockReset = base.addingTimeInterval(-3 * 3600)
        #expect(corrector.corrected(clockReset) == clockReset)
    }

    // With the transition cross-check, a backward wall-clock jump AWAY from
    // any real clocks-back transition (a device-clock resync, a manual time
    // change, or these early-May rows in any simulator timezone) must be
    // left untouched — "correcting" it would shift every subsequent sample
    // forward an hour, a worse corruption than the dropped-hour bug. No DST
    // zone on Earth sets clocks back in early May, so this is deterministic.
    @Test("Backward jump away from a DST transition is not 'corrected'")
    func backwardJumpWithoutTransitionLeftAlone() throws {
        let csv = """
        Date,Time,SpO2(%),PR(bpm)
        5/8/2026,1:59:58 AM,98,52
        5/8/2026,1:59:59 AM,97,53
        5/8/2026,1:00:00 AM,96,54
        5/8/2026,1:00:01 AM,,
        5/8/2026,1:00:02 AM,95,55
        """
        let url = try writeTempCSV(csv)
        defer { try? FileManager.default.removeItem(at: url) }

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let result = try EMAYImporter.importCSV(from: url, into: context)
        // No wall-clock values collide, so nothing dedups away even without
        // a correction; all 4 data rows land.
        #expect(result.inserted == 8)
        #expect(result.sensorGapRowCount == 1)

        // The naive parses stand: the span from min to max stays ~59.9 min.
        // A misfired +1h correction would compress it to ~4 s.
        let timestamps = try emaySamples(in: context)
            .filter { $0.metricType == EMAYImporter.heartRateMetricType }
            .map(\.timestamp)
            .sorted()
        #expect(timestamps.count == 4)
        let span = timestamps.last!.timeIntervalSince(timestamps.first!)
        #expect(abs(span - 3599) < 0.001)
    }

    // Corrector-level fold coverage lives in the tests above with an
    // injected DST-observing zone anchored at a real clocks-back
    // transition; end-to-end import coverage of the fold itself would
    // depend on the simulator's timezone (the importer parses in
    // TimeZone.current), so it is deliberately not asserted here.

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
