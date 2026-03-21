import HealthKit

/// Single point of contact for all HealthKit reads. Never query HealthKit directly from views.
actor HealthKitManager {
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
        ]

        var types = Set<HKObjectType>()
        for id in quantityIdentifiers {
            types.insert(HKQuantityType(id))
        }
        types.insert(HKCategoryType(.sleepAnalysis))
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
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKClinicalRecord]) ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Statistics Queries

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
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: stats) }
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
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: stats) }
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
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: stats) }
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
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: results?.first as? HKQuantitySample) }
            }
            healthStore.execute(query)
        }

        guard let sample else { return nil }
        return (sample.endDate, sample.quantity.doubleValue(for: unit))
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
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: results?.first as? HKQuantitySample) }
            }
            healthStore.execute(query)
        }
        return sample?.startDate
    }

    // MARK: - Observer Queries

    /// Types worth observing — these change frequently and drive dashboard/trends updates.
    private var observedSampleTypes: [HKSampleType] {
        [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKCategoryType(.sleepAnalysis),
        ]
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
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    // MARK: - Sleep Analysis

    struct SleepData: Sendable {
        var totalMinutes: Int = 0
        var deepMinutes: Int = 0
        var remMinutes: Int = 0
        var coreMinutes: Int = 0
        var awakeMinutes: Int = 0
    }

    /// Query sleep stages for a date range. Returns aggregated minutes per stage.
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
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
                }
            }
            healthStore.execute(query)
        }

        var data = SleepData()
        for sample in samples {
            let minutes = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }

            switch value {
            case .asleepDeep:
                data.deepMinutes += minutes
            case .asleepREM:
                data.remMinutes += minutes
            case .asleepCore:
                data.coreMinutes += minutes
            case .awake:
                data.awakeMinutes += minutes
            case .inBed:
                break // Not counted toward sleep total
            case .asleepUnspecified:
                data.coreMinutes += minutes
            @unknown default:
                break
            }
        }
        data.totalMinutes = data.deepMinutes + data.remMinutes + data.coreMinutes
        return data
    }
}
