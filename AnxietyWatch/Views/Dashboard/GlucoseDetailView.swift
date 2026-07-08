import Charts
import Foundation
import SwiftData
import SwiftUI

// MARK: - View-model (testable)

/// Pure data-prep layer for `GlucoseDetailView`. Filters samples by day +
/// window, formats the provenance footer, looks up the per-day reliability
/// tier, builds the 14-day pill list, clips sleep bands to the window, and
/// filters anxiety markers to the window. Lives outside the view body so the
/// logic is unit-testable without instantiating SwiftUI / Charts.
struct GlucoseDetailViewModel {
    /// Glucose samples for the view's window. The caller (`GlucoseDetailView`)
    /// bounds these to glucose via its `@Query` metricType predicate (capped by
    /// `fetchLimit`) and applies the 30-day cutoff in-memory before passing
    /// them in — so this array is already glucose-only and within-window, but
    /// that filtering is the caller's responsibility, not this array's own
    /// invariant.
    let allSamples: [QuantityHealthSample]
    /// Daily snapshots; used solely for `dataQuality` reliability lookup.
    let snapshots: [HealthSnapshot]
    /// Sleep intervals (start/end pairs) that may cross day boundaries.
    let sleepIntervals: [(start: Date, end: Date)]
    /// Anxiety entries; filtered down per-window for vertical markers.
    let anxietyEntries: [AnxietyEntry]

