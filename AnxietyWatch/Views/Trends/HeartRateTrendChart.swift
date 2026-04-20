import Charts
import SwiftUI

struct HeartRateTrendChart: View {
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    private var hrSnapshots: [HealthSnapshot] {
        snapshots.filter { $0.restingHR != nil }
    }

    private var chartData: [ChartDatum] {
        hrSnapshots.map { .snapshot($0) } + entries.map { .entry($0) }
    }

    var body: some View {
        ChartCard(title: "Resting Heart Rate", isEmpty: hrSnapshots.isEmpty) {
            Chart(chartData) { datum in
                switch datum {
                case .snapshot(let snapshot):
                    LineMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("BPM", snapshot.restingHR!)
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", snapshot.date, unit: .day),
                        y: .value("BPM", snapshot.restingHR!)
                    )
                    .foregroundStyle(.red)
                    .symbolSize(30)
                case .entry(let entry):
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(Color.severity(entry.severity).opacity(0.2))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartXScale(domain: dateRange)
            .frame(height: 200)
        }
    }

}

private enum ChartDatum: Identifiable {
    case snapshot(HealthSnapshot)
    case entry(AnxietyEntry)

    var id: String {
        switch self {
        case .snapshot(let s): "snapshot-\(s.id)"
        case .entry(let e): "entry-\(e.id)"
        }
    }
}
