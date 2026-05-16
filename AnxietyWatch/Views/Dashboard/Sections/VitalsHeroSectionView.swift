import HealthKit
import SwiftUI

/// Hero vitals section: full-width Heart Rate (sparkline) and HRV
/// (recent-bars + baseline chip). The remaining vitals live in the 2-col
/// grid section below.
struct VitalsHeroSectionView: View {
    let vm: DashboardViewModel

    var body: some View {
        VStack(spacing: 12) {
            heartRateCard
            hrvCard
        }
    }

    @ViewBuilder
    private var heartRateCard: some View {
        let type = HKQuantityTypeIdentifier.heartRate.rawValue
        if let latest = vm.latestSample(for: type) {
            LiveMetricCard(
                title: "Heart Rate",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: vm.trend(for: type),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: .red,
                visualization: .sparkline(
                    segments: vm.sparklineSegments(for: type),
                    color: .red
                ),
                sourceChip: vm.deviceChipSource(for: latest)
            )
        }
    }

    @ViewBuilder
    private var hrvCard: some View {
        let type = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        if let latest = vm.latestSample(for: type) {
            // HK emits 1-3 HRV samples/day — a sparkline of one point is a
            // misleading dot floating on empty axes. Prefer a baseline chip
            // when a baseline exists; otherwise recent-bars over last 14.
            let viz: MetricVisualization = {
                if let delta = vm.baselineDelta(
                    value: latest.value, baseline: vm.hrvBaseline, higherIsBetter: true
                ) {
                    return .baselineChip(deltaText: delta.text, color: delta.color)
                }
                return .recentBars(values: vm.recentValues(for: type, count: 14), color: .blue)
            }()
            LiveMetricCard(
                title: "HRV",
                value: String(format: "%.0f", latest.value),
                unitLabel: "ms",
                trend: vm.trend(for: type),
                freshness: vm.freshnessLabel(latest.timestamp),
                color: vm.baselineColor(value: latest.value, baseline: vm.hrvBaseline, higherIsBetter: true),
                visualization: viz,
                sourceChip: vm.deviceChipSource(for: latest)
            )
        }
    }
}
