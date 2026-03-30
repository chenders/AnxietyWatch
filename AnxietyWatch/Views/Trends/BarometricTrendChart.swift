import Charts
import SwiftData
import SwiftUI

struct BarometricTrendChart: View {
    let readings: [BarometricReading]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    /// Cap chart points to avoid rendering thousands of raw CMAltimeter samples
    private var displayReadings: [BarometricReading] {
        let maxPoints = 500
        guard readings.count > maxPoints else { return readings }
        // Ceiling division guarantees stride > 1, so output never exceeds maxPoints
        let stride = Int(ceil(Double(readings.count) / Double(maxPoints)))
        return Array(Swift.stride(from: 0, to: readings.count, by: stride).map { readings[$0] }.prefix(maxPoints))
    }

    private var chartData: [ChartDatum] {
        displayReadings.map { .reading($0) } + entries.map { .entry($0) }
    }

    var body: some View {
        ChartCard(title: "Barometric Pressure", isEmpty: readings.isEmpty) {
            Chart(chartData) { datum in
                switch datum {
                case .reading(let reading):
                    LineMark(
                        x: .value("Time", reading.timestamp, unit: .hour),
                        y: .value("kPa", reading.pressureKPa)
                    )
                    .foregroundStyle(.gray)
                    .interpolationMethod(.catmullRom)
                case .entry(let entry):
                    RuleMark(x: .value("Time", entry.timestamp, unit: .hour))
                        .foregroundStyle(anxietyColor(entry.severity).opacity(0.2))
                        .lineStyle(StrokeStyle(lineWidth: 2))
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

/// Tagged union for combining multiple data sources in a single Chart(data:) call,
/// avoiding ForEach inside Chart bodies (which has availability issues across Xcode versions).
private enum ChartDatum: Identifiable {
    case reading(BarometricReading)
    case entry(AnxietyEntry)

    var id: String {
        switch self {
        case .reading(let r): "reading-\(r.id)"
        case .entry(let e): "entry-\(e.id)"
        }
    }
}
