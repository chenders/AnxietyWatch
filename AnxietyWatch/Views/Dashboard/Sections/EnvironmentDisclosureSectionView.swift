import HealthKit
import SwiftUI

/// Collapsible "background & environment" disclosure. Default collapsed.
/// Contains Env Sound (no viz), Headphone Audio (no viz), Barometric Pressure
/// (with intraday change subtitle). Header preview shows a salient metric
/// when one exists, otherwise just "3 metrics".
struct EnvironmentDisclosureSectionView: View {
    let vm: DashboardViewModel
    let snapshots: [HealthSnapshot]
    let barometer: BarometerService

    var body: some View {
        CollapsibleSection(
            id: "environment",
            title: "Environment & background",
            preview: previewText,
            defaultExpanded: false
        ) {
            VStack(spacing: 10) {
                envSoundCard
                headphoneCard
                barometricCard
            }
        }
    }

    private var previewText: String? {
        if barometer.currentPressureKPa != nil,
           let today = vm.todaySnapshot(from: snapshots),
           let change = today.barometricPressureChangeKPa,
           abs(change) > 0.4 {
            let arrow = change < 0 ? "↓" : "↑"
            return "Baro \(arrow)\(String(format: "%.1f", abs(change))) kPa today"
        }
        return "3 metrics"
    }

    @ViewBuilder private var envSoundCard: some View {
        let t = HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue
        if let latest = vm.latestSample(for: t) {
            LiveMetricCard(
                title: "Env. Sound", value: String(format: "%.0f", latest.value), unitLabel: "dBA",
                trend: nil, freshness: vm.freshnessLabel(latest.timestamp),
                color: .gray, visualization: .none
            )
        }
    }

    @ViewBuilder private var headphoneCard: some View {
        let t = HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue
        if let latest = vm.latestSample(for: t) {
            LiveMetricCard(
                title: "Headphone Audio", value: String(format: "%.0f", latest.value), unitLabel: "dBA",
                trend: nil, freshness: vm.freshnessLabel(latest.timestamp),
                color: .teal, visualization: .none
            )
        }
    }

    @ViewBuilder private var barometricCard: some View {
        if let pressure = barometer.currentPressureKPa {
            let subtitle: String = {
                guard let today = vm.todaySnapshot(from: snapshots),
                      let change = today.barometricPressureChangeKPa,
                      abs(change) > 0.01 else { return "Current" }
                let arrow = change < 0 ? "↓" : "↑"
                return "\(arrow) \(String(format: "%.1f", abs(change))) kPa today"
            }()
            MetricCard(
                title: "Barometric Pressure",
                value: String(format: "%.1f kPa", pressure),
                subtitle: subtitle, color: .gray
            )
        }
    }
}
