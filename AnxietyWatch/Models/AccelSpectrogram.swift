// AnxietyWatch/Models/AccelSpectrogram.swift
import Foundation
import SwiftData

/// 10-second FFT spectral bin from accelerometer magnitude signal.
@Model
final class AccelSpectrogram {
    var id: UUID
    var timestamp: Date             // Start of 10-second window
    var tremorBandPower: Double     // 4–12 Hz spectral power
    var breathingBandPower: Double  // 0.2–0.4 Hz spectral power
    var fidgetBandPower: Double     // 0.5–4 Hz spectral power
    var activityLevel: Double       // Overall RMS acceleration (g)
    var sensorSessionID: UUID?

    init(timestamp: Date, tremorBandPower: Double, breathingBandPower: Double,
         fidgetBandPower: Double, activityLevel: Double,
         sensorSessionID: UUID? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.tremorBandPower = tremorBandPower
        self.breathingBandPower = breathingBandPower
        self.fidgetBandPower = fidgetBandPower
        self.activityLevel = activityLevel
        self.sensorSessionID = sensorSessionID
    }
}
