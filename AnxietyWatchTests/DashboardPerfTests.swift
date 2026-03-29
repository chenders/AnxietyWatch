import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests that expensive computations used by the dashboard are fast enough
/// to avoid scroll jank when called per-render.
/// Serialized to prevent resource contention from skewing timing measurements.
@Suite(.serialized)
struct DashboardPerfTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            HealthSnapshot.self, AnxietyEntry.self, MedicationDose.self,
            MedicationDefinition.self, Prescription.self, Pharmacy.self,
            PharmacyCallLog.self, CPAPSession.self, BarometricReading.self,
            ClinicalLabResult.self, HealthSample.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Baseline calculation with 365 snapshots completes quickly")
    func baselinePerformance() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current

        // Insert 365 days of snapshots
        for day in 0..<365 {
            let date = calendar.date(byAdding: .day, value: -day, to: .now)!
            let snapshot = HealthSnapshot(date: date)
            snapshot.hrvAvg = Double.random(in: 30...60)
            snapshot.restingHR = Double.random(in: 55...75)
            context.insert(snapshot)
        }
        try context.save()

        let snapshots = try context.fetch(
            FetchDescriptor<HealthSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        )

        // Baseline computation should handle 365 snapshots without issue
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            _ = BaselineCalculator.hrvBaseline(from: snapshots)
            _ = BaselineCalculator.restingHRBaseline(from: snapshots)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 100 iterations of dual baseline on 365 snapshots should be under 1 second
        #expect(elapsed < 1.0, "Baseline calculation too slow: \(elapsed)s for 100 iterations")
    }

    @Test("Supply status computation with 200 prescriptions completes quickly")
    func supplyAlertPerformance() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current

        // Insert 200 prescriptions (simulating CapRx import)
        for i in 0..<200 {
            let rx = Prescription(
                rxNumber: "CRX-\(i)",
                medicationName: "Drug \(i % 10)",
                doseMg: 10.0,
                quantity: 30,
                dateFilled: calendar.date(byAdding: .day, value: -(i * 2), to: .now)!,
                estimatedRunOutDate: calendar.date(byAdding: .day, value: -(i * 2) + 30, to: .now)
            )
            context.insert(rx)
        }
        try context.save()

        let prescriptions = try context.fetch(
            FetchDescriptor<Prescription>(sortBy: [SortDescriptor(\.dateFilled, order: .reverse)])
        )

        let now = Date()
        let cutoff = calendar.date(
            byAdding: .day,
            value: -PrescriptionSupplyCalculator.alertStalenessLimitDays,
            to: now
        )

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            _ = prescriptions.filter { rx in
                let fillDate = rx.lastFillDate ?? rx.dateFilled
                if let cutoff, fillDate < cutoff { return false }
                let status = PrescriptionSupplyCalculator.supplyStatus(for: rx)
                return status == .low || status == .warning || status == .expired
            }.count
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 100 iterations of supply filtering on 200 prescriptions should be under 1 second
        #expect(elapsed < 1.0, "Supply alert computation too slow: \(elapsed)s for 100 iterations")
    }

    @Test("HealthSample grouping with 5000 samples completes quickly")
    func sampleGroupingPerformance() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let types = ["hr", "hrv", "spo2", "rr", "env", "head", "vo2", "walkHR", "rhr", "bpSys", "bpDia", "bg", "steady"]
        for i in 0..<5000 {
            let sample = HealthSample(
                type: types[i % types.count],
                value: Double.random(in: 50...100),
                timestamp: Date.now.addingTimeInterval(-Double(i) * 300)
            )
            context.insert(sample)
        }
        try context.save()

        let samples = try context.fetch(
            FetchDescriptor<HealthSample>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        )

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            _ = Dictionary(grouping: samples, by: \.type)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 100 iterations of grouping 5000 samples should be under 1 second
        #expect(elapsed < 1.0, "Sample grouping too slow: \(elapsed)s for 100 iterations")
    }
}
