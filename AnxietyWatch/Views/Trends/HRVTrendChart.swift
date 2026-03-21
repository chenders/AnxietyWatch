import Charts
import SwiftUI

struct HRVTrendChart: View {
    let snapshots: [HealthSnapshot]
    /// Full history needed for baseline calculation
    let allSnapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]

    private var hrvSnapshots: [HealthSnapshot] {
        snapshots.filter { $0.hrvAvg != nil }
    }

    private var baseline: BaselineCalculator.BaselineResult? {
        BaselineCalculator.hrvBaseline(from: allSnapshots)
    }

    private var isBelowBaseline: Bool {
        BaselineCalculator.isHRVBelowBaseline(snapshots: allSnapshots)
    }

    var body: some View {
        ChartCard(
            title: "Heart Rate Variability (SDNN)",
            subtitle: baselineSubtitle,
            isEmpty: hrvSnapshots.isEmpty
        ) {
            Chart {
                // HRV line
                ForEach(hrvSnapshots) { snapshot in
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
                }

                // Baseline reference line
                if let baseline {
                    RuleMark(y: .value("Baseline", baseline.mean))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(dash: [5, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("avg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }

                    // Lower bound (deviation threshold)
                    RuleMark(y: .value("Lower", baseline.lowerBound))
                        .foregroundStyle(.red.opacity(0.3))
                        .lineStyle(StrokeStyle(dash: [3, 3]))
                }

                // Anxiety entries as vertical markers
                ForEach(entries) { entry in
                    RuleMark(x: .value("Date", entry.timestamp, unit: .hour))
                        .foregroundStyle(anxietyColor(entry.severity).opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, spacing: 0) {
                            Text("\(entry.severity)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(anxietyColor(entry.severity))
                        }
                }
            }
            .frame(height: 220)
        }
    }

    private var baselineSubtitle: String? {
        guard let baseline else { return nil }
        let status = isBelowBaseline ? "⚠ Below baseline" : "Within normal range"
        return String(format: "30-day avg: %.0f ms · %@", baseline.mean, status)
    }

    private func anxietyColor(_ severity: Int) -> Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}
