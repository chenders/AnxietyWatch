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

        // Source-precedence override: when a high-fidelity device covers
        // the window (EMAY/Wellue oximeter for overnight SpO2, Polar H10
        // for HR/RHR/HRV), recompute the corresponding aggregate from the
        // preferred subset only and overwrite the HealthKit-direct value
        // above. Layered ON TOP of the HK path rather than replacing it
        // so existing HealthKit-mock test coverage stays intact: when no
        // preferred SwiftData rows exist for the window, the HK-direct
        // value remains the snapshot's authoritative value.
        //
        // Order matters: SpO2 first (uses overnight window), then daily
        // heart metrics (use full day window). The two windows can overlap
        // but the fetches are filtered by metricType so they're disjoint.
        try applyOvernightSpO2Precedence(
            on: snapshot, overnightStart: overnightStart, overnightEnd: overnightEnd
        )
        try applyDailyHeartMetricsPrecedence(
            on: snapshot, start: start, end: end
        )

        // Compute reliability + source-summary JSON from the local SwiftData
        // mirror of `QuantityHealthSample` rows. Reliability/source metadata
        // is derived from the local mirror — the authoritative source for
        // source/device fields.
        snapshot.dataQuality = try computeDataQuality(
            dayStart: start, dayEnd: end,
            overnightStart: overnightStart, overnightEnd: overnightEnd
        )

        try modelContext.save()
    }

    // MARK: - Source-precedence overrides

    /// Replace HealthKit-direct SpO2 aggregates with values computed from
    /// the high-fidelity tier (EMAY/Wellue oximeters) when those samples
    /// cover the overnight window. Also always populates
    /// `spo2NadirOpportunistic` so the trends chart can show the Apple
    /// Watch line independently.
    ///
    /// No-op when no high-fidelity samples exist for the window: the HK-
    /// direct values (which in that case were already all-opportunistic)
    /// remain the snapshot's authoritative value.
    private func applyOvernightSpO2Precedence(
        on snapshot: HealthSnapshot,
        overnightStart: Date,
        overnightEnd: Date
    ) throws {
        let spo2Type = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        // Date-only predicate + in-memory metricType filter. A compound
        // `&&` predicate with a captured `String` local (here `spo2Type`)
        // can trip the iOS 26 SwiftData footgun documented in CLAUDE.md
        // (`+[_NSPredicateUtilities _predicateEnforceRestrictionsOnSelector:…]`
        // hang during SQL ORDER BY generation, scene-update watchdog
        // `0x8BADF00D`). Keep the predicate single-table-of-comparisons
        // on indexed primitive `Date` fields and filter strings post-fetch.
        let descriptor = FetchDescriptor<QuantityHealthSample>(
            predicate: #Predicate {
                $0.timestamp >= overnightStart && $0.timestamp < overnightEnd
            }
        )
        let windowRows = try modelContext.fetch(descriptor)
        let rows = windowRows.filter { $0.metricType == spo2Type }
        let parts = DeviceProvenance.partition(samples: rows, metricType: spo2Type)

        // Opportunistic nadir is always reported when any opportunistic
        // samples exist — it feeds the trends chart's Apple Watch line
        // regardless of whether a preferred source also covers the window.
        let opportunisticValues = parts.opportunistic.map(\.value)
        snapshot.spo2NadirOpportunistic = opportunisticValues.min().map { $0 * 100 }

        // No preferred-tier samples → keep the HK-direct values, which are
        // already opportunistic-only in this case.
        guard !parts.preferred.isEmpty else { return }

        // Recompute avg + nadir from the preferred tier alone.
        let preferredValues = parts.preferred.map(\.value)
        let preferredAvg = preferredValues.reduce(0, +) / Double(preferredValues.count)
        snapshot.spo2Avg = preferredAvg * 100
        if let preferredNadir = preferredValues.min() {
            snapshot.spo2NadirOvernight = preferredNadir * 100
        }

        // T90 + desat count need start/end intervals. Synthesize 1-second
        // intervals — overnight oximeters write at 1 Hz so this matches
        // both the cadence and what HealthKit reports for the same writes.
        let preferredQS = parts.preferred.map { sample in
            QuantitySample(
                start: sample.timestamp,
                end: sample.timestamp.addingTimeInterval(1.0),
                value: sample.value
            )
        }
        let monitored = Self.totalMonitoredDuration(preferredQS)
        if preferredQS.count >= Self.minSamplesForOvernightStats,
           monitored >= Self.minMonitoredDurationForOvernightStats {
            snapshot.spo2TimeBelow90Min = Statistics.timeBelowThresholdMinutes(
                preferredQS, threshold: 0.90
            )
            snapshot.spo2DesatsCount = Statistics.countDesatEvents(
                preferredQS, dropThreshold: 0.04, recoveryThreshold: 0.02
            )
        } else {
            snapshot.spo2TimeBelow90Min = nil
            snapshot.spo2DesatsCount = nil
        }
    }

    /// Replace HealthKit-direct HR/RHR/HRV aggregates with values from the
    /// chest-strap tier (Polar H10) when present for the day. Each metric
    /// is handled independently — Polar might cover HR but not HRV on a
    /// given day, in which case only HR is overridden.
    ///
    /// No-op for metrics whose preferred subset is empty: the HK-direct
    /// value is kept.
    private func applyDailyHeartMetricsPrecedence(
        on snapshot: HealthSnapshot,
        start: Date,
        end: Date
    ) throws {
        let hrType = HKQuantityTypeIdentifier.heartRate.rawValue
        let rhrType = HKQuantityTypeIdentifier.restingHeartRate.rawValue
        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        let wantedMetrics: Set<String> = [hrType, rhrType, hrvType]

        // Date-only predicate + in-memory metricType filter — same iOS 26
        // SwiftData footgun avoidance as `applyOvernightSpO2Precedence`.
        // Captured `String` locals inside a compound `#Predicate &&` clause
        // can hang the main thread during SQL ORDER BY generation; keep
        // the predicate restricted to indexed primitive `Date` comparisons
        // and partition by metric type in memory.
        let descriptor = FetchDescriptor<QuantityHealthSample>(
            predicate: #Predicate {
                $0.timestamp >= start && $0.timestamp < end
            }
        )
        let windowRows = try modelContext.fetch(descriptor)
        let rows = windowRows.filter { wantedMetrics.contains($0.metricType) }
        let byMetric = Dictionary(grouping: rows, by: \.metricType)

        // HRV — preferred subset, mean of SDNN values (already stored in ms
        // by the HealthKit mirror).
        if let hrv = byMetric[hrvType] {
            let parts = DeviceProvenance.partition(samples: hrv, metricType: hrvType)
            if !parts.preferred.isEmpty {
                let vals = parts.preferred.map(\.value)
                snapshot.hrvAvg = vals.reduce(0, +) / Double(vals.count)
                snapshot.hrvMin = vals.min()
            }
        }

        // Resting HR — preferred subset, mean. Apple Watch writes one
        // daily value; Polar samples could be more numerous over a session.
        if let rhr = byMetric[rhrType] {
            let parts = DeviceProvenance.partition(samples: rhr, metricType: rhrType)
            if !parts.preferred.isEmpty {
                let vals = parts.preferred.map(\.value)
                snapshot.restingHR = vals.reduce(0, +) / Double(vals.count)
            }
        }

        // Plain HR is fetched alongside RHR/HRV (cheaper than three
        // separate descriptors) but not stored as a snapshot field —
        // only the nocturnal-dip ratio uses raw HR aggregates. When
        // an HR-mean column lands, fetch the partition for `hrType`
        // and overwrite here.
    }

    /// Build the `dataQuality` JSON object describing reliability tier + source
    /// breakdown per metric family for this day. Always emits a key per
    /// family — when no samples are present, the family is `insufficient`
    /// with empty `sources`. Keys are sorted for deterministic output.
    private func computeDataQuality(
        dayStart: Date, dayEnd: Date,
        overnightStart: Date, overnightEnd: Date
    ) throws -> String? {
        // Day-window samples (most metrics)
        let dayDescriptor = FetchDescriptor<QuantityHealthSample>(
            predicate: #Predicate { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        )
        let daySamples = try modelContext.fetch(dayDescriptor)

        // Overnight-window samples (SpO2). Fetched separately because the
        // overnight noon-to-noon window straddles two calendar days. Filtered
        // to oxygen saturation only — this fetch only feeds the spo2 family,
        // so pulling other metrics is wasted I/O.
        let spo2MetricType = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        let overnightDescriptor = FetchDescriptor<QuantityHealthSample>(
            predicate: #Predicate {
                $0.timestamp >= overnightStart
                    && $0.timestamp < overnightEnd
                    && $0.metricType == spo2MetricType
            }
        )
        let overnightSamples = try modelContext.fetch(overnightDescriptor)

        // Bucket samples by metricType identifier raw value.
        let byType = Dictionary(grouping: daySamples, by: \.metricType)
        let overnightByType = Dictionary(grouping: overnightSamples, by: \.metricType)

        func group(_ id: HKQuantityTypeIdentifier, source: [String: [QuantityHealthSample]]) -> [QuantityHealthSample] {
            source[id.rawValue] ?? []
        }

        // Build family entries. Each entry: [reliability, sources(bundleID:count)].
        var families: [String: [String: Any]] = [:]

        func emit(_ family: String, samples: [QuantityHealthSample], reliability: Reliability) {
            var sources: [String: Int] = [:]
            for s in samples {
                sources[s.sourceBundleID, default: 0] += 1
            }
            families[family] = [
                "reliability": reliability.rawValue,
                "sources": sources
            ]
        }

        let glucose = group(.bloodGlucose, source: byType)
        emit("glucose", samples: glucose, reliability: .glucoseDaily(samples: glucose))

        let spo2 = group(.oxygenSaturation, source: overnightByType)
        emit("spo2", samples: spo2, reliability: .spo2Overnight(samples: spo2))

        let hr = group(.heartRate, source: byType)
        emit("hr", samples: hr, reliability: .heartRate(samples: hr))

        // HRV/RHR/RR/wrist temp use per-metric classifiers because Apple
        // Watch writes them at very different cadences than HR (which logs
        // minute-by-minute). Reusing `Reliability.heartRate`'s ≥50 threshold
        // would make every other Watch-derived metric look "medium" forever.
        let hrv = group(.heartRateVariabilitySDNN, source: byType)
        emit("hrv", samples: hrv, reliability: .hrv(samples: hrv))

        let rhr = group(.restingHeartRate, source: byType)
        emit("rhr", samples: rhr, reliability: .restingHR(samples: rhr))

        let rr = group(.respiratoryRate, source: byType)
        emit("rr", samples: rr, reliability: .respiratoryRate(samples: rr))

        // Blood pressure: combine systolic + diastolic into one family.
        let bpSamples = group(.bloodPressureSystolic, source: byType) +
                        group(.bloodPressureDiastolic, source: byType)
        emit("bp", samples: bpSamples, reliability: .bloodPressure(samples: bpSamples))

        // Wrist temp: Apple Watch writes one nightly value, so any
        // Apple-Watch-sourced sample is high reliability.
        let wrist = group(.appleSleepingWristTemperature, source: byType)
        emit("wristTemp", samples: wrist, reliability: .wristTemperature(samples: wrist))

        // Body temperature, weight: medical-device model (same as BP).
        let bodyTemp = group(.bodyTemperature, source: byType)
        emit("bodyTemp", samples: bodyTemp, reliability: .bloodPressure(samples: bodyTemp))

        let weight = group(.bodyMass, source: byType)
        emit("weight", samples: weight, reliability: .bloodPressure(samples: weight))

        guard let data = try? JSONSerialization.data(
            withJSONObject: families, options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
