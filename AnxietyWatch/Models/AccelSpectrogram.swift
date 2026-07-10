// AnxietyWatch/Models/AccelSpectrogram.swift
import Foundation
import SwiftData

/// 10-second FFT spectral bin from accelerometer magnitude signal.
@Model
final class AccelSpectrogram {
    #Unique<AccelSpectrogram>([\.id])

    var id: UUID
    var timestamp: Date             // Start of 10-second window
    var tremorBandPower: Double     // 4–12 Hz spectral power
    var breathingBandPower: Double  // 0.2–0.4 Hz spectral power
    var fidgetBandPower: Double     // 0.5–4 Hz spectral power
    var activityLevel: Double       // Overall RMS acceleration (g)
    var sensorSessionID: UUID?
    /// `true` once the row has been mirrored to the sync server via
    /// `/api/sync`. Matches the `HRVReading` / `QuantityHealthSample`
    /// pattern. Defaulted for lightweight SwiftData migration of
    /// existing rows.
    var syncedToServer: Bool = false
    /// Staleness token for the post-upload synced-flag flip; see
    /// `SensorSession.pendingSyncVersion`. AccelSpectrograms are
    /// append-only today (no post-insert mutation path), so this stays
    /// 0 — the field exists so any future correction path that
    /// re-dirties a row is automatically covered by the same race guard
    /// as the other synced types. Defaulted for lightweight migration.
    var pendingSyncVersion: Int = 0
    /// True once this row has been successfully transferred to the phone.
    /// Gates the Watch → phone batch so already-sent rows aren't re-sent
    /// every cycle; see `PhoneTransferable` (F-018). Defaulted for
    /// lightweight SwiftData migration of existing rows.
    var transferredToPhone: Bool = false

    init(id: UUID = UUID(), timestamp: Date, tremorBandPower: Double, breathingBandPower: Double,
         fidgetBandPower: Double, activityLevel: Double,
         sensorSessionID: UUID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.tremorBandPower = tremorBandPower
        self.breathingBandPower = breathingBandPower
        self.fidgetBandPower = fidgetBandPower
        self.activityLevel = activityLevel
        self.sensorSessionID = sensorSessionID
        self.syncedToServer = false
        self.pendingSyncVersion = 0
    }
}

extension AccelSpectrogram: PhoneTransferable {}
