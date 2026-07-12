import SwiftUI

/// Computes baseline alerts and renders them via `AlertsStrip`.
/// Lives as a child View so the rolled-up alert logic reads VM properties
/// (baselines) without invalidating the whole Dashboard root.
struct AlertsSectionView: View {
    let snapshots: [HealthSnapshot]
    let vm: DashboardViewModel

    var body: some View {
        AlertsStrip(alerts: AlertsDeduper.collapse(alerts: buildAlerts()))
    }

    private func buildAlerts() -> [DashboardAlert] {
        var out: [DashboardAlert] = []

        if let baseline = vm.hrvBaseline,
           let recent = BaselineCalculator.recentAverage(from: snapshots, days: 3, keyPath: \.hrvAvg),
           recent < baseline.lowerBound, baseline.standardDeviation > 0 {
            let z = (recent - baseline.mean) / baseline.standardDeviation
            out.append(.init(
                id: "hrv",
                title: "HRV Below Baseline",
                message: "Your 3-day HRV average is below your 30-day baseline",
                severity: .warn, category: .autonomic, zScore: z
            ))
        }
        if let baseline = vm.sleepBaseline,
           let lastSleep = snapshots.first?.sleepDurationMin.map(Double.init),
           lastSleep < baseline.lowerBound, baseline.mean > 0, baseline.standardDeviation > 0 {
            let z = (lastSleep - baseline.mean) / baseline.standardDeviation
            let pct = Int(((baseline.mean - lastSleep) / baseline.mean) * 100)
            out.append(.init(
                id: "sleep",
                title: "Sleep Below Baseline",
                message: "Last night's sleep was \(pct)% below your 30-day average",
                severity: .warn, category: .sleep, zScore: z
            ))
        }
        if let baseline = vm.respiratoryBaseline,
           let lastRR = snapshots.first?.respiratoryRate,
           lastRR > baseline.upperBound, baseline.mean > 0, baseline.standardDeviation > 0 {
            let z = (lastRR - baseline.mean) / baseline.standardDeviation
            let pct = Int(((lastRR - baseline.mean) / baseline.mean) * 100)
            out.append(.init(
                id: "rr",
                title: "Respiratory Rate Elevated",
                message: "Your respiratory rate is \(pct)% above your 30-day average",
                severity: .warn, category: .autonomic, zScore: z
            ))
        }
        if let baseline = vm.cpapAHIBaseline,
           let recentAHI = BaselineCalculator.recentAverage(from: snapshots, days: 3, keyPath: \.cpapAHI),
           recentAHI > baseline.upperBound, baseline.mean > 0, baseline.standardDeviation > 0 {
            let z = (recentAHI - baseline.mean) / baseline.standardDeviation
            let pct = Int(((recentAHI - baseline.mean) / baseline.mean) * 100)
            out.append(.init(
                id: "ahi",
                title: "CPAP AHI Elevated",
                message: "Your 3-night AHI average is \(pct)% above your 30-day baseline",
                severity: .warn, category: .sleep, zScore: z
            ))
        }
        if let baseline = vm.barometricBaseline,
           let today = vm.todaySnapshot(from: snapshots),
           let pressure = today.barometricPressureAvgKPa,
           pressure < baseline.lowerBound, baseline.standardDeviation > 0 {
            let z = (pressure - baseline.mean) / baseline.standardDeviation
            out.append(.init(
                id: "baro",
                title: "Low Barometric Pressure",
                message: "Pressure is significantly below your 30-day average",
                severity: .info, category: .environment, zScore: z
            ))
        }
        return out
    }
}
