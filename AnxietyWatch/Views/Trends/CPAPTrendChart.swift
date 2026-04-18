import Charts
import SwiftData
import SwiftUI

struct CPAPTrendChart: View {
    let sessions: [CPAPSession]
    /// Full history needed for baseline calculation
    let allSnapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    private var baseline: BaselineCalculator.BaselineResult? {
        BaselineCalculator.cpapAHIBaseline(from: allSnapshots)
    }

    /// Unified data point for the AHI chart — avoids ForEach/MapContentBuilder
    /// ambiguity that occurs on some Xcode versions when Charts and MapKit
    /// cross-import overlays are both active.
    private struct AHIDatum: Identifiable {
        let id: UUID
        let date: Date
        let ahi: Double
        let color: Color
    }

    private var ahiData: [AHIDatum] {
        sessions.map {
            AHIDatum(id: $0.id, date: $0.date, ahi: $0.ahi, color: ahiColor($0.ahi))
        }
    }

    var body: some View {
        ChartCard(
            title: "CPAP — AHI & Usage",
            subtitle: baseline.map { String(format: "30-day avg: %.1f events/hr", $0.mean) },
            isEmpty: sessions.isEmpty
        ) {
            Chart(ahiData) { datum in
                BarMark(
                    x: .value("Date", datum.date, unit: .day),
                    y: .value("AHI", datum.ahi)
                )
                .foregroundStyle(datum.color.gradient)
            }
            .chartOverlay(content: baselineOverlay)
            .chartOverlay(content: anxietyEntriesOverlay)
            .chartXScale(domain: dateRange)
            .chartYAxisLabel("AHI (events/hr)")
            .frame(height: 180)

            Chart(sessions) { session in
                let hours = Double(session.totalUsageMinutes) / 60.0
                BarMark(
                    x: .value("Date", session.date, unit: .day),
                    y: .value("Hours", hours)
                )
                .foregroundStyle(.teal.gradient)
            }
            .chartXScale(domain: dateRange)
            .chartYAxisLabel("Usage (hours)")
            .frame(height: 120)
        }
    }

    private func baselineOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let baseline,
               let meanY = proxy.position(forY: baseline.mean) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: meanY))
                    path.addLine(to: CGPoint(x: geo.size.width, y: meanY))
                }
                .stroke(.green.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))

                Text("avg")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .position(x: geo.size.width - 12, y: meanY - 8)

                if let upperY = proxy.position(forY: baseline.upperBound) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: upperY))
                        path.addLine(to: CGPoint(x: geo.size.width, y: upperY))
                    }
                    .stroke(.red.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
    }

    private func anxietyEntriesOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            ForEach(entries) { entry in
                if let xPos = proxy.position(forX: entry.timestamp) {
                    Path { path in
                        path.move(to: CGPoint(x: xPos, y: 0))
                        path.addLine(to: CGPoint(x: xPos, y: geo.size.height))
                    }
                    .stroke(Color.severity(entry.severity).opacity(0.25), lineWidth: 2)

                    Text("\(entry.severity)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.severity(entry.severity))
                        .position(x: xPos, y: 4)
                }
            }
        }
    }

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<5: return .green
        case 5..<15: return .yellow
        case 15..<30: return .orange
        default: return .red
        }
    }

}
