import BackgroundTasks
import Foundation
import os
import SwiftData

/// Coordinates HealthKit data flow: backfills historical snapshots on first launch
/// and keeps today's snapshot updated in real-time via observer queries.
@Observable
final class HealthDataCoordinator {
    private let modelContainer: ModelContainer
    private var hasSetupObservers = false
    private var pendingRefreshTask: Task<Void, Never>?
    private var lastClinicalImport: Date = .distantPast

    /// Exposed so the UI can show backfill progress.
    var isBackfilling = false
    var backfillProgress = 0
    var backfillTotal = 0

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Call once at app launch. Backfills history if needed, fills any gaps,
    /// imports clinical records, starts live observers, and wires up barometer persistence.
    func setupIfNeeded() async {
        pruneOldSamples()
        // Wire barometer persistence immediately so monitoring/persistence start at launch,
        // even if backfill/import/observer setup take a while.
        startBarometerPersistence()
        await backfillIfNeeded()
        await fillGaps()
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

    // MARK: - Gap Fill

    /// Pure calculation: returns the dates that need gap-filling between lastSnapshotDate and today.
    /// Returns empty if no gap exists or lastSnapshotDate is nil.
    static func gapDates(lastSnapshotDate: Date?, today: Date, maxDays: Int = 90) -> [Date] {
        guard let lastDate = lastSnapshotDate else { return [] }
        let calendar = Calendar.current
        guard let daysBetween = calendar.dateComponents([.day], from: lastDate, to: today).day,
              daysBetween > 1 else { return [] }

        let cappedGap = min(daysBetween, maxDays + 1)
        return (1..<cappedGap).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: lastDate)
        }
    }

    /// Aggregates snapshots for any days missed between the most recent snapshot and today.
    /// Runs every launch to catch days the app was not opened. Skips if initial backfill
    /// hasn't completed yet to avoid racing with it.
    private func fillGaps() async {
        guard UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }

        let context = ModelContext(modelContainer)
        let today = Calendar.current.startOfDay(for: .now)

        // Fetch the most recent snapshot strictly before today so a concurrently-created
        // today snapshot can't short-circuit gap filling.
        var descriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate<HealthSnapshot> { $0.date < today },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let lastSnapshot = try? context.fetch(descriptor).first else { return }

        let dates = Self.gapDates(lastSnapshotDate: lastSnapshot.date, today: today)
        guard !dates.isEmpty else { return }

        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        for date in dates {
            if Task.isCancelled { return }
            try? await aggregator.aggregateDay(date)
        }
    }

    // MARK: - Clinical Records Import

    /// Silently imports any new clinical lab results from HealthKit Health Records.
    /// Throttled to at most once per hour since clinical records rarely change.
    /// Deduplication in ClinicalRecordImporter handles repeat imports.
    private func importClinicalRecordsIfNeeded() async {
        let now = Date.now
        guard now.timeIntervalSince(lastClinicalImport) >= 3600 else { return }

        let context = ModelContext(modelContainer)
        let importer = ClinicalRecordImporter(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )
        do {
            try await importer.importLabResults()
            lastClinicalImport = Date.now
        } catch {
            // Don't advance throttle on failure so we can retry soon
        }
    }

    // MARK: - Live Observer Queries

    private func startObserving() async {
        guard !hasSetupObservers else { return }
        hasSetupObservers = true

        // Sleep analysis stays on observer query (category type)
        await HealthKitManager.shared.startObserving { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }

        // All quantity types use anchored queries for individual sample caching
        await HealthKitManager.shared.startAnchoredQueries { [weak self] newSamples in
            Task { @MainActor in
                self?.insertSamples(newSamples)
                self?.scheduleRefresh()
            }
        }
    }

    // MARK: - Background Task Scheduler

    static let backgroundRefreshIdentifier = "org.waitingforthefuture.AnxietyWatch.refresh"

    /// Register the BGAppRefreshTask handler. Must be called during app launch,
    /// before the app finishes launching (i.e., in App.init).
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleBackgroundRefresh(task)
            }
        }
    }

    /// Request the system schedule a background refresh. The system decides exactly when
    /// to run it based on app usage patterns, battery, connectivity, etc.
    func scheduleBackgroundRefresh() {
        // Cancel any existing pending request to avoid hitting tooManyPendingTaskRequests
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundRefreshIdentifier)

        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 6, to: .now)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.health.error("Background refresh scheduling failed: \(error)")
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()

        let workTask = Task {
            await fillGaps()
            guard !Task.isCancelled else { return }

            let context = ModelContext(modelContainer)
            let aggregator = SnapshotAggregator(
                healthKit: HealthKitManager.shared,
                modelContext: context
            )
            try? await aggregator.aggregateDay(.now)
        }

        task.expirationHandler = {
            workTask.cancel()
        }

        Task {
            _ = await workTask.result
            task.setTaskCompleted(success: !workTask.isCancelled)
        }
    }

    // MARK: - Live Observer Refresh

    /// Debounce rapid-fire observer callbacks (e.g., Watch syncing multiple types at once).
    /// Waits 5 seconds after the last update before re-aggregating today's snapshot
    /// and checking for new clinical records.
    private func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
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

    // MARK: - Sample Cache

    /// Insert new HealthKit samples into the HealthSample cache.
    private func insertSamples(_ samples: [(type: String, value: Double, timestamp: Date, source: String?)]) {
        let context = ModelContext(modelContainer)
        for sample in samples {
            context.insert(HealthSample(
                type: sample.type,
                value: sample.value,
                timestamp: sample.timestamp,
                source: sample.source
            ))
        }
        try? context.save()
    }

    /// Delete HealthSample rows older than 7 days.
    func pruneOldSamples() {
        let context = ModelContext(modelContainer)
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)
            ?? Date(timeIntervalSinceNow: -7 * 86400)
        let old = try? context.fetch(FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { $0.timestamp < cutoff }
        ))
        for sample in old ?? [] {
            context.delete(sample)
        }
        try? context.save()
    }

    // MARK: - Barometer Persistence

    /// Wires BarometerService to persist significant readings into SwiftData.
    /// Runs for the app's lifetime via the coordinator, not tied to any view.
    private func startBarometerPersistence() {
        let container = modelContainer
        // Called on main actor (BarometerService uses .main queue for altimeter updates)
        BarometerService.shared.onSignificantChange = { pressure, altitude in
            let context = ModelContext(container)
            let reading = BarometricReading(
                pressureKPa: pressure,
                relativeAltitudeM: altitude
            )
            context.insert(reading)
            try? context.save()
        }
        BarometerService.shared.startMonitoring()
    }
}
