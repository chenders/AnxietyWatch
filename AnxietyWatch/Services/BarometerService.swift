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
    var onSignificantChange: ((Double, Double) -> Void)?

    var currentPressureKPa: Double?
    var currentRelativeAltitude: Double?
    private(set) var isMonitoring = false

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

    /// Save a reading when pressure changes by >= 0.05 kPa or at least 15 minutes have elapsed.
    private func captureIfSignificant(pressure: Double, altitude: Double) {
        let now = Date.now
        let timeSinceLastSave = lastSavedTime.map { now.timeIntervalSince($0) } ?? .infinity
        let pressureDelta = lastSavedPressure.map { abs(pressure - $0) } ?? .infinity

        guard pressureDelta >= 0.05 || timeSinceLastSave >= 900 else { return }

        lastSavedPressure = pressure
        lastSavedTime = now
        onSignificantChange?(pressure, altitude)
    }
}
