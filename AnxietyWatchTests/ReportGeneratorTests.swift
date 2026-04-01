import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for ReportGenerator — verifies PDF output for various input combinations.
/// Tests focus on verifying the generator produces valid, non-empty PDF data
/// and handles edge cases (empty collections, mixed data) without crashing.
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
}
