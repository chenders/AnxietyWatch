// AnxietyWatchTests/SpectralAnalyzerTests.swift
import Darwin
import Testing

@testable import AnxietyWatch

struct SpectralAnalyzerTests {

    @Test("PSD of pure sine wave peaks at signal frequency")
    func psdSineWavePeak() {
        let sampleRate: Float = 200.0
        let frequency: Float = 10.0
        let sampleCount = 2000 // 10 seconds

        let signal = (0..<sampleCount).map { i in
            sinf(2.0 * .pi * frequency * Float(i) / sampleRate)
        }

        guard let psd = SpectralAnalyzer.computePSD(signal: signal, sampleRate: sampleRate) else {
            Issue.record("PSD returned nil")
            return
        }

        // Peak should be at or within 1 bin of 10Hz
        let peakIndex = psd.magnitudes.indices.max(by: { psd.magnitudes[$0] < psd.magnitudes[$1] })!
        let peakFreq = psd.frequencies[peakIndex]
        let freqRes = sampleRate / Float(1 << Int(ceil(log2(Float(sampleCount)))))
        #expect(abs(peakFreq - frequency) <= freqRes)
    }

    @Test("Band power captures energy in correct frequency band")
    func bandPowerCorrectBand() {
        let sampleRate: Float = 200.0
        let frequency: Float = 8.0 // In tremor band (4–12Hz)
        let sampleCount = 2000

        let signal = (0..<sampleCount).map { i in
            sinf(2.0 * .pi * frequency * Float(i) / sampleRate)
        }

        guard let psd = SpectralAnalyzer.computePSD(signal: signal, sampleRate: sampleRate) else {
            Issue.record("PSD returned nil")
            return
        }

        let tremorPower = SpectralAnalyzer.bandPower(psd, lowHz: 4.0, highHz: 12.0)
        let breathingPower = SpectralAnalyzer.bandPower(psd, lowHz: 0.2, highHz: 0.4)

        #expect(tremorPower > 0)
        #expect(tremorPower > breathingPower * 100)
    }

    @Test("Band power outside signal frequency is near zero")
    func bandPowerOutsideSignal() {
        let sampleRate: Float = 200.0
        let signal = (0..<2000).map { i in
            sinf(2.0 * .pi * 50.0 * Float(i) / sampleRate) // 50Hz
        }

        guard let psd = SpectralAnalyzer.computePSD(signal: signal, sampleRate: sampleRate) else {
            Issue.record("PSD returned nil")
            return
        }

        // 50Hz signal should have negligible energy in breathing band
        let breathingPower = SpectralAnalyzer.bandPower(psd, lowHz: 0.2, highHz: 0.4)
        #expect(breathingPower < 0.001)
    }

    @Test("RMS of known signal is correct")
    func rmsKnownSignal() {
        // RMS of [3, 4] = sqrt((9+16)/2) = sqrt(12.5) ≈ 3.536
        let result = SpectralAnalyzer.rms([3.0, 4.0])
        #expect(abs(result - 3.536) < 0.01)
    }

    @Test("RMS of empty signal is zero")
    func rmsEmpty() {
        #expect(SpectralAnalyzer.rms([]) == 0)
    }

    @Test("PSD returns nil for fewer than 4 samples")
    func psdTooShort() {
        #expect(SpectralAnalyzer.computePSD(signal: [1, 2, 3], sampleRate: 100) == nil)
    }

    @Test("PSD returns non-nil for 4+ samples")
    func psdMinimum() {
        #expect(SpectralAnalyzer.computePSD(signal: [1, 2, 3, 4], sampleRate: 100) != nil)
    }
}
