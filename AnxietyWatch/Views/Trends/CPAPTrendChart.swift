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

    var body: some View {
        ChartCard(
            title: "CPAP — AHI & Usage",
            subtitle: baseline.map { String(format: "30-day avg: %.1f events/hr", $0.mean) },
            isEmpty: sessions.isEmpty
        ) {
            Chart {
                ForEach(sessions) { session in
                    BarMark(
                        x: .value("Date", session.date, unit: .day),
                        y: .value("AHI", session.ahi)
                    )
                    .foregroundStyle(ahiColor(session.ahi).gradient)
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

                    RuleMark(y: .value("Upper", baseline.upperBound))
                        .foregroundStyle(.red.opacity(0.3))
                        .lineStyle(StrokeStyle(dash: [3, 3]))
                }

                ForEach(entries) { entry in
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(anxietyColor(entry.severity).opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, spacing: 0) {
                            Text("\(entry.severity)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(anxietyColor(entry.severity))
                        }
                }
            }
            .chartXScale(domain: dateRange)
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
            .chartXScale(domain: dateRange)
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

    private func anxietyColor(_ severity: Int) -> Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}
