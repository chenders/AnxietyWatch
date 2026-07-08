import SwiftData
import SwiftUI

struct CorrelationInsightsView: View, Equatable {
    // Trivially Equatable (no identity inputs — all state is @Query/derived);
    // paired with `.equatable()` at the NavigationLink call site so SwiftUI
    // dedupes rebuilds. See CLAUDE.md render-pitfall #2.
    static func == (lhs: CorrelationInsightsView, rhs: CorrelationInsightsView) -> Bool { true }

    @Query(sort: \PhysiologicalCorrelation.computedAt)
    private var correlations: [PhysiologicalCorrelation]

    private var sortedCorrelations: [PhysiologicalCorrelation] {
        correlations.sorted { abs($0.correlation) > abs($1.correlation) }
    }

    var body: some View {
        Group {
            if correlations.isEmpty {
                // The paired-day meter's two full-table @Querys (AnxietyEntry,
                // HealthSnapshot) live in this child so they are only fetched
                // and observed while the empty state is on screen. Once
                // correlations exist, `InsightsEmptyState` is never
                // instantiated, so both tables stop being observed (F-063).
                InsightsEmptyState()
            } else {
                List {
                    ForEach(sortedCorrelations) { corr in
                        NavigationLink {
                            CorrelationChartView(correlation: corr).equatable()
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
}

/// Empty-state progress meter for `CorrelationInsightsView`. Owns the two
/// full-table @Querys used only by the paired-day counter, so they are scoped
/// to the pre-correlations phase and released once real insights exist (F-063).
private struct InsightsEmptyState: View {
    static let minimumPairedDays = 12
    /// Trailing window for the paired-day estimate. Comfortably larger than the
    /// 12-day threshold so it never undercounts a user's progress toward
    /// correlations, while still bounding the fetch instead of materializing
    /// the whole AnxietyEntry/HealthSnapshot history (F-063 review follow-up).
    private static let countingWindowDays = 90

    @Query private var entries: [AnxietyEntry]
    @Query private var snapshots: [HealthSnapshot]

    init() {
        let cal = Calendar.current
        let cutoff = cal.date(
            byAdding: .day, value: -Self.countingWindowDays, to: cal.startOfDay(for: .now)
        ) ?? cal.startOfDay(for: .now)
        _entries = Query(filter: #Predicate<AnxietyEntry> { $0.timestamp >= cutoff })
        _snapshots = Query(filter: #Predicate<HealthSnapshot> { $0.date >= cutoff })
    }

    private var pairedDayCount: Int {
        let calendar = Calendar.current
        let entryDates = Set(entries.map { calendar.startOfDay(for: $0.timestamp) })
        let snapshotDates = Set(snapshots.map(\.date))
        return entryDates.intersection(snapshotDates).count
    }

    var body: some View {
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

            ProgressView(value: Double(min(pairedDayCount, Self.minimumPairedDays)),
                         total: Double(Self.minimumPairedDays))
                .tint(.blue)

            Text("\(pairedDayCount) / \(Self.minimumPairedDays) paired days")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}
