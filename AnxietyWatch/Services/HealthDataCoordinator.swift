import BackgroundTasks
import Foundation
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

    /// Aggregates snapshots for any days missed between the most recent snapshot and today.
    /// Runs every launch to catch days the app was not opened. Skips if initial backfill
    /// hasn't completed yet to avoid racing with it.
    private func fillGaps() async {
        guard UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }

        let context = ModelContext(modelContainer)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        var descriptor = FetchDescriptor<HealthSnapshot>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let lastSnapshot = try? context.fetch(descriptor).first else { return }

        let lastDate = lastSnapshot.date
        guard let daysBetween = calendar.dateComponents([.day], from: lastDate, to: today).day,
              daysBetween > 1 else { return }

        let daysToFill = min(daysBetween, 90)

        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        // Fill from the day after the last snapshot up to today (exclusive — today
        // is handled by the observer and view .task refreshes).
        for offset in 1..<daysToFill {
            guard let date = calendar.date(byAdding: .day, value: offset, to: lastDate) else { continue }
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

        await HealthKitManager.shared.startObserving { [weak self] in
            Task { @MainActor in
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
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleBackgroundRefresh(task)
        }
    }

    /// Request the system schedule a background refresh. The system decides exactly when
    /// to run it based on app usage patterns, battery, connectivity, etc.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 6, to: .now)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Background refresh scheduling failed: \(error)")
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()

        let workTask = Task {
            await fillGaps()

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
            task.setTaskCompleted(success: true)
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
