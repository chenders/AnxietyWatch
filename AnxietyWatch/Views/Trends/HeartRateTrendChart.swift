import Charts
import SwiftUI

struct HeartRateTrendChart: View {
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]

    private var hrSnapshots: [HealthSnapshot] {
        snapshots.filter { $0.restingHR != nil }
    }

    var body: some View {
        ChartCard(title: "Resting Heart Rate", isEmpty: hrSnapshots.isEmpty) {
            Chart {
                ForEach(hrSnapshots) { snapshot in
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
                }

                // Anxiety overlay
                ForEach(entries) { entry in
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(anxietyColor(entry.severity).opacity(0.2))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .frame(height: 200)
        }
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
