import Foundation
import PDFKit
import Testing

@testable import AnxietyWatch

/// Tests for ReportGenerator — verifies PDF output for various input combinations.
/// Tests focus on verifying the generator produces valid, non-empty PDF data
/// and handles edge cases (empty collections, mixed data) without crashing.
/// @MainActor because ReportGenerator uses UIKit drawing APIs (UIGraphicsPDFRenderer,
/// UIFont, NSAttributedString.draw) which must be called on the main thread.
@MainActor
struct ReportGeneratorTests {

    private let start = ModelFactory.daysAgo(30)
    private let end = ModelFactory.referenceDate

    // MARK: - Basic PDF generation

    @Test("Generates non-empty PDF with all empty inputs")
    func emptyInputsProducePDF() {
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
        // PDF magic bytes: %PDF
        #expect(data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46]))
    }

    @Test("Generates PDF with anxiety entries")
    func pdfWithAnxietyEntries() {
        let entries = [
            ModelFactory.anxietyEntry(timestamp: ModelFactory.daysAgo(5), severity: 3),
            ModelFactory.anxietyEntry(timestamp: ModelFactory.daysAgo(3), severity: 7),
            ModelFactory.anxietyEntry(timestamp: ModelFactory.daysAgo(1), severity: 5),
        ]
        let data = ReportGenerator.generatePDF(
            entries: entries,
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
        #expect(data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46]))
    }

    @Test("Generates PDF with medication doses")
    func pdfWithDoses() {
        let doses = [
            ModelFactory.medicationDose(
                timestamp: ModelFactory.daysAgo(5),
                medicationName: "Test Medication 50mg"
            ),
            ModelFactory.medicationDose(
                timestamp: ModelFactory.daysAgo(3),
                medicationName: "Test Medication 50mg"
            ),
            ModelFactory.medicationDose(
                timestamp: ModelFactory.daysAgo(1),
                medicationName: "Another Med 25mg"
            ),
        ]
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: doses,
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    @Test("Generates PDF with health snapshots including sleep")
    func pdfWithSleepData() {
        let snapshots = [
            ModelFactory.healthSnapshot(
                date: ModelFactory.daysAgo(2),
                hrvAvg: 45.0,
                restingHR: 62.0,
                sleepDurationMin: 420,
                sleepDeepMin: 60,
                sleepREMMin: 90,
                sleepCoreMin: 270
            ),
            ModelFactory.healthSnapshot(
                date: ModelFactory.daysAgo(1),
                hrvAvg: 50.0,
                restingHR: 58.0,
                sleepDurationMin: 480,
                sleepDeepMin: 70,
                sleepREMMin: 100,
                sleepCoreMin: 310
            ),
        ]
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: snapshots,
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    @Test("Generates PDF with CPAP sessions")
    func pdfWithCPAP() {
        let sessions = [
            ModelFactory.cpapSession(date: ModelFactory.daysAgo(2), ahi: 2.5, totalUsageMinutes: 420),
            ModelFactory.cpapSession(date: ModelFactory.daysAgo(1), ahi: 6.0, totalUsageMinutes: 360),
        ]
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: sessions,
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    @Test("Generates PDF with blood pressure data")
    func pdfWithBloodPressure() {
        let snapshots = [
            ModelFactory.healthSnapshot(
                date: ModelFactory.daysAgo(1),
                bpSystolic: 120.0,
                bpDiastolic: 80.0
            ),
        ]
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: snapshots,
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    @Test("Generates PDF with lab results")
    func pdfWithLabResults() {
        let labResults = [
            ModelFactory.clinicalLabResult(
                loincCode: "2093-3",
                testName: "Total Cholesterol",
                value: 180.0,
                unit: "mg/dL",
                effectiveDate: ModelFactory.daysAgo(5),
                referenceRangeHigh: 200.0
            ),
            ModelFactory.clinicalLabResult(
                loincCode: "2571-8",
                testName: "Triglycerides",
                value: 250.0,
                unit: "mg/dL",
                effectiveDate: ModelFactory.daysAgo(5),
                referenceRangeHigh: 150.0
            ),
        ]
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            labResults: labResults,
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    // MARK: - Combined data

    @Test("Generates PDF with all data types populated")
    func pdfWithAllData() {
        let entries = [
            ModelFactory.anxietyEntry(timestamp: ModelFactory.daysAgo(1), severity: 6),
        ]
        let doses = [
            ModelFactory.medicationDose(timestamp: ModelFactory.daysAgo(1)),
        ]
        let snapshots = (0..<15).map { day in
            ModelFactory.healthSnapshot(
                date: ModelFactory.daysAgo(day),
                hrvAvg: 40.0 + Double(day),
                restingHR: 60.0,
                sleepDurationMin: 420
            )
        }
        let sessions = [
            ModelFactory.cpapSession(date: ModelFactory.daysAgo(1)),
        ]
        let labResults = [
            ModelFactory.clinicalLabResult(effectiveDate: ModelFactory.daysAgo(3)),
        ]

        let data = ReportGenerator.generatePDF(
            entries: entries,
            doses: doses,
            definitions: [],
            snapshots: snapshots,
            cpapSessions: sessions,
            labResults: labResults,
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
        #expect(data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46]))
    }

    // MARK: - Edge cases

    @Test("Single anxiety entry produces valid PDF")
    func singleEntry() {
        let entries = [
            ModelFactory.anxietyEntry(timestamp: ModelFactory.daysAgo(1), severity: 10),
        ]
        let data = ReportGenerator.generatePDF(
            entries: entries,
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    @Test("All high severity entries produces valid PDF")
    func allHighSeverity() {
        let entries = (0..<5).map {
            ModelFactory.anxietyEntry(timestamp: ModelFactory.daysAgo($0), severity: 9)
        }
        let data = ReportGenerator.generatePDF(
            entries: entries,
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    @Test("Same-day start and end produces valid PDF")
    func sameDayRange() {
        let today = ModelFactory.referenceDate
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            start: today,
            end: today
        )
        #expect(!data.isEmpty)
    }

    @Test("Snapshots with nil optional fields produce valid PDF")
    func snapshotsWithNils() {
        let snapshots = [
            ModelFactory.healthSnapshot(
                date: ModelFactory.daysAgo(1),
                hrvAvg: nil,
                restingHR: nil,
                sleepDurationMin: nil,
                bpSystolic: nil,
                bpDiastolic: nil
            ),
        ]
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: snapshots,
            cpapSessions: [],
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    @Test("Lab result below reference range produces valid PDF")
    func labResultBelowRange() {
        let labResults = [
            ModelFactory.clinicalLabResult(
                loincCode: "718-7",
                testName: "Hemoglobin",
                value: 10.0,
                unit: "g/dL",
                effectiveDate: ModelFactory.daysAgo(2),
                referenceRangeLow: 12.0,
                referenceRangeHigh: 17.5
            ),
        ]
        let data = ReportGenerator.generatePDF(
            entries: [],
            doses: [],
            definitions: [],
            snapshots: [],
            cpapSessions: [],
            labResults: labResults,
            start: start,
            end: end
        )
        #expect(!data.isEmpty)
    }

    // MARK: - HRV current-status anchoring (F-043)

    /// Calendar.current-relative day offsets so the arithmetic matches the
    /// production code (BaselineCalculator uses Calendar.current), independent
    /// of the machine's time zone.
    private func snapshot(daysBefore n: Int, of anchor: Date, hrv: Double) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -n, to: anchor)!
        return ModelFactory.healthSnapshot(date: date, hrvAvg: hrv, restingHR: nil, sleepDurationMin: nil)
    }

    @Test("HRV status is BELOW BASELINE when the range-end data is low — not 'within range' from today's absent data")
    func hrvStatusAnchoredToRangeEnd() throws {
        // A report range that ended well in the past. Baseline over the 30 days
        // ending at rangeEnd is high (~50), but the 3 days ending at rangeEnd
        // are low (~10). Anchored to rangeEnd → BELOW BASELINE. Anchored to
        // .now (the old bug) the 3-day window would be empty → the report would
        // falsely print "Within normal range".
        let rangeEnd = Calendar.current.date(from: DateComponents(year: 2024, month: 4, day: 1))!
        var snapshots: [HealthSnapshot] = []
        // Baseline body: high HRV on days 4...25 before the end.
        for n in 4...25 {
            snapshots.append(snapshot(daysBefore: n, of: rangeEnd, hrv: 50.0 + Double(n % 3)))
        }
        // Trailing window ending at rangeEnd: sharply low HRV. recentAverage's
        // 3-day cutoff is inclusive at day 3, so seed days 0...3 all-low.
        for n in 0...3 {
            snapshots.append(snapshot(daysBefore: n, of: rangeEnd, hrv: 10.0))
        }

        let result = try #require(ReportGenerator.hrvReportStatus(snapshots: snapshots, rangeEnd: rangeEnd))
        #expect(result.status == .belowBaseline)
        #expect(result.baseline.mean > 20.0) // baseline reflects the high body, not the low tail
    }

    @Test("HRV status is 'no recent data' when the range ends long ago with no near-end data")
    func hrvStatusNoRecentDataForStaleRange() throws {
        // Baseline can be formed (≥14 snapshots in the 30 days before the end)
        // but nothing falls in the final 3 days, so the status must be honest
        // about the absence rather than defaulting to "within normal range".
        let rangeEnd = Calendar.current.date(from: DateComponents(year: 2024, month: 4, day: 1))!
        var snapshots: [HealthSnapshot] = []
        for n in 8...25 { // 18 days, all older than the trailing 3-day window
            snapshots.append(snapshot(daysBefore: n, of: rangeEnd, hrv: 45.0 + Double(n % 4)))
        }

        let result = try #require(ReportGenerator.hrvReportStatus(snapshots: snapshots, rangeEnd: rangeEnd))
        #expect(result.status == .noRecentData)
        #expect(result.status.reportLabel != "Within normal range")
    }

    @Test("HRV status is within range when near-end data matches baseline")
    func hrvStatusWithinRange() throws {
        let rangeEnd = Calendar.current.date(from: DateComponents(year: 2024, month: 4, day: 1))!
        var snapshots: [HealthSnapshot] = []
        for n in 0...25 { // steady HRV through the range end
            snapshots.append(snapshot(daysBefore: n, of: rangeEnd, hrv: 50.0 + Double(n % 3)))
        }

        let result = try #require(ReportGenerator.hrvReportStatus(snapshots: snapshots, rangeEnd: rangeEnd))
        #expect(result.status == .withinRange)
    }

    @Test("HRV status is nil (baseline omitted) when too few snapshots exist near the range end")
    func hrvStatusNilWhenBaselineUnavailable() {
        let rangeEnd = Calendar.current.date(from: DateComponents(year: 2024, month: 4, day: 1))!
        // Only a handful of snapshots — below the 14-sample baseline minimum.
        let snapshots = (0...4).map { snapshot(daysBefore: $0, of: rangeEnd, hrv: 48.0) }
        #expect(ReportGenerator.hrvReportStatus(snapshots: snapshots, rangeEnd: rangeEnd) == nil)
    }

    @Test("Stale-range PDF never prints a fabricated 'Within normal range' HRV status (F-043)")
    func stalePDFOmitsFabricatedStatus() throws {
        let rangeEnd = Calendar.current.date(from: DateComponents(year: 2024, month: 4, day: 1))!
        let rangeStart = Calendar.current.date(byAdding: .day, value: -30, to: rangeEnd)!
        var snapshots: [HealthSnapshot] = []
        for n in 8...25 { // baseline forms, but nothing in the last 3 days
            snapshots.append(snapshot(daysBefore: n, of: rangeEnd, hrv: 45.0 + Double(n % 4)))
        }

        let pdfData = ReportGenerator.generatePDF(
            entries: [], doses: [], definitions: [],
            snapshots: snapshots, cpapSessions: [],
            start: rangeStart, end: rangeEnd
        )
        let doc = try #require(PDFDocument(data: pdfData))
        var raw = ""
        for i in 0..<doc.pageCount where doc.page(at: i) != nil {
            raw += doc.page(at: i)?.string ?? ""
        }
        #expect(!raw.contains("Within normal range"))
        #expect(raw.contains("No recent data in range"))
    }

    @Test("Short report range draws its 30-day HRV baseline from the unfiltered history, capped at range end (F-095)")
    func shortRangeUsesUnfilteredBaselineCappedAtEnd() throws {
        let rangeEnd = Calendar.current.date(from: DateComponents(year: 2024, month: 4, day: 1))!
        // A short 5-day report window: its range-filtered snapshots are below
        // the 14-sample baseline floor on their own.
        let rangeStart = Calendar.current.date(byAdding: .day, value: -4, to: rangeEnd)!
        let rangeSnapshots = (0...4).map { snapshot(daysBefore: $0, of: rangeEnd, hrv: 50.0) }

        // Unfiltered history: 30 days ENDING at rangeEnd all at HRV 50, PLUS 40
        // days AFTER rangeEnd all at HRV 90. The post-end block outnumbers the
        // in-window block, so if the baseline window weren't capped at `end`
        // the MAD trim would treat the 50s as the outliers and the baseline
        // mean would come out ~90 — data from after the visit (the F-085 leak
        // this fix must not trigger).
        var fullHistory = (0...29).map { snapshot(daysBefore: $0, of: rangeEnd, hrv: 50.0) }
        fullHistory += (1...40).map { snapshot(daysBefore: -$0, of: rangeEnd, hrv: 90.0) }

        let pdfData = ReportGenerator.generatePDF(
            entries: [], doses: [], definitions: [],
            snapshots: rangeSnapshots, cpapSessions: [],
            start: rangeStart, end: rangeEnd,
            baselineSnapshots: fullHistory
        )
        let doc = try #require(PDFDocument(data: pdfData))
        var raw = ""
        for i in 0..<doc.pageCount { raw += doc.page(at: i)?.string ?? "" }
        // Baseline is present (drawn from the 30-day history, not the 5 in-range
        // days) AND reflects the in-window value 50.0 — NOT the post-end 90.0.
        #expect(raw.contains("30-day baseline: 50.0"))
        #expect(!raw.contains("30-day baseline: 90.0"))
    }

    @Test("Report includes overnight respiratory and glucose section with both halves")
    func reportIncludesOvernightSection() throws {
        let cal = Calendar.current
        let date = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        let snapshot = HealthSnapshot(date: date)
        snapshot.spo2NadirOvernight = 87.0
        snapshot.spo2TimeBelow90Min = 12
        snapshot.spo2DesatsCount = 4
        snapshot.glucoseMin = 80
        snapshot.glucoseMax = 165
        snapshot.glucoseCV = 18.5

        let pdfData = ReportGenerator.generatePDF(
            entries: [], doses: [], definitions: [],
            snapshots: [snapshot], cpapSessions: [],
            start: date, end: cal.date(byAdding: .day, value: 1, to: date)!
        )

        // UIGraphicsPDFRenderer compresses content streams with FlateDecode,
        // so a raw byte scan can't find the drawn text. Use PDFKit to extract
        // the rendered text from each page.
        let doc = try #require(PDFDocument(data: pdfData))
        var raw = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                raw += s
            }
        }
        #expect(raw.contains("Overnight Respiratory"))
        // SpO₂ half: each metric appears in its labeled context.
        #expect(raw.contains("87"))    // nadir
        #expect(raw.contains("T90"))   // T90 label
        #expect(raw.contains("desats")) // desats label
        // Glucose half — ensure the report doesn't silently stop rendering it.
        // Loose digit checks (the en-dash in "80–165" and rounding of 18.5
        // are both fragile across PDFKit text extraction).
        #expect(raw.contains("Glucose"))
        #expect(raw.contains("80"))
        #expect(raw.contains("165"))
        #expect(raw.contains("CV"))
    }
}
