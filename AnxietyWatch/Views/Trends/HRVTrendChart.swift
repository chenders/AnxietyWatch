import Charts
import SwiftUI

struct HRVTrendChart: View {
    let snapshots: [HealthSnapshot]
    /// Full history needed for baseline calculation
    let allSnapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    private var hrvSnapshots: [HealthSnapshot] {
        snapshots.filter { $0.hrvAvg != nil }
    }

    private var baseline: BaselineCalculator.BaselineResult? {
        BaselineCalculator.hrvBaseline(from: allSnapshots)
    }

    private var isBelowBaseline: Bool {
        BaselineCalculator.isHRVBelowBaseline(snapshots: allSnapshots)
    }

    private var chartData: [ChartDatum] {
        var data: [ChartDatum] = hrvSnapshots.map { .snapshot($0) }
        if let baseline {
            data.append(.baselineMean(baseline.mean))
            data.append(.baselineLower(baseline.lowerBound))
        }
        data += entries.map { .entry($0) }
        return data
    }

    var body: some View {
        ChartCard(
            title: "Heart Rate Variability (SDNN)",
            subtitle: baselineSubtitle,
            isEmpty: hrvSnapshots.isEmpty
        ) {
            Chart(chartData) { datum in
                switch datum {
                case .snapshot(let snapshot):
                    LineMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("HRV (ms)", snapshot.hrvAvg!)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("HRV (ms)", snapshot.hrvAvg!)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(30)
                case .baselineMean(let value):
                    RuleMark(y: .value("Baseline", value))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(dash: [5, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("avg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                case .baselineLower(let value):
                    RuleMark(y: .value("Lower", value))
                        .foregroundStyle(.red.opacity(0.3))
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
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 220)
        }
    }

    private var baselineSubtitle: String? {
        guard let baseline else { return nil }
        let status = isBelowBaseline ? "⚠ Below baseline" : "Within normal range"
        return String(format: "30-day avg: %.0f ms · %@", baseline.mean, status)
    }

}

private enum ChartDatum: Identifiable {
    case snapshot(HealthSnapshot)
    case baselineMean(Double)
    case baselineLower(Double)
    case entry(AnxietyEntry)

    var id: String {
        switch self {
        case .snapshot(let s): "snapshot-\(s.id)"
        case .baselineMean: "baseline-mean"
        case .baselineLower: "baseline-lower"
        case .entry(let e): "entry-\(e.id)"
        }
    }
}
