import SwiftData
import SwiftUI

struct TrendsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HealthSnapshot.date) private var allSnapshots: [HealthSnapshot]
    @Query(sort: \AnxietyEntry.timestamp) private var allEntries: [AnxietyEntry]
    @Query(sort: \CPAPSession.date) private var allCPAPSessions: [CPAPSession]
    @Query(sort: \BarometricReading.timestamp) private var allBarometric: [BarometricReading]
    @State private var timeRange: TimeRange = .week

    enum TimeRange: String, CaseIterable {
        case week = "7 Days"
        case month = "30 Days"
        case quarter = "90 Days"

        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            }
        }
    }

    private var startDate: Date {
        let daysAgo = Calendar.current.date(byAdding: .day, value: -timeRange.days, to: .now)!
        return Calendar.current.startOfDay(for: daysAgo)
    }

    private var snapshots: [HealthSnapshot] {
        allSnapshots.filter { $0.date >= startDate }
    }

    private var entries: [AnxietyEntry] {
        allEntries.filter { $0.timestamp >= startDate }
    }

    private var cpapSessions: [CPAPSession] {
        allCPAPSessions.filter { $0.date >= startDate }
    }

    private var barometricReadings: [BarometricReading] {
        allBarometric.filter { $0.timestamp >= startDate }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Time Range", selection: $timeRange) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    let hasAnyData = !entries.isEmpty || !snapshots.isEmpty
                        || !cpapSessions.isEmpty || !barometricReadings.isEmpty

                    if !hasAnyData {
                        ContentUnavailableView(
                            "No Data Yet",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Log journal entries and open the app daily to build your trends")
                        )
                    } else {
                        AnxietySeverityChart(entries: entries)
                        HRVTrendChart(snapshots: snapshots, allSnapshots: allSnapshots, entries: entries)
                        HeartRateTrendChart(snapshots: snapshots, entries: entries)
                        SleepTrendChart(snapshots: snapshots)
                        ActivityTrendChart(snapshots: snapshots)
                        CPAPTrendChart(sessions: cpapSessions)
                        BarometricTrendChart(readings: barometricReadings, entries: entries)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Trends")
            .task {
                await refreshSnapshot()
            }
        }
    }

    private func refreshSnapshot() async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        try? await aggregator.aggregateDay(.now)
    }
}
