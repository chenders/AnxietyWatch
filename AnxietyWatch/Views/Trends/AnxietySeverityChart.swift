import Charts
import SwiftUI

struct AnxietySeverityChart: View {
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    var body: some View {
        ChartCard(title: "Anxiety Severity", isEmpty: entries.isEmpty) {
            // Explicit `id:` (not the Identifiable overload): AnxietyEntry's
            // Identifiable conformance comes from @Model/PersistentModel and
            // is main-actor-inferred under InferIsolatedConformances on
            // newer toolchains, which fails Chart's nonisolated
            // `Data.Element: Identifiable` requirement. Keying on `\.id`
            // sidesteps the conformance lookup with identical behavior.
            Chart(entries, id: \.id) { entry in
                PointMark(
                    x: .value("Date", entry.timestamp, unit: .hour),
                    y: .value("Severity", entry.severity)
                )
                .foregroundStyle(Color.severity(entry.severity))
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
            .chartXScale(domain: dateRange)
            .chartYScale(domain: 1...10)
            .chartYAxis {
                AxisMarks(values: [1, 3, 5, 7, 10])
            }
            .frame(height: 200)
        }
    }
}
