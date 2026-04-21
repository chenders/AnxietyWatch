// AnxietyWatchTests/AccelerometerProcessorTests.swift
import Darwin
import Testing

@testable import AnxietyWatch

struct AccelerometerProcessorTests {

    @Test("Processes 10-second window with tremor signal")
    func processWindowTremor() {
        let sampleRate: Float = 200.0
        let count = 2000 // 10 seconds

        // 8Hz tremor in x-axis, gravity in z-axis
        let x = (0..<count).map { i -> Float in
            0.01 * sinf(2.0 * .pi * 8.0 * Float(i) / sampleRate)
        }
        let y = [Float](repeating: 0, count: count)
        let z = [Float](repeating: 1.0, count: count) // gravity

        let result = AccelerometerProcessor.processWindow(
            x: x, y: y, z: z, sampleRate: sampleRate
        )
        #expect(result != nil)
        #expect(result!.tremorBandPower > 0)
        #expect(result!.activityLevel > 0)
    }

    @Test("Breathing signal lands in breathing band")
    func processWindowBreathing() {
        let sampleRate: Float = 200.0
        let count = 2000

        // 0.3Hz breathing modulation in z-axis (wrist rises/falls with chest)
        let x = [Float](repeating: 0, count: count)
        let y = [Float](repeating: 0, count: count)
        let z = (0..<count).map { i -> Float in
            1.0 + 0.05 * sinf(2.0 * .pi * 0.3 * Float(i) / sampleRate)
        }

        let result = AccelerometerProcessor.processWindow(
            x: x, y: y, z: z, sampleRate: sampleRate
        )
        #expect(result != nil)
        #expect(result!.breathingBandPower > 0)
    }

    @Test("Returns nil for mismatched axis lengths")
    func mismatchedAxes() {
        let result = AccelerometerProcessor.processWindow(
            x: [1, 2, 3], y: [1, 2], z: [1, 2, 3], sampleRate: 200
        )
        #expect(result == nil)
    }

    @Test("Returns nil for too-short window")
    func tooShort() {
        let result = AccelerometerProcessor.processWindow(
            x: [1, 2, 3], y: [1, 2, 3], z: [1, 2, 3], sampleRate: 200
        )
        #expect(result == nil)
    }

    @Test("Breathing rate estimation finds correct frequency")
    func breathingRateEstimate() {
        let sampleRate: Float = 200.0
        let count = 12000 // 60 seconds for better frequency resolution

        // 0.25Hz = 15 breaths/min
        let x = [Float](repeating: 0, count: count)
        let y = [Float](repeating: 0, count: count)
        let z = (0..<count).map { i -> Float in
            1.0 + 0.05 * sinf(2.0 * .pi * 0.25 * Float(i) / sampleRate)
        }

        let result = AccelerometerProcessor.estimateBreathingRate(
            x: x, y: y, z: z, sampleRate: sampleRate
        )
        #expect(result != nil)
        #expect(abs(result!.breathsPerMinute - 15.0) < 2.0)
        #expect(result!.confidence > 0)
    }
}
