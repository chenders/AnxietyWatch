import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct PrescriptionImporterTests {

    @Test("Complete CapRx record maps all fields")
    func completeCapRxRecord() throws {
        let record: [String: Any] = [
            "rx_number": "CRX-12345",
            "medication_name": "Clonazepam 1mg",
            "dose_mg": 1.0 as Double,
            "dose_description": "1mg tablet",
            "quantity": 30 as Int,
            "refills_remaining": 0 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "pharmacy_name": "Test Pharmacy #12345",
            "ndc_code": "00000-0000-00",
            "rx_status": "paid",
            "import_source": "caprx",
            "days_supply": 30 as Int,
            "patient_pay": 10.0 as Double,
            "plan_pay": 45.5 as Double,
            "dosage_form": "tablet",
            "drug_type": "generic",
            "directions": "Take 1 tablet by mouth daily",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        #expect(rx.rxNumber == "CRX-12345")
        #expect(rx.medicationName == "Clonazepam 1mg")
        #expect(rx.daysSupply == 30)
        #expect(rx.patientPay == 10.0)
        #expect(rx.planPay == 45.5)
        #expect(rx.dosageForm == "tablet")
        #expect(rx.drugType == "generic")
        #expect(rx.directions == "Take 1 tablet by mouth daily")
    }

    @Test("Missing optional fields use defaults")
    func missingOptionalFields() throws {
        let record: [String: Any] = [
            "rx_number": "CRX-99999",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "import_source": "caprx",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        #expect(rx.daysSupply == nil)
        #expect(rx.patientPay == nil)
        #expect(rx.planPay == nil)
        #expect(rx.dosageForm == "")
        #expect(rx.drugType == "")
        #expect(rx.directions == "")
    }

    @Test("daysSupply used for run-out date when present")
    func daysSupplyUsedForRunOut() throws {
        let record: [String: Any] = [
            "rx_number": "CRX-77777",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 90 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "days_supply": 30 as Int,
            "import_source": "caprx",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        // Run-out should be based on daysSupply (30 days), not quantity (90)
        let expectedRunOut = Calendar.current.date(byAdding: .day, value: 30, to: rx.dateFilled)!
        #expect(rx.estimatedRunOutDate != nil)
        let diff = abs(rx.estimatedRunOutDate!.timeIntervalSince(expectedRunOut))
        #expect(diff < 86400) // within 1 day
    }

    @Test("Existing prescription is updated, not duplicated")
    func existingPrescriptionUpdated() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Insert first
        let record1: [String: Any] = [
            "rx_number": "CRX-55555",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record1, into: context)
        try context.save()

        // Update with new directions
        let record2: [String: Any] = [
            "rx_number": "CRX-55555",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "directions": "Take 1 tablet by mouth daily",
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record2, into: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Prescription>())
        #expect(all.count == 1)
        #expect(all.first?.directions == "Take 1 tablet by mouth daily")
    }

    @Test("Nil dailyDoseCount does not fabricate run-out date")
    func nilDailyDoseNoRunOut() throws {
        // No estimated_run_out_date, no days_supply, no daily_dose_count —
        // run-out should be nil rather than computed from a fabricated 1.0
        let record: [String: Any] = [
            "rx_number": "CRX-88888",
            "medication_name": "Test Med 25mg",
            "dose_mg": 25.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-06-01T00:00:00.000Z",
            "import_source": "caprx",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        #expect(rx.dailyDoseCount == nil)
        #expect(rx.estimatedRunOutDate == nil)
    }

    @Test("Providing dailyDoseCount computes run-out date")
    func dailyDoseCountComputesRunOut() throws {
        let record: [String: Any] = [
            "rx_number": "CRX-88889",
            "medication_name": "Test Med 25mg",
            "dose_mg": 25.0 as Double,
            "quantity": 30 as Int,
            "daily_dose_count": 1.0 as Double,
            "date_filled": "2024-06-01T00:00:00.000Z",
            "import_source": "caprx",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        #expect(rx.dailyDoseCount == 1.0)
        #expect(rx.estimatedRunOutDate != nil)
    }

    @Test("Re-sync with newer fill date advances dateFilled and lastFillDate")
    func reimportAdvancesFillDates() throws {
        // Regression (F-009): update() refreshed daysSupply/cost fields on
        // re-sync but never the fill dates, so effectiveRunOutDate combined a
        // stale fill date with the fresh supply duration after a refill.
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let record1: [String: Any] = [
            "rx_number": "7654321",
            "medication_name": "Test Med 10mg",
            "dose_mg": 10.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2026-01-01T00:00:00Z",
            "last_fill_date": "2026-01-01T00:00:00Z",
            "days_supply": 30 as Int,
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record1, into: context)
        try context.save()

        // Refill re-sync: newer fill dates and a different supply duration.
        let record2: [String: Any] = [
            "rx_number": "7654321",
            "medication_name": "Test Med 10mg",
            "dose_mg": 10.0 as Double,
            "quantity": 90 as Int,
            "date_filled": "2026-03-02T00:00:00Z",
            "last_fill_date": "2026-03-02T00:00:00Z",
            "days_supply": 90 as Int,
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record2, into: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Prescription>())
        #expect(all.count == 1)
        let rx = try #require(all.first)

        let iso = ISO8601DateFormatter()
        let newFill = try #require(iso.date(from: "2026-03-02T00:00:00Z"))
        #expect(abs(rx.dateFilled.timeIntervalSince(newFill)) < 1)
        let lastFill = try #require(rx.lastFillDate)
        #expect(abs(lastFill.timeIntervalSince(newFill)) < 1)
        #expect(rx.daysSupply == 90)
    }

    @Test("Re-sync omitting fill dates preserves existing dates")
    func reimportWithoutFillDatesPreservesExisting() throws {
        // A record that omits date_filled / last_fill_date must not null-out
        // or reset the dates the prescription already carries.
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let record1: [String: Any] = [
            "rx_number": "9999999-00001",
            "medication_name": "Test Med 10mg",
            "dose_mg": 10.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2026-01-01T00:00:00Z",
            "last_fill_date": "2026-01-01T00:00:00Z",
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record1, into: context)
        try context.save()

        let record2: [String: Any] = [
            "rx_number": "9999999-00001",
            "medication_name": "Test Med 10mg",
            "dose_mg": 10.0 as Double,
            "quantity": 30 as Int,
            "days_supply": 30 as Int,
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record2, into: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Prescription>())
        #expect(all.count == 1)
        let rx = try #require(all.first)

        let iso = ISO8601DateFormatter()
        let originalFill = try #require(iso.date(from: "2026-01-01T00:00:00Z"))
        // dateFilled must remain the original — in particular not reset to .now.
        #expect(abs(rx.dateFilled.timeIntervalSince(originalFill)) < 1)
        let lastFill = try #require(rx.lastFillDate)
        #expect(abs(lastFill.timeIntervalSince(originalFill)) < 1)
    }

    @Test("Record missing rx_number throws")
    func missingRxNumberThrows() throws {
        let record: [String: Any] = [
            "medication_name": "Test Med",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(throws: PrescriptionImporter.ImportError.self) {
            try PrescriptionImporter.importRecord(record, into: context)
        }
    }
}
