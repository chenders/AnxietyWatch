import HealthKit
import os

/// Single point of contact for all HealthKit reads. Never query HealthKit directly from views.
actor HealthKitManager: HealthKitDataSource {
    static let shared = HealthKitManager()

    private let healthStore = HKHealthStore()

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Read Types

    private var allReadTypes: Set<HKObjectType> {
        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,       // HRV (SDNN, ms)
            .heartRate,                       // Instantaneous HR (bpm)
            .restingHeartRate,                // Resting HR (bpm)
            .respiratoryRate,                 // Breaths per minute (sleep)
            .oxygenSaturation,                // SpO2 (%)
            .appleSleepingWristTemperature,   // Wrist temp deviation during sleep (°C)
            .stepCount,                       // Daily steps
            .activeEnergyBurned,              // Active calories (kcal)
            .appleExerciseTime,               // Exercise minutes
            .environmentalAudioExposure,      // Ambient noise (dBA)
            .bloodPressureSystolic,           // Systolic BP (mmHg)
            .bloodPressureDiastolic,          // Diastolic BP (mmHg)
            .bloodGlucose,                    // Blood glucose (mg/dL)
            // New: Apple Watch Series 8 types
            .vo2Max,                          // Cardiorespiratory fitness (mL/kg/min)
            .walkingHeartRateAverage,         // Average HR during walking (bpm)
            .headphoneAudioExposure,          // Headphone volume (dBA)
            .appleWalkingSteadiness,          // Balance/fall risk (0–1)
            .atrialFibrillationBurden,        // % time in AFib (0–1)
            .walkingSpeed,                    // Gait pace (m/s)
            .walkingStepLength,               // Stride length (m)
            .walkingDoubleSupportPercentage,  // Both feet on ground (0–1)
            .walkingAsymmetryPercentage,      // Left/right asymmetry (0–1)
            // Anxiety-relevant Apple Watch metrics (iOS 17+)
            .timeInDaylight,                  // Outdoor daylight exposure (minutes) — circadian rhythm
            .physicalEffort,                  // Relative physical effort (kcal/(kg·hr)) — disambiguates exercise vs anxiety HR
        ]

        var types = Set<HKObjectType>()
        for id in quantityIdentifiers {
            types.insert(HKQuantityType(id))
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKWorkoutType.workoutType())
        types.insert(HKCorrelationType(.bloodPressure))
        // Characteristic types (demographics — no samples, just static properties)
        types.insert(HKCharacteristicType(.dateOfBirth))
        types.insert(HKCharacteristicType(.biologicalSex))
        return types
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await healthStore.requestAuthorization(toShare: [], read: allReadTypes)
    }

    // MARK: - Clinical Records Authorization

    /// Request access to clinical health records (lab results).
    /// This shows a separate system dialog from the standard HealthKit authorization.
    func requestClinicalAuthorization() async throws {
        guard isAvailable else { return }
        let clinicalType = HKClinicalType(.labResultRecord)
        try await healthStore.requestAuthorization(toShare: [], read: [clinicalType])
    }

    // MARK: - Clinical Records Queries

    /// Query all clinical lab result records from HealthKit Health Records.
    func queryClinicalLabResults(since startDate: Date? = nil) async throws -> [HKClinicalRecord] {
        guard isAvailable else { return [] }
        let type = HKClinicalType(.labResultRecord)
        let predicate = startDate.map { HKQuery.predicateForSamples(withStart: $0, end: nil) }

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: [])
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKClinicalRecord]) ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Statistics Queries

    /// HealthKit error codes that should be treated as "no data" rather than thrown.
    /// Code 5 (authorizationNotDetermined): type not in authorization request or user hasn't responded
    /// Code 11 (noData): no samples match the predicate
    private static let noDataErrorCodes: Set<Int> = [5, 11]

    private static func isNoDataError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == HKErrorDomain && noDataErrorCodes.contains(nsError.code)
    }

    /// Average of a discrete quantity type over a date range.
    func averageQuantity(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let statistics: HKStatistics? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: stats)
                }
            }
            healthStore.execute(query)
        }
        return statistics?.averageQuantity()?.doubleValue(for: unit)
    }

    /// Minimum of a discrete quantity type over a date range.
    func minimumQuantity(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let statistics: HKStatistics? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteMin
            ) { _, stats, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: stats)
                }
            }
            healthStore.execute(query)
        }
        return statistics?.minimumQuantity()?.doubleValue(for: unit)
    }

    /// Cumulative sum of a quantity type over a date range (steps, calories, exercise).
    func cumulativeQuantity(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let statistics: HKStatistics? = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: stats)
                }
            }
            healthStore.execute(query)
        }
        return statistics?.sumQuantity()?.doubleValue(for: unit)
    }

    /// Most recent sample of a quantity type.
    func mostRecentQuantity(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> (date: Date, value: Double)? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(identifier)

        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, results, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results?.first as? HKQuantitySample)
                }
            }
            healthStore.execute(query)
        }

        guard let sample else { return nil }
        return (sample.endDate, sample.quantity.doubleValue(for: unit))
    }

    // MARK: - Blood Pressure (Correlation)

    /// Query blood pressure as HKCorrelation to get properly paired
    /// systolic/diastolic readings. Returns average of paired readings
    /// in the given date range, or nil if no readings exist.
    func averageBloodPressure(
        start: Date,
        end: Date
    ) async throws -> (systolic: Double, diastolic: Double)? {
        guard isAvailable else { return nil }
        let bpType = HKCorrelationType(.bloodPressure)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let correlations: [HKCorrelation] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: bpType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: [])
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKCorrelation]) ?? [])
                }
            }
            healthStore.execute(query)
        }

        guard !correlations.isEmpty else { return nil }

        let mmHg = HKUnit.millimeterOfMercury()
        var sysTotal = 0.0, diaTotal = 0.0, count = 0

        for correlation in correlations {
            if let sys = correlation.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample,
               let dia = correlation.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample {
                sysTotal += sys.quantity.doubleValue(for: mmHg)
                diaTotal += dia.quantity.doubleValue(for: mmHg)
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return (sysTotal / Double(count), diaTotal / Double(count))
    }

    // MARK: - History Discovery

    /// Finds the date of the oldest HRV sample in HealthKit.
    /// Used to determine how far back to backfill snapshots.
    func oldestSampleDate() async throws -> Date? {
        guard isAvailable else { return nil }
        let type = HKQuantityType(.heartRateVariabilitySDNN)

        let sample: HKQuantitySample? = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results?.first as? HKQuantitySample)
                }
            }
            healthStore.execute(query)
        }
        return sample?.startDate
    }

    // MARK: - Heartbeat Series (RR Intervals)

    /// Query heartbeat series samples in the given range and extract RR intervals.
    /// Returns RR intervals in milliseconds, computed from successive beat timestamps.
    /// Gaps between series samples are excluded (no artificial long intervals).
    func queryHeartbeatSeries(start: Date, end: Date) async throws -> [Double] {
        guard isAvailable else { return [] }
        let type = HKSeriesType.heartbeat()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let series: [HKHeartbeatSeriesSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: [])
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKHeartbeatSeriesSample]) ?? [])
                }
            }
            healthStore.execute(query)
        }

        var allIntervals = [Double]()

        for sample in series {
            let intervals: [Double] = try await withCheckedThrowingContinuation { continuation in
                var beats = [(time: Double, gapBefore: Bool)]()
                var resumed = false
                let query = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, timeSinceStart, precededByGap, done, error in
                    guard !resumed else { return }
                    if let error {
                        resumed = true
                        continuation.resume(throwing: error)
                        return
                    }
                    beats.append((timeSinceStart, precededByGap))
                    if done {
                        resumed = true
                        // Only compute RR intervals between consecutive beats where
                        // the second beat is NOT preceded by a gap. This avoids
                        // producing artificially long intervals that span gaps.
                        var rr = [Double]()
                        for i in 1..<beats.count where !beats[i].gapBefore {
                            rr.append((beats[i].time - beats[i - 1].time) * 1000.0)
                        }
                        continuation.resume(returning: rr)
                    }
                }
                healthStore.execute(query)
            }
            allIntervals.append(contentsOf: intervals)
        }

        return allIntervals
    }

    // MARK: - Observer Queries

    /// Sleep analysis stays on HKObserverQuery since it's a category type.
    /// All quantity types have moved to HKAnchoredObjectQuery.
    private var observedSampleTypes: [HKSampleType] {
        [HKCategoryType(.sleepAnalysis)]
    }

    private var activeObserverQueries: [HKObserverQuery] = []

    /// Start long-running observer queries that fire when HealthKit receives new samples.
    /// Call this once at app launch. The `onUpdate` closure fires from an arbitrary thread
    /// whenever any observed type gets new data (e.g., Watch syncs a new HRV reading).
    func startObserving(onUpdate: @Sendable @escaping () -> Void) {
        guard isAvailable else { return }

        for query in activeObserverQueries {
            healthStore.stop(query)
        }
        activeObserverQueries.removeAll()

        for type in observedSampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                if error == nil {
                    onUpdate()
                }
                completionHandler()
            }
            healthStore.execute(query)
            activeObserverQueries.append(query)

            // Request background delivery so the app is woken when new data arrives
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
                if let error {
                    Log.health.error("enableBackgroundDelivery failed for \(type.identifier, privacy: .public): \(error, privacy: .public)")
                } else if !success {
                    Log.health.warning("enableBackgroundDelivery returned false for \(type.identifier, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Anchored Object Queries

    private var activeAnchoredQueries: [HKAnchoredObjectQuery] = []

    /// UserDefaults key prefix for persisting query anchors per type.
    private static let anchorKeyPrefix = "HKAnchor_"

    /// Start anchored object queries for all types in SampleTypeConfig.anchoredTypes.
    /// Calls onNewSamples with an array of (type raw identifier, value, timestamp, source)
    /// for each batch of new samples received.
    func startAnchoredQueries(
        onNewSamples: @Sendable @escaping ([(type: String, value: Double, timestamp: Date, source: String?)]) -> Void
    ) {
        guard isAvailable else { return }

        for query in activeAnchoredQueries {
            healthStore.stop(query)
        }
        activeAnchoredQueries.removeAll()

        for config in SampleTypeConfig.anchoredTypes {
            let sampleType = HKQuantityType(config.identifier)
            let anchor = loadAnchor(for: config.identifier.rawValue)

            let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, (any Error)?) -> Void = {
                [weak self] query, newSamples, _, newAnchor, error in
                if let error {
                    Log.health.error("Anchored query error for \(config.identifier.rawValue, privacy: .public): \(error, privacy: .public)")
                    return
                }

                // Always advance the anchor, even when there are no samples
                if let newAnchor {
                    Task { await self?.saveAnchor(newAnchor, for: config.identifier.rawValue) }
                }

                let samples = (newSamples as? [HKQuantitySample]) ?? []
                guard !samples.isEmpty else { return }

                let converted: [(type: String, value: Double, timestamp: Date, source: String?)] = samples.map { sample in
                    let value = sample.quantity.doubleValue(for: config.unit)
                    let source = sample.sourceRevision.source.name
                    return (config.identifier.rawValue, value, sample.endDate, source)
                }
                onNewSamples(converted)
            }

            // Only scope to 7-day window on first run (no anchor) to avoid fetching
            // entire history. When an anchor exists, pass nil predicate so HealthKit
            // returns everything since the anchor — even if the app hasn't been opened
            // for more than 7 days.
            let predicate: NSPredicate? = if anchor == nil {
                Calendar.current.date(byAdding: .day, value: -7, to: .now)
                    .map { HKQuery.predicateForSamples(withStart: $0, end: nil) }
            } else {
                nil
            }

            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit,
                resultsHandler: handler
            )
            query.updateHandler = handler
            healthStore.execute(query)
            activeAnchoredQueries.append(query)

            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                if let error {
                    Log.health.error("enableBackgroundDelivery failed for \(config.identifier.rawValue, privacy: .public): \(error, privacy: .public)")
                } else if !success {
                    Log.health.warning("enableBackgroundDelivery returned false for \(config.identifier.rawValue, privacy: .public)")
                }
            }
        }
    }

    private func loadAnchor(for typeKey: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorKeyPrefix + typeKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, for typeKey: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.anchorKeyPrefix + typeKey)
    }

    // MARK: - Sleep Analysis

    /// Query sleep stages for a date range. Returns aggregated minutes per stage.
    /// Merges overlapping intervals from multiple sources (Watch + iPhone)
    /// to prevent double-counting.
    func querySleepAnalysis(start: Date, end: Date) async throws -> SleepData {
        guard isAvailable else { return SleepData() }
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: [])
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
                }
            }
            healthStore.execute(query)
        }

        // Group sample intervals by sleep stage, then merge overlaps per stage.
        var deepIntervals: [(Date, Date)] = []
        var remIntervals: [(Date, Date)] = []
        var coreIntervals: [(Date, Date)] = []
        var awakeIntervals: [(Date, Date)] = []

        for sample in samples {
            let interval = (sample.startDate, sample.endDate)
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }

            switch value {
            case .asleepDeep:
                deepIntervals.append(interval)
            case .asleepREM:
                remIntervals.append(interval)
            case .asleepCore:
                coreIntervals.append(interval)
            case .awake:
                awakeIntervals.append(interval)
            case .inBed:
                break
            case .asleepUnspecified:
                coreIntervals.append(interval)
            @unknown default:
                break
            }
        }

        var data = SleepData()
        data.deepMinutes = SleepIntervalMerger.mergedMinutes(deepIntervals)
        data.remMinutes = SleepIntervalMerger.mergedMinutes(remIntervals)
        data.coreMinutes = SleepIntervalMerger.mergedMinutes(coreIntervals)
        data.awakeMinutes = SleepIntervalMerger.mergedMinutes(awakeIntervals)
        data.totalMinutes = data.deepMinutes + data.remMinutes + data.coreMinutes
        return data
    }

    // MARK: - Workout Queries

    struct WorkoutData: Sendable {
        let startDate: Date
        let endDate: Date
        let durationMinutes: Int
        let activityType: UInt   // HKWorkoutActivityType raw value
        let totalCalories: Double?
    }

    /// Query workouts for a date range. Used to identify exercise periods
    /// so exercise HR can be excluded from anxiety-related baselines.
    func queryWorkouts(start: Date, end: Date) async throws -> [WorkoutData] {
        guard isAvailable else { return [] }
        let type = HKWorkoutType.workoutType()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)

        let samples: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error, Self.isNoDataError(error) {
                    continuation.resume(returning: [])
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKWorkout]) ?? [])
                }
            }
            healthStore.execute(query)
        }

        return samples.map { workout in
            let minutes = Int(workout.endDate.timeIntervalSince(workout.startDate) / 60)
            let calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            return WorkoutData(
                startDate: workout.startDate,
                endDate: workout.endDate,
                durationMinutes: minutes,
                activityType: workout.workoutActivityType.rawValue,
                totalCalories: calories
            )
        }
    }

    // MARK: - Demographics

    /// Read date of birth from HealthKit.
    func dateOfBirth() throws -> DateComponents? {
        try healthStore.dateOfBirthComponents()
    }

    /// Read biological sex from HealthKit.
    func biologicalSex() throws -> HKBiologicalSex {
        try healthStore.biologicalSex().biologicalSex
    }
}