    /// Samples whose timestamp falls inside the window for the given day.
    ///
    /// The window is anchored to the END of the visible time slice, so a
    /// `1h/3h/6h/12h` selection always shows the most-recent N hours of the
    /// selected day:
    /// - When `day` is today, the window ends at `now` → `(now - window, now)`.
    /// - When `day` is a past day, the window ends at end-of-day →
    ///   `(endOfDay - window, endOfDay)`.
    /// - The 24h window covers the full day regardless.
    ///
    /// This matches the user intuition that picking a past day plus a window
    /// size means "the latest N hours of that day," not "midnight → N hours."
    func samples(forDay day: Date, window: TimeInterval) -> [QuantityHealthSample] {
        let (start, end) = windowBounds(forDay: day, window: window)
        return allSamples
            .filter { $0.timestamp >= start && $0.timestamp < end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Provenance footer string. Examples:
    ///   - `"287 samples from Stelo over 24 h"` (single source)
    ///   - `"287 from Stelo + 5 from Apple Watch over 24 h"` (multi-source)
    /// Empty input → `"No samples in this window"`.
    ///
    /// Convenience overload that re-derives `windowSamples` from `(day, window)`.
    /// Prefer `provenanceFooter(samples:window:)` from the view body so the
    /// already-computed slice can be passed in directly rather than re-filtering
    /// and re-sorting `allSamples` here.
    func provenanceFooter(forDay day: Date, window: TimeInterval) -> String {
        provenanceFooter(samples: samples(forDay: day, window: window), window: window)
    }

    /// Provenance footer string built from a pre-computed `windowSamples`
    /// slice. The view body computes `windowSamples` once per render via
    /// `samples(forDay:window:)`; passing it through avoids duplicating the
    /// O(n log n) filter+sort here.
    func provenanceFooter(samples: [QuantityHealthSample], window: TimeInterval) -> String {
        guard !samples.isEmpty else { return "No samples in this window" }

        // Group by source bundle ID, then sort most-frequent first so the
        // dominant source is named first.
        var counts: [String: Int] = [:]
        for s in samples { counts[s.sourceBundleID, default: 0] += 1 }
        let ordered = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }

        let windowLabel = formatWindow(window)
        if ordered.count == 1 {
            let (bundle, count) = ordered[0]
            return "\(count) samples from \(DeviceProvenance.displayName(for: bundle)) over \(windowLabel)"
        }
        // Multi-source: "287 from Stelo + 5 from Apple Watch over 24 h"
        let parts = ordered.map { "\($0.value) from \(DeviceProvenance.displayName(for: $0.key))" }
        return parts.joined(separator: " + ") + " over \(windowLabel)"
    }

    /// Reliability label for the day, e.g. `"Reliability: high"`. Falls back
    /// to `insufficient` when no snapshot exists or the JSON is malformed.
    func reliabilityLabel(forDay day: Date) -> String {
        let tier = reliability(forDay: day) ?? .insufficient
        return "Reliability: \(tier.rawValue)"
    }

    /// Last 14 days (oldest first), each as `startOfDay`. The last entry is
    /// today's date.
    func dayPills(asOf today: Date) -> [Date] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: today)
        return (0..<14).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: todayStart)
        }
    }

    /// Sleep intervals clipped to the active day/window. Intervals that don't
    /// intersect the window are excluded entirely. Window bounds match
    /// `samples(forDay:window:)` — anchored to the end of the visible slice.
    func sleepBands(forDay day: Date, window: TimeInterval) -> [(start: Date, end: Date)] {
        let (windowStart, windowEnd) = windowBounds(forDay: day, window: window)
        return sleepIntervals.compactMap { interval in
            let clippedStart = max(interval.start, windowStart)
            let clippedEnd = min(interval.end, windowEnd)
            guard clippedStart < clippedEnd else { return nil }
            return (start: clippedStart, end: clippedEnd)
        }
    }

    /// Anxiety entries inside the active day/window. Window bounds match
    /// `samples(forDay:window:)` — anchored to the end of the visible slice.
    func anxietyMarkers(forDay day: Date, window: TimeInterval) -> [AnxietyEntry] {
        let (start, end) = windowBounds(forDay: day, window: window)
        return anxietyEntries.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    /// Compute `(start, end)` of the visible window for a given day-pill
    /// selection + window size. Anchors to the END of the slice so past days
    /// show the latest N hours of the day, not midnight → N hours.
    ///
    /// Exposed `internal` so the view can pass identical bounds to the chart's
    /// x-scale without recomputing — keeping the picker, sample filter, sleep
    /// clip, and chart axis perfectly aligned.
    func windowBounds(forDay day: Date, window: TimeInterval) -> (start: Date, end: Date) {
        Self.windowBounds(forDay: day, window: window, calendar: Calendar.current, now: Date.now)
    }

    /// DST-safe bounds calculation, parameterised on `Calendar` and `now` for
    /// deterministic testing (Calendar carries the timezone, which is what
    /// makes 23-hour spring-forward / 25-hour fall-back days possible).
    static func windowBounds(
        forDay day: Date,
        window: TimeInterval,
        calendar cal: Calendar,
        now: Date
    ) -> (start: Date, end: Date) {
        let dayStart = cal.startOfDay(for: day)
        // Use calendar arithmetic (not a fixed 86 400 s offset) so DST
        // transitions land on the correct wall-clock midnight: a 23-hour
        // "spring forward" day or a 25-hour "fall back" day must still end
        // at the *next* day's start-of-day, not exactly 24h after.
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        // 24h window: always full day, regardless of today vs past.
        if window >= 86_400 {
            return (start: dayStart, end: dayEnd)
        }
        // Today: anchor the window at `now` so the chart shows the most-recent
        // slice ending at the current time.
        if cal.isDate(day, inSameDayAs: now) {
            return (start: now.addingTimeInterval(-window), end: now)
        }
        // Past day: anchor at end-of-day to show the latest slice of that day.
        return (start: dayEnd.addingTimeInterval(-window), end: dayEnd)
    }

    // MARK: - Internals

    /// Look up the parsed `glucose.reliability` tier for the given day. Returns
    /// nil when no snapshot for the day exists or the JSON can't be parsed.
    private func reliability(forDay day: Date) -> Reliability? {
        let dayStart = Calendar.current.startOfDay(for: day)
        guard let snapshot = snapshots.first(where: {
            Calendar.current.startOfDay(for: $0.date) == dayStart
        }) else {
            return nil
        }
        return parseReliability(snapshot.dataQuality)
    }

    private func parseReliability(_ json: String?) -> Reliability? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data, options: []),
            let top = any as? [String: Any],
            let glucose = top["glucose"] as? [String: Any],
            let raw = glucose["reliability"] as? String
        else {
            return nil
        }
        return Reliability(rawValue: raw)
    }

    /// Window seconds → human label ("1 h", "3 h", "24 h"). Whole hours only.
    private func formatWindow(_ seconds: TimeInterval) -> String {
        let hours = Int((seconds / 3600).rounded())
        return "\(hours) h"
    }
}

