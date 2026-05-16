import HealthKit
import SwiftUI

/// 2-column tile grid for the bulk of vital metrics. Heart Rate and HRV are
/// already promoted to the hero section above; the grid handles everything else
/// that has at least a recent reading.
struct VitalsGridSectionView: View {
    let vm: DashboardViewModel
    let snapshots: [HealthSnapshot]

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Vitals")
            LazyVGrid(columns: columns, spacing: 8) {
                rhrTile
                spo2Tile
                rrTile
                walkHRTile
                bpTile
                glucoseTile
                vo2Tile
                steadinessTile
                afibTile
            }
        }
    }

    @ViewBuilder private var rhrTile: some View {
        let t = HKQuantityTypeIdentifier.restingHeartRate.rawValue
        if let latest = vm.latestSample(for: t) {
            let viz: MetricVisualization = vm.baselineDelta(
                value: latest.value, baseline: vm.rhrBaseline, higherIsBetter: false
            ).map { .baselineChip(deltaText: $0.text, color: $0.color) } ?? .none
            LiveMetricCard(
                title: "Resting HR", value: String(format: "%.0f", latest.value), unitLabel: "bpm",
                trend: nil, freshness: vm.freshnessLabel(latest.timestamp),
                color: vm.baselineColor(value: latest.value, baseline: vm.rhrBaseline, higherIsBetter: false),
                visualization: viz,
                sourceChip: vm.deviceChipSource(for: latest)
            )
        }
    }

    @ViewBuilder private var spo2Tile: some View {
        let t = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        if let latest = vm.latestSample(for: t) {
            LiveMetricCard(
                title: "Blood Oxygen",
                value: String(format: "%.0f", latest.value * 100), unitLabel: "%",
                trend: vm.trend(for: t), freshness: vm.freshnessLabel(latest.timestamp),
                color: .green,
                visualization: .sparkline(segments: vm.sparklineSegments(for: t), color: .green),
                sourceChip: vm.deviceChipSource(for: latest)
            )
        }
    }

    @ViewBuilder private var rrTile: some View {
        let t = HKQuantityTypeIdentifier.respiratoryRate.rawValue
        if let latest = vm.latestSample(for: t) {
            // RR is nightly-derived. recent-bars over last 14 nights replaces
            // the misleading intraday sparkline that the old card showed.
            LiveMetricCard(
                title: "Resp Rate", value: String(format: "%.0f", latest.value), unitLabel: "br/min",
                trend: nil, freshness: vm.freshnessLabel(latest.timestamp),
                color: .mint,
                visualization: .recentBars(values: vm.recentValues(for: t, count: 14), color: .mint),
                sourceChip: vm.deviceChipSource(for: latest)
            )
        }
    }

    @ViewBuilder private var walkHRTile: some View {
        let t = HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue
        if let latest = vm.latestSample(for: t) {
            // No personal baseline tracked for Walking HR; the chip is a no-op
            // until baseline support is added. Falls through to .none rather
            // than a misleading bar chart of 7 values that move slowly.
            let viz: MetricVisualization = vm.baselineDelta(
                value: latest.value, baseline: nil, higherIsBetter: false
            ).map { .baselineChip(deltaText: $0.text, color: $0.color) } ?? .none
            LiveMetricCard(
                title: "Walking HR", value: String(format: "%.0f", latest.value), unitLabel: "bpm",
                trend: nil, freshness: vm.freshnessLabel(latest.timestamp),
                color: .orange, visualization: viz
            )
        }
    }

    @ViewBuilder private var bpTile: some View {
        let sysT = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
        let diaT = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
        if let sys = vm.latestSample(for: sysT), let dia = vm.latestSample(for: diaT) {
            LiveMetricCard(
                title: "Blood Pressure",
                value: "\(String(format: "%.0f", sys.value))/\(String(format: "%.0f", dia.value))",
                unitLabel: "mmHg", trend: nil, freshness: vm.freshnessLabel(sys.timestamp),
                color: .pink, visualization: .none
            )
        }
    }

    @ViewBuilder private var glucoseTile: some View {
        let t = HKQuantityTypeIdentifier.bloodGlucose.rawValue
        if let latest = vm.latestSample(for: t) {
            LiveMetricCard(
                title: "Blood Glucose", value: String(format: "%.0f", latest.value),
                unitLabel: "mg/dL", trend: vm.trend(for: t), freshness: vm.freshnessLabel(latest.timestamp),
                color: .purple, visualization: .none
            )
        }
    }

    @ViewBuilder private var vo2Tile: some View {
        let t = HKQuantityTypeIdentifier.vo2Max.rawValue
        if let latest = vm.latestSample(for: t) {
            // Cadence is ~weekly, so the "last 7 readings" label was misleading.
            // 7 readings ≈ 7 weeks of data.
            LiveMetricCard(
                title: "VO₂ Max", value: String(format: "%.1f", latest.value),
                unitLabel: "mL/kg/min", trend: nil, freshness: "last 7 weeks",
                color: .indigo,
                visualization: .recentBars(values: vm.recentValues(for: t, count: 7), color: .indigo)
            )
        }
    }

    @ViewBuilder private var steadinessTile: some View {
        let t = HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue
        if let latest = vm.latestSample(for: t) {
            // Rare updates with low variance — bars look static. Number-only.
            LiveMetricCard(
                title: "Walking Steadiness",
                value: String(format: "%.0f", latest.value * 100), unitLabel: "%",
                trend: nil, freshness: vm.freshnessLabel(latest.timestamp),
                color: .cyan, visualization: .none
            )
        }
    }

    @ViewBuilder private var afibTile: some View {
        if let (snap, isToday) = vm.lastSnapshotWith(\.atrialFibrillationBurden, from: snapshots) {
            let b = snap.atrialFibrillationBurden!
            LiveMetricCard(
                title: "AFib Burden", value: String(format: "%.1f", b * 100), unitLabel: "%",
                trend: nil, freshness: isToday ? "today" : vm.staleLabel(snap.date),
                color: b < 0.01 ? .green : .orange, visualization: .none
            )
        }
    }
}
