import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for BarometricTrendChart downsampling logic.
struct BarometricDownsamplingTests {

    /// Replicates the downsampling logic from BarometricTrendChart.
    private func downsample(_ readings: [BarometricReading], maxPoints: Int = 500) -> [BarometricReading] {
        guard readings.count > maxPoints else { return readings }
        let stride = Int(ceil(Double(readings.count) / Double(maxPoints)))
        return Array(Swift.stride(from: 0, to: readings.count, by: stride).map { readings[$0] }.prefix(maxPoints))
    }

    private func makeReadings(count: Int) -> [BarometricReading] {
        let base = ModelFactory.referenceDate
        return (0..<count).map { i in
            let date = base.addingTimeInterval(Double(i) * 5.0) // 5 seconds apart
            return BarometricReading(
                timestamp: date,
                pressureKPa: 101.3 + Double(i) * 0.001,
                relativeAltitudeM: 0.0
            )
        }
    }

    @Test("Small dataset is not downsampled")
    func smallDatasetUnchanged() {
        let readings = makeReadings(count: 100)
        let result = downsample(readings)
        #expect(result.count == 100)
    }

    @Test("500 readings are not downsampled")
    func exactThresholdUnchanged() {
        let readings = makeReadings(count: 500)
        let result = downsample(readings)
        #expect(result.count == 500)
    }

    @Test("1000 readings are downsampled to ~500")
    func largeDatasetDownsampled() {
        let readings = makeReadings(count: 1000)
        let result = downsample(readings)
        #expect(result.count == 500)
    }

    @Test("50000 readings are downsampled to ~500")
    func veryLargeDatasetDownsampled() {
        let readings = makeReadings(count: 50000)
        let result = downsample(readings)
        #expect(result.count <= 500)
        #expect(result.count >= 490)
    }

    @Test("Downsampled readings preserve first reading")
    func preservesFirstReading() {
        let readings = makeReadings(count: 2000)
        let result = downsample(readings)
        #expect(result.first?.timestamp == readings.first?.timestamp)
    }

    @Test("Downsampled readings are evenly spaced from original")
    func evenlySpaced() {
        let readings = makeReadings(count: 2000)
        let result = downsample(readings)
        // Stride should be 4 (2000/500)
        if result.count >= 3 {
            let gap1 = result[1].timestamp.timeIntervalSince(result[0].timestamp)
            let gap2 = result[2].timestamp.timeIntervalSince(result[1].timestamp)
            #expect(abs(gap1 - gap2) < 0.01)
        }
    }
}
