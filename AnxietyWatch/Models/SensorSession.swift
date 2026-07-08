// AnxietyWatch/Models/SensorSession.swift
import Foundation
import SwiftData

/// Codable record of a sensor capture interruption (user workout, Low Power Mode, etc.)
struct SensorInterruption: Codable {
    var reason: String      // "userWorkout", "lowPowerMode", "charging"
    var startTime: Date
    var endTime: Date?
}

/// Tracks a continuous sensor capture session on the watch.
@Model
final class SensorSession {
    var id: UUID
    var startTime: Date
    var endTime: Date?
    var interruptions: [SensorInterruption]
    var batteryAtStart: Int
    var batteryAtEnd: Int?
    /// Originating data source for this session (e.g. "polar_h10"). New
    /// Polar sessions always populate this. Nil otherwise — covers both
    /// pre-source-tracking rows and Watch-side capture sessions that
    /// don't set source yet.
    var source: String?
    /// JSON-encoded session summary (e.g. rmssdMean, rrCount, durationSec).
    /// Schema is intentionally flexible while we figure out which derived
    /// fields actually drive the chart pipeline.
    var summaryJSON: String?
    /// `true` once the session row has been mirrored to the sync server via
    /// `/api/sync`. Matches the `QuantityHealthSample` / `SleepStageEvent`
    /// pattern so `SyncService` can fetch unsynced rows generically.
    var syncedToServer: Bool = false
    /// Timestamp the RR-interval binary archive was successfully uploaded
    /// via `POST /api/sensor_sessions/<id>/rr_archive`. Nil until upload
    /// lands. Tracked separately from `syncedToServer` because the archive
    /// upload is a second HTTP call that can fail independently — the next
    /// sync run retries any session where this is nil but the on-disk
    /// `.rr` file still exists.
    var rrArchiveUploadedAt: Date?
    /// Monotonic counter bumped alongside every post-creation
    /// `syncedToServer = false` re-dirty (finalize / finalizeOrphan).
    /// `SyncService` captures this value at payload-build time and the
    /// post-upload flag flip skips any row whose current version drifted —
    /// closing the race where a finalize interleaves with an in-flight
    /// sync's network await and the flip would otherwise mark the
    /// finalized-but-not-uploaded state as synced (stranding `endTime` /
    /// `summaryJSON` server-side forever). Mirrors
    /// `HealthSnapshot.pendingSyncVersion`.
    var pendingSyncVersion: Int = 0

    init(startTime: Date, batteryAtStart: Int) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = nil
        self.interruptions = []
        self.batteryAtStart = batteryAtStart
        self.batteryAtEnd = nil
        self.source = nil
        self.summaryJSON = nil
        self.syncedToServer = false
        self.rrArchiveUploadedAt = nil
        self.pendingSyncVersion = 0
    }
}
