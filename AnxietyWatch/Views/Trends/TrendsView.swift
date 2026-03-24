import SwiftData
import SwiftUI

struct TrendsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HealthSnapshot.date) private var allSnapshots: [HealthSnapshot]
    @Query(sort: \AnxietyEntry.timestamp) private var allEntries: [AnxietyEntry]
    @Query(sort: \CPAPSession.date) private var allCPAPSessions: [CPAPSession]
    @Query(sort: \BarometricReading.timestamp) private var allBarometric: [BarometricReading]
    @State private var timeRange: TimeRange = .week
    /// 0 = current period (ending now), -1 = previous period, etc.
    @State private var pageOffset = 0

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

    // MARK: - Window Calculation

    private var window: TrendWindow {
        TrendWindow(now: .now, periodDays: timeRange.days, pageOffset: pageOffset)
    }

    private var windowEnd: Date { window.end }
    private var windowStart: Date { window.start }
    private var dateRange: ClosedRange<Date> { window.start...window.end }
    private var isShowingCurrentPeriod: Bool { pageOffset == 0 }

    // MARK: - Date Label

    private var windowLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let start = formatter.string(from: windowStart)
        let end = formatter.string(from: windowEnd)
        return "\(start) – \(end)"
    }

    // MARK: - Filtered Data

    private var snapshots: [HealthSnapshot] {
        allSnapshots.filter { $0.date >= windowStart && $0.date <= windowEnd }
    }

    private var entries: [AnxietyEntry] {
        allEntries.filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
    }

    private var cpapSessions: [CPAPSession] {
        allCPAPSessions.filter { $0.date >= windowStart && $0.date <= windowEnd }
    }

    private var barometricReadings: [BarometricReading] {
        allBarometric.filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
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
                    .onChange(of: timeRange) { pageOffset = 0 }

                    // Navigation header
                    HStack {
                        Button { pageOffset -= 1 } label: {
                            Image(systemName: "chevron.left")
                                .fontWeight(.semibold)
                        }

                        Spacer()

                        Text(windowLabel)
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()

                        Spacer()

                        Button {
                            guard !isShowingCurrentPeriod else { return }
                            pageOffset += 1
                        } label: {
                            Image(systemName: "chevron.right")
                                .fontWeight(.semibold)
                        }
                        .disabled(isShowingCurrentPeriod)

                        if !isShowingCurrentPeriod {
                            Button("Today") { pageOffset = 0 }
                                .font(.subheadline.weight(.medium))
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.horizontal)

                    let hasAnyData = !entries.isEmpty || !snapshots.isEmpty
                        || !cpapSessions.isEmpty || !barometricReadings.isEmpty

                    if !hasAnyData {
                        ContentUnavailableView(
                            "No Data Yet",
                            systemImage: "chart.xyaxis.line",
                            description: Text("No data for this period. Try navigating to a different time range.")
                        )
                    } else {
                        AnxietySeverityChart(entries: entries, dateRange: dateRange)
                        HRVTrendChart(snapshots: snapshots, allSnapshots: allSnapshots, entries: entries, dateRange: dateRange)
                        HeartRateTrendChart(snapshots: snapshots, entries: entries, dateRange: dateRange)
                        SleepTrendChart(snapshots: snapshots, dateRange: dateRange)
                        ActivityTrendChart(snapshots: snapshots, dateRange: dateRange)
                        CPAPTrendChart(sessions: cpapSessions, dateRange: dateRange)
                        BarometricTrendChart(readings: barometricReadings, entries: entries, dateRange: dateRange)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Trends")
            .gesture(
                DragGesture(minimumDistance: 50)
                    .onEnded { value in
                        if value.translation.width > 50 {
                            // Swipe right → go back in time
                            pageOffset -= 1
                        } else if value.translation.width < -50, !isShowingCurrentPeriod {
                            // Swipe left → go forward in time
                            pageOffset += 1
                        }
                    }
            )
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
