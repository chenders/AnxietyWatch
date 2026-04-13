import SwiftData
import SwiftUI

struct CorrelationInsightsView: View {
    @Query(sort: \PhysiologicalCorrelation.computedAt)
    private var correlations: [PhysiologicalCorrelation]

    @Query private var entries: [AnxietyEntry]
    @Query private var snapshots: [HealthSnapshot]

    private var pairedDayCount: Int {
        let calendar = Calendar.current
        let entryDates = Set(entries.map { calendar.startOfDay(for: $0.timestamp) })
        let snapshotDates = Set(snapshots.map(\.date))
        return entryDates.intersection(snapshotDates).count
    }

    private var sortedCorrelations: [PhysiologicalCorrelation] {
        correlations.sorted { abs($0.correlation) > abs($1.correlation) }
    }

    var body: some View {
        Group {
            if correlations.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedCorrelations) { corr in
                        NavigationLink {
                            CorrelationChartView(correlation: corr)
                        } label: {
                            CorrelationCardView(correlation: corr)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Insights")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Keep logging check-ins")
                .font(.headline)

            Text("Insights will appear after ~2 weeks of paired data (mood entries + health data on the same days).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ProgressView(value: Double(min(pairedDayCount, 12)), total: 12)
                .tint(.blue)

            Text("\(pairedDayCount) / 12 paired days")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}
