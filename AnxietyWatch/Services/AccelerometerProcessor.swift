// AnxietyWatch/Services/AccelerometerProcessor.swift
import Accelerate

/// Derives anxiety-relevant spectral features from raw accelerometer windows.
enum AccelerometerProcessor {

    struct SpectrogramResult {
        let tremorBandPower: Double     // 4–12 Hz
        let breathingBandPower: Double  // 0.2–0.4 Hz
        let fidgetBandPower: Double     // 0.5–4 Hz
        let activityLevel: Double       // Overall RMS acceleration (g, gravity removed)
    }

    /// Process a window of 3-axis accelerometer data into spectral features.
    /// Expects x, y, z arrays of equal length with at least 4 samples.
    static func processWindow(
        x: [Float], y: [Float], z: [Float],
        sampleRate: Float
    ) -> SpectrogramResult? {
        guard x.count == y.count, y.count == z.count, x.count >= 4 else {
            return nil
        }

        let count = x.count

        // Compute acceleration magnitude: sqrt(x² + y² + z²)
        var magnitude = [Float](repeating: 0, count: count)
        for i in 0..<count {
            magnitude[i] = sqrtf(x[i] * x[i] + y[i] * y[i] + z[i] * z[i])
        }

        // Remove gravity: subtract mean (≈1g for a stationary wrist)
        let mean = magnitude.reduce(0, +) / Float(count)
        magnitude = magnitude.map { $0 - mean }

        guard let psd = SpectralAnalyzer.computePSD(
            signal: magnitude, sampleRate: sampleRate
        ) else { return nil }

        return SpectrogramResult(
            tremorBandPower: Double(SpectralAnalyzer.bandPower(psd, lowHz: 4.0, highHz: 12.0)),
            breathingBandPower: Double(SpectralAnalyzer.bandPower(psd, lowHz: 0.2, highHz: 0.4)),
            fidgetBandPower: Double(SpectralAnalyzer.bandPower(psd, lowHz: 0.5, highHz: 4.0)),
            activityLevel: Double(SpectralAnalyzer.rms(magnitude))
        )
    }

    /// Estimate breathing rate from the peak frequency in the breathing band.
    /// Returns (breathsPerMinute, confidence) or nil.
    static func estimateBreathingRate(
        x: [Float], y: [Float], z: [Float],
        sampleRate: Float
    ) -> (breathsPerMinute: Double, confidence: Double)? {
        guard x.count == y.count, y.count == z.count, x.count >= 4 else {
            return nil
        }

        let count = x.count
        var magnitude = [Float](repeating: 0, count: count)
        for i in 0..<count {
            magnitude[i] = sqrtf(x[i] * x[i] + y[i] * y[i] + z[i] * z[i])
        }
        let mean = magnitude.reduce(0, +) / Float(count)
        magnitude = magnitude.map { $0 - mean }

        guard let psd = SpectralAnalyzer.computePSD(
            signal: magnitude, sampleRate: sampleRate
        ) else { return nil }

        // Find peak in extended breathing band: 0.15–0.5Hz = 9–30 breaths/min
        let breathingBins = zip(psd.frequencies, psd.magnitudes)
            .filter { $0.0 >= 0.15 && $0.0 <= 0.5 }

        guard let peak = breathingBins.max(by: { $0.1 < $1.1 }),
              peak.1 > 0 else { return nil }

        let bpm = Double(peak.0) * 60.0

        // Confidence: ratio of peak power to total breathing band power
        let totalPower = breathingBins.reduce(Float(0)) { $0 + $1.1 }
        let confidence = totalPower > 0 ? min(Double(peak.1 / totalPower), 1.0) : 0

        return (bpm, confidence)
    }
}
