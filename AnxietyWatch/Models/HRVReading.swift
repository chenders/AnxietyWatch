// AnxietyWatch/Models/HRVReading.swift
import Foundation
import SwiftData

/// Per-minute full-spectrum HRV computed from beat-to-beat RR intervals.
@Model
final class HRVReading {
    #Unique<HRVReading>([\.id])

    var id: UUID
    var timestamp: Date
    var rmssd: Double       // Root mean square of successive differences (ms)
    var sdnn: Double        // Standard deviation of NN intervals (ms)
    var pnn50: Double       // % of successive diffs > 50ms
    var lfPower: Double     // Low-frequency power 0.04–0.15 Hz
    var hfPower: Double     // High-frequency power 0.15–0.40 Hz
    var lfHfRatio: Double   // Sympathovagal balance
    var sensorSessionID: UUID?
    /// Originating data source for this reading (e.g. "polar_h10",
    /// "apple_watch_ppg"). New Polar sessions always populate this. Nil
    /// otherwise — covers both pre-source-tracking rows and rows from the
    /// existing Watch → phone transfer pipeline that doesn't set source yet.
    var source: String?
    /// `true` once the reading has been mirrored to the sync server via
    /// `/api/sync`. Matches the `QuantityHealthSample` / `SleepStageEvent`
    /// pattern.
    var syncedToServer: Bool = false
    /// Staleness token for the post-upload synced-flag flip; see
    /// `SensorSession.pendingSyncVersion`. HRVReadings are append-only today
    /// (no post-insert mutation path), so this stays 0 — the field exists so
    /// any future correction path that re-dirties a reading is automatically
    /// covered by the same race guard as the other synced types.
    var pendingSyncVersion: Int = 0

    init(id: UUID = UUID(), timestamp: Date, rmssd: Double, sdnn: Double, pnn50: Double,
         lfPower: Double, hfPower: Double, lfHfRatio: Double,
         sensorSessionID: UUID? = nil, source: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.rmssd = rmssd
        self.sdnn = sdnn
        self.pnn50 = pnn50
        self.lfPower = lfPower
        self.hfPower = hfPower
        self.lfHfRatio = lfHfRatio
        self.sensorSessionID = sensorSessionID
        self.source = source
        self.syncedToServer = false
        self.pendingSyncVersion = 0
    }
}
