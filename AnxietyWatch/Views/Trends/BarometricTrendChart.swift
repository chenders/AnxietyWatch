import Charts
import SwiftData
import SwiftUI

struct BarometricTrendChart: View {
    let readings: [BarometricReading]
    let entries: [AnxietyEntry]
    let allSnapshots: [HealthSnapshot]
    let dateRange: ClosedRange<Date>

    /// Cap chart points to avoid rendering thousands of raw CMAltimeter samples
    private var displayReadings: [BarometricReading] {
        let maxPoints = 500
        guard readings.count > maxPoints else { return readings }
        // Ceiling division guarantees stride > 1, so output never exceeds maxPoints
        let stride = Int(ceil(Double(readings.count) / Double(maxPoints)))
        return Array(Swift.stride(from: 0, to: readings.count, by: stride).map { readings[$0] }.prefix(maxPoints))
    }

    private var baseline: BaselineCalculator.BaselineResult? {
        BaselineCalculator.barometricPressureBaseline(from: allSnapshots)
    }

    var body: some View {
        ChartCard(
            title: "Barometric Pressure",
            subtitle: baseline.map { String(format: "30-day avg: %.1f kPa", $0.mean) },
            isEmpty: readings.isEmpty
        ) {
            Chart {
                // Explicit Plot wrapping avoids MapContentBuilder ambiguity
                // on Xcode 16.4+ where ForEach resolves to MapKit's overload.
                Plot {
                    ForEach(displayReadings) { reading in
                        LineMark(
                            x: .value("Time", reading.timestamp, unit: .hour),
                            y: .value("kPa", reading.pressureKPa)
                        )
                        .foregroundStyle(.gray)
                        .interpolationMethod(.catmullRom)
                    }
                }

                if let baseline {
                    RuleMark(y: .value("Baseline", baseline.mean))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(dash: [5, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("avg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                }

                Plot {
                    ForEach(entries) { entry in
                        RuleMark(x: .value("Time", entry.timestamp, unit: .hour))
                            .foregroundStyle(anxietyColor(entry.severity).opacity(0.2))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartXScale(domain: dateRange)
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
