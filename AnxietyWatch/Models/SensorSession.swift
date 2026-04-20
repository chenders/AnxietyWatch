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

    init(startTime: Date, batteryAtStart: Int) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = nil
        self.interruptions = []
        self.batteryAtStart = batteryAtStart
        self.batteryAtEnd = nil
    }
}
