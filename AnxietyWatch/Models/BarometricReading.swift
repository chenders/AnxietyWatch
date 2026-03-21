import Foundation
import SwiftData

@Model
final class BarometricReading {
    var id: UUID
    var timestamp: Date
    /// Atmospheric pressure in kilopascals
    var pressureKPa: Double
    /// Altitude change in meters relative to CMAltimeter start point
    var relativeAltitudeM: Double

    init(
        timestamp: Date = .now,
        pressureKPa: Double,
        relativeAltitudeM: Double
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.pressureKPa = pressureKPa
        self.relativeAltitudeM = relativeAltitudeM
    }
}
