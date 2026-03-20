import Charts
import SwiftData
import SwiftUI

struct CPAPTrendChart: View {
    let sessions: [CPAPSession]

    var body: some View {
        ChartCard(title: "CPAP — AHI & Usage", isEmpty: sessions.isEmpty) {
            Chart(sessions) { session in
                // AHI as bars
                BarMark(
                    x: .value("Date", session.date, unit: .day),
                    y: .value("AHI", session.ahi)
                )
                .foregroundStyle(ahiColor(session.ahi).gradient)
            }
            .chartYAxisLabel("AHI (events/hr)")
            .frame(height: 180)

            // Usage as a separate small chart
            Chart(sessions) { session in
                let hours = Double(session.totalUsageMinutes) / 60.0
                BarMark(
                    x: .value("Date", session.date, unit: .day),
                    y: .value("Hours", hours)
                )
                .foregroundStyle(.teal.gradient)
            }
            .chartYAxisLabel("Usage (hours)")
            .frame(height: 120)
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
