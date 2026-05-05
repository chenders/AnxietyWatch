import Foundation
import HealthKit
import SwiftData

/// Pulls a day's worth of HealthKit data into a local HealthSnapshot for efficient trending.
/// Run daily on app foreground or via background task.
struct SnapshotAggregator {
    let healthKit: any HealthKitDataSource
    let modelContext: ModelContext

    /// Minimum SpO₂ sample count to compute T90 / desat stats. Below this we
    /// treat the data as spot-reading only (e.g., Apple Watch periodic checks)
    /// and emit nil rather than a misleading "good night" zero.
    static let minSamplesForOvernightStats = 30
    /// Minimum total *monitored* duration (seconds) for overnight SpO₂ stats —
    /// the sum of each sample's own duration, not the wall-clock span between
    /// first and last. 30 one-second samples scattered across half an hour
    /// would clear a span-based gate but only represent 30 seconds of actual
    /// monitoring; this gate excludes them.
    static let minMonitoredDurationForOvernightStats: TimeInterval = 300  // 5 minutes
    /// Minimum glucose sample count to compute SD / CV. Below this we emit nil
    /// (one or two finger-sticks aren't a variability measurement). Min/max
    /// are still emitted because a single reading is a meaningful extreme.
    static let minSamplesForGlucoseVariability = 4
    /// Minimum reading-spread (seconds) for glucose variability — `last.start`
    /// minus `first.start`. Glucose samples are typically point-in-time so
    /// "monitored duration" is meaningless; what matters is that the readings
    /// are spread across the day rather than clustered around one meal.
    static let minSpreadForGlucoseVariability: TimeInterval = 3600  // 1 hour

