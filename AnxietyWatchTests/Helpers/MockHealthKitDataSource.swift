import Foundation
import HealthKit

@testable import AnxietyWatch

actor MockHealthKitDataSource: HealthKitDataSource {
    /// Simulates `HKAuthorizationRequestStatus.shouldRequest` — the
    /// never-asked state a fresh install (or bundle-ID rename) starts in.
    var authorizationNeedsRequestResult = false
    private(set) var authorizationRequestCount = 0

    func authorizationNeedsRequest() async -> Bool {
        authorizationNeedsRequestResult
    }

    func requestAuthorization() async throws {
        authorizationRequestCount += 1
        // Responding to the sheet (grant or deny) moves the system status to
        // `.unnecessary`; mirror that so call-order tests see the transition.
        authorizationNeedsRequestResult = false
    }

    func setAuthorizationNeedsRequest(_ value: Bool) {
        authorizationNeedsRequestResult = value
    }

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

    var quantitySamplesResults: [HKQuantityTypeIdentifier: [QuantitySample]] = [:]

    func quantitySamples(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> [QuantitySample] {
        queriedIdentifiers.append(identifier)
        return quantitySamplesResults[identifier] ?? []
    }

    var quantitySamplesWithSourceResults: [HKQuantityTypeIdentifier: [SourcedQuantitySample]] = [:]
    var sleepStageEventsResult: [SourcedSleepStageEvent] = []

    func quantitySamplesWithSource(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                                   start: Date, end: Date) async throws -> [SourcedQuantitySample] {
        queriedIdentifiers.append(identifier)
        // Filter by `[start, end)` to mirror HealthKit's `.strictStartDate`
        // semantics. Tests asserting the look-back boundary depend on this:
        // samples whose timestamp falls outside the queried window must be
        // invisible to the caller, just as they would be in production.
        let all = quantitySamplesWithSourceResults[identifier] ?? []
        return all.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    func sleepStageEvents(start: Date, end: Date) async throws -> [SourcedSleepStageEvent] {
        // Same `[start, end)` filtering as quantity samples — keyed on the
        // event's `start` so tests can assert look-back boundary behaviour.
        sleepStageEventsResult.filter { $0.start >= start && $0.start < end }
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
    func setQuantitySamples(_ id: HKQuantityTypeIdentifier, _ samples: [QuantitySample]) {
        quantitySamplesResults[id] = samples
    }
    func setQuantitySamplesWithSource(_ id: HKQuantityTypeIdentifier,
                                      _ samples: [SourcedQuantitySample]) {
        quantitySamplesWithSourceResults[id] = samples
    }
    func setSleepStageEvents(_ events: [SourcedSleepStageEvent]) {
        sleepStageEventsResult = events
    }
    func setOldestDate(_ date: Date?) {
        oldestDate = date
    }
}