// MARK: - Detail view

/// Stelo-style intraday glucose view. Day-pill picker (last 14 days), window
/// segmented picker (1/3/6/12/24h), line chart with target band and sleep
/// overlay, anxiety markers, and a source/reliability provenance footer.
///
/// Tap-to-inspect is implemented as a basic drag gesture over the chart that
/// snaps a `RuleMark` + callout to the nearest sample by x-axis position.
struct GlucoseDetailView: View {
    let anxietyEntries: [AnxietyEntry]
    let sleepIntervals: [(start: Date, end: Date)]

    @Query private var allGlucoseSamples: [QuantityHealthSample]
    @Query private var snapshots: [HealthSnapshot]

    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var selectedWindow: TimeInterval = 86_400  // 24h default
    @State private var inspected: QuantityHealthSample?

    /// Upper bound on the glucose fetch. 30 days of a 1-minute CGM is ~43k
    /// samples; 50k covers the window with margin while capping a multi-year
    /// CGM history from ever materializing in full. Paired with a descending
    /// sort so the cap keeps the MOST RECENT samples.
    private static let glucoseFetchLimit = 50_000
    /// 30-day cutoff applied in-memory (the fetch is metricType-bounded, not
    /// date-bounded, in SQL). Captured once at init for render stability.
    private let windowCutoff: Date

