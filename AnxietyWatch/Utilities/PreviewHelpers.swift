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
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
            // Needed by TrendsView's live-oximeter @Query and the
            // EMAYLiveView preview's persistence context.
            QuantityHealthSample.self,
            // Needed by CNSMonitoringView's preview, which constructs a
            // CNSMonitoringCoordinator against this container (klaxon Phase 2).
            MonitoringSession.self,
            CNSRiskSampleRecord.self,
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
            dateFilled: base,
            pharmacyName: "Test Pharmacy #12345",
            medication: med,
            pharmacy: pharmacy
        )
        context.insert(rx)

        seedHRVData(into: context)

        do {
            try context.save()
        } catch {
            preconditionFailure("PreviewHelpers.seedData failed to save: \(error)")
        }
    }

    private static func seedHRVData(into context: ModelContext) {
        let now = Date(timeIntervalSince1970: 1_711_929_600) // 2024-04-01
        let calendar = Calendar.current

        for nightIdx in 0..<4 {
            let dayOffset = -(nightIdx * 3 + 1)
            let bedTime = calendar.date(byAdding: .day, value: dayOffset, to: now)!
                .addingTimeInterval(-5 * 3600)
            let durationMinutes = 300 + nightIdx * 30
            let session = SensorSession(startTime: bedTime, batteryAtStart: 85)
            session.endTime = bedTime.addingTimeInterval(Double(durationMinutes) * 60)
            session.source = PolarHRMService.sourceLabel
            context.insert(session)

            let hfBaseline = 50.0 + Double(nightIdx) * 6
            let lfBaseline = hfBaseline * 1.8
            for minute in 0..<durationMinutes {
                let ts = bedTime.addingTimeInterval(Double(minute) * 60)
                let isSentinel = (minute % 25) == 0
                let hf = isSentinel ? 0 : hfBaseline + sin(Double(minute) / 30) * 12
                let lf = isSentinel ? 0 : lfBaseline + cos(Double(minute) / 30) * 22
                let ratio = (isSentinel || hf == 0) ? 0 : lf / hf
                context.insert(HRVReading(
                    timestamp: ts,
                    rmssd: 40, sdnn: 50, pnn50: 10,
                    lfPower: lf, hfPower: hf, lfHfRatio: ratio,
                    sensorSessionID: session.id,
                    source: PolarHRMService.sourceLabel
                ))
            }
        }

        let manualStart = calendar.date(byAdding: .hour, value: -3, to: now)!
        let manualSession = SensorSession(startTime: manualStart, batteryAtStart: 90)
        manualSession.endTime = manualStart.addingTimeInterval(10 * 60)
        manualSession.source = PolarHRMService.sourceLabel
        context.insert(manualSession)
        for minute in 0..<10 {
            context.insert(HRVReading(
                timestamp: manualStart.addingTimeInterval(Double(minute) * 60),
                rmssd: 35, sdnn: 45, pnn50: 8,
                lfPower: 80, hfPower: 35, lfHfRatio: 2.3,
                sensorSessionID: manualSession.id,
                source: PolarHRMService.sourceLabel
            ))
        }
    }
}
#endif
