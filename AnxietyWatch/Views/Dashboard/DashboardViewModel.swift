import Foundation
import os
import SwiftData
import SwiftUI

/// Computational layer for the Dashboard. Owns no data — receives @Query
/// results from the view and computes derived state (baselines, trends,
/// sparklines, grouped metrics). This separation makes the computation
/// testable and keeps the view focused on layout.
@Observable
final class DashboardViewModel {
    // MARK: - Computed State

    private(set) var samplesByType: [String: [HealthSample]] = [:]
    private(set) var lowSupplyCount = 0
    private(set) var hrvBaseline: BaselineCalculator.BaselineResult?
    private(set) var rhrBaseline: BaselineCalculator.BaselineResult?

    // MARK: - Data Loading

    /// Load HealthSamples manually (not via @Query) to avoid re-rendering
    /// on every anchored query insert.
    func loadSamples(from context: ModelContext) {
        let descriptor = FetchDescriptor<HealthSample>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let samples = (try? context.fetch(descriptor)) ?? []
        samplesByType = Dictionary(grouping: samples, by: \.type)
    }

    /// Compute HRV and resting HR baselines from snapshots.
    func computeBaselines(from snapshots: [HealthSnapshot]) {
        hrvBaseline = BaselineCalculator.hrvBaseline(from: snapshots)
        rhrBaseline = BaselineCalculator.restingHRBaseline(from: snapshots)
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
    func todaySamples(for typeRawValue: String) -> [HealthSample] {
        let midnight = Calendar.current.startOfDay(for: .now)
        return (samplesByType[typeRawValue] ?? []).filter { $0.timestamp >= midnight }
    }

    /// Last N values for a given type (for RecentBarsView).
    func recentValues(for typeRawValue: String, count: Int = 7) -> [Double] {
        let samples = (samplesByType[typeRawValue] ?? []).prefix(count)
        return samples.reversed().map(\.value)
    }

    /// Sparkline segments for a given type using today's samples.
    func sparklineSegments(for typeRawValue: String) -> [[SparklinePoint]] {
        let samples = todaySamples(for: typeRawValue)
        let midnight = Calendar.current.startOfDay(for: .now)
        return SparklineData.segments(from: samples, midnight: midnight, now: .now)
    }

    /// Trend direction for a given type.
    func trend(for typeRawValue: String) -> TrendCalculator.Direction? {
        let config = SampleTypeConfig.config(for: typeRawValue)
        let samples = todaySamples(for: typeRawValue)
        return TrendCalculator.direction(
            samples: samples,
            threshold: config?.trendThreshold ?? 3
        )
    }

    // MARK: - Snapshot Queries

    /// Today's snapshot from the provided list.
    func todaySnapshot(from snapshots: [HealthSnapshot]) -> HealthSnapshot? {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return snapshots.first { $0.date == startOfDay }
    }

    /// Most recent snapshot with a non-nil value for a key path, plus whether it's today.
    func lastSnapshotWith<T>(
        _ keyPath: KeyPath<HealthSnapshot, T?>,
        from snapshots: [HealthSnapshot]
    ) -> (HealthSnapshot, Bool)? {
        guard let snapshot = snapshots.first(where: { $0[keyPath: keyPath] != nil }) else {
            return nil
        }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let isToday = snapshot.date == startOfDay
        return (snapshot, isToday)
    }

    /// Latest lab result per unique test from last 7 days (max 4 for dashboard).
    func latestLabResultPerTest(from labResults: [ClinicalLabResult]) -> [ClinicalLabResult] {
        let calendar = Calendar.current
        let weekAgoBase = calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
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
    func freshnessLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: .now)
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
