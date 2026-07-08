// AnxietyWatchTests/HRVCalculatorTests.swift
import Darwin
import Testing

@testable import AnxietyWatch

struct HRVCalculatorTests {

    // MARK: - Time Domain

    @Test("RMSSD from known RR intervals")
    func rmssdCorrect() {
        let intervals: [Double] = [800, 850, 790, 810, 760]
        let result = HRVCalculator.timeDomain(rrIntervals: intervals)!
        // sqrt((2500+3600+400+2500)/4) = sqrt(2250) ≈ 47.434
        #expect(abs(result.rmssd - 47.434) < 0.01)
    }

    @Test("SDNN from known RR intervals")
    func sdnnCorrect() {
        let intervals: [Double] = [800, 850, 790, 810, 760]
        let result = HRVCalculator.timeDomain(rrIntervals: intervals)!
        // sqrt((4+2304+144+64+1764)/4) = sqrt(1070) ≈ 32.711
        #expect(abs(result.sdnn - 32.711) < 0.01)
    }

    @Test("pNN50 from known RR intervals")
    func pnn50Correct() {
        let intervals: [Double] = [800, 850, 790, 810, 760]
        let result = HRVCalculator.timeDomain(rrIntervals: intervals)!
        // Only |−60| > 50 → 1/4 = 25.0%
        #expect(abs(result.pnn50 - 25.0) < 0.01)
    }

    // MARK: - Adjacency-aware time domain (F-026)

    @Test("Removed interior artifact does not splice its neighbors into a fake successive pair")
    func artifactExclusionDoesNotSplice() {
        // 120 ms is a contact artifact between two steady 800/900 runs.
        // The spliced (filter-then-diff) computation would see 900-800=100 as
        // a successive difference across the excised beat; the adjacency-aware
        // path must drop both pairs that touch the artifact.
        let raw: [Double] = [800, 800, 120, 900, 900]
        let result = HRVCalculator.timeDomain(rawRRIntervals: raw)!
        // Valid adjacent pairs: (800,800) → 0 and (900,900) → 0. No 100-ms
        // gap-spanning diff → RMSSD 0, pNN50 0.
        #expect(abs(result.rmssd) < 0.001)
        #expect(abs(result.pnn50) < 0.001)
        // SDNN/mean still use all four in-range intervals.
        #expect(result.count == 4)
        #expect(abs(result.meanRR - 850) < 0.001)

        // Contrast: the spliced legacy computation over the filtered array
        // would report a nonzero RMSSD from the fabricated 100 ms diff.
        let spliced = HRVCalculator.timeDomain(rrIntervals: [800, 800, 900, 900])!
        #expect(spliced.rmssd > 50)
    }

    @Test("Clean sequences produce identical results through both time-domain paths")
    func adjacencyAwareMatchesLegacyOnCleanData() {
        let intervals: [Double] = [800, 850, 790, 810, 760]
        let legacy = HRVCalculator.timeDomain(rrIntervals: intervals)!
        let adjacencyAware = HRVCalculator.timeDomain(rawRRIntervals: intervals)!
        #expect(abs(legacy.rmssd - adjacencyAware.rmssd) < 0.001)
        #expect(abs(legacy.sdnn - adjacencyAware.sdnn) < 0.001)
        #expect(abs(legacy.pnn50 - adjacencyAware.pnn50) < 0.001)
        #expect(legacy.count == adjacencyAware.count)
    }

    @Test("No adjacent in-range pair returns nil rather than a fabricated RMSSD")
    func noAdjacentPairReturnsNil() {
        // Every valid beat is separated by an artifact — RMSSD is undefined.
        let raw: [Double] = [800, 120, 850, 90, 900]
        #expect(HRVCalculator.timeDomain(rawRRIntervals: raw) == nil)
    }

    @Test("Mean RR is correct")
    func meanRRCorrect() {
        let intervals: [Double] = [800, 850, 790, 810, 760]
        let result = HRVCalculator.timeDomain(rrIntervals: intervals)!
        #expect(abs(result.meanRR - 802.0) < 0.01)
    }

    @Test("Returns nil for fewer than 2 intervals")
    func timeDomainMinimum() {
        #expect(HRVCalculator.timeDomain(rrIntervals: [800]) == nil)
        #expect(HRVCalculator.timeDomain(rrIntervals: []) == nil)
    }

    @Test("Constant intervals produce zero RMSSD and SDNN")
    func constantIntervals() {
        let intervals: [Double] = [800, 800, 800, 800, 800]
        let result = HRVCalculator.timeDomain(rrIntervals: intervals)!
        #expect(result.rmssd == 0)
        #expect(result.sdnn == 0)
        #expect(result.pnn50 == 0)
    }

    @Test("Two intervals produce valid result")
    func twoIntervals() {
        let intervals: [Double] = [800, 900]
        let result = HRVCalculator.timeDomain(rrIntervals: intervals)!
        // Only 1 diff: 100ms. RMSSD = 100, SDNN = sqrt((50^2+50^2)/1) = sqrt(5000) ≈ 70.71
        #expect(abs(result.rmssd - 100.0) < 0.01)
        #expect(abs(result.pnn50 - 100.0) < 0.01) // 100ms > 50ms → 100%
    }

    // MARK: - Frequency Domain

    @Test("Frequency domain returns LF and HF power from synthetic RR series")
    func frequencyDomainBasic() {
        // Sinus arrhythmia: RR modulated at 0.25Hz (in HF band, 0.15–0.4Hz)
        // Mean HR 75bpm → mean RR ~800ms
        var intervals = [Double]()
        for i in 0..<120 { // 120 beats ≈ 96 seconds
            let breathingModulation = 30.0 * sin(2.0 * .pi * 0.25 * Double(i) * 0.8)
            intervals.append(800.0 + breathingModulation)
        }

        let result = HRVCalculator.frequencyDomain(rrIntervals: intervals)
        #expect(result != nil)
        #expect(result!.hfPower > 0)
        #expect(result!.totalPower > 0)
    }

    @Test("Frequency domain requires >= 30 intervals")
    func frequencyDomainMinimum() {
        #expect(HRVCalculator.frequencyDomain(rrIntervals: [Double](repeating: 800, count: 29)) == nil)
    }

    @Test("Constant RR intervals have near-zero frequency power")
    func frequencyDomainConstant() {
        let intervals = [Double](repeating: 800, count: 60)
        let result = HRVCalculator.frequencyDomain(rrIntervals: intervals)
        #expect(result != nil)
        // Constant intervals → no spectral power
        #expect(result!.lfPower < 0.001)
        #expect(result!.hfPower < 0.001)
    }

    @Test("LF/HF ratio is zero when HF power is zero")
    func lfHfRatioZeroDenominator() {
        // Constant intervals → both LF and HF near zero
        let intervals = [Double](repeating: 800, count: 60)
        let result = HRVCalculator.frequencyDomain(rrIntervals: intervals)!
        #expect(result.lfHfRatio == 0)
    }

    // MARK: - Resampling

    @Test("Resample produces correct count for known duration")
    func resampleCount() {
        // 60 intervals of 800ms each = 48,000ms total
        // At 4Hz (250ms interval): 48000/250 = 192 samples
        let intervals = [Double](repeating: 800, count: 60)
        let resampled = HRVCalculator.resampleRRIntervals(intervals, targetRateHz: 4.0)
        #expect(resampled != nil)
        #expect(resampled!.count == 192)
    }

    @Test("Resample returns nil for too few intervals")
    func resampleTooShort() {
        #expect(HRVCalculator.resampleRRIntervals([800, 900], targetRateHz: 4.0) == nil)
    }
}
