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
