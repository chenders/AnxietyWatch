#if DEBUG
import Foundation
import SwiftData

/// Preview-friendly container with seeded data. Wraps the test helpers
/// for use in #Preview blocks. Compiled only in DEBUG builds.
enum PreviewHelpers {
    static func makeFullContainer() throws -> ModelContainer {
        let schema = Schema([
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
            Pharmacy.self,
            Prescription.self,
            PharmacyCallLog.self,
            HealthSample.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func makeSeededContainer() throws -> ModelContainer {
        let container = try makeFullContainer()
        let context = ModelContext(container)
        seedData(into: context)
        return container
    }

    private static func seedData(into context: ModelContext) {
        let base = Date(timeIntervalSince1970: 1_711_929_600) // 2024-04-01
        let calendar = Calendar.current

        for day in 0..<30 {
            let date = calendar.date(byAdding: .day, value: -day, to: base)!
            let snapshot = HealthSnapshot(date: date)
            snapshot.hrvAvg = 40.0 + Double(day % 7) * 3.0
            snapshot.restingHR = 60.0 + Double(day % 5) * 2.0
            snapshot.sleepDurationMin = 360 + (day % 4) * 30
            snapshot.respiratoryRate = 14.0 + Double(day % 3) * 0.5
            snapshot.steps = 5000 + (day % 6) * 1500
            context.insert(snapshot)
        }

        for i in 0..<15 {
            let entry = AnxietyEntry(
                timestamp: calendar.date(byAdding: .day, value: -(i * 2), to: base)!,
                severity: 3 + (i % 5),
                notes: "",
                tags: i % 3 == 0 ? ["sleep"] : i % 3 == 1 ? ["work"] : []
            )
            context.insert(entry)
        }

        let med = MedicationDefinition(
            name: "Test Medication 50mg",
            defaultDoseMg: 50.0,
            category: "SSRI"
        )
        context.insert(med)

        for i in 0..<10 {
            let dose = MedicationDose(
                timestamp: calendar.date(byAdding: .day, value: -(i * 3), to: base)!,
                medicationName: "Test Medication 50mg",
                doseMg: 50.0,
                isPRN: true,
                medication: med
            )
            context.insert(dose)
        }

        for i in 0..<5 {
            let session = CPAPSession(
                date: calendar.date(byAdding: .day, value: -(i * 6), to: base)!,
                ahi: 1.5 + Double(i) * 0.5,
                totalUsageMinutes: 420,
                leakRate95th: 18.0,
                pressureMin: 6.0,
                pressureMax: 12.0,
                pressureMean: 9.5,
                obstructiveEvents: 3,
                centralEvents: 1,
                hypopneaEvents: 2,
                importSource: "csv"
            )
            context.insert(session)
        }

        let pharmacy = Pharmacy(
            name: "Test Pharmacy #12345",
            address: "100 Example Blvd, Anytown, ST 00000",
            phoneNumber: "555-0100"
        )
        context.insert(pharmacy)

        let rx = Prescription(
            rxNumber: "9999999-00001",
            medicationName: "Test Medication 50mg",
            doseMg: 50.0,
            quantity: 30,
            refillsRemaining: 3,
            dateFilled: base,
            pharmacyName: "Test Pharmacy #12345",
            prescriberName: "Jane Smith MD",
            medication: med,
            pharmacy: pharmacy
        )
        context.insert(rx)

        do {
            try context.save()
        } catch {
            preconditionFailure("PreviewHelpers.seedData failed to save: \(error)")
        }
    }
}
#endif
