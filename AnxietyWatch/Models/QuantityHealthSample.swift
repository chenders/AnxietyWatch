import Foundation
import SwiftData

/// Per-sample mirror of `HKQuantitySample` rows for clinically-meaningful metrics.
/// For HealthKit-sourced rows, `id` is the originating `HKSample.uuid`, which
/// makes anchored-query sync end-to-end idempotent. For rows imported from
/// external sources without HealthKit UUIDs (e.g. EMAY oximeter CSVs),
/// `id` is an app-generated UUID; idempotency for those imports is enforced
/// instead by `(sourceBundleID, timestamp, metricType)` dedup at the importer.
@Model
final class QuantityHealthSample {
    /// Dedup queries during CSV imports filter by `sourceBundleID` and read
    /// timestamps; a compound index keeps that lookup O(log n) as the table
    /// grows past CSV-friendly sizes (EMAY 1 Hz exports add ~36k rows per
    /// overnight session).
    #Index<QuantityHealthSample>([\.sourceBundleID, \.timestamp])

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
    /// Staleness token for the post-upload synced-flag flip; see
    /// `SensorSession.pendingSyncVersion`. Bumped by
    /// `HealthDataCoordinator`'s mirror pass whenever a retroactive
    /// HealthKit correction updates this row in place and re-dirties it.
    var pendingSyncVersion: Int = 0

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
        self.pendingSyncVersion = 0
    }
}
