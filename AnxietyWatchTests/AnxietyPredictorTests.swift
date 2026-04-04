import Foundation
import Testing

@testable import AnxietyWatch

struct AnxietyPredictorTests {

    private func makeBaselines(count: Int, hrvAvg: Double, restingHR: Double) -> [HealthSnapshot] {
        (0..<count).map { day in
            ModelFactory.healthSnapshot(
                date: ModelFactory.daysAgo(day + 1),
                hrvAvg: hrvAvg + Double(day % 3) * 2,
                restingHR: restingHR + Double(day % 3)
            )
        }
    }

    @Test("Returns nil when no significant correlations")
    func nilWithoutSignificant() {
        let corr = ModelFactory.correlation(pValue: 0.5)
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result == nil)
    }

    @Test("Returns nil when no today snapshot")
    func nilWithoutSnapshot() {
        let corr = ModelFactory.correlation(pValue: 0.01)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: nil, baselineSnapshots: baselines
        )
        #expect(result == nil)
    }

    @Test("Score is between 0 and 1")
    func scoreInRange() {
        let corr = ModelFactory.correlation(signalName: "hrv_avg", correlation: -0.6, pValue: 0.01)
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result != nil)
        #expect(result!.score >= 0.0 && result!.score <= 1.0)
    }

    @Test("Low HRV with negative correlation produces higher score")
    func lowHRVHigherScore() {
        let corr = ModelFactory.correlation(signalName: "hrv_avg", correlation: -0.6, pValue: 0.01)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)

        let todayLow = ModelFactory.healthSnapshot(hrvAvg: 30.0)
        let todayNormal = ModelFactory.healthSnapshot(hrvAvg: 45.0)

        let lowResult = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: todayLow, baselineSnapshots: baselines
        )!
        let normalResult = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: todayNormal, baselineSnapshots: baselines
        )!

        #expect(lowResult.score > normalResult.score)
    }

    @Test("Contributing signals are sorted by weight")
    func signalsSortedByWeight() {
        let correlations = [
            ModelFactory.correlation(signalName: "hrv_avg", correlation: -0.6, pValue: 0.01),
            ModelFactory.correlation(signalName: "resting_hr", correlation: 0.3, pValue: 0.03),
        ]
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0, restingHR: 75.0)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: correlations, todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result != nil)
        let weights = result!.contributingSignals.map(\.weight)
        #expect(weights == weights.sorted(by: >))
    }

    @Test("Insufficient baseline data returns nil")
    func insufficientBaselines() {
        let corr = ModelFactory.correlation(pValue: 0.01)
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0)
        let baselines = makeBaselines(count: 3, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result == nil)
    }
}
