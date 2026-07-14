import Foundation
import HealthKit
import os
import SwiftData

/// Pulls a day's worth of HealthKit data into a local HealthSnapshot for efficient trending.
/// Run daily on app foreground or via background task.
struct SnapshotAggregator {
    let healthKit: any HealthKitDataSource
    let modelContext: ModelContext

    /// Backing store for the `RestoreMigrationGate` check in `aggregateDay`.
    /// Injectable so tests can exercise the gate against an isolated suite
    /// rather than mutating `.standard` (which would leak across tests and,
    /// in the simulator, across runs).
    var defaults: UserDefaults = .standard

    /// The overnight window runs noon-to-noon: `snapshot.date`'s morning is
    /// the window's end, offset ±12 h from local start-of-day. Shared so
    /// consumers that re-derive "last night" (e.g.
    /// `DashboardViewModel.lastNightEvents`) can't drift from the
    /// aggregator's convention.
    static let overnightOffsetHours = 12

    /// The calendar days whose snapshots can be affected by samples in
    /// `range` — one `aggregateDay` call per returned day. Walks
    /// `startOfDay(lowerBound)` through `startOfDay(upperBound) + 1 day`:
    /// the extra trailing day matters because `aggregateDay(D)`'s overnight
    /// window is `[noon D-1, noon D)`, so a sample recorded in the EVENING
    /// of day D lands in day D+1's snapshot. Import backfill loops that
    /// stepped raw timestamps by 24 h missed exactly that morning-after day
    /// for overnight EMAY files (bedtime 22:30 → dateRange upper 06:15 next
    /// day: one iteration at 22:30, then 22:30+1d > 06:15, loop over —
    /// the only day whose window held the samples never aggregated).
    /// `aggregateDay` is an idempotent upsert, so the extra day is harmless
    /// for day-aligned (CPAP) ranges.
    static func backfillDays(covering range: ClosedRange<Date>) -> [Date] {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: range.lowerBound)
        guard let end = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: range.upperBound)
        ) else { return [first] }
        var days: [Date] = []
        var date = first
        while date <= end {
            days.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return days
    }

    /// How many days BEFORE today each refresh re-aggregates, so data that
    /// lands in HealthKit after a day's last aggregation still reaches that
    /// day's snapshot. Two covers the known late-arrival patterns for daily
    /// (≤1-day-gap) usage: last night's sleep/RR sync from the Watch AFTER
    /// the typical early-morning app open (re-visiting today and yesterday),
    /// and Apple writing a day's final resting-HR sample near midnight — a
    /// day whose evening the app never saw gets its RHR on the aggregation
    /// after next (day-2). Away-gaps LONGER than this lookback are healed by
    /// `HealthDataCoordinator.gapDates`, whose walk starts AT the last
    /// existing snapshot's own day; "Rebuild All History" in Settings
    /// remains the manual catch-all. See the 2026-07 "Trends empty"
    /// investigation: every snapshot field arriving later than the day's
    /// last aggregation was silently frozen out, for months.
    static let recentAggregationLookbackDays = 2

    /// The calendar days a refresh should (re-)aggregate: today and the
    /// `lookbackDays` before it, each normalized to `startOfDay`, ordered
    /// oldest → newest so today aggregates last with the freshest inputs.
    static func recentAggregationDays(
        endingAt now: Date,
        lookbackDays: Int = recentAggregationLookbackDays,
        calendar: Calendar = .current
    ) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0...max(0, lookbackDays)).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    /// Re-aggregate today plus the trailing look-back days. Idempotent:
    /// `aggregateDay` is an upsert whose fingerprint check only marks rows
    /// dirty when a value actually changed, so re-visiting an unchanged day
    /// costs queries but no sync traffic. Checks for cancellation between
    /// days so the BG-refresh expiration handler can cut the walk short.
    /// Each `aggregateDay` call re-checks the authorization status itself
    /// (one extra round trip per day) — intentional redundancy, since
    /// `aggregateDay` has direct callers (gap-fill, backfill, rebuild) that
    /// need the gate regardless of this walk.
    func aggregateRecentDays(endingAt now: Date) async throws {
        for day in Self.recentAggregationDays(endingAt: now) {
            guard !Task.isCancelled else { return }
            try await aggregateDay(day)
        }
    }

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
        // Do not write snapshots while the restore-vs-fresh decision is still
        // pending. A snapshot row is one of the tables `restoreGuardTablesAreEmpty`
        // checks, so writing even ONE here makes the store "non-empty" and
        // permanently blocks the restore that the migration gate exists to enable
        // — the user is then stuck with no way out but deleting the app.
        //
        // This was a real failure on a fresh install after the bundle-ID rename:
        // the gate correctly deferred `setupIfNeeded()`, but a snapshot got written
        // anyway (observer/refresh path), and every restore attempt then failed with
        // "Local store already contains data" on a store the user had never touched.
        // Deferring setup is not enough on its own; the WRITE has to be gated too.
        //
        // Both "Restore from Server" (on success) and "Start Fresh" resolve the gate,
        // and an existing non-empty store auto-resolves it at launch, so this only
        // suppresses writes inside the narrow pre-decision window.
        guard RestoreMigrationGate.isResolved(defaults: defaults) else { return }

        // While HealthKit authorization has never been REQUESTED, every read
        // errors with code 5 (authorizationNotDetermined), which the query
        // layer coerces to nil — indistinguishable from "no data" — and the
        // unconditional HealthKit field assignments below would overwrite
        // real (e.g. server-restored) values with nils. This is the asymmetry
        // rule from the CNS engine applied here: "can't assess" must never be
        // written down as "no data". The flag scopes the skip to the
        // HealthKit-derived block ONLY: CPAP, barometric, sensor-derived,
        // precedence, and dataQuality stitching read SwiftData, not
        // HealthKit, and must keep aggregating for a user whose
        // authorization sheet is still unanswered. After the sheet has been
        // answered (even with everything denied), reads legitimately return
        // empty and full aggregation semantics apply.
        let healthKitAuthorizationPending = await healthKit.authorizationNeedsRequest()

        #if DEBUG && targetEnvironment(simulator)
        // Skip aggregation when the app was launched with
        // `-autoRestoreFromServer` (server-restored data) or `-seedDemoData`
        // (synthetic demo data). In both cases the snapshots were written by
        // something other than HealthKit, and the aggregator would otherwise
        // overwrite those fields with nils derived from the (empty)
        // on-simulator HealthKit store — the "data appears then disappears"
        // flicker.
        if RestoreDemoMode.isActive || SeedDemoMode.isActive {
            return
        }
        #endif
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        // Noon-to-noon window captures a full overnight sleep period in one day's snapshot.
        // Sleep for "March 13" typically runs ~11 PM Mar 13 to ~7 AM Mar 14.
        // Querying noon Mar 13 to noon Mar 14 gets the whole night.
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: start),
              let overnightStart = calendar.date(
                  bySettingHour: Self.overnightOffsetHours, minute: 0, second: 0, of: previousDay
              ),
              let overnightEnd = calendar.date(
                  bySettingHour: Self.overnightOffsetHours, minute: 0, second: 0, of: start
              )
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

        // Capture the row's aggregate-field state BEFORE we overwrite it, so
        // we can flip `syncedToServer` only when an aggregation actually
        // changes a value. Without this guard, the trailing-day snapshots
        // (re-aggregated on every observer trigger, app launch, and BG
        // refresh via `aggregateRecentDays`) would be re-uploaded on every
        // sync even when no inputs changed, producing persistent extra sync
        // traffic for unchanged days. A new snapshot's fingerprint is
        // all-nil; if aggregation puts values in, the diff is non-trivial
        // and dirty fires correctly.
        let preAggregateFingerprint = SnapshotFingerprint(from: snapshot)

        if healthKitAuthorizationPending {
            // Reduced pass: skip every HealthKit read (each would nil-coerce
            // code 5) so the HealthKit-derived fields keep whatever values
            // they already hold, but still stitch the SwiftData-sourced
            // inputs and finalize normally.
            try stitchNonHealthKitSources(into: snapshot, dayStart: start, dayEnd: end)
            try await applySourcePrecedenceAndDataQuality(
                on: snapshot, dayStart: start, dayEnd: end,
                overnightStart: overnightStart, overnightEnd: overnightEnd
            )
            try finalizeAggregation(of: snapshot, preAggregateFingerprint: preAggregateFingerprint)
            return
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

        try stitchNonHealthKitSources(into: snapshot, dayStart: start, dayEnd: end)

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

        try await applySourcePrecedenceAndDataQuality(
            on: snapshot, dayStart: start, dayEnd: end,
            overnightStart: overnightStart, overnightEnd: overnightEnd
        )

        try finalizeAggregation(of: snapshot, preAggregateFingerprint: preAggregateFingerprint)
    }

    // MARK: - Aggregation passes shared by the full and reduced paths

    /// Stitch the SwiftData-sourced inputs into the snapshot: CPAP summary,
    /// barometric aggregates, and watch-sensor-derived metrics. Runs on every
    /// aggregation pass — including the reduced pass taken while HealthKit
    /// authorization is still unrequested — because none of these read
    /// HealthKit.
    private func stitchNonHealthKitSources(
        into snapshot: HealthSnapshot, dayStart start: Date, dayEnd end: Date
    ) throws {
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
            // Deterministic tie-break among same-usage duplicates. An unknown
            // AHI (nil, F-094) is treated as +∞ so a scored night always wins
            // the tie — a nil must never displace a measured AHI when both
            // exist for the same date. Comparison-only; the chosen session's
            // actual (possibly nil) AHI is what propagates to the snapshot.
            return (lhs.ahi ?? .infinity) > (rhs.ahi ?? .infinity)
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
        try Self.applySensorDerivedMetrics(
            to: snapshot, dayStart: start, dayEnd: end, context: modelContext
        )
    }

    /// Source-precedence override: when a high-fidelity device covers
    /// the window (EMAY/Wellue oximeter for overnight SpO2, Polar H10
    /// for HR/RHR/HRV), recompute the corresponding aggregate from the
    /// preferred subset only and overwrite the HealthKit-direct value
    /// assigned in `aggregateDay`. Layered ON TOP of the HK path rather
    /// than replacing it so existing HealthKit-mock test coverage stays
    /// intact: when no preferred SwiftData rows exist for the window, the
    /// HK-direct value remains the snapshot's authoritative value. Derives
    /// everything from the local `QuantityHealthSample` mirror — never
    /// HealthKit directly — so it also runs on the reduced
    /// authorization-pending pass.
    ///
    /// Order matters: SpO2 first, then heart metrics. Both precedence
    /// passes use the overnight noon-to-noon window: chest-strap sessions
    /// are overnight recordings, and bucketing them by calendar day split
    /// a midnight-crossing session across two snapshots — each day's
    /// hrvAvg mixing fragments of two different nights, disagreeing with
    /// the same row's sleep fields and the Trends Polar series (F-046).
    /// The HK-direct hrv/rhr fallbacks keep their calendar-day
    /// convention (Watch spot samples are day-attributed by HealthKit).
    private func applySourcePrecedenceAndDataQuality(
        on snapshot: HealthSnapshot,
        dayStart start: Date, dayEnd end: Date,
        overnightStart: Date, overnightEnd: Date
    ) async throws {
        // Tag the SpO₂ source basis (F-092). At this point avg/nadir/T90/desats
        // are the HealthKit-direct mixed-source values, so default both bases
        // to `.mixed` for whichever group was actually computed. The
        // precedence override below upgrades a group to `.oximeter` only when
        // it recomputes that group from the dedicated-oximeter subset — so a
        // group left un-upgraded stays honestly `.mixed`, and the two bases
        // can legitimately diverge (an oximeter nadir alongside a mixed T90).
        snapshot.spo2AggregateBasis =
            (snapshot.spo2Avg != nil || snapshot.spo2NadirOvernight != nil) ? .mixed : nil
        snapshot.spo2BurdenBasis =
            (snapshot.spo2TimeBelow90Min != nil || snapshot.spo2DesatsCount != nil) ? .mixed : nil

        try await applyOvernightSpO2Precedence(
            on: snapshot, overnightStart: overnightStart, overnightEnd: overnightEnd
        )

        // Single QuantityHealthSample fetch spanning the union of the two
        // windows this method's helpers need: the overnight window
        // [overnightStart, overnightEnd) for heart-metrics precedence and the
        // calendar-day window [start, end) for data quality. Because
        // overnightStart < start < overnightEnd < end, that union is simply
        // [overnightStart, end). Both helpers filter this array in-memory to
        // their own sub-window, replacing three overlapping fetches (heart
        // metrics + data-quality day + data-quality overnight-SpO2, the last a
        // subset of the first) with one materialization (F-055).
        // Live EMAY BLE rows are excluded from the union before it feeds
        // heart-metric precedence and data quality: their bundle ID is
        // deliberately outside every DeviceProvenance tier, so counting them
        // would (a) leave HR/SpO₂ aggregates open to double-counting once the
        // same night's CSV import lands and (b) dilute the reliability
        // classifiers' recognized-source share with rows they can't classify.
        // See `excludingLiveOximeterRows`.
        let sampleUnion = Self.excludingLiveOximeterRows(try modelContext.fetch(
            FetchDescriptor<QuantityHealthSample>(
                predicate: #Predicate { $0.timestamp >= overnightStart && $0.timestamp < end }
            )
        ))

        try applyDailyHeartMetricsPrecedence(
            on: snapshot, samples: sampleUnion, start: overnightStart, end: overnightEnd
        )

        // Compute reliability + source-summary JSON from the local SwiftData
        // mirror of `QuantityHealthSample` rows. Reliability/source metadata
        // is derived from the local mirror — the authoritative source for
        // source/device fields.
        snapshot.dataQuality = computeDataQuality(
            samples: sampleUnion,
            dayStart: start, dayEnd: end,
            overnightStart: overnightStart, overnightEnd: overnightEnd
        )
    }

    /// Only mark dirty when an aggregate field actually changed. This
    /// keeps "Rebuild All History" (and any other re-aggregation flow)
    /// re-uploading past-day snapshots whose values shifted under the
    /// SpO2 precedence fix, while sparing the trailing-day snapshots
    /// (re-aggregated on every observer trigger, launch, and BG refresh)
    /// the every-trigger re-upload churn they would otherwise see.
    ///
    /// Bump `pendingSyncVersion` alongside the dirty flip so the
    /// post-upload `flagSnapshotsSynced` step can detect when an
    /// in-flight `aggregateDay` (running while `sync()` is suspended on
    /// its URLSession await) has mutated the row out from under the
    /// payload. The version is the only thing that distinguishes "row
    /// is clean and matches what we uploaded" from "row was re-dirtied
    /// during the sync and has new pending changes."
    private func finalizeAggregation(
        of snapshot: HealthSnapshot, preAggregateFingerprint: SnapshotFingerprint
    ) throws {
        let postAggregateFingerprint = SnapshotFingerprint(from: snapshot)
        if postAggregateFingerprint != preAggregateFingerprint {
            snapshot.syncedToServer = false
            snapshot.pendingSyncVersion &+= 1
        }

        try modelContext.save()
    }

    // MARK: - Sensor-derived aggregates

    /// Recompute the snapshot's sensor-derived aggregates —
    /// `tremorBandPowerAvg` / `fidgetIndexAvg` from the day's
    /// `AccelSpectrogram` rows and `breathingRateAvg` from the day's
    /// `DerivedBreathingRate` rows — setting each to nil when the day has no
    /// backing rows. Touches nothing else on the snapshot — in particular it
    /// never flips `syncedToServer`: these three averages have no columns in
    /// the server schema and are never synced, so recomputing them must not
    /// mark the snapshot dirty (that would only re-upload the unchanged
    /// synced fields).
    ///
    /// Extracted from `aggregateDay` so the post-restore path
    /// (`SyncService.reaggregateSensorDerivedSnapshots`) can re-run exactly
    /// this block for historical days without a full `aggregateDay` — which
    /// would blank restored HealthKit-derived fields against an empty
    /// post-reinstall HealthKit store.
    ///
    /// `dayStart`/`dayEnd` must be calendar-day bounds
    /// (`Calendar.current.startOfDay` and +1 day) — these are day-attributed
    /// metrics, unlike the overnight noon-to-noon window used for sleep/SpO2.
    static func applySensorDerivedMetrics(
        to snapshot: HealthSnapshot,
        dayStart start: Date,
        dayEnd end: Date,
        context: ModelContext
    ) throws {
        let spectrogramDescriptor = FetchDescriptor<AccelSpectrogram>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
        )
        let spectrograms = try context.fetch(spectrogramDescriptor)
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
        let breathingRates = try context.fetch(breathingDescriptor)
        if !breathingRates.isEmpty {
            let values = breathingRates.map(\.breathsPerMinute)
            snapshot.breathingRateAvg = values.reduce(0, +) / Double(values.count)
        } else {
            snapshot.breathingRateAvg = nil
        }
    }

    // MARK: - Dirty-flag fingerprinting

    /// Equatable snapshot of every aggregate field `aggregateDay` writes,
    /// used to decide whether re-aggregation actually changed anything.
    /// Excludes `id`, `date`, `syncedToServer` — those aren't aggregates and
    /// shouldn't drive the dirty flag.
    private struct SnapshotFingerprint: Equatable {
        let hrvAvg: Double?
        let hrvMin: Double?
        let restingHR: Double?
        let sleepDurationMin: Int?
        let sleepDeepMin: Int?
        let sleepREMMin: Int?
        let sleepCoreMin: Int?
        let sleepAwakeMin: Int?
        let skinTempDeviation: Double?
        let skinTempWrist: Double?
        let respiratoryRate: Double?
        let spo2Avg: Double?
        let spo2NadirOvernight: Double?
        let spo2NadirOpportunistic: Double?
        let spo2TimeBelow90Min: Int?
        let spo2DesatsCount: Int?
        let steps: Int?
        let activeCalories: Double?
        let exerciseMinutes: Int?
        let environmentalSoundAvg: Double?
        let bpSystolic: Double?
        let bpDiastolic: Double?
        let bloodGlucoseAvg: Double?
        let glucoseStdDev: Double?
        let glucoseCV: Double?
        let glucoseMin: Double?
        let glucoseMax: Double?
        let vo2Max: Double?
        let walkingHeartRateAvg: Double?
        let walkingSteadiness: Double?
        let atrialFibrillationBurden: Double?
        let headphoneAudioExposure: Double?
        let walkingSpeed: Double?
        let walkingStepLength: Double?
        let walkingDoubleSupportPct: Double?
        let walkingAsymmetryPct: Double?
        let timeInDaylightMin: Int?
        let physicalEffortAvg: Double?
        let cpapAHI: Double?
        let cpapUsageMinutes: Int?
        let barometricPressureAvgKPa: Double?
        let barometricPressureChangeKPa: Double?
        let nocturnalHRDip: Double?
        let tremorBandPowerAvg: Double?
        let breathingRateAvg: Double?
        let fidgetIndexAvg: Double?
        let dataQuality: String?
        // F-092 SpO₂ source basis — included so a basis-only change (rare, but
        // possible when a re-aggregation flips oximeter↔mixed while the numeric
        // value coincidentally lands identical) still marks the row dirty.
        let spo2AggregateSource: String?
        let spo2BurdenSource: String?

        init(from s: HealthSnapshot) {
            hrvAvg = s.hrvAvg
            hrvMin = s.hrvMin
            restingHR = s.restingHR
            sleepDurationMin = s.sleepDurationMin
            sleepDeepMin = s.sleepDeepMin
            sleepREMMin = s.sleepREMMin
            sleepCoreMin = s.sleepCoreMin
            sleepAwakeMin = s.sleepAwakeMin
            skinTempDeviation = s.skinTempDeviation
            skinTempWrist = s.skinTempWrist
            respiratoryRate = s.respiratoryRate
            spo2Avg = s.spo2Avg
            spo2NadirOvernight = s.spo2NadirOvernight
            spo2NadirOpportunistic = s.spo2NadirOpportunistic
            spo2TimeBelow90Min = s.spo2TimeBelow90Min
            spo2DesatsCount = s.spo2DesatsCount
            steps = s.steps
            activeCalories = s.activeCalories
            exerciseMinutes = s.exerciseMinutes
            environmentalSoundAvg = s.environmentalSoundAvg
            bpSystolic = s.bpSystolic
            bpDiastolic = s.bpDiastolic
            bloodGlucoseAvg = s.bloodGlucoseAvg
            glucoseStdDev = s.glucoseStdDev
            glucoseCV = s.glucoseCV
            glucoseMin = s.glucoseMin
            glucoseMax = s.glucoseMax
            vo2Max = s.vo2Max
            walkingHeartRateAvg = s.walkingHeartRateAvg
            walkingSteadiness = s.walkingSteadiness
            atrialFibrillationBurden = s.atrialFibrillationBurden
            headphoneAudioExposure = s.headphoneAudioExposure
            walkingSpeed = s.walkingSpeed
            walkingStepLength = s.walkingStepLength
            walkingDoubleSupportPct = s.walkingDoubleSupportPct
            walkingAsymmetryPct = s.walkingAsymmetryPct
            timeInDaylightMin = s.timeInDaylightMin
            physicalEffortAvg = s.physicalEffortAvg
            cpapAHI = s.cpapAHI
            cpapUsageMinutes = s.cpapUsageMinutes
            barometricPressureAvgKPa = s.barometricPressureAvgKPa
            barometricPressureChangeKPa = s.barometricPressureChangeKPa
            nocturnalHRDip = s.nocturnalHRDip
            tremorBandPowerAvg = s.tremorBandPowerAvg
            breathingRateAvg = s.breathingRateAvg
            fidgetIndexAvg = s.fidgetIndexAvg
            dataQuality = s.dataQuality
            spo2AggregateSource = s.spo2AggregateSource
            spo2BurdenSource = s.spo2BurdenSource
        }
    }

    // MARK: - Source-precedence overrides

    /// Drop rows persisted by the live EMAY BLE stream
    /// (`EMAYRealtimeService.liveSourceBundleID`) before any aggregation.
    ///
    /// Triple-provenance double-count risk: the same physical overnight
    /// session can reach `QuantityHealthSample` via up to three routes — the
    /// live BLE stream (per-minute means persisted while the night happens),
    /// a CSV export imported afterwards (`com.emay.SleepO2`, 1 Hz), and the
    /// EMAY iOS app writing to HealthKit (`com.emay.oximeter`, mirrored in).
    /// The CSV/HK routes are the clinical-grade records and already partition
    /// as preferred overnight oximetry. Letting live rows join the overnight
    /// SpO₂ avg/nadir/T90 partition on EITHER side would be dishonest: on the
    /// preferred side the night double-counts once the CSV lands; on the
    /// opportunistic side per-minute oximeter means masquerade as the "Apple
    /// Watch" nadir line. Live rows are display-only provenance for the
    /// Trends "Oximeter (live sessions)" card — they contribute to no
    /// snapshot aggregate, heart-metric precedence, or data-quality tier.
    nonisolated static func excludingLiveOximeterRows(
        _ rows: [QuantityHealthSample]
    ) -> [QuantityHealthSample] {
        rows.filter { $0.sourceBundleID != EMAYRealtimeService.liveSourceBundleID }
    }

    /// Provenance-tagged sample value used for SpO2 partitioning. Decoupled
    /// from `QuantityHealthSample` so the precedence path can also consume
    /// `SourcedQuantitySample` values pulled live from HealthKit when the
    /// SwiftData mirror hasn't backfilled yet.
    private struct ProvSpO2Sample {
        let timestamp: Date
        let value: Double
        let sourceBundleID: String
    }

    /// Compute SpO2 aggregates (avg, nadir, opportunistic nadir, T90, desats)
    /// from the high-fidelity tier (EMAY/Wellue oximeters) when present,
    /// falling back to opportunistic (Apple Watch / unknown) otherwise.
    /// Always populates `spo2NadirOpportunistic` so the trends chart can show
    /// the Apple Watch line independently.
    ///
    /// Pulls samples from BOTH layers so the override doesn't silently no-op
    /// on a fresh install or before the HealthKit→SwiftData mirror has caught
    /// up: HK live samples cover Apple-Watch + EMAY-iOS-app writes, SwiftData
    /// rows additionally cover CSV-imported EMAY sessions. Dedupe by hkUUID
    /// so HK samples already mirrored into SwiftData aren't double-counted.
    ///
    /// Pre-fix: the override only read SwiftData. On a fresh install the
    /// SwiftData table was empty, partition returned (preferred: [], opp: []),
    /// the function early-returned, and the HK-direct nadir (which mixes ALL
    /// sources via `minimumQuantity`) remained — surfacing Apple Watch
    /// off-finger artifacts (e.g. a single 0.78 afternoon reading) as the
    /// green "Oximeter" line.
    private func applyOvernightSpO2Precedence(
        on snapshot: HealthSnapshot,
        overnightStart: Date,
        overnightEnd: Date
    ) async throws {
        let spo2Type = HKQuantityTypeIdentifier.oxygenSaturation.rawValue

        // 1) SwiftData rows (mirror + CSV imports). Date-only predicate +
        // in-memory metricType filter to dodge the iOS 26 SwiftData footgun
        // documented in CLAUDE.md (compound `&&` with captured `String`
        // locals hangs during SQL ORDER BY generation).
        let descriptor = FetchDescriptor<QuantityHealthSample>(
            predicate: #Predicate {
                $0.timestamp >= overnightStart && $0.timestamp < overnightEnd
            }
        )
        let windowRows = try modelContext.fetch(descriptor)
        // Live-BLE rows never join the overnight partition — see
        // `excludingLiveOximeterRows` for the triple-provenance
        // double-count rationale.
        let swiftDataRows = Self.excludingLiveOximeterRows(windowRows)
            .filter { $0.metricType == spo2Type }

        // 2) HealthKit live samples with source provenance, but only when
        // SwiftData LACKS HK-mirrored coverage for this window. The mirror
        // pulls every HK SpO2 sample (Apple Watch + EMAY iOS app) for its
        // lookback window, so any HK-attributed SwiftData row means the
        // mirror has touched this window and we already have the rows we'd
        // get from HK live. Skipping the round-trip in that case avoids a
        // second per-sample HK query for the same window — on a 1 Hz EMAY
        // night that's ~32k samples doubled on every `aggregateDay` call,
        // and `aggregateDay` runs on launch from several views.
        //
        // CSV-imported EMAY rows (`com.emay.SleepO2`) DON'T count as HK-
        // mirrored coverage: those rows live only in SwiftData, never in
        // HealthKit, and a window populated entirely from CSV import
        // wouldn't have caught any Apple Watch readings via the mirror.
        // Still fetch HK in that case so the precedence partition can see
        // Watch/EMAY-iOS-app samples that complement the CSV data.
        //
        // The empty-SwiftData / CSV-only cases are what motivated this
        // whole fallback — they're the paths the May 12 bug took, and the
        // ones we MUST keep wired up. Failure is non-fatal: with no
        // SwiftData rows AND no HK rows we just leave the HK-direct
        // avg/nadir values in place rather than crashing the day's
        // aggregation.
        // Authoritative list lives on `DeviceProvenance` so the gate stays
        // in sync with the bundle IDs the EMAY CSV importer is allowed to
        // write — and covers both case variants (the upper-cased form the
        // importer currently uses AND the lower-cased legacy form).
        let hasHKMirroredCoverage = swiftDataRows.contains { row in
            !DeviceProvenance.csvOnlySpO2Bundles.contains(row.sourceBundleID)
        }
        let hkSourced: [SourcedQuantitySample]
        if !hasHKMirroredCoverage {
            do {
                hkSourced = try await healthKit.quantitySamplesWithSource(
                    .oxygenSaturation, unit: .percent(),
                    start: overnightStart, end: overnightEnd
                )
            } catch {
                // Don't swallow silently — if HK auth is denied or the API
                // call breaks, this fallback is the only thing keeping the
                // precedence override correct on an unprimed mirror, and a
                // failed query here will quietly degrade the chart back to
                // mixed-source HK aggregates. Log with the metric + window
                // so production issues can be triaged from device logs.
                let isoFormatter = ISO8601DateFormatter()
                Log.health.error(
                    """
                    SpO2 sourced-fallback fetch failed for \
                    [\(isoFormatter.string(from: overnightStart), privacy: .public)..\
                    \(isoFormatter.string(from: overnightEnd), privacy: .public)): \
                    \(error, privacy: .public)
                    """
                )
                hkSourced = []
            }
        } else {
            hkSourced = []
        }

        // 3) Union by hkUUID. SwiftData rows mirroring HK samples share the
        // same UUID as their HK origin, so prefer SwiftData (which can carry
        // a retroactive correction from a later mirror pass) and add HK rows
        // only when their UUID isn't already represented.
        //
        // NB: CSV-imported EMAY rows (`com.emay.SleepO2`) carry app-generated
        // UUIDs by design (see `QuantityHealthSample` docstring) — they
        // cannot collide with `hkUUID` and so won't be deduped by this step.
        // That's intentional: those rows live only in SwiftData and are not
        // mirrored from HealthKit. The corner case where this still
        // double-counts is a user who runs BOTH paths for the same overnight
        // session — exporting the EMAY device's CSV AND letting the EMAY
        // iOS app write `com.emay.oximeter` samples to HealthKit. The two
        // datasets land under different `sourceBundleID`s, both classify as
        // preferred, and both contribute to avg/nadir/T90. Pre-existing
        // behavior; `EMAYImporter`'s `(timestamp, metricType, sourceBundleID)`
        // dedup is intentionally scoped to its own bundle ID for clarity and
        // doesn't deduplicate against the HK-app's writes.
        let swiftDataUUIDs = Set(swiftDataRows.map(\.id))
        var unified: [ProvSpO2Sample] = []
        unified.reserveCapacity(swiftDataRows.count + hkSourced.count)
        for row in swiftDataRows {
            unified.append(ProvSpO2Sample(
                timestamp: row.timestamp,
                value: row.value,
                sourceBundleID: row.sourceBundleID
            ))
        }
        for sample in hkSourced where !swiftDataUUIDs.contains(sample.hkUUID) {
            unified.append(ProvSpO2Sample(
                timestamp: sample.timestamp,
                value: sample.value,
                sourceBundleID: sample.sourceBundleID
            ))
        }

        // 4) Partition by bundle-ID provenance.
        let preferredBundles = DeviceProvenance.overnightPulseOximeters
        var preferred: [ProvSpO2Sample] = []
        var opportunistic: [ProvSpO2Sample] = []
        for sample in unified {
            if preferredBundles.contains(sample.sourceBundleID) {
                preferred.append(sample)
            } else {
                opportunistic.append(sample)
            }
        }

        // 5) Opportunistic nadir is always reported when any opportunistic
        // samples exist — feeds the trends chart's Apple Watch line
        // regardless of whether a preferred source also covers the window.
        snapshot.spo2NadirOpportunistic = opportunistic.map(\.value).min().map { $0 * 100 }

        // 6) No preferred-tier coverage: keep the HK-direct avg/nadir/T90/desats
        // already set by the HealthKit aggregate calls in `aggregateDay` (those
        // mix sources, but with no dedicated oximeter they collapse to
        // opportunistic-only, which is the right answer when no oximeter ran).
        // T90/desats specifically: leave them untouched here — they were
        // computed from the HK-direct `quantitySamples` array against the same
        // continuous-monitoring thresholds, so wiping them would lose
        // legitimate Apple-Watch-derived overnight stats on watch-only nights.
        guard !preferred.isEmpty else { return }

        // 7) Preferred-tier coverage: recompute avg + nadir from preferred
        // only so a single Apple Watch positional artifact (e.g. 0.78 wrist
        // reading at 3 PM) can't drag the clinically-meaningful EMAY nadir.
        let preferredValues = preferred.map(\.value)
        let preferredAvg = preferredValues.reduce(0, +) / Double(preferredValues.count)
        snapshot.spo2Avg = preferredAvg * 100
        if let preferredNadir = preferredValues.min() {
            snapshot.spo2NadirOvernight = preferredNadir * 100
        }
        // avg/nadir now come from the dedicated-oximeter subset (F-092).
        snapshot.spo2AggregateBasis = .oximeter

        // 8) T90 + desat count need start/end intervals. Synthesize 1-second
        // intervals — overnight oximeters write at 1 Hz so this matches
        // both the cadence and what HealthKit reports for the same writes.
        let preferredQS = preferred.map { sample in
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
            // T90/desats now come from the dedicated-oximeter subset (F-092).
            // If this branch is skipped, the basis stays `.mixed` (set before
            // the precedence call) — which is exactly the divergence F-092
            // discloses: an oximeter nadir alongside a mixed-source T90.
            snapshot.spo2BurdenBasis = .oximeter
        }
        // Preferred coverage exists but is too sparse for T90/desat math
        // (oximeter connected briefly, then dropped): KEEP the HK-direct
        // values `aggregateDay` computed against the same sufficiency gate.
        // Nil-ing them here discarded already-sufficient Apple-Watch-derived
        // overnight stats and understated hypoxic burden in the clinician
        // PDF for a night with adequate combined-source coverage (F-023) —
        // the exact loss the step-6 early-return's comment promises to avoid
        // on watch-only nights, reintroduced whenever `preferred` was
        // non-empty-but-insufficient.
    }

    /// Replace HealthKit-direct HR/RHR/HRV aggregates with values from the
    /// chest-strap tier (Polar H10) when present for the night. Each metric
    /// is handled independently — Polar might cover HR but not HRV on a
    /// given day, in which case only HR is overridden.
    ///
    /// `start`/`end` are the overnight noon-to-noon window (see the call
    /// site + F-046): chest-strap sessions are whole-night recordings and
    /// must be night-attributed like the sleep/SpO2 fields, not split at
    /// midnight.
    ///
    /// Two chest-strap routes exist and BOTH are checked (F-027):
    /// - `QuantityHealthSample` rows tagged `fi.polar.polarflow` — the
    ///   optional Polar Flow companion-app → HealthKit → mirror path.
    /// - `HRVReading` rows tagged `polar_h10` — the app's own BLE pipeline,
    ///   which never writes `QuantityHealthSample`. Before this branch
    ///   existed, first-party Polar sessions could never win precedence and
    ///   the snapshot silently kept the noisier Watch value.
    ///
    /// No-op for metrics with no chest-strap coverage on either route: the
    /// HK-direct value is kept.
    private func applyDailyHeartMetricsPrecedence(
        on snapshot: HealthSnapshot,
        samples: [QuantityHealthSample],
        start: Date,
        end: Date
    ) throws {
        let hrType = HKQuantityTypeIdentifier.heartRate.rawValue
        let rhrType = HKQuantityTypeIdentifier.restingHeartRate.rawValue
        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        let wantedMetrics: Set<String> = [hrType, rhrType, hrvType]

        // `samples` is the shared union fetch from aggregateDay; filter it to
        // this method's [start, end) window and the wanted metrics in memory
        // (F-055). This preserves the previous behavior exactly — the old
        // per-method fetch used the identical Date-only predicate — while
        // avoiding a redundant materialization. (Date-only predicates also
        // sidestep the iOS 26 compound-#Predicate ORDER BY hang, which the
        // union fetch in aggregateDay likewise honors.)
        let windowRows = samples.filter { $0.timestamp >= start && $0.timestamp < end }
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

        // First-party BLE route: per-minute HRVReading rows from our own
        // Polar pipeline (source == PolarHRMService.sourceLabel), which
        // never reach QuantityHealthSample — the partition above cannot
        // see them (F-027). Their SDNN is the same metric HealthKit stores for
        // hrvAvg/hrvMin, computed from clinical-fidelity RR intervals, so
        // they outrank both the Watch value and the Polar-Flow-mirrored
        // samples when present. Date-only predicate + in-memory source
        // filter for the same compound-#Predicate footgun reason as above.
        //
        // Resting HR is deliberately NOT overridden from this route: the
        // BLE pipeline records session HR, and a session mean is not a
        // resting measurement.
        let readingDescriptor = FetchDescriptor<HRVReading>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
        )
        let windowReadings = try modelContext.fetch(readingDescriptor)
        let strapReadings = windowReadings.filter { reading in
            reading.source.map { DeviceProvenance.isChestStrapHRMonitor($0) } ?? false
        }
        if !strapReadings.isEmpty {
            let sdnnValues = strapReadings.map(\.sdnn)
            snapshot.hrvAvg = sdnnValues.reduce(0, +) / Double(sdnnValues.count)
            snapshot.hrvMin = sdnnValues.min()
        }
    }

    /// Build the `dataQuality` JSON object describing reliability tier + source
    /// breakdown per metric family for this day. Always emits a key per
    /// family — when no samples are present, the family is `insufficient`
    /// with empty `sources`. Keys are sorted for deterministic output.
    private func computeDataQuality(
        samples: [QuantityHealthSample],
        dayStart: Date, dayEnd: Date,
        overnightStart: Date, overnightEnd: Date
    ) -> String? {
        // Both slices come from the shared union fetch (F-055), filtered in
        // memory to the same windows the old per-descriptor fetches used.
        // Day-window samples (most metrics).
        let daySamples = samples.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }

        // Overnight-window samples (SpO2). The overnight noon-to-noon window
        // straddles two calendar days; filtered to oxygen saturation only —
        // this slice only feeds the spo2 family.
        let spo2MetricType = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        let overnightSamples = samples.filter {
            $0.timestamp >= overnightStart
                && $0.timestamp < overnightEnd
                && $0.metricType == spo2MetricType
        }

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
