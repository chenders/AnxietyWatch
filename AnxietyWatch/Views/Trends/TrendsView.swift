import SwiftData
import SwiftUI

struct TrendsView: View {
    @Environment(\.modelContext) private var modelContext
    /// Deliberately still whole-table. Every consumer is a `.now`-anchored
    /// `BaselineCalculator` window (see the `anchorDate: Date = .now` default
    /// on `hrvBaseline`/`cpapAHIBaseline`/`barometricPressureBaseline`), not
    /// the displayed page — scoping this to the visible window would silently
    /// change the baselines the charts draw when the user pages back. It is
    /// also one row per day, so it is ~1.4k rows after four years and is not
    /// the fetch cost this type's `WindowedTrendTables` split targets.
    @Query(sort: \HealthSnapshot.date) private var allSnapshots: [HealthSnapshot]
    // AnxietyEntry / CPAPSession / BarometricReading previously lived here as
    // unbounded whole-table @Querys. They are now fetched window-scoped by
    // `WindowedTrendTables` (below) — see that type's doc comment for why.
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
    /// Live EMAY oximeter per-minute rows for the "Oximeter (live sessions)"
    /// card. Single-clause #Predicate on `sourceBundleID` ONLY: adding a
    /// `timestamp >= cutoff` clause alongside this query's sort routes SQL
    /// ORDER BY generation through the documented iOS 26
    /// `_predicateEnforceRestrictionsOnSelector` main-thread hang (F-030 —
    /// the same shape already fixed in HRVSessionCardView and
    /// GlucoseDetailView). No date bound is needed: every sibling query in
    /// this view is date-unbounded and windowed in-memory per render, and
    /// the live bundle only accrues two rows per streamed minute (~1k
    /// rows/night ceiling — the ~36k-rows/night EMAY CSV imports live under
    /// a different bundle ID and never match this predicate).
    @Query private var allLiveOximeterSamples: [QuantityHealthSample]
    @State private var timeRange: TimeRange = .week
    /// 0 = current period (ending now), -1 = previous period, etc.
    @State private var pageOffset = 0
    /// User-picked bounds for `.custom` — event-anchored windows down to
    /// hour granularity ("the 6 hours after that dose"), which the fixed
    /// day presets can't express. Defaults to a rolling last-24-hours,
    /// matching the 1D preset (startOfDay(yesterday) would span 24–48h
    /// depending on time of day).
    @State private var customStart: Date = .now.addingTimeInterval(-24 * 3600)
    @State private var customEnd: Date = .now
    @State private var sourceFilter: SourceFilter = .all
    @State private var tappedNight: CoalescedNightRef?

    init() {
        // Bind the typed constant to a local so the #Predicate macro can
        // capture it (single source of truth, per the source-label-drift
        // rule). This works because an init-based Query CAN capture locals —
        // the same trick as HRVSessionCardView.init — unlike the
        // property-wrapper-default HRVReading/SensorSession queries above,
        // which have no init body to capture in and must inline the literal.
        let liveBundle = EMAYRealtimeService.liveSourceBundleID
        _allLiveOximeterSamples = Query(
            filter: #Predicate<QuantityHealthSample> { $0.sourceBundleID == liveBundle },
            sort: \QuantityHealthSample.timestamp
        )
    }

    enum SourceFilter: String, CaseIterable {
        case all = "All"
        case selfReported = "Self-Reported"
        case checkIns = "Check-Ins"
    }

    enum TimeRange: String, CaseIterable {
        case day = "1D"
        case week = "7D"
        case month = "30D"
        case quarter = "90D"
        case custom = "Custom"

        /// Window width for the fixed presets; nil for `.custom`, whose
        /// window comes from the user-picked start/end instead.
        var days: Int? {
            switch self {
            case .day: return 1
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .custom: return nil
            }
        }

        /// Spoken-friendly label — VoiceOver would read the compact visual
        /// labels as "seven D".
        var accessibilityLabel: String {
            switch self {
            case .day: return "1 day"
            case .week: return "7 days"
            case .month: return "30 days"
            case .quarter: return "90 days"
            case .custom: return "Custom range"
            }
        }
    }

    // MARK: - Window Calculation

    private var isShowingCurrentPeriod: Bool { pageOffset == 0 }

