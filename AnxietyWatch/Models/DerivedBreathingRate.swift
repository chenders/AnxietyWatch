// AnxietyWatch/Models/DerivedBreathingRate.swift
import Foundation
import SwiftData

/// Per-minute breathing rate derived from accelerometer wrist motion.
@Model
final class DerivedBreathingRate {
    #Unique<DerivedBreathingRate>([\.id])

    var id: UUID
    var timestamp: Date
    var breathsPerMinute: Double
    var confidence: Double          // 0–1 quality of the estimate
    var source: String              // "accelerometer" or "healthkit_sleep"
    var sensorSessionID: UUID?
    /// `true` once the row has been mirrored to the sync server via
    /// `/api/sync`. Matches the `HRVReading` / `QuantityHealthSample`
    /// pattern. Defaulted for lightweight SwiftData migration of
    /// existing rows.
    var syncedToServer: Bool = false
    /// Staleness token for the post-upload synced-flag flip; see
    /// `SensorSession.pendingSyncVersion`. DerivedBreathingRates are
    /// append-only today (no post-insert mutation path), so this stays
    /// 0 — the field exists so any future correction path that
    /// re-dirties a row is automatically covered by the same race guard
    /// as the other synced types. Defaulted for lightweight migration.
    var pendingSyncVersion: Int = 0
    /// True once transferred to the phone; see `PhoneTransferable` (F-018).
    var transferredToPhone: Bool = false

    init(id: UUID = UUID(), timestamp: Date, breathsPerMinute: Double, confidence: Double,
         source: String, sensorSessionID: UUID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.breathsPerMinute = breathsPerMinute
        self.confidence = confidence
        self.source = source
        self.sensorSessionID = sensorSessionID
        self.syncedToServer = false
        self.pendingSyncVersion = 0
    }
}

extension DerivedBreathingRate: PhoneTransferable {}