    /// Sum of each sample's own duration after collapsing overlaps. Use for
    /// sources where the question is "how much continuous monitoring data do
    /// we have?" — e.g., SpO₂ where 30 samples × 1s gives 30 seconds,
    /// regardless of how they're scattered in time. Overlaps are deduped via
    /// `Statistics.collapseOverlaps` so two sources recording the same 3
    /// minutes contribute 3 minutes of coverage, not 6.
    private static func totalMonitoredDuration(_ samples: [QuantitySample]) -> TimeInterval {
        Statistics.collapseOverlaps(samples)
            .reduce(0.0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
    }

    /// Span between the first and last sample's start times. Use for sources
    /// where the question is "how spread out across the day are the readings?"
    /// — e.g., glucose where samples are point-in-time and duration is moot.
    private static func sampleStartSpread(_ samples: [QuantitySample]) -> TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.start.timeIntervalSince(first.start))
    }

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
        async let spo2Nadir = healthKit.minimumQuantity(
            .oxygenSaturation, unit: .percent(),
            start: overnightStart, end: overnightEnd)
        async let spo2Samples = healthKit.quantitySamples(
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
        async let bp = healthKit.averageBloodPressure(start: start, end: end)
        // Glucose avg is derived locally from glucoseSamples below so it
        // shares the same .strictStartDate predicate as min/max/CV. Mixing
        // averageQuantity (overlap predicate) with quantitySamples-derived
        // stats lets a midnight-straddling sample contribute to the average
        // on both adjacent days but the range only on one — visually
        // breaks the chart when avg lands outside the day's min/max band.
        async let glucoseSamples = healthKit.quantitySamples(
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

        let skinTempValue = try await skinTemp
        snapshot.skinTempWrist = skinTempValue

        // Compute deviation from rolling 14-day baseline of raw wrist temps
        if let skinTempValue {
            let baselineWindow = 14
            if let cutoff = calendar.date(byAdding: .day, value: -baselineWindow, to: start) {
                let historical = try modelContext.fetch(
                    FetchDescriptor<HealthSnapshot>(
                        predicate: #Predicate { $0.date >= cutoff && $0.date < start }
                    )
                )
                let wristTemps = historical.compactMap(\.skinTempWrist)
                if wristTemps.count >= baselineWindow {
                    let mean = wristTemps.reduce(0, +) / Double(wristTemps.count)
                    snapshot.skinTempDeviation = skinTempValue - mean
                } else {
                    snapshot.skinTempDeviation = nil
                }
            } else {
                snapshot.skinTempDeviation = nil
            }
        } else {
            snapshot.skinTempDeviation = nil
        }

        snapshot.respiratoryRate = try await respiratoryRate
        if let spo2Value = try await spo2 {
            snapshot.spo2Avg = spo2Value * 100
        } else {
            snapshot.spo2Avg = nil
        }

        if let nadir = try await spo2Nadir {
            snapshot.spo2NadirOvernight = nadir * 100
        } else {
            snapshot.spo2NadirOvernight = nil
        }

        // T90 + rough desat count from raw overnight samples.
        // HealthKit stores SpO2 as a fraction 0–1; threshold 0.90 = 90%, 0.04 drop = 4% absolute.
        // Require BOTH enough samples AND enough total monitored duration.
        // Count alone catches Apple Watch spot reads (a few per night), but
        // a brief 30-sample 1 Hz burst, or 30 one-second samples scattered
        // across half an hour, would still clear a span-based gate. Summing
        // each sample's own duration captures what we actually care about:
        // how much continuous monitoring data exists.
        let spo2SamplesResolved = try await spo2Samples
        let spo2Monitored = Self.totalMonitoredDuration(spo2SamplesResolved)
        if spo2SamplesResolved.count >= Self.minSamplesForOvernightStats,
           spo2Monitored >= Self.minMonitoredDurationForOvernightStats {
            snapshot.spo2TimeBelow90Min = Statistics.timeBelowThresholdMinutes(
                spo2SamplesResolved, threshold: 0.90)
            snapshot.spo2DesatsCount = Statistics.countDesatEvents(
                spo2SamplesResolved, dropThreshold: 0.04, recoveryThreshold: 0.02)
        } else {
            snapshot.spo2TimeBelow90Min = nil
            snapshot.spo2DesatsCount = nil
        }

        if let s = try await steps { snapshot.steps = Int(s) }
        snapshot.activeCalories = try await calories
        if let e = try await exercise { snapshot.exerciseMinutes = Int(e) }

        snapshot.environmentalSoundAvg = try await envSound
        if let bpReading = try await bp {
            snapshot.bpSystolic = bpReading.systolic
            snapshot.bpDiastolic = bpReading.diastolic
        } else {
            snapshot.bpSystolic = nil
            snapshot.bpDiastolic = nil
        }
        let glucoseSamplesResolved = try await glucoseSamples
        let glucoseValues = glucoseSamplesResolved.map(\.value)
        // Avg is derived from the same sample set as min/max/CV so the
        // four glucose fields all share boundary semantics.
        snapshot.bloodGlucoseAvg = glucoseValues.isEmpty
            ? nil
            : glucoseValues.reduce(0, +) / Double(glucoseValues.count)
        // Min/max are meaningful with even a single reading; SD/CV require
        // both enough samples AND enough time-of-day spread to be a real
        // variability measurement. Four readings clustered around one meal
        // would otherwise export trivially low CV that reads as "stable"
        // instead of "insufficient daily coverage".
        snapshot.glucoseMin = glucoseValues.min()
        snapshot.glucoseMax = glucoseValues.max()
        let glucoseSpread = Self.sampleStartSpread(glucoseSamplesResolved)
        if glucoseValues.count >= Self.minSamplesForGlucoseVariability,
           glucoseSpread >= Self.minSpreadForGlucoseVariability {
            snapshot.glucoseStdDev = Statistics.stdDev(glucoseValues)
            snapshot.glucoseCV = Statistics.coefficientOfVariation(glucoseValues)
        } else {
            snapshot.glucoseStdDev = nil
            snapshot.glucoseCV = nil
        }

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

        // Stitch sensor-derived metrics (from watch sensor capture session)
        let spectrogramDescriptor = FetchDescriptor<AccelSpectrogram>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
        )
        let spectrograms = try modelContext.fetch(spectrogramDescriptor)
        if !spectrograms.isEmpty {
            let tremorValues = spectrograms.map(\.tremorBandPower)
            snapshot.tremorBandPowerAvg = tremorValues.reduce(0, +) / Double(tremorValues.count)
            let fidgetValues = spectrograms.map(\.fidgetBandPower)
            snapshot.fidgetIndexAvg = fidgetValues.reduce(0, +) / Double(fidgetValues.count)
        } else {
            snapshot.tremorBandPowerAvg = nil
            snapshot.fidgetIndexAvg = nil
        }

        let breathingDescriptor = FetchDescriptor<DerivedBreathingRate>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
        )
        let breathingRates = try modelContext.fetch(breathingDescriptor)
        if !breathingRates.isEmpty {
            let values = breathingRates.map(\.breathsPerMinute)
            snapshot.breathingRateAvg = values.reduce(0, +) / Double(values.count)
        } else {
            snapshot.breathingRateAvg = nil
        }

        // Nocturnal HR dip: midnight–6am HR vs 9am–9pm HR
        if let sixAM = calendar.date(byAdding: .hour, value: 6, to: start),
           let nineAM = calendar.date(byAdding: .hour, value: 9, to: start),
           let ninePM = calendar.date(byAdding: .hour, value: 21, to: start) {
            async let nightHR = healthKit.averageQuantity(
                .heartRate, unit: .count().unitDivided(by: .minute()),
                start: start, end: sixAM)
            async let dayHR = healthKit.averageQuantity(
                .heartRate, unit: .count().unitDivided(by: .minute()),
                start: nineAM, end: ninePM)

            if let nightVal = try await nightHR,
               let dayVal = try await dayHR,
               dayVal > 0 {
                snapshot.nocturnalHRDip = 1.0 - (nightVal / dayVal)
            } else {
                snapshot.nocturnalHRDip = nil
            }
        }

        try modelContext.save()
    }
}
