import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for BarometerService.shouldCapture — the debounce/threshold logic
/// that decides when a barometric reading is worth persisting.
struct BarometerServiceTests {

    private let basePressure = 101.325
    private let baseTime = Date(timeIntervalSince1970: 1_711_300_000)

    // MARK: - First reading (no previous state)

    @Test("First reading always captures (no previous pressure)")
    func firstReadingCaptures() {
        let result = BarometerService.shouldCapture(
            pressure: basePressure,
            lastSavedPressure: nil,
            lastSavedTime: nil,
            now: baseTime
        )
        #expect(result == true)
    }

    // MARK: - Pressure threshold

    @Test("Captures when pressure changes by exactly the threshold")
    func capturesAtExactThreshold() {
        let delta = BarometerService.significantPressureChangeKPa
        let result = BarometerService.shouldCapture(
            pressure: basePressure + delta,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(1)
        )
        #expect(result == true)
    }

    @Test("Captures when pressure drops significantly")
    func capturesLargeDrop() {
        let result = BarometerService.shouldCapture(
            pressure: basePressure - 0.1,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(1)
        )
        #expect(result == true)
    }

    @Test("Suppresses when pressure change is below threshold")
    func suppressesSmallChange() {
        let result = BarometerService.shouldCapture(
            pressure: basePressure + 0.01,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(1)
        )
        #expect(result == false)
    }

    @Test("Suppresses when pressure is identical")
    func suppressesIdenticalPressure() {
        let result = BarometerService.shouldCapture(
            pressure: basePressure,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(60)
        )
        #expect(result == false)
    }

    // MARK: - Time threshold

    @Test("Captures when minimum interval has elapsed even without pressure change")
    func capturesAfterTimeInterval() {
        let interval = BarometerService.minimumSaveIntervalSeconds
        let result = BarometerService.shouldCapture(
            pressure: basePressure,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(interval)
        )
        #expect(result == true)
    }

    @Test("Suppresses when just under the time interval")
    func suppressesJustUnderInterval() {
        let interval = BarometerService.minimumSaveIntervalSeconds
        let result = BarometerService.shouldCapture(
            pressure: basePressure,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(interval - 1)
        )
        #expect(result == false)
    }

    // MARK: - Combined conditions

    @Test("Captures when both thresholds exceeded")
    func capturesBothExceeded() {
        let result = BarometerService.shouldCapture(
            pressure: basePressure + 0.1,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(1000)
        )
        #expect(result == true)
    }

    @Test("Captures when only pressure threshold met (recent save)")
    func capturesPressureOnlyRecentSave() {
        let result = BarometerService.shouldCapture(
            pressure: basePressure + 0.06,
            lastSavedPressure: basePressure,
            lastSavedTime: baseTime,
            now: baseTime.addingTimeInterval(10)
        )
        #expect(result == true)
    }

    // MARK: - Threshold constants

    @Test("Pressure threshold is 0.05 kPa")
    func pressureThreshold() {
        #expect(BarometerService.significantPressureChangeKPa == 0.05)
    }

    @Test("Time threshold is 900 seconds (15 minutes)")
    func timeThreshold() {
        #expect(BarometerService.minimumSaveIntervalSeconds == 900)
    }
}
