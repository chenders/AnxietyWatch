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

    init(startTime: Date, batteryAtStart: Int) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = nil
        self.interruptions = []
        self.batteryAtStart = batteryAtStart
        self.batteryAtEnd = nil
        self.source = nil
        self.summaryJSON = nil
    }
}
