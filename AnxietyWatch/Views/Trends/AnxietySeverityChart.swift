import Charts
import SwiftUI

struct AnxietySeverityChart: View {
    let entries: [AnxietyEntry]

    var body: some View {
        ChartCard(title: "Anxiety Severity", isEmpty: entries.isEmpty) {
            Chart(entries) { entry in
                PointMark(
                    x: .value("Date", entry.timestamp, unit: .hour),
                    y: .value("Severity", entry.severity)
                )
                .foregroundStyle(severityColor(entry.severity))
                .symbolSize(60)

                if entries.count > 1 {
                    LineMark(
                        x: .value("Date", entry.timestamp, unit: .hour),
                        y: .value("Severity", entry.severity)
                    )
                    .foregroundStyle(.secondary.opacity(0.3))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 1...10)
            .chartYAxis {
                AxisMarks(values: [1, 3, 5, 7, 10])
            }
            .frame(height: 200)
        }
    }

    private func severityColor(_ severity: Int) -> Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}
