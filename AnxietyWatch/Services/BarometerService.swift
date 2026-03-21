import CoreMotion

/// CMAltimeter wrapper for barometric pressure readings.
/// Readings are only available while the app is running — store them in SwiftData.
@Observable
final class BarometerService {
    static let shared = BarometerService()

    private let altimeter = CMAltimeter()

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
                self?.currentPressureKPa = data.pressure.doubleValue
                self?.currentRelativeAltitude = data.relativeAltitude.doubleValue
            }
        }
    }

    func stopMonitoring() {
        altimeter.stopRelativeAltitudeUpdates()
        isMonitoring = false
    }
}
