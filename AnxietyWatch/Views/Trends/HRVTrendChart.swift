import Charts
import SwiftUI

/// Combined chart datum for the SDNN trend. HealthKit `hrvAvg` (`.snapshot`)
/// and Polar overnight session SDNN means (`.polar`) render as separate
/// visually-distinct series. Baseline mean/lower-bound rules and anxiety
/// entry rule marks remain HK-derived so they don't shift around as the
/// Polar series grows.
enum HRVTrendDatum: Identifiable {
    case snapshot(HealthSnapshot)
    case baselineMean(Double)
    case baselineLower(Double)
    case entry(AnxietyEntry)
    case polar(LFHFAggregator.NightlyValue)

    var id: String {
        switch self {
        case .snapshot(let s): "snapshot-\(s.id)"
        case .baselineMean: "baseline-mean"
        case .baselineLower: "baseline-lower"
        case .entry(let e): "entry-\(e.id)"
        case .polar(let p): "polar-\(p.id)"
        }
    }

    /// Build the combined datum array from HK snapshots, anxiety entries,
    /// optional baseline, and Polar overnight SDNN points. Snapshots without
    /// `hrvAvg` and Polar points with nil `value` are filtered out.
    static func from(
        snapshots: [HealthSnapshot],
        entries: [AnxietyEntry],
        baseline: BaselineCalculator.BaselineResult?,
        polarSeries: [LFHFAggregator.NightlyValue]
    ) -> [HRVTrendDatum] {
        var data: [HRVTrendDatum] = snapshots
            .filter { $0.hrvAvg != nil }
            .map(HRVTrendDatum.snapshot)
        if let baseline {
            data.append(.baselineMean(baseline.mean))
            data.append(.baselineLower(baseline.lowerBound))
        }
        data += entries.map(HRVTrendDatum.entry)
        data += polarSeries
            .filter { $0.value != nil }
            .map(HRVTrendDatum.polar)
        return data
    }

    /// True when either source has at least one HRV value. Entries and
    /// baseline are context, not data — a chart with only those should
    /// still read as "no data."
    static func hasAnyData(
        snapshots: [HealthSnapshot],
        polarSeries: [LFHFAggregator.NightlyValue]
    ) -> Bool {
        snapshots.contains { $0.hrvAvg != nil }
            || polarSeries.contains { $0.value != nil }
    }
}

struct HRVTrendChart: View {
    let snapshots: [HealthSnapshot]
    /// Full history needed for baseline calculation
    let allSnapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let polarSeries: [LFHFAggregator.NightlyValue]
    let dateRange: ClosedRange<Date>

    init(
        snapshots: [HealthSnapshot],
        allSnapshots: [HealthSnapshot],
        entries: [AnxietyEntry],
        polarSeries: [LFHFAggregator.NightlyValue] = [],
        dateRange: ClosedRange<Date>
    ) {
        self.snapshots = snapshots
        self.allSnapshots = allSnapshots
        self.entries = entries
        self.polarSeries = polarSeries
        self.dateRange = dateRange
    }

    private var baseline: BaselineCalculator.BaselineResult? {
        BaselineCalculator.hrvBaseline(from: allSnapshots)
    }

    private var isBelowBaseline: Bool {
        BaselineCalculator.isHRVBelowBaseline(snapshots: allSnapshots)
    }

    var body: some View {
        let hasData = HRVTrendDatum.hasAnyData(snapshots: snapshots, polarSeries: polarSeries)
        let datums = HRVTrendDatum.from(
            snapshots: snapshots,
            entries: entries,
            baseline: baseline,
            polarSeries: polarSeries
        )
        ChartCard(
            title: "Heart Rate Variability (SDNN)",
            subtitle: baselineSubtitle,
            isEmpty: !hasData
        ) {
            Chart(datums) { datum in
                switch datum {
                case .snapshot(let snapshot):
                    LineMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("HRV (ms)", snapshot.hrvAvg ?? 0),
                        series: .value("Source", "HealthKit")
                    )
                    .foregroundStyle(ChartPalette.healthKitHRV)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("HRV (ms)", snapshot.hrvAvg ?? 0)
                    )
                    .foregroundStyle(ChartPalette.healthKitHRV)
                    .symbolSize(30)
                case .baselineMean(let value):
                    RuleMark(y: .value("Baseline", value))
                        .foregroundStyle(ChartPalette.baselineRule)
                        .lineStyle(StrokeStyle(dash: [5, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("avg")
                                .font(.caption2)
                                .foregroundStyle(ChartPalette.baselineLabel)
                        }
                case .baselineLower(let value):
                    RuleMark(y: .value("Lower", value))
                        .foregroundStyle(ChartPalette.outOfRangeFill)
                        .lineStyle(StrokeStyle(dash: [3, 3]))
                case .entry(let entry):
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(Color.severity(entry.severity).opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, spacing: 0) {
                            Text("\(entry.severity)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.severity(entry.severity))
                        }
                case .polar(let point):
                    // Polar overnight-session SDNN. Separate series so the
                    // line breaks between sessions instead of running through
                    // the HK trace — the two metrics use different windows
                    // (HK ≈ 60s sliding; Polar per-session aggregate) and
                    // shouldn't read as one continuous quantity.
                    LineMark(
                        x: .value("Date", point.night, unit: .day),
                        y: .value("HRV (ms)", point.value ?? 0),
                        series: .value("Source", "Polar")
                    )
                    .foregroundStyle(ChartPalette.polarRMSSD)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", point.night, unit: .day),
                        y: .value("HRV (ms)", point.value ?? 0)
                    )
                    .foregroundStyle(ChartPalette.polarRMSSD)
                    .symbol(.diamond)
                    .symbolSize(40)
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 220)

            // Only surface the legend when the Polar overlay is actually
            // drawn — `polarSeries` can be non-empty but consist entirely of
            // all-sentinel sessions (value == nil), in which case the chart
            // shows only HealthKit data and the legend would mislead.
            if polarSeries.contains(where: { $0.value != nil }) {
                Text("Blue: HealthKit (~60s sliding window) · Purple: Polar (per-session overnight aggregate)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var baselineSubtitle: String? {
        guard let baseline else { return nil }
        let status = isBelowBaseline ? "⚠ Below baseline" : "Within normal range"
        return String(format: "30-day avg: %.0f ms · %@", baseline.mean, status)
    }
}
