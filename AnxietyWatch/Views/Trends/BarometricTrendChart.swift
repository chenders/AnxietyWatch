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

    /// Unified data point for the chart — avoids ForEach/MapContentBuilder
    /// ambiguity that occurs on some Xcode versions when Charts and MapKit
    /// cross-import overlays are both active.
    private struct ChartDatum: Identifiable {
        let id: Date
        let timestamp: Date
        let kPa: Double
    }

    private var chartData: [ChartDatum] {
        displayReadings.map {
            ChartDatum(id: $0.timestamp, timestamp: $0.timestamp, kPa: $0.pressureKPa)
        }
    }

    var body: some View {
        ChartCard(
            title: "Barometric Pressure",
            subtitle: baseline.map { String(format: "30-day avg: %.1f kPa", $0.mean) },
            isEmpty: readings.isEmpty
        ) {
            Chart(chartData) { datum in
                LineMark(
                    x: .value("Time", datum.timestamp, unit: .hour),
                    y: .value("kPa", datum.kPa)
                )
                .foregroundStyle(.gray)
                .interpolationMethod(.catmullRom)
            }
            .chartOverlay(content: baselineOverlay)
            .chartOverlay(content: entriesOverlay)
            .chartXScale(domain: dateRange)
            .chartYAxisLabel("kPa")
            .frame(height: 180)
        }
    }

    private func baselineOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let baseline,
               let yPos = proxy.position(forY: baseline.mean) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: yPos))
                    path.addLine(to: CGPoint(x: geo.size.width, y: yPos))
                }
                .stroke(.green.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))

                Text("avg")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .position(x: geo.size.width - 12, y: yPos - 8)
            }
        }
    }

    private func entriesOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            ForEach(entries) { entry in
                if let xPos = proxy.position(forX: entry.timestamp) {
                    Path { path in
                        path.move(to: CGPoint(x: xPos, y: 0))
                        path.addLine(to: CGPoint(x: xPos, y: geo.size.height))
                    }
                    .stroke(anxietyColor(entry.severity).opacity(0.2), lineWidth: 2)
                }
            }
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
