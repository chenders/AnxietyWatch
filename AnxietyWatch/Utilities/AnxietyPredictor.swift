import Foundation

enum AnxietyPredictor {

    struct PredictionResult {
        let score: Double
        let contributingSignals: [(name: String, direction: String, weight: Double)]
    }

    static func predict(
        correlations: [PhysiologicalCorrelation],
        todaySnapshot: HealthSnapshot?,
        baselineSnapshots: [HealthSnapshot]
    ) -> PredictionResult? {
        let significant = correlations.filter { $0.isSignificant }
        guard !significant.isEmpty, let today = todaySnapshot else { return nil }

        var contributions: [(name: String, direction: String, weight: Double)] = []
        var totalWeight = 0.0

        for corr in significant {
            guard let (todayValue, baselineMean, baselineStd) = signalValues(
                for: corr.signalName, today: today, baselines: baselineSnapshots
            ), baselineStd > 0 else { continue }

            let z = (todayValue - baselineMean) / baselineStd
            let weight = z * corr.correlation
            totalWeight += weight

            let direction = weight > 0 ? "elevated risk" : "reduced risk"
            contributions.append((corr.displayName, direction, abs(weight)))
        }

        guard !contributions.isEmpty else { return nil }

        let score = 1.0 / (1.0 + exp(-totalWeight))
        let sorted = contributions.sorted { $0.weight > $1.weight }

        return PredictionResult(score: score, contributingSignals: sorted)
    }

    private static func signalValues(
        for signalName: String,
        today: HealthSnapshot,
        baselines: [HealthSnapshot]
    ) -> (todayValue: Double, mean: Double, std: Double)? {
        switch signalName {
        case "hrv_avg":
            guard let v = today.hrvAvg else { return nil }
            return computeStats(todayValue: v, baselineValues: baselines.compactMap(\.hrvAvg))
        case "resting_hr":
            guard let v = today.restingHR else { return nil }
            return computeStats(todayValue: v, baselineValues: baselines.compactMap(\.restingHR))
        case "sleep_duration_min":
            guard let v = today.sleepDurationMin else { return nil }
            return computeStats(todayValue: Double(v), baselineValues: baselines.compactMap(\.sleepDurationMin).map(Double.init))
        case "sleep_quality_ratio":
            guard let d = today.sleepDurationMin, d > 0 else { return nil }
            let todayRatio = Double((today.sleepDeepMin ?? 0) + (today.sleepREMMin ?? 0)) / Double(d)
            let ratios = baselines.compactMap { snap -> Double? in
                guard let dur = snap.sleepDurationMin, dur > 0 else { return nil }
                return Double((snap.sleepDeepMin ?? 0) + (snap.sleepREMMin ?? 0)) / Double(dur)
            }
            return computeStats(todayValue: todayRatio, baselineValues: ratios)
        case "steps":
            guard let v = today.steps else { return nil }
            return computeStats(todayValue: Double(v), baselineValues: baselines.compactMap(\.steps).map(Double.init))
        case "cpap_ahi":
            guard let v = today.cpapAHI else { return nil }
            return computeStats(todayValue: v, baselineValues: baselines.compactMap(\.cpapAHI))
        case "barometric_pressure_change_kpa":
            guard let v = today.barometricPressureChangeKPa else { return nil }
            return computeStats(todayValue: v, baselineValues: baselines.compactMap(\.barometricPressureChangeKPa))
        default:
            return nil
        }
    }

    private static func computeStats(
        todayValue: Double,
        baselineValues: [Double]
    ) -> (Double, Double, Double)? {
        guard baselineValues.count >= 7 else { return nil }
        let mean = baselineValues.reduce(0, +) / Double(baselineValues.count)
        let variance = baselineValues.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
            / Double(baselineValues.count - 1)
        let std = variance.squareRoot()
        guard std > 0 else { return nil }
        return (todayValue, mean, std)
    }
}
