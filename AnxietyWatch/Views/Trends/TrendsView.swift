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

    private var isShowingCurrentPeriod: Bool { pageOffset == 0 }

    /// Snapshot the window once per body evaluation to avoid recomputing from .now on every access.
    private var windowState: (start: Date, end: Date, chartEnd: Date) {
        let w = TrendWindow(now: .now, periodDays: timeRange.days, pageOffset: pageOffset)
        if isShowingCurrentPeriod {
            return (w.start, w.end, w.end)
        } else {
            // For past periods, end is exclusive (midnight). Chart domain uses the inclusive last day.
            let inclusiveEnd = Calendar.current.date(byAdding: .day, value: -1, to: w.end) ?? w.end
            return (w.start, w.end, inclusiveEnd)
        }
    }

    // MARK: - Date Label

    private static let windowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Filtered Data

    private func inWindow(_ date: Date, start: Date, end: Date) -> Bool {
        date >= start && (isShowingCurrentPeriod ? date <= end : date < end)
    }

    var body: some View {
        let ws = windowState
        let f = Self.windowDateFormatter
        let label = "\(f.string(from: ws.start)) – \(f.string(from: ws.chartEnd))"
        let dateRange = ws.start...ws.chartEnd

        let snapshots = allSnapshots.filter { inWindow($0.date, start: ws.start, end: ws.end) }
        let entries = allEntries.filter { inWindow($0.timestamp, start: ws.start, end: ws.end) }
        let cpapSessions = allCPAPSessions.filter { inWindow($0.date, start: ws.start, end: ws.end) }
        let barometricReadings = allBarometric.filter { inWindow($0.timestamp, start: ws.start, end: ws.end) }

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
                    .onChange(of: timeRange) { _, _ in pageOffset = 0 }

                    // Navigation header
                    HStack {
                        Button { pageOffset -= 1 } label: {
                            Image(systemName: "chevron.left")
                                .fontWeight(.semibold)
                        }

                        Spacer()

                        Text(label)
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
            .simultaneousGesture(
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

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    TrendsView()
        .modelContainer(container)
}
#endif
