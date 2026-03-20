import Charts
import SwiftData
import SwiftUI

struct BarometricTrendChart: View {
    let readings: [BarometricReading]
    let entries: [AnxietyEntry]

    var body: some View {
        ChartCard(title: "Barometric Pressure", isEmpty: readings.isEmpty) {
            Chart {
                ForEach(readings) { reading in
                    LineMark(
                        x: .value("Time", reading.timestamp, unit: .hour),
                        y: .value("kPa", reading.pressureKPa)
                    )
                    .foregroundStyle(.gray)
                    .interpolationMethod(.catmullRom)
                }

                // Anxiety overlay
                ForEach(entries) { entry in
                    RuleMark(x: .value("Time", entry.timestamp, unit: .hour))
                        .foregroundStyle(anxietyColor(entry.severity).opacity(0.2))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYAxisLabel("kPa")
            .frame(height: 180)
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
