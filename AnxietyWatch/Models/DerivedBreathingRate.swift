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

    init(id: UUID = UUID(), timestamp: Date, breathsPerMinute: Double, confidence: Double,
         source: String, sensorSessionID: UUID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.breathsPerMinute = breathsPerMinute
        self.confidence = confidence
        self.source = source
        self.sensorSessionID = sensorSessionID
    }
}
