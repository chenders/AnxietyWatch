// AnxietyWatchTests/HRVCalculatorTests.swift
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
}
