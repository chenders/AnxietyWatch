import Foundation

/// A point-in-time snapshot of live vitals for ViewModel consumption.
/// Lightweight, sendable, and safe for crossing the actor boundary from
/// SensorRouter to @MainActor SwiftUI views.
public struct ViewModelSnapshot: Sendable, Equatable, Codable {
    public var latestHR: Int?
    public var latestSpO2: Int?
    public var latestHRV: Double?
    public var vitalsStatus: VitalsStatus
    public var isIdle: Bool

    public init(
        latestHR: Int? = nil,
        latestSpO2: Int? = nil,
        latestHRV: Double? = nil,
        vitalsStatus: VitalsStatus = .idle,
        isIdle: Bool = true
    ) {
        self.latestHR = latestHR
        self.latestSpO2 = latestSpO2
        self.latestHRV = latestHRV
        self.vitalsStatus = vitalsStatus
        self.isIdle = isIdle
    }
}
