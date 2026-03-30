import SwiftData
@testable import AnxietyWatch

/// Pre-built data sets for tests. All data uses ModelFactory
/// defaults and fictional values per project conventions.
enum SampleData {

    /// Seeds a ModelContext with 30 days of realistic data:
    /// - 30 HealthSnapshots with varying HRV, sleep, and activity
    /// - 15 AnxietyEntries at varying severities
    /// - 1 MedicationDefinition with 10 doses
    /// - 5 CPAPSessions
    /// - 3 BarometricReadings
    /// - 1 Pharmacy with 1 Prescription
    static func seed(into context: ModelContext) {
        let base = ModelFactory.referenceDate

        // 30 days of health snapshots with mild variance
        for day in 0..<30 {
            let date = ModelFactory.daysAgo(day, from: base)
            let snapshot = ModelFactory.healthSnapshot(
                date: date,
                hrvAvg: 40.0 + Double(day % 7) * 3.0,
                restingHR: 60.0 + Double(day % 5) * 2.0,
                sleepDurationMin: 360 + (day % 4) * 30,
                steps: 5000 + (day % 6) * 1500
            )
            context.insert(snapshot)
        }

        // 15 anxiety entries spread across 30 days
        for i in 0..<15 {
            let entry = ModelFactory.anxietyEntry(
                timestamp: ModelFactory.daysAgo(i * 2, from: base),
                severity: 3 + (i % 5),
                tags: i % 3 == 0 ? ["sleep"] : i % 3 == 1 ? ["work"] : []
            )
            context.insert(entry)
        }

        // One medication with 10 doses
        let med = ModelFactory.medicationDefinition(
            name: "Test Medication 50mg",
            category: "SSRI"
        )
        context.insert(med)

        for i in 0..<10 {
            let dose = ModelFactory.medicationDose(
                timestamp: ModelFactory.daysAgo(i * 3, from: base),
                medication: med
            )
            context.insert(dose)
        }

        // 5 CPAP sessions
        for i in 0..<5 {
            let session = ModelFactory.cpapSession(
                date: ModelFactory.daysAgo(i * 6, from: base),
                ahi: 1.5 + Double(i) * 0.5
            )
            context.insert(session)
        }

        // Barometric readings
        for i in 0..<3 {
            let reading = ModelFactory.barometricReading(
                timestamp: ModelFactory.daysAgo(i * 10, from: base),
                pressureKPa: 101.0 + Double(i) * 0.2
            )
            context.insert(reading)
        }

        // One pharmacy with one prescription
        let pharmacy = ModelFactory.pharmacy()
        context.insert(pharmacy)

        let rx = ModelFactory.prescription(
            medication: med,
            pharmacy: pharmacy
        )
        context.insert(rx)

        do {
            try context.save()
        } catch {
            preconditionFailure("SampleData.seed(into:) failed to save seeded data: \(error)")
        }
    }

    /// Creates a seeded in-memory container ready for use in tests or previews.
    static func makeSeededContainer() throws -> ModelContainer {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        seed(into: context)
        return container
    }
}
