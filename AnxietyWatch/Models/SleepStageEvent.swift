import Foundation
import SwiftData

/// Per-event mirror of `HKCategorySample` sleep-analysis rows.
/// `id` is the HealthKit sample UUID, making sync end-to-end idempotent.
@Model
final class SleepStageEvent {
    @Attribute(.unique) var id: UUID
    var startTime: Date
    var endTime: Date
    /// Raw value name of `HKCategoryValueSleepAnalysis` (e.g. "asleepDeep", "asleepREM", "awake", "inBed").
    var stage: String
    var sourceBundleID: String
    var sourceName: String
    var deviceModel: String?
    var syncedToServer: Bool
    var createdAt: Date
    /// Staleness token for the post-upload synced-flag flip; see
    /// `SensorSession.pendingSyncVersion`. Bumped by
    /// `HealthDataCoordinator`'s mirror pass whenever a retroactive
    /// sleep-stage correction updates this row in place and re-dirties it.
    var pendingSyncVersion: Int = 0

    init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        stage: String,
        sourceBundleID: String,
        sourceName: String,
        deviceModel: String? = nil,
        syncedToServer: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.stage = stage
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.deviceModel = deviceModel
        self.syncedToServer = syncedToServer
        self.createdAt = createdAt
        self.pendingSyncVersion = 0
    }
}
