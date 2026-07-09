import Foundation
import os
import SwiftData
import SwiftUI

/// Computational layer for the Dashboard. Owns no data — receives @Query
/// results from the view and computes derived state (baselines, trends,
/// sparklines, grouped metrics). This separation makes the computation
/// testable and keeps the view focused on layout.
@MainActor @Observable
final class DashboardViewModel {
    // MARK: - Computed State

    private(set) var samplesByType: [String: [HealthSample]] = [:]
    private(set) var lowSupplyCount = 0
    private(set) var hrvBaseline: BaselineCalculator.BaselineResult?
    private(set) var rhrBaseline: BaselineCalculator.BaselineResult?
    private(set) var sleepBaseline: BaselineCalculator.BaselineResult?
    private(set) var respiratoryBaseline: BaselineCalculator.BaselineResult?
    private(set) var cpapAHIBaseline: BaselineCalculator.BaselineResult?
    private(set) var barometricBaseline: BaselineCalculator.BaselineResult?

    // MARK: - Data Loading

    /// Load HealthSamples manually (not via @Query) to avoid re-rendering
    /// on every anchored query insert. Uses a 7-day window so infrequent
    /// types (VO2Max, walking steadiness) aren't dropped while keeping
    /// the result set bounded.
    func loadSamples(from context: ModelContext, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        var descriptor = FetchDescriptor<HealthSample>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 5000  // safety cap
        let samples = (try? context.fetch(descriptor)) ?? []
        samplesByType = Dictionary(grouping: samples, by: \.type)
    }

    /// Compute HRV and resting HR baselines from snapshots.
    func computeBaselines(from snapshots: [HealthSnapshot]) {
        hrvBaseline = BaselineCalculator.hrvBaseline(from: snapshots)
        rhrBaseline = BaselineCalculator.restingHRBaseline(from: snapshots)
        sleepBaseline = BaselineCalculator.sleepBaseline(from: snapshots)
        respiratoryBaseline = BaselineCalculator.respiratoryRateBaseline(from: snapshots)
        cpapAHIBaseline = BaselineCalculator.cpapAHIBaseline(from: snapshots)
        barometricBaseline = BaselineCalculator.barometricPressureBaseline(from: snapshots)
    }

    /// Compute supply alert count.
    func computeSupplyAlerts(from prescriptions: [Prescription]) {
        lowSupplyCount = PrescriptionSupplyCalculator.alertPrescriptions(from: prescriptions).count
    }

