import Foundation
import SwiftData

/// Per-sample mirror of `HKQuantitySample` rows for clinically-meaningful metrics.
/// `id` is the HealthKit sample UUID, making sync end-to-end idempotent.
@Model
final class QuantityHealthSample {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    /// Raw value of `HKQuantityTypeIdentifier` (e.g. "HKQuantityTypeIdentifierBloodGlucose").
    var metricType: String
    var value: Double
    var unitString: String
    var sourceBundleID: String
    var sourceName: String
    var deviceModel: String?
    /// Links the systolic + diastolic rows produced from a single BP correlation.
    var groupID: UUID?
    var syncedToServer: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        timestamp: Date,
        metricType: String,
        value: Double,
        unitString: String,
        sourceBundleID: String,
        sourceName: String,
        deviceModel: String? = nil,
        groupID: UUID? = nil,
        syncedToServer: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.timestamp = timestamp
        self.metricType = metricType
        self.value = value
        self.unitString = unitString
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.deviceModel = deviceModel
        self.groupID = groupID
        self.syncedToServer = syncedToServer
        self.createdAt = createdAt
    }
}
