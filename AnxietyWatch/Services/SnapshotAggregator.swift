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

        // Noon-to-noon window captures a full overnight sleep period in one day's snapshot.
        // Sleep for "March 13" typically runs ~11 PM Mar 13 to ~7 AM Mar 14.
        // Querying noon Mar 13 to noon Mar 14 gets the whole night.
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: start),
              let overnightStart = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: previousDay)),
              let overnightEnd = calendar.date(byAdding: .hour, value: 12, to: start)
        else { return }

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

        // Run all HealthKit queries concurrently — they're independent reads
        // of different data types for the same time window.
        async let hrvAvg = healthKit.averageQuantity(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),
            start: start, end: end)
        async let hrvMin = healthKit.minimumQuantity(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli),
            start: start, end: end)
        async let restingHR = healthKit.averageQuantity(
            .restingHeartRate, unit: .count().unitDivided(by: .minute()),
            start: start, end: end)
        async let sleep = healthKit.querySleepAnalysis(
            start: overnightStart, end: overnightEnd)
        async let skinTemp = healthKit.averageQuantity(
            .appleSleepingWristTemperature, unit: .degreeCelsius(),
            start: overnightStart, end: overnightEnd)
        async let respiratoryRate = healthKit.averageQuantity(
            .respiratoryRate, unit: .count().unitDivided(by: .minute()),
            start: overnightStart, end: overnightEnd)
        async let spo2 = healthKit.averageQuantity(
            .oxygenSaturation, unit: .percent(),
            start: overnightStart, end: overnightEnd)
        async let steps = healthKit.cumulativeQuantity(
            .stepCount, unit: .count(), start: start, end: end)
        async let calories = healthKit.cumulativeQuantity(
            .activeEnergyBurned, unit: .kilocalorie(), start: start, end: end)
        async let exercise = healthKit.cumulativeQuantity(
            .appleExerciseTime, unit: .minute(), start: start, end: end)
        async let envSound = healthKit.averageQuantity(
            .environmentalAudioExposure, unit: .decibelAWeightedSoundPressureLevel(),
            start: start, end: end)
        async let bpSys = healthKit.averageQuantity(
            .bloodPressureSystolic, unit: .millimeterOfMercury(),
            start: start, end: end)
        async let bpDia = healthKit.averageQuantity(
            .bloodPressureDiastolic, unit: .millimeterOfMercury(),
            start: start, end: end)
        async let glucose = healthKit.averageQuantity(
            .bloodGlucose,
            unit: .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),
            start: start, end: end)
        async let vo2 = healthKit.mostRecentQuantity(
            .vo2Max, unit: HKUnit(from: "mL/kg*min"))
        async let walkingHR = healthKit.averageQuantity(
            .walkingHeartRateAverage, unit: .count().unitDivided(by: .minute()),
            start: start, end: end)
        async let steadiness = healthKit.mostRecentQuantity(
            .appleWalkingSteadiness, unit: .percent())
        async let afib = healthKit.mostRecentQuantity(
            .atrialFibrillationBurden, unit: .percent())
        async let headphone = healthKit.averageQuantity(
            .headphoneAudioExposure, unit: .decibelAWeightedSoundPressureLevel(),
            start: start, end: end)
        async let walkSpeed = healthKit.averageQuantity(
            .walkingSpeed, unit: HKUnit.meter().unitDivided(by: .second()),
            start: start, end: end)
        async let walkStepLen = healthKit.averageQuantity(
            .walkingStepLength, unit: .meter(), start: start, end: end)
        async let walkDoubleSupport = healthKit.averageQuantity(
            .walkingDoubleSupportPercentage, unit: .percent(),
            start: start, end: end)
        async let walkAsymmetry = healthKit.averageQuantity(
            .walkingAsymmetryPercentage, unit: .percent(),
            start: start, end: end)

        // Await all results and assign to snapshot
        snapshot.hrvAvg = try await hrvAvg
        snapshot.hrvMin = try await hrvMin
        snapshot.restingHR = try await restingHR

        let sleepData = try await sleep
        snapshot.sleepDurationMin = sleepData.totalMinutes > 0 ? sleepData.totalMinutes : nil
        snapshot.sleepDeepMin = sleepData.deepMinutes > 0 ? sleepData.deepMinutes : nil
        snapshot.sleepREMMin = sleepData.remMinutes > 0 ? sleepData.remMinutes : nil
        snapshot.sleepCoreMin = sleepData.coreMinutes > 0 ? sleepData.coreMinutes : nil
        snapshot.sleepAwakeMin = sleepData.awakeMinutes > 0 ? sleepData.awakeMinutes : nil

        snapshot.skinTempDeviation = try await skinTemp
        snapshot.respiratoryRate = try await respiratoryRate
        snapshot.spo2Avg = try await spo2

        if let s = try await steps { snapshot.steps = Int(s) }
        snapshot.activeCalories = try await calories
        if let e = try await exercise { snapshot.exerciseMinutes = Int(e) }

        snapshot.environmentalSoundAvg = try await envSound
        snapshot.bpSystolic = try await bpSys
        snapshot.bpDiastolic = try await bpDia
        snapshot.bloodGlucoseAvg = try await glucose

        if let v = try await vo2, v.date >= start && v.date < end {
            snapshot.vo2Max = v.value
        }

        snapshot.walkingHeartRateAvg = try await walkingHR

        if let s = try await steadiness, s.date >= start && s.date < end {
            snapshot.walkingSteadiness = s.value
        }
        if let a = try await afib, a.date >= start && a.date < end {
            snapshot.atrialFibrillationBurden = a.value
        }

        snapshot.headphoneAudioExposure = try await headphone
        snapshot.walkingSpeed = try await walkSpeed
        snapshot.walkingStepLength = try await walkStepLen
        snapshot.walkingDoubleSupportPct = try await walkDoubleSupport
        snapshot.walkingAsymmetryPct = try await walkAsymmetry

        // Time in daylight (cumulative daily total, like steps)
        if let daylight = try await healthKit.cumulativeQuantity(
            .timeInDaylight, unit: .minute(), start: start, end: end
        ) {
            snapshot.timeInDaylightMin = Int(daylight)
        }

        // Physical effort (daily average, unit: kcal/(kg*hr))
        snapshot.physicalEffortAvg = try await healthKit.averageQuantity(
            .physicalEffort,
            unit: .kilocalorie().unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .hour())),
            start: start, end: end
        )

        // Stitch CPAP data from CPAPSession (matched by date).
        // When duplicates exist (re-imports), pick the session with highest usage
        // for deterministic results — it represents the most complete therapy night.
        let cpapDescriptor = FetchDescriptor<CPAPSession>(
            predicate: #Predicate { $0.date == start }
        )
        let cpapSessions = try modelContext.fetch(cpapDescriptor)
        if let cpapSession = cpapSessions.max(by: { lhs, rhs in
            if lhs.totalUsageMinutes != rhs.totalUsageMinutes {
                return lhs.totalUsageMinutes < rhs.totalUsageMinutes
            }
            return lhs.ahi > rhs.ahi
        }) {
            snapshot.cpapAHI = cpapSession.ahi
            snapshot.cpapUsageMinutes = cpapSession.totalUsageMinutes
        } else {
            snapshot.cpapAHI = nil
            snapshot.cpapUsageMinutes = nil
        }

        // Stitch barometric data (average and change for the day)
        let barometricDescriptor = FetchDescriptor<BarometricReading>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
        )
        let barometricReadings = try modelContext.fetch(barometricDescriptor)
        if !barometricReadings.isEmpty {
            let pressures = barometricReadings.map(\.pressureKPa)
            snapshot.barometricPressureAvgKPa = pressures.reduce(0, +) / Double(pressures.count)
            if let minP = pressures.min(), let maxP = pressures.max() {
                snapshot.barometricPressureChangeKPa = maxP - minP
            }
        } else {
            snapshot.barometricPressureAvgKPa = nil
            snapshot.barometricPressureChangeKPa = nil
        }

        try modelContext.save()
    }
}