    /// Refresh today's snapshot from HealthKit.
    func refreshSnapshot(context: ModelContext) async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )
        do {
            try await aggregator.aggregateDay(.now)
        } catch {
            Log.data.error("Dashboard refresh aggregation failed: \(error, privacy: .public)")
        }
    }

    /// Auto-sync if configured.
    func autoSync(context: ModelContext) async {
        let sync = SyncService.shared
        guard sync.autoSyncEnabled, sync.isConfigured else { return }
        await sync.sync(modelContext: context)
    }

    /// Send current stats to the Watch companion.
    func sendStatsToWatch(
        lastAnxiety: Int?,
        todaySnapshot: HealthSnapshot?
    ) {
        PhoneConnectivityManager.shared.sendStatsToWatch(
            lastAnxiety: lastAnxiety,
            hrvAvg: todaySnapshot?.hrvAvg,
            restingHR: todaySnapshot?.restingHR
        )
    }

    // MARK: - Sample Queries

    /// Most recent sample for a given HealthKit type (any day in cache).
    func latestSample(for typeRawValue: String) -> HealthSample? {
        samplesByType[typeRawValue]?.first
    }

    /// Today's samples for a given type.
    func todaySamples(for typeRawValue: String, now: Date = .now) -> [HealthSample] {
        let midnight = Calendar.current.startOfDay(for: now)
        return (samplesByType[typeRawValue] ?? []).filter { $0.timestamp >= midnight }
    }

    /// Last N values for a given type (for RecentBarsView).
    func recentValues(for typeRawValue: String, count: Int = 7) -> [Double] {
        let samples = (samplesByType[typeRawValue] ?? []).prefix(count)
        return samples.reversed().map(\.value)
    }

    /// Sparkline segments for a given type using today's samples.
    func sparklineSegments(for typeRawValue: String, now: Date = .now) -> [[SparklinePoint]] {
        let samples = todaySamples(for: typeRawValue, now: now)
        let midnight = Calendar.current.startOfDay(for: now)
        return SparklineData.segments(from: samples, midnight: midnight, now: now)
    }

    /// Trend direction for a given type.
    func trend(for typeRawValue: String, now: Date = .now) -> TrendCalculator.Direction? {
        let config = SampleTypeConfig.config(for: typeRawValue)
        let samples = todaySamples(for: typeRawValue, now: now)
        return TrendCalculator.direction(
            samples: samples,
            threshold: config?.trendThreshold ?? 3
        )
    }

    // MARK: - Snapshot Queries

    /// Average of the last 7 non-nil values for a Double-optional snapshot keypath.
    func sevenDayAverage(
        _ keyPath: KeyPath<HealthSnapshot, Double?>,
        from snapshots: [HealthSnapshot]
    ) -> Double? {
        let values = snapshots.prefix(7).compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Average of the last 7 non-nil values for an Int-optional snapshot keypath.
    func sevenDayAverage(
        _ keyPath: KeyPath<HealthSnapshot, Int?>,
        from snapshots: [HealthSnapshot]
    ) -> Double? {
        let values = snapshots.prefix(7).compactMap { $0[keyPath: keyPath].map(Double.init) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Today's snapshot from the provided list.
    func todaySnapshot(from snapshots: [HealthSnapshot], now: Date = .now) -> HealthSnapshot? {
        let startOfDay = Calendar.current.startOfDay(for: now)
        return snapshots.first { $0.date == startOfDay }
    }

    /// Most recent snapshot with a non-nil value for a key path, plus whether it's today.
    func lastSnapshotWith<T>(
        _ keyPath: KeyPath<HealthSnapshot, T?>,
        from snapshots: [HealthSnapshot],
        now: Date = .now
    ) -> (HealthSnapshot, Bool)? {
        guard let snapshot = snapshots.first(where: { $0[keyPath: keyPath] != nil }) else {
            return nil
        }
        let startOfDay = Calendar.current.startOfDay(for: now)
        let isToday = snapshot.date == startOfDay
        return (snapshot, isToday)
    }

    /// Format a freshness label for an overnight snapshot.
    /// `snapshot.date` represents the morning the overnight window ended (per
    /// SnapshotAggregator's noon-to-noon range), so day-diff = N corresponds
    /// to "(N+1) nights ago" colloquially. A same-day snapshot reads "Last
    /// night"; older snapshots roll forward.
    static func nightFreshnessLabel(for snapshotDate: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let snapDay = cal.startOfDay(for: snapshotDate)
        let days = cal.dateComponents([.day], from: snapDay, to: today).day ?? 0
        switch days {
        case ...0: return "Last night"
        default: return "\(days + 1) nights ago"
        }
    }

    /// Latest lab result per unique test from last 7 days (max 4 for dashboard).
    func latestLabResultPerTest(from labResults: [ClinicalLabResult], now: Date = .now) -> [ClinicalLabResult] {
        let calendar = Calendar.current
        let weekAgoBase = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let oneWeekAgo = calendar.startOfDay(for: weekAgoBase)
        let sorted = labResults.sorted { $0.effectiveDate > $1.effectiveDate }
        var seen = Set<String>()
        var results: [ClinicalLabResult] = []
        for result in sorted {
            if result.effectiveDate < oneWeekAgo { break }
            guard LabTestRegistry.isTracked(result.loincCode),
                  !seen.contains(result.loincCode) else { continue }
            seen.insert(result.loincCode)
            results.append(result)
            if results.count >= 4 { break }
        }
        return results
    }

    // MARK: - Formatting

    /// Freshness label for a sample timestamp.
    func freshnessLabel(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        if date >= midnight {
            return date.formatted(.relative(presentation: .named))
        }
        let hour = calendar.component(.hour, from: date)
        if let yesterdayMidnight = calendar.date(byAdding: .day, value: -1, to: midnight),
           date >= yesterdayMidnight && date < midnight && hour >= 18 {
            return "last night"
        }
        return date.formatted(.relative(presentation: .named))
    }

    /// Human-readable label for a stale snapshot date.
    func staleLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month().day())
    }

    // MARK: - Smart Summary

    /// Compose the "What changed today" summary from current VM state.
    /// Pure — no SwiftData, no view; just packs the composer Input.
    ///
    /// Note on `sleepEfficiencyBaseline`: until we track per-night efficiency,
    /// approximate from the sleep-duration baseline (typical-night minutes /
    /// 480 min target × 100). Tunable later when a real efficiency baseline
    /// is added.
    ///
    /// Clamped at 100% — the placeholder formula treats 480 min as the
    /// efficiency target, so users who typically sleep >8 h would otherwise
    /// get a baseline >100%, which reads nonsensical next to the (clamped)
    /// efficiency value. Falls back to 88% when no sleep baseline exists.
    static func efficiencyBaselinePct(sleepBaselineMean: Double) -> Double {
        sleepBaselineMean > 0
            ? min(100.0, sleepBaselineMean / 480.0 * 100.0)
            : 88.0
    }

    /// Events from the noon-to-noon night window ending on `morning`
    /// (a start-of-day instant, e.g. `snapshot.date`), matching
    /// SnapshotAggregator's overnight convention. SleepEfficiencyCalculator
    /// is a single-night calculator; every consumer must pre-filter to one
    /// night's window — a same-calendar-day filter spans 48 hours and can
    /// dilute the night with an adjacent night's stray events (F-011).
    static func nightEvents(from events: [SleepStageEvent], forMorning morning: Date) -> [SleepStageEvent] {
        let offset = TimeInterval(SnapshotAggregator.overnightOffsetHours) * 3600
        let windowStart = morning.addingTimeInterval(-offset)
        let windowEnd = morning.addingTimeInterval(offset)
        return events.filter { $0.startTime >= windowStart && $0.startTime < windowEnd }
    }

    /// The most recent night window (yesterday noon through today noon).
    static func lastNightEvents(from events: [SleepStageEvent], now: Date = .now) -> [SleepStageEvent] {
        nightEvents(from: events, forMorning: Calendar.current.startOfDay(for: now))
    }

    /// CPAP session recorded for the same night as `snapshot`, or nil when
    /// none was imported for that date. Mirrors SnapshotAggregator's
    /// `date == snapshot.date` stitch rule, including the highest-usage
    /// dedup for re-imported duplicates — so the Dashboard's "Last Night"
    /// card can never present a stale session's AHI as last night's value
    /// (F-036); a nil here renders the card without an AHI clause instead.
    func cpapSession(for snapshot: HealthSnapshot, in sessions: [CPAPSession]) -> CPAPSession? {
        sessions
            .filter { $0.date == snapshot.date }
            .max(by: { lhs, rhs in
                if lhs.totalUsageMinutes != rhs.totalUsageMinutes {
                    return lhs.totalUsageMinutes < rhs.totalUsageMinutes
                }
                // Deterministic tie-break among same-usage duplicates. An
                // unknown AHI (nil, F-094) is treated as +∞ so a scored night
                // always wins the tie and its real AHI propagates — a nil must
                // never displace a measured value. Comparison-only; the
                // returned session's real (possibly nil) AHI is untouched.
                return (lhs.ahi ?? .infinity) > (rhs.ahi ?? .infinity)
            })
    }

    func smartSummary(
        snapshots: [HealthSnapshot],
        sleepEvents: [SleepStageEvent],
        lastAnxiety: AnxietyEntry?,
        activeAlerts: Int,
        now: Date = .now
    ) -> SmartSummaryComposer.Output {
        let today = todaySnapshot(from: snapshots, now: now)
        // Missing metrics stay nil — collapsing them to 0 fabricated extreme
        // "below baseline" headlines (a nil resting HR read as a -10σ drop)
        // whenever today's snapshot lacked the metric (F-010).
        let hrvValue = today?.hrvAvg ?? snapshots.first?.hrvAvg
        let rhrValue = today?.restingHR ?? snapshots.first?.restingHR
        let lastNight = Self.lastNightEvents(from: sleepEvents, now: now)
        // nil (not 0%) when last night has no events, so the composer skips
        // the efficiency candidate instead of reporting a fabricated
        // "0% (typical 88%)" (F-011).
        let efficiency: Double? = lastNight.isEmpty
            ? nil
            : SleepEfficiencyCalculator.compute(from: lastNight).efficiencyPct
        let efficiencyBaseline = Self.efficiencyBaselinePct(sleepBaselineMean: sleepBaseline?.mean ?? 0)

        let anxietySeverity24h: Int? = {
            guard let a = lastAnxiety,
                  a.timestamp >= now.addingTimeInterval(-24 * 3600) else { return nil }
            return a.severity
        }()

        let input = SmartSummaryComposer.Input(
            hrv: .init(value: hrvValue, baseline: hrvBaseline),
            restingHR: .init(value: rhrValue, baseline: rhrBaseline),
            sleepEfficiencyPct: efficiency,
            sleepEfficiencyBaseline: efficiencyBaseline,
            ahi: today?.cpapAHI,
            ahiBaseline: cpapAHIBaseline,
            anxietyLast24h: anxietySeverity24h,
            activeAlerts: activeAlerts
        )
        return SmartSummaryComposer.compose(input: input)
    }

    // MARK: - Device chip

    /// Map a HealthSample's source string to a `DeviceChip.Source`.
    /// Returns nil when the source isn't one of the known device families —
    /// callers should treat nil as "no chip".
    func deviceChipSource(for sample: HealthSample?) -> DeviceChip.Source? {
        guard let s = sample, let src = s.source else { return nil }
        let id = src.lowercased()
        if id.contains(EMAYImporter.sourceBundleID.lowercased()) { return .emay }
        if id.contains(PolarHRMService.sourceLabel.lowercased()) { return .polar }
        // Apple Watch and Apple Health share a "com.apple.*" bundle ID prefix;
        // no single named constant covers all variants, so substring match is correct.
        if id.contains("apple.health") || id.contains("com.apple") { return .watch }
        return nil
    }

    // MARK: - Baseline deltas (for `.baselineChip` viz)

    struct BaselineDelta {
        let text: String   // e.g. "↓ 28% vs 30d"
        let color: Color
    }

    func baselineDelta(
        value: Double,
        baseline: BaselineCalculator.BaselineResult?,
        higherIsBetter: Bool
    ) -> BaselineDelta? {
        guard let b = baseline, b.mean > 0 else { return nil }
        let delta = value - b.mean
        let pct = Int(abs(delta) / b.mean * 100)
        guard pct >= 5 else { return nil }  // suppress noise
        let arrow = delta < 0 ? "↓" : "↑"
        // For "higher is better" metrics, drops are bad. Otherwise rises are bad.
        let bad = higherIsBetter ? delta < 0 : delta > 0
        let color: Color = bad ? .orange : .green
        return BaselineDelta(text: "\(arrow) \(pct)% vs 30d", color: color)
    }

    /// Color a metric based on personal baseline deviation.
    func baselineColor(
        value: Double,
        baseline: BaselineCalculator.BaselineResult?,
        higherIsBetter: Bool
    ) -> Color {
        guard let baseline else { return .primary }

        if higherIsBetter {
            if value >= baseline.lowerBound { return .green }
            if value >= baseline.lowerBound - baseline.standardDeviation { return .yellow }
            return .red
        } else {
            if value <= baseline.upperBound { return .green }
            if value <= baseline.upperBound + baseline.standardDeviation { return .yellow }
            return .red
        }
    }

    func sleepColor(minutes: Int) -> Color {
        switch minutes {
        case 420...: return .green
        case 360..<420: return .yellow
        default: return .red
        }
    }

    func stepsColor(_ steps: Int) -> Color {
        switch steps {
        case 8000...: return .green
        case 5000..<8000: return .yellow
        default: return .red
        }
    }
}
