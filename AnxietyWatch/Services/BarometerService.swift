import CoreMotion

/// CMAltimeter wrapper for barometric pressure readings.
/// Readings are only available while the app is running — store them in SwiftData.
@Observable
final class BarometerService {
    static let shared = BarometerService()

    private let altimeter = CMAltimeter()
    private var lastSavedPressure: Double?
    private var lastSavedTime: Date?

    /// Called whenever a new reading is worth persisting.
    /// Always invoked on the main actor (from `startRelativeAltitudeUpdates` on `.main` queue).
    var onSignificantChange: ((Double, Double) -> Void)?

    var currentPressureKPa: Double?
    var currentRelativeAltitude: Double?
    private(set) var isMonitoring = false

    // MARK: - Capture Thresholds

    /// Minimum pressure change (kPa) to trigger a save.
    static let significantPressureChangeKPa = 0.05
    /// Minimum interval (seconds) between saves, even without pressure change.
    static let minimumSaveIntervalSeconds: TimeInterval = 900

    var isAvailable: Bool {
        CMAltimeter.isRelativeAltitudeAvailable()
    }

    func startMonitoring() {
        guard isAvailable, !isMonitoring else { return }
        isMonitoring = true

        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pressure = data.pressure.doubleValue
                let altitude = data.relativeAltitude.doubleValue
                self.currentPressureKPa = pressure
                self.currentRelativeAltitude = altitude
                self.captureIfSignificant(pressure: pressure, altitude: altitude)
            }
        }
    }

    func stopMonitoring() {
        altimeter.stopRelativeAltitudeUpdates()
        isMonitoring = false
    }

    /// Pure decision: should we capture this reading based on thresholds?
    static func shouldCapture(
        pressure: Double,
        lastSavedPressure: Double?,
        lastSavedTime: Date?,
        now: Date
    ) -> Bool {
        let timeSinceLastSave = lastSavedTime.map { now.timeIntervalSince($0) } ?? .infinity
        let pressureDelta = lastSavedPressure.map { abs(pressure - $0) } ?? .infinity
        return pressureDelta >= significantPressureChangeKPa
            || timeSinceLastSave >= minimumSaveIntervalSeconds
    }

    /// Save a reading when pressure changes significantly or enough time has elapsed.
    private func captureIfSignificant(pressure: Double, altitude: Double) {
        let now = Date.now
        guard Self.shouldCapture(
            pressure: pressure,
            lastSavedPressure: lastSavedPressure,
            lastSavedTime: lastSavedTime,
            now: now
        ) else { return }

        if let callback = onSignificantChange {
            lastSavedPressure = pressure
            lastSavedTime = now
            callback(pressure, altitude)
        }
    }
}
