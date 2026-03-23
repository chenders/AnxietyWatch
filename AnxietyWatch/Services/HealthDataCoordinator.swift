import Foundation
import SwiftData

/// Coordinates HealthKit data flow: backfills historical snapshots on first launch
/// and keeps today's snapshot updated in real-time via observer queries.
@Observable
final class HealthDataCoordinator {
    private let modelContainer: ModelContainer
    private var hasSetupObservers = false
    private var pendingRefreshTask: Task<Void, Never>?

    /// Exposed so the UI can show backfill progress.
    var isBackfilling = false
    var backfillProgress = 0
    var backfillTotal = 0

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Call once at app launch. Backfills history if needed, imports clinical records, then starts live observers.
    func setupIfNeeded() async {
        await backfillIfNeeded()
        await importClinicalRecordsIfNeeded()
        await startObserving()
    }

    // MARK: - Backfill

    /// Backfill key includes a version so we can re-trigger after bug fixes
    /// that change how snapshots are computed (e.g., the noon-to-noon sleep window fix).
    private static let backfillKey = "hasBackfilledSnapshots_v3"

    private func backfillIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }

        let calendar = Calendar.current

        // Ask HealthKit how far back data goes
        let oldestDate = try? await HealthKitManager.shared.oldestSampleDate()
        let startDate = oldestDate ?? calendar.date(byAdding: .day, value: -90, to: .now)!
        let totalDays = max(1, (calendar.dateComponents([.day], from: startDate, to: .now).day ?? 90) + 1)

        isBackfilling = true
        backfillTotal = totalDays
        backfillProgress = 0

        let context = ModelContext(modelContainer)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        for offset in 0..<totalDays {
            let date = calendar.date(byAdding: .day, value: offset, to: startDate)!
            try? await aggregator.aggregateDay(date)
            backfillProgress = offset + 1
        }

        UserDefaults.standard.set(true, forKey: Self.backfillKey)
        isBackfilling = false
    }

    // MARK: - Clinical Records Import

    /// Silently imports any new clinical lab results from HealthKit Health Records.
    /// Runs every launch; deduplication in ClinicalRecordImporter handles repeat imports.
    private func importClinicalRecordsIfNeeded() async {
        let context = ModelContext(modelContainer)
        let importer = ClinicalRecordImporter(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )
        _ = try? await importer.importLabResults()
    }

    // MARK: - Live Observer Queries

    private func startObserving() async {
        guard !hasSetupObservers else { return }
        hasSetupObservers = true

        await HealthKitManager.shared.startObserving { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    /// Debounce rapid-fire observer callbacks (e.g., Watch syncing multiple types at once).
    /// Waits 5 seconds after the last update before re-aggregating today's snapshot
    /// and checking for new clinical records.
    private func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }

            let context = ModelContext(modelContainer)
            let aggregator = SnapshotAggregator(
                healthKit: HealthKitManager.shared,
                modelContext: context
            )
            try? await aggregator.aggregateDay(.now)

            await importClinicalRecordsIfNeeded()
        }
    }
}
