import Foundation
import HealthKit
import SwiftData

/// Pulls a day's worth of HealthKit data into a local HealthSnapshot for efficient trending.
/// Run daily on app foreground or via background task.
struct SnapshotAggregator {
    let healthKit: HealthKitManager
    let modelContext: ModelContext

    func aggregateDay(_ date: Date) async throws {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        // Find or create snapshot for this calendar day
        let existing = try modelContext.fetch(
            FetchDescriptor<HealthSnapshot>(
                predicate: #Predicate { $0.date == start }
            )
        )
        let snapshot = existing.first ?? HealthSnapshot(date: date)
        if existing.isEmpty {
            modelContext.insert(snapshot)
        }

        // HRV — best single autonomic biomarker
        snapshot.hrvAvg = try await healthKit.averageQuantity(
            .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            start: start, end: end
        )
        snapshot.hrvMin = try await healthKit.minimumQuantity(
            .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            start: start, end: end
        )

        // Resting heart rate
        snapshot.restingHR = try await healthKit.averageQuantity(
            .restingHeartRate,
            unit: .count().unitDivided(by: .minute()),
            start: start, end: end
        )

        // Sleep stages
        let sleep = try await healthKit.querySleepAnalysis(start: start, end: end)
        snapshot.sleepDurationMin = sleep.totalMinutes > 0 ? sleep.totalMinutes : nil
        snapshot.sleepDeepMin = sleep.deepMinutes > 0 ? sleep.deepMinutes : nil
        snapshot.sleepREMMin = sleep.remMinutes > 0 ? sleep.remMinutes : nil
        snapshot.sleepCoreMin = sleep.coreMinutes > 0 ? sleep.coreMinutes : nil
        snapshot.sleepAwakeMin = sleep.awakeMinutes > 0 ? sleep.awakeMinutes : nil

        // Overnight metrics
        snapshot.skinTempDeviation = try await healthKit.averageQuantity(
            .appleSleepingWristTemperature,
            unit: .degreeCelsius(),
            start: start, end: end
        )
        snapshot.respiratoryRate = try await healthKit.averageQuantity(
            .respiratoryRate,
            unit: .count().unitDivided(by: .minute()),
            start: start, end: end
        )
        snapshot.spo2Avg = try await healthKit.averageQuantity(
            .oxygenSaturation,
            unit: .percent(),
            start: start, end: end
        )

        // Activity
        if let steps = try await healthKit.cumulativeQuantity(
            .stepCount, unit: .count(), start: start, end: end
        ) {
            snapshot.steps = Int(steps)
        }
        snapshot.activeCalories = try await healthKit.cumulativeQuantity(
            .activeEnergyBurned,
            unit: .kilocalorie(),
            start: start, end: end
        )
        if let exercise = try await healthKit.cumulativeQuantity(
            .appleExerciseTime, unit: .minute(), start: start, end: end
        ) {
            snapshot.exerciseMinutes = Int(exercise)
        }

        // Environment
        snapshot.environmentalSoundAvg = try await healthKit.averageQuantity(
            .environmentalAudioExposure,
            unit: .decibelAWeightedSoundPressureLevel(),
            start: start, end: end
        )

        // Blood pressure (available if Omron cuff syncs via HealthKit)
        snapshot.bpSystolic = try await healthKit.averageQuantity(
            .bloodPressureSystolic,
            unit: .millimeterOfMercury(),
            start: start, end: end
        )
        snapshot.bpDiastolic = try await healthKit.averageQuantity(
            .bloodPressureDiastolic,
            unit: .millimeterOfMercury(),
            start: start, end: end
        )

        // Blood glucose (available if CGM syncs via HealthKit)
        snapshot.bloodGlucoseAvg = try await healthKit.averageQuantity(
            .bloodGlucose,
            unit: .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),
            start: start, end: end
        )

        try modelContext.save()
    }
}