    /// Snapshot the window once per body evaluation to avoid recomputing from .now on every access.
    private var windowState: (start: Date, end: Date, chartEnd: Date) {
        guard let periodDays = timeRange.days else {
            // Custom mode: the window IS the picked range (shifted by
            // paging); the end doubles as the chart's right edge. Boundary
            // semantics live in inWindow(): the active page includes its end
            // instant, paged windows are end-exclusive so pages tile.
            let w = TrendWindow(customStart: customStart, customEnd: customEnd, pageOffset: pageOffset)
            return (w.start, w.end, w.end)
        }
        let w = TrendWindow(now: .now, periodDays: periodDays, pageOffset: pageOffset)
        // chartEnd derivation lives in TrendWindow (tested there): past
        // multi-day pages show their inclusive last day; 1-day and current
        // windows keep their exact end.
        return (w.start, w.end, w.chartEnd(isCurrentPeriod: isShowingCurrentPeriod, periodDays: periodDays))
    }

    // MARK: - Date Label

    private static let windowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Custom windows can span hours, not just days, so their header label
    /// carries the time of day too. Localized template (not a fixed format)
    /// so the hour respects the user's 12/24-hour preference and locale.
    private static let windowDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f
    }()

    // MARK: - Filtered Data

    private func filterBySource(_ entries: [AnxietyEntry]) -> [AnxietyEntry] {
        Self.filterBySource(entries, filter: sourceFilter)
    }

    /// Pure source-filter used by the Source segmented control. `nonisolated
    /// static` so SourceFilterTests can exercise the PRODUCTION predicate
    /// directly (it was previously private, forcing every test to re-implement
    /// the self-reported/check-in logic inline — the nil-source back-compat
    /// invariant went unprotected, F-048).
    nonisolated static func filterBySource(
        _ entries: [AnxietyEntry], filter: SourceFilter
    ) -> [AnxietyEntry] {
        switch filter {
        case .all: return entries
        case .selfReported: return entries.filter { $0.source == nil || $0.source == "user" || $0.source == "dose_followup" }
        case .checkIns: return entries.filter { $0.source == "random_checkin" }
        }
    }

    private func inWindow(_ date: Date, start: Date, end: Date) -> Bool {
        // The active window (pageOffset 0) includes its end instant — the
        // picked custom end, or "now" for presets. Paged windows use an
        // exclusive end so adjacent pages tile without double-counting a
        // sample sitting exactly on the boundary instant.
        date >= start && (isShowingCurrentPeriod ? date <= end : date < end)
    }

    var body: some View {
        let ws = windowState
        // The three window-scoped tables are fetched by a child view whose
        // `@Query`s are rebuilt from these dates on every window change —
        // `@Query` can't read `@State` (timeRange/pageOffset/custom range),
        // so the bounds have to arrive through an `init`.
        WindowedTrendTables(windowStart: ws.start, windowEnd: ws.end) { allEntries, allCPAPSessions, allBarometric in
            charts(
                ws: ws,
                allEntries: allEntries,
                allCPAPSessions: allCPAPSessions,
                allBarometric: allBarometric
            )
        }
    }

    /// Split out of `body` verbatim so the window-scoped fetch can wrap it.
    /// `ws` is passed through as the same tuple `windowState` produces, so
    /// every `ws.start` / `ws.end` / `ws.chartEnd` reference below is unchanged.
    @ViewBuilder
    private func charts(
        ws: (start: Date, end: Date, chartEnd: Date),
        allEntries: [AnxietyEntry],
        allCPAPSessions: [CPAPSession],
        allBarometric: [BarometricReading]
    ) -> some View {
        let f = timeRange == .custom ? Self.windowDateTimeFormatter : Self.windowDateFormatter
        // A past 1-day page IS one calendar day — "Mar 23 – Mar 24" would
        // misread as a two-day window.
        let label = timeRange == .day && !isShowingCurrentPeriod
            ? f.string(from: ws.start)
            : "\(f.string(from: ws.start)) – \(f.string(from: ws.chartEnd))"
        // Chart-domain end. Sub-day-capable modes pad proportionally (5% of
        // the window — a fixed 12h pad would blank half of a 24h window),
        // clamped to never end before the window (late-day marks plot at
        // hour granularity). Multi-day presets pad a fixed 12h from the
        // window's TRUE end — not from the inclusive last day, whose noon
        // landing clipped evening marks — so current and past pages get
        // identical breathing room.
        let paddedChartEnd: Date = (timeRange == .day || timeRange == .custom)
            ? max(ws.chartEnd.addingTimeInterval(ws.chartEnd.timeIntervalSince(ws.start) * 0.05), ws.end)
            : ws.end.addingTimeInterval(12 * 3600)
        let dateRange = ws.start...paddedChartEnd

        // HealthSnapshot and CPAPSession rows are midnight-normalized, so an
        // intraday custom window (2 PM–8 PM) matches none of them by exact
        // instant even though the day's data exists — the CLAUDE.md "filter
        // granularity vs aggregation unit" pitfall. Custom windows spanning
        // at least a full day compare calendar DAYS for those series; shorter
        // custom windows intentionally show them empty (a caption near the
        // pickers says why) rather than a misleading full-plot day bar.
        let customSpanSeconds = ws.end.timeIntervalSince(ws.start)
        let showsDayGranularSeries = timeRange != .custom || customSpanSeconds >= 24 * 3600
        let dayWindow: ClosedRange<Date> = {
            let cal = Calendar.current
            let startDay = cal.startOfDay(for: ws.start)
            // Anchor the end day to the last instant BEFORE ws.end: a range
            // ending exactly at midnight contains none of that day, so its
            // midnight-normalized rows must not be pulled in. max() keeps the
            // range valid for windows contained within a single day.
            let endDay = cal.startOfDay(for: ws.end.addingTimeInterval(-1))
            return startDay...max(startDay, endDay)
        }()
        let isCustomWindow = timeRange == .custom
        let inDayGranularWindow: (Date) -> Bool = { [self] date in
            guard showsDayGranularSeries else { return false }
            if isCustomWindow { return dayWindow.contains(date) }
            return inWindow(date, start: ws.start, end: ws.end)
        }

        let snapshots = allSnapshots.filter { inDayGranularWindow($0.date) }
        let entries = filterBySource(allEntries.filter { inWindow($0.timestamp, start: ws.start, end: ws.end) })
        let cpapSessions = allCPAPSessions.filter { inDayGranularWindow($0.date) }
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

        // Live-oximeter minutes are per-instant data (one mean per minute),
        // so they take the exact-instant window path — never the
        // day-granular one reserved for midnight-normalized rows.
        let liveOximeterWindow = allLiveOximeterSamples.filter {
            inWindow($0.timestamp, start: ws.start, end: ws.end)
        }

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Time Range", selection: $timeRange) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Text(range.rawValue)
                                .accessibilityLabel(range.accessibilityLabel)
                                .tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .onChange(of: timeRange) { _, _ in pageOffset = 0 }

                    if timeRange == .custom {
                        // Event-anchored range: date AND time, so a window
                        // like "8 PM last night through 9 AM" is expressible.
                        VStack(spacing: 4) {
                            DatePicker(
                                "From",
                                selection: $customStart,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            DatePicker(
                                "To",
                                selection: $customEnd,
                                in: customStart...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                        .font(.subheadline)
                        .padding(.horizontal)
                        .onChange(of: customStart) { _, newStart in
                            // Keep the invariant in code, not just in the
                            // picker's UI bound: dragging From to/past To
                            // moves To an hour ahead — the same window the
                            // math would normalize a degenerate range to —
                            // so the pickers never display a zero-length
                            // range that the charts silently render as 1h.
                            if customEnd <= newStart {
                                customEnd = newStart.addingTimeInterval(3600)
                            }
                            pageOffset = 0
                        }
                        .onChange(of: customEnd) { _, _ in pageOffset = 0 }

                        if customEnd.timeIntervalSince(customStart) < 24 * 3600 {
                            Text("Daily metrics (sleep, activity, glucose, CPAP) appear "
                                + "when the range spans at least a full day.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }

                    Picker("Anxiety Source", selection: $sourceFilter) {
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
                            // In custom mode offset 0 is the picked range,
                            // not "today" — label it honestly.
                            Button(timeRange == .custom ? "Reset" : "Today") { pageOffset = 0 }
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
                        || !liveOximeterWindow.isEmpty

                    if !hasAnyData {
                        ContentUnavailableView(
                            "No Data Yet",
                            systemImage: "chart.xyaxis.line",
                            description: Text(
                                timeRange == .custom
                                    ? "No data in this exact range. Daily metrics only appear "
                                        + "for ranges spanning a full day — try widening the range."
                                    : "No data for this period. Try navigating to a different time range."
                            )
                        )
                    } else {
                        AnxietySeverityChart(entries: entries, dateRange: dateRange)
                        OuraTrendsSection(start: ws.start, end: ws.end)
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
                        // Rendered only when the user has ANY live-session
                        // rows at all — users without an EMAY shouldn't
                        // scroll past a permanently empty card.
                        // Within that, the per-window empty state comes from
                        // ChartCard(isEmpty:) like every sibling.
                        if !allLiveOximeterSamples.isEmpty {
                            OximeterLiveTrendChart(
                                samples: liveOximeterWindow,
                                dateRange: dateRange
                            )
                        }
                        GlucoseTrendChart(snapshots: snapshots, entries: entries, dateRange: dateRange)
                        BarometricTrendChart(readings: barometricReadings, entries: entries, allSnapshots: allSnapshots, dateRange: dateRange)

                        // Insights link
                        NavigationLink {
                            CorrelationInsightsView().equatable()
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
#if DEBUG
            .demoAutoScroll("trends", stops: 8, initialDelay: .seconds(4), pause: .seconds(2.2), step: 505)
#endif
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
        // Trailing days, not just today: the charts on this tab are exactly
        // where a yesterday whose sleep/resting HR landed late would
        // otherwise show a permanent hole.
        try? await aggregator.aggregateRecentDays(endingAt: .now)
    }
}

/// Window-scoped fetch for the three Trends tables whose only consumer is the
/// currently displayed window.
///
/// `TrendsView` previously held these as predicate-less whole-table `@Query`s
/// and narrowed them in `body`. That is the shape CLAUDE.md prohibits ("Any
/// new `@Query` on `HRVReading`, `BarometricReading`, or another unbounded
/// table must filter by `source` *and* bound by date. Don't fetch the whole
/// table to filter in-memory"), and the cost compounds: `@Query` invalidates
/// per *model type*, so every insert into any of these tables re-ran a whole
/// -table fetch plus sort on the main thread and re-evaluated all twelve chart
/// cards. Overnight — the barometer captures up to every 15 min and the EMAY
/// live stream writes ~2 rows/min — that becomes a continuous fetch/render
/// loop. It is what iOS killed the app for three times in July 2026
/// (`AnxietyWatch.cpu_resource_fatal`: ~48s CPU over ~50s, 91–96% average).
///
/// `@Query` cannot observe `@State`, so the bounds arrive through `init`;
/// SwiftUI re-inits this view — and therefore rebuilds the queries — on every
/// `TrendsView.body` evaluation. Paging back keeps working because the fetch
/// follows the window rather than being pinned to a fixed cutoff.
///
/// Note that "re-inits on every body evaluation" is *not* the same as
/// "re-fetches on every body evaluation": the current period's window is
/// `.now`-anchored (`TrendWindow` sets `end = now`), so the raw bounds differ
/// by microseconds each render, and `@Query` re-fetches whenever a captured
/// predicate value changes. `TrendsFetchWindow` snaps both bounds outward to
/// `boundGranularity` to collapse that into at most one re-fetch per minute —
/// without it, a re-render driven by the still-whole-table queries would drag
/// these three back into the very fetch loop this split exists to break.
///
/// All three predicates are **two-clause `Date`-only** windows. That shape is
/// safe from the iOS 26 SwiftData ORDER BY hang, which targets captured
/// non-primitive locals (`String`, `UUID`) — `CPAPDetailView` documents the
/// same pattern. It is also why `TrendsView`'s three `source`-filtered queries
/// are deliberately left whole-table: adding a `Date` clause beside their
/// captured `String` would produce exactly the unsafe compound shape (F-030).
///
/// Each bound is a superset of the in-memory window filter that still runs in
/// `TrendsView.charts(...)`, so the rendered result is unchanged.
private struct WindowedTrendTables<Content: View>: View {
    @Query private var entries: [AnxietyEntry]
    @Query private var cpapSessions: [CPAPSession]
    @Query private var barometric: [BarometricReading]

    private let content: ([AnxietyEntry], [CPAPSession], [BarometricReading]) -> Content

    init(
        windowStart: Date,
        windowEnd: Date,
        @ViewBuilder content: @escaping ([AnxietyEntry], [CPAPSession], [BarometricReading]) -> Content
    ) {
        self.content = content
        _entries = Query(
            filter: TrendsFetchWindow.entries(windowStart: windowStart, windowEnd: windowEnd),
            sort: \AnxietyEntry.timestamp
        )
        _cpapSessions = Query(
            filter: TrendsFetchWindow.cpapSessions(windowStart: windowStart, windowEnd: windowEnd),
            sort: \CPAPSession.date
        )
        _barometric = Query(
            filter: TrendsFetchWindow.barometric(windowStart: windowStart, windowEnd: windowEnd),
            sort: \BarometricReading.timestamp
        )
    }

    var body: some View {
        content(entries, cpapSessions, barometric)
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    TrendsView()
        .modelContainer(container)
}
#endif
