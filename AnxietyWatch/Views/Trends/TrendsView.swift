import SwiftData
import SwiftUI

struct TrendsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HealthSnapshot.date) private var allSnapshots: [HealthSnapshot]
    @Query(sort: \AnxietyEntry.timestamp) private var allEntries: [AnxietyEntry]
    @Query(sort: \CPAPSession.date) private var allCPAPSessions: [CPAPSession]
    @Query(sort: \BarometricReading.timestamp) private var allBarometric: [BarometricReading]
    // Source-filtered at the SwiftData layer so the per-minute HRVReading
    // table doesn't load non-Polar rows (and won't bloat the Trends tab as
    // future HRV writers start populating other source labels). String
    // literal because #Predicate can't reference static properties on
    // foreign types at macro expansion time.
    @Query(
        filter: #Predicate<HRVReading> { $0.source == "polar_h10" },
        sort: \HRVReading.timestamp
    )
    private var allHRVReadings: [HRVReading]
    @Query(
        filter: #Predicate<SensorSession> { $0.source == "polar_h10" },
        sort: \SensorSession.startTime
    )
    private var allSensorSessions: [SensorSession]
    @State private var timeRange: TimeRange = .week
    /// 0 = current period (ending now), -1 = previous period, etc.
    @State private var pageOffset = 0
    @State private var sourceFilter: SourceFilter = .all
    @State private var tappedNight: CoalescedNightRef?

    enum SourceFilter: String, CaseIterable {
        case all = "All"
        case selfReported = "Self-Reported"
        case checkIns = "Check-Ins"
    }

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

    private func filterBySource(_ entries: [AnxietyEntry]) -> [AnxietyEntry] {
        switch sourceFilter {
        case .all: return entries
        case .selfReported: return entries.filter { $0.source == nil || $0.source == "user" || $0.source == "dose_followup" }
        case .checkIns: return entries.filter { $0.source == "random_checkin" }
        }
    }

    private func inWindow(_ date: Date, start: Date, end: Date) -> Bool {
        date >= start && (isShowingCurrentPeriod ? date <= end : date < end)
    }

    var body: some View {
        let ws = windowState
        let f = Self.windowDateFormatter
        let label = "\(f.string(from: ws.start)) – \(f.string(from: ws.chartEnd))"
        // Pad trailing edge so data doesn't crowd the Y-axis labels on the right
        let paddedChartEnd = Calendar.current.date(byAdding: .hour, value: 12, to: ws.chartEnd) ?? ws.chartEnd
        let dateRange = ws.start...paddedChartEnd

        let snapshots = allSnapshots.filter { inWindow($0.date, start: ws.start, end: ws.end) }
        let entries = filterBySource(allEntries.filter { inWindow($0.timestamp, start: ws.start, end: ws.end) })
        let cpapSessions = allCPAPSessions.filter { inWindow($0.date, start: ws.start, end: ws.end) }
        let barometricReadings = allBarometric.filter { inWindow($0.timestamp, start: ws.start, end: ws.end) }

        // LF/HF card: coalesce all Polar sessions into logical nights first,
        // then filter to nights whose total wear time meets the overnight
        // threshold. This lets a fragmented night (BLE drops + reconnects)
        // qualify even when no single session is ≥3h, as long as the
        // combined wear time across the night is.
        //
        // Crucially, the window filter runs on the per-night NightlyMean
        // (anchored to the earliest member's startTime), not on per-reading
        // timestamps. An overnight session straddling the window boundary
        // (started 11 PM, slept past midnight) contributes its full-night
        // mean anchored to bedtime, not a partial mean anchored to the first
        // post-midnight reading.
        let coalescedNights = LFHFAggregator.coalesce(sessions: allSensorSessions)
        let overnightNights = coalescedNights.filter {
            $0.wearTimeSeconds >= LFHFAggregator.overnightThresholdSeconds
        }
        let overnightMemberIDs = Set(overnightNights.flatMap(\.memberSessionIDs))
        let overnightReadings = allHRVReadings.filter {
            guard let sid = $0.sensorSessionID else { return false }
            return overnightMemberIDs.contains(sid)
        }
        let overnightSessions = allSensorSessions.filter { overnightMemberIDs.contains($0.id) }
        // Single grouping pass over `overnightReadings` produces all three
        // series (frequency-domain NightlyMean, SDNN, RMSSD) anchored to the
        // coalesced-night start time so the body doesn't re-group the
        // per-minute table three times per render.
        let nightlyAggregates = LFHFAggregator.nightlyAggregates(
            from: overnightReadings,
            coalescedNights: overnightNights
        )
        let lfhfAllMeans = nightlyAggregates.means
        let lfhfWindowMeans = lfhfAllMeans
            .filter { inWindow($0.night, start: ws.start, end: ws.end) }
        let sdnnWindowMeans = nightlyAggregates.sdnn
            .filter { inWindow($0.night, start: ws.start, end: ws.end) }
        let rmssdWindowMeans = nightlyAggregates.rmssd
            .filter { inWindow($0.night, start: ws.start, end: ws.end) }
        let polarHRWindowMeans = LFHFAggregator
            .nightlyHRFromSummaries(from: overnightSessions, coalescedNights: overnightNights)
            .filter { inWindow($0.night, start: ws.start, end: ws.end) }
        // CoalescedNightRef payloads for the diamonds visible in the current
        // window — derived from `polarHRWindowMeans` so the nav set is
        // exactly the rendered diamond set. `nightlyHRFromSummaries` drops
        // nights with missing/unparseable/zero `hrMean`, so filtering
        // `overnightNights` by time alone would let the tap overlay resolve
        // to a night that has no visible diamond.
        let nightByID = Dictionary(uniqueKeysWithValues: overnightNights.map { ($0.id, $0) })
        let coalescedNightRefs = polarHRWindowMeans.compactMap { mean in
            nightByID[mean.id].map(CoalescedNightRef.init(from:))
        }

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

                    Picker("Source", selection: $sourceFilter) {
                        ForEach(SourceFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

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

                    // hasAnyData includes the Polar-derived series explicitly
                    // so a user with only Polar H10 data (no HealthKit
                    // backfill yet) still sees the Trends tab populated.
                    let hasAnyData = !entries.isEmpty || !snapshots.isEmpty
                        || !cpapSessions.isEmpty || !barometricReadings.isEmpty
                        || !lfhfWindowMeans.isEmpty
                        || !sdnnWindowMeans.isEmpty
                        || !rmssdWindowMeans.isEmpty
                        || !polarHRWindowMeans.isEmpty

                    if !hasAnyData {
                        ContentUnavailableView(
                            "No Data Yet",
                            systemImage: "chart.xyaxis.line",
                            description: Text("No data for this period. Try navigating to a different time range.")
                        )
                    } else {
                        AnxietySeverityChart(entries: entries, dateRange: dateRange)
                        // HRV cards grouped together. SDNN trend now overlays
                        // Polar overnight aggregates onto the existing HK line;
                        // RMSSD and HF Power are Polar-only sibling cards in
                        // the same vocabulary. LF/HF Ratio is no longer
                        // surfaced from Trends — kept only in the per-session
                        // detail view.
                        HRVTrendChart(
                            snapshots: snapshots,
                            allSnapshots: allSnapshots,
                            entries: entries,
                            polarSeries: sdnnWindowMeans,
                            dateRange: dateRange
                        )
                        RMSSDTrendChart(
                            polarSeries: rmssdWindowMeans,
                            entries: entries,
                            dateRange: dateRange
                        )
                        HFPowerTrendChart(
                            windowMeans: lfhfWindowMeans,
                            allOvernightMeans: lfhfAllMeans,
                            entries: entries,
                            dateRange: dateRange,
                            baselineAnchor: ws.end
                        )
                        HeartRateTrendChart(
                            snapshots: snapshots,
                            entries: entries,
                            polarSeries: polarHRWindowMeans,
                            dateRange: dateRange,
                            coalescedNights: coalescedNightRefs,
                            tappedNight: $tappedNight
                        )
                        SleepTrendChart(snapshots: snapshots, dateRange: dateRange)
                        ActivityTrendChart(snapshots: snapshots, dateRange: dateRange)
                        SleepRespiratoryTrendChart(
                            sessions: cpapSessions,
                            snapshots: snapshots,
                            allSnapshots: allSnapshots,
                            entries: entries,
                            dateRange: dateRange
                        )
                        GlucoseTrendChart(snapshots: snapshots, entries: entries, dateRange: dateRange)
                        BarometricTrendChart(readings: barometricReadings, entries: entries, allSnapshots: allSnapshots, dateRange: dateRange)

                        // Insights link
                        NavigationLink {
                            CorrelationInsightsView()
                        } label: {
                            HStack {
                                Image(systemName: "chart.dots.scatter")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text("Correlation Insights")
                                        .font(.headline)
                                    Text("See how your physiology relates to anxiety")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding()
                            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
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
            .navigationDestination(item: $tappedNight) { ref in
                // .equatable() lets SwiftUI use the destination's
                // `night`-only `==` to dedupe rebuilds when this view's
                // body re-runs. Without it, the destination's @Query state
                // defeats SwiftUI's default memberwise comparison and a
                // parent re-render storm cascades into a CA::Layer
                // use-after-free on iOS 26 (CLAUDE.md pitfall).
                PolarSessionHRDetailView(night: ref).equatable()
            }
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
