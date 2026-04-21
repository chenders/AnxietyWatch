import Foundation
import HealthKit

/// Aggregated sleep stage data from HealthKit.
/// Top-level so it can be used in the protocol without referencing HealthKitManager.
struct SleepData: Sendable {
    var totalMinutes: Int = 0
    var deepMinutes: Int = 0
    var remMinutes: Int = 0
    var coreMinutes: Int = 0
    var awakeMinutes: Int = 0
}

/// Abstraction over HealthKit queries. HealthKitManager conforms to this;
/// tests can inject a MockHealthKitDataSource instead.
protocol HealthKitDataSource: Sendable {
    func averageQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double?
    func minimumQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double?
    func cumulativeQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                            start: Date, end: Date) async throws -> Double?
    func mostRecentQuantity(_ identifier: HKQuantityTypeIdentifier,
                            unit: HKUnit) async throws -> (date: Date, value: Double)?
    func averageBloodPressure(start: Date, end: Date) async throws -> (systolic: Double, diastolic: Double)?
    func querySleepAnalysis(start: Date, end: Date) async throws -> SleepData
    func queryClinicalLabResults(since startDate: Date?) async throws -> [HKClinicalRecord]
    func oldestSampleDate() async throws -> Date?
    /// Extract RR intervals (ms) from heartbeat series samples in the given range.
    func queryHeartbeatSeries(start: Date, end: Date) async throws -> [Double]
    func startObserving(onUpdate: @Sendable @escaping () -> Void) async
    func startAnchoredQueries(
        onNewSamples: @Sendable @escaping ([(type: String, value: Double, timestamp: Date, source: String?)]) -> Void
    ) async
}
