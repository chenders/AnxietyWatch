// AnxietyWatch/Models/HRVReading.swift
import Foundation
import SwiftData

/// Per-minute full-spectrum HRV computed from beat-to-beat RR intervals.
@Model
final class HRVReading {
    var id: UUID
    var timestamp: Date
    var rmssd: Double       // Root mean square of successive differences (ms)
    var sdnn: Double        // Standard deviation of NN intervals (ms)
    var pnn50: Double       // % of successive diffs > 50ms
    var lfPower: Double     // Low-frequency power 0.04–0.15 Hz
    var hfPower: Double     // High-frequency power 0.15–0.40 Hz
    var lfHfRatio: Double   // Sympathovagal balance
    var sensorSessionID: UUID?

    init(id: UUID = UUID(), timestamp: Date, rmssd: Double, sdnn: Double, pnn50: Double,
         lfPower: Double, hfPower: Double, lfHfRatio: Double,
         sensorSessionID: UUID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.rmssd = rmssd
        self.sdnn = sdnn
        self.pnn50 = pnn50
        self.lfPower = lfPower
        self.hfPower = hfPower
        self.lfHfRatio = lfHfRatio
        self.sensorSessionID = sensorSessionID
    }
}
