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
