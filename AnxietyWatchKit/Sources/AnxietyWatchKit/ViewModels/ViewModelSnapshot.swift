import Foundation

/// A point-in-time snapshot of the monitoring state for ViewModel consumption.
/// Lightweight (< 200 bytes), sendable, and thread-safe for crossing the
/// actor boundary from SensorRouter to @MainActor SwiftUI views.
///
/// Spec §3.4: emitted at 10 Hz by SensorRouter.throttled(rate:).
public struct ViewModelSnapshot: Sendable, Equatable, Codable {
    /// Latest instantaneous heart rate (bpm), or nil if no HR has arrived yet.
    public var latestHR: Int?

    /// Latest SpO2 percentage, or nil if no oximetry data has arrived yet.
    public var latestSpO2: Int?

    /// Latest HRV (SDNN ms), or nil if no HRV data has arrived yet.
    public var latestHRV: Double?

    /// Current alert tier per the CNS pipeline.
    public var alertTier: AlertTier

    /// True when no source has delivered a frame for ≥ 60 s.
    public var isIdle: Bool

    /// Fusion score from the CNS fusion engine (0.0 = healthy, 1.0 = max risk).
    public var fusionScore: Double

    public init(
        latestHR: Int? = nil,
        latestSpO2: Int? = nil,
        latestHRV: Double? = nil,
        alertTier: AlertTier = .normal,
        isIdle: Bool = true,
        fusionScore: Double = 0.0
    ) {
        self.latestHR = latestHR
        self.latestSpO2 = latestSpO2
        self.latestHRV = latestHRV
        self.alertTier = alertTier
        self.isIdle = isIdle
        self.fusionScore = fusionScore
    }
}