    init(
        anxietyEntries: [AnxietyEntry] = [],
        sleepIntervals: [(start: Date, end: Date)] = []
    ) {
        self.anxietyEntries = anxietyEntries
        self.sleepIntervals = sleepIntervals

        // SINGLE-CLAUSE #Predicate on metricType — the original compound
        // `metricType == capturedString && timestamp >= capturedDate` routed
        // SQL ORDER BY generation through the iOS 26 SwiftData
        // `_predicateEnforceRestrictionsOnSelector` hang path and froze the
        // main thread on first open (0x8BADF00D), the shape fixed in
        // HRVSessionCardView (F-030). We bound on metricType (glucose only) —
        // NOT on timestamp — because QuantityHealthSample also holds
        // high-frequency imports (EMAY oximeter at ~1 Hz), so a date-only
        // predicate would materialize tens of thousands of unrelated rows per
        // day (Copilot review of #173). A `fetchLimit` + descending sort bounds
        // the glucose fetch to the most-recent `glucoseFetchLimit` samples so a
        // multi-year CGM history can't materialize in full; the 30-day cutoff
        // is applied in-memory in `viewModel`. Calendar day subtraction is
        // DST-safe (matches DashboardView's cutoff).
        let glucoseRaw = "HKQuantityTypeIdentifierBloodGlucose"
        let cal = Calendar.current
        // Capture startOfToday ONCE so the primary and fallback paths can't
        // anchor to different days if init straddles midnight (Copilot #173).
        let startOfToday = cal.startOfDay(for: .now)
        self.windowCutoff = cal.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
        var descriptor = FetchDescriptor<QuantityHealthSample>(
            predicate: #Predicate { $0.metricType == glucoseRaw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.glucoseFetchLimit
        _allGlucoseSamples = Query(descriptor)
        _snapshots = Query(sort: \HealthSnapshot.date, order: .reverse)
    }

    private var viewModel: GlucoseDetailViewModel {
        // `allGlucoseSamples` is glucose-only (predicate) and newest-first
        // (fetchLimit sort); trim to the 30-day window in-memory. Downstream
        // `samples(forDay:)` re-sorts ascending, so the descending fetch order
        // is fine.
        GlucoseDetailViewModel(
            allSamples: allGlucoseSamples.filter { $0.timestamp >= windowCutoff },
            snapshots: snapshots,
            sleepIntervals: sleepIntervals,
            anxietyEntries: anxietyEntries
        )
    }

    var body: some View {
        // Compute the windowed sample slice ONCE per body evaluation. The
        // view-model is a struct, so caching there would require a class or a
        // global; computing here lets us pass the already-filtered array to
        // every subview that needs it. Without this, header + chart + footer
        // each re-filter+sort `allSamples` on every render — for a CGM that's
        // ~288 samples/day filtered three times per render.
        let model = viewModel
        let bounds = model.windowBounds(forDay: selectedDay, window: selectedWindow)
        let windowSamples = model.samples(forDay: selectedDay, window: selectedWindow)
        let sleepBands = model.sleepBands(forDay: selectedDay, window: selectedWindow)
        let anxietyMarkers = model.anxietyMarkers(forDay: selectedDay, window: selectedWindow)
        // Pass the pre-computed windowSamples through so the footer doesn't
        // re-filter+sort `allSamples`. `reliabilityLabel(forDay:)` reads only
        // `snapshots` (no sample re-filter), so it stays day-based.
        let provenance = model.provenanceFooter(samples: windowSamples, window: selectedWindow)
        let reliability = model.reliabilityLabel(forDay: selectedDay)

        return ScrollView {
            VStack(spacing: 16) {
                GlucoseDetailHeader(samples: windowSamples)

                // Pass the already-built `model` so the day pills reuse the one
                // in-memory metricType filter instead of re-invoking `viewModel`
                // (a second filter per render — Copilot review of #173).
                dayPills(model)

                windowPicker

                GlucoseIntradayChart(
                    samples: windowSamples,
                    sleepBands: sleepBands,
                    anxietyEntries: anxietyMarkers,
                    windowStart: bounds.start,
                    windowEnd: bounds.end,
                    inspected: $inspected
                )

                provenanceFooterView(provenance: provenance, reliability: reliability)
            }
            .padding()
        }
        .navigationTitle("Glucose")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Subviews

    private func dayPills(_ model: GlucoseDetailViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.dayPills(asOf: .now), id: \.self) { day in
                    DayPill(
                        day: day,
                        isSelected: Calendar.current.isDate(day, inSameDayAs: selectedDay)
                    ) {
                        selectedDay = day
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var windowPicker: some View {
        Picker("Window", selection: $selectedWindow) {
            Text("1h").tag(TimeInterval(3600))
            Text("3h").tag(TimeInterval(10_800))
            Text("6h").tag(TimeInterval(21_600))
            Text("12h").tag(TimeInterval(43_200))
            Text("24h").tag(TimeInterval(86_400))
        }
        .pickerStyle(.segmented)
    }

    /// Footer accepts pre-computed strings so it doesn't re-derive them from
    /// the view-model on every render — see `body` for the single computation
    /// site.
    private func provenanceFooterView(provenance: String, reliability: String) -> some View {
        VStack(spacing: 4) {
            Text(provenance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(reliability)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Equatable conformance

extension GlucoseDetailView: Equatable {
    /// Identity is just the inputs passed in from the parent. The two
    /// `@Query`s are SwiftData observation state and must NOT participate
    /// in equality — otherwise every body recompute produces a "different"
    /// destination on iOS 26 and the NavigationStack push animation
    /// restarts at ~30 Hz (see CLAUDE.md "Closure-based `NavigationLink`
    /// destinations that contain `@Query`" pitfall).
    static func == (lhs: GlucoseDetailView, rhs: GlucoseDetailView) -> Bool {
        lhs.anxietyEntries.map(\.persistentModelID) == rhs.anxietyEntries.map(\.persistentModelID)
            && lhs.sleepIntervals.count == rhs.sleepIntervals.count
            && zip(lhs.sleepIntervals, rhs.sleepIntervals).allSatisfy { l, r in
                l.start == r.start && l.end == r.end
            }
    }
}

// MARK: - Header

/// Compact header showing the latest in-window glucose value, trend status,
/// and freshness. Everything is derived from `samples` (the currently selected
/// day/window slice) so the header never mixes today's value with a past day's
/// trend. When the window has no samples we degrade to a "no data" line.
/// Mirrors `LiveMetricCard`'s value-stack styling without taking the dependency.
private struct GlucoseDetailHeader: View {
    let samples: [QuantityHealthSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current = samples.last {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", current.value))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.purple)
                    Text("mg/dL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(freshness(from: current.timestamp))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No data in selected window")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Stable / rising / falling" judged off the last few samples in the
    /// current window. Defaults to "stable" when there's not enough signal.
    private var statusLabel: String {
        guard samples.count >= 3 else { return "stable" }
        let tail = samples.suffix(3).map(\.value)
        let delta = tail.last! - tail.first!
        if delta > 10 { return "rising" }
        if delta < -10 { return "falling" }
        return "stable"
    }

    private func freshness(from date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3_600 { return "\(Int(interval / 60)) m ago" }
        if interval < 86_400 { return "\(Int(interval / 3_600)) h ago" }
        return "\(Int(interval / 86_400)) d ago"
    }
}

// MARK: - Day pill

private struct DayPill: View {
    let day: Date
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(weekdayLabel)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                Text(dayNumber)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : .primary)
            }
            .frame(width: 40, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.purple : Color.gray.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
    }

    private var weekdayLabel: String {
        day.formatted(.dateTime.weekday(.narrow))
    }

    private var dayNumber: String {
        day.formatted(.dateTime.day())
    }
}

// MARK: - Chart

/// Line chart with a 70-140 target band, sleep band overlay, anxiety markers,
/// and a tap-to-inspect drag gesture that snaps to the nearest sample.
private struct GlucoseIntradayChart: View {
    let samples: [QuantityHealthSample]
    let sleepBands: [(start: Date, end: Date)]
    let anxietyEntries: [AnxietyEntry]
    let windowStart: Date
    let windowEnd: Date
    @Binding var inspected: QuantityHealthSample?

    var body: some View {
        Chart {
            // Target band (70-140 mg/dL) — lightly tinted background
            RectangleMark(
                xStart: .value("Start", windowStart),
                xEnd: .value("End", windowEnd),
                yStart: .value("Low", 70),
                yEnd: .value("High", 140)
            )
            .foregroundStyle(.green.opacity(0.08))

            // Sleep band overlays — gray, semi-transparent.
            ForEach(sleepBands.indices, id: \.self) { i in
                RectangleMark(
                    xStart: .value("Sleep start", sleepBands[i].start),
                    xEnd: .value("Sleep end", sleepBands[i].end)
                )
                .foregroundStyle(.gray.opacity(0.18))
            }

            // Glucose line + points
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("mg/dL", sample.value)
                )
                .foregroundStyle(.purple)
                .interpolationMethod(.catmullRom)
            }

            ForEach(samples) { sample in
                PointMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("mg/dL", sample.value)
                )
                .foregroundStyle(.purple)
                .symbolSize(15)
            }

            // Anxiety entry markers
            ForEach(anxietyEntries) { entry in
                RuleMark(x: .value("Time", entry.timestamp))
                    .foregroundStyle(Color.severity(entry.severity).opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }

            // Tap-to-inspect indicator
            if let inspected {
                RuleMark(x: .value("Time", inspected.timestamp))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4) {
                        Text(inspectedCallout(for: inspected))
                            .font(.caption2.weight(.semibold))
                            .padding(4)
                            .background(.thinMaterial, in: .rect(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: windowStart...windowEnd)
        .chartYScale(domain: 40...250)
        .chartYAxisLabel("mg/dL")
        .frame(height: 240)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                handleDrag(at: value.location, proxy: proxy, geo: geo)
                            }
                            .onEnded { _ in
                                // Keep the inspected value visible after release; the
                                // user dismisses by tapping a different day/window.
                            }
                    )
            }
        }
    }

    private func handleDrag(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard !samples.isEmpty else { return }
        // Convert tap x-position into a Date via ChartProxy.
        let plotFrame: CGRect
        if let anchor = proxy.plotFrame {
            plotFrame = geo[anchor]
        } else {
            plotFrame = geo.frame(in: .local)
        }
        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }

        // Snap to the sample with the closest timestamp.
        let nearest = samples.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        })
        inspected = nearest
    }

    private func inspectedCallout(for sample: QuantityHealthSample) -> String {
        let timeStr = sample.timestamp.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(timeStr) · \(Int(sample.value)) mg/dL"
    }
}
