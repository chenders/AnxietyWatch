import Foundation
import HealthKit

@testable import AnxietyWatch

actor MockHealthKitDataSource: HealthKitDataSource {
    var averageResults: [HKQuantityTypeIdentifier: Double] = [:]
    var minimumResults: [HKQuantityTypeIdentifier: Double] = [:]
    var cumulativeResults: [HKQuantityTypeIdentifier: Double] = [:]
    var mostRecentResults: [HKQuantityTypeIdentifier: (date: Date, value: Double)] = [:]
    var bloodPressureResult: (systolic: Double, diastolic: Double)?
    var sleepResult = SleepData()
    var clinicalRecords: [HKClinicalRecord] = []
    var oldestDate: Date?
    private(set) var queriedIdentifiers: [HKQuantityTypeIdentifier] = []

    func averageQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double? {
        queriedIdentifiers.append(identifier)
        return averageResults[identifier]
    }

    func minimumQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double? {
        queriedIdentifiers.append(identifier)
        return minimumResults[identifier]
    }

    func cumulativeQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                            start: Date, end: Date) async throws -> Double? {
        queriedIdentifiers.append(identifier)
        return cumulativeResults[identifier]
    }

    func mostRecentQuantity(_ identifier: HKQuantityTypeIdentifier,
                            unit: HKUnit) async throws -> (date: Date, value: Double)? {
        queriedIdentifiers.append(identifier)
        return mostRecentResults[identifier]
    }

    func averageBloodPressure(start: Date, end: Date) async throws -> (systolic: Double, diastolic: Double)? {
        bloodPressureResult
    }

    func querySleepAnalysis(start: Date, end: Date) async throws -> SleepData {
        sleepResult
    }

    func queryClinicalLabResults(since startDate: Date?) async throws -> [HKClinicalRecord] {
        clinicalRecords
    }

    func oldestSampleDate() async throws -> Date? {
        oldestDate
    }

    func startObserving(onUpdate: @Sendable @escaping () -> Void) async {}

    func startAnchoredQueries(
        onNewSamples: @Sendable @escaping ([(type: String, value: Double, timestamp: Date, source: String?)]) -> Void
    ) async {}

    var heartbeatSeriesResult: [Double] = []

    func queryHeartbeatSeries(start: Date, end: Date) async throws -> [Double] {
        heartbeatSeriesResult
    }

    // Convenience setters
    func setAverage(_ id: HKQuantityTypeIdentifier, value: Double) {
        averageResults[id] = value
    }
    func setMinimum(_ id: HKQuantityTypeIdentifier, value: Double) {
        minimumResults[id] = value
    }
    func setCumulative(_ id: HKQuantityTypeIdentifier, value: Double) {
        cumulativeResults[id] = value
    }
    func setMostRecent(_ id: HKQuantityTypeIdentifier, date: Date, value: Double) {
        mostRecentResults[id] = (date, value)
    }
    func setBloodPressure(systolic: Double, diastolic: Double) {
        bloodPressureResult = (systolic, diastolic)
    }
    func setSleep(_ data: SleepData) {
        sleepResult = data
    }
    func setHeartbeatSeries(_ intervals: [Double]) {
        heartbeatSeriesResult = intervals
    }
}
