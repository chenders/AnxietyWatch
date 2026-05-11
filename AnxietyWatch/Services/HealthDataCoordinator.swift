import BackgroundTasks
import Foundation
import HealthKit
import os
import SwiftData

/// Coordinates HealthKit data flow: backfills historical snapshots on first launch
/// and keeps today's snapshot updated in real-time via observer queries.
@Observable
final class HealthDataCoordinator {
    private let modelContainer: ModelContainer
    private let healthKit: any HealthKitDataSource
    /// Storage for per-metric anchor dates used by `mirrorHealthKitSamples()`.
    /// Injected so tests can isolate anchor state per run.
    private let defaults: UserDefaults
    private var hasSetupObservers = false
    private var pendingRefreshTask: Task<Void, Never>?
    private var lastClinicalImport: Date = .distantPast
    /// Serialization guard for `mirrorHealthKitSamples()`. Multiple call sites
    /// (debounced observer refresh, BG-refresh task, and `setupIfNeeded`) can
    /// fire in overlapping orders. Without this guard, two concurrent runs can
    /// both prefetch the same UUID set into separate ModelContexts and then
    /// race their inserts, producing unique-constraint save failures (and on
    /// `QuantityHealthSample.id`, dropped writes). The flag is touched only
    /// from `mirrorHealthKitSamples()` itself, which is `@MainActor`-bound, so
    /// reads/writes are serialized by the main actor without extra locking.
    @MainActor private var isMirroring = false

    /// Exposed so the UI can show backfill progress.
    var isBackfilling = false
    var backfillProgress = 0
    var backfillTotal = 0

    init(
        modelContainer: ModelContainer,
        healthKit: any HealthKitDataSource = HealthKitManager.shared,
        defaults: UserDefaults = .standard
    ) {
        self.modelContainer = modelContainer
        self.healthKit = healthKit
        self.defaults = defaults
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
        // Start observers before clinical import — clinical import is slow (~16s)
        await startObserving()
        // Initial mirror of per-sample HealthKit data into SwiftData. Runs after
        // observers are wired (so HealthKit auth has been triggered) and before
        // clinical import. Anchors are persisted in `defaults`, so subsequent
        // launches only pull data since the last successful mirror.
        await mirrorHealthKitSamples()
        await importClinicalRecordsIfNeeded()
    }

    // MARK: - Backfill

    /// Backfill key includes a version so we can re-trigger after bug fixes
    /// that change how snapshots are computed (e.g., the noon-to-noon sleep window fix).
    private static let backfillKey = "hasBackfilledSnapshots_v3"

    private func backfillIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.backfillKey) else { return }

        let calendar = Calendar.current

        // Ask HealthKit how far back data goes
        let oldestDate: Date?
        do {
            oldestDate = try await healthKit.oldestSampleDate()
        } catch {
            Log.health.error("Failed to query oldest sample date: \(error, privacy: .public)")
            oldestDate = nil
        }
        let startDate = oldestDate
            ?? calendar.date(byAdding: .day, value: -90, to: .now)
            ?? Date(timeIntervalSinceNow: -90 * 86400)
        let totalDays = max(1, (calendar.dateComponents([.day], from: startDate, to: .now).day ?? 90) + 1)

        isBackfilling = true
        backfillTotal = totalDays
        backfillProgress = 0

        let context = ModelContext(modelContainer)
        let aggregator = SnapshotAggregator(
            healthKit: healthKit,
            modelContext: context
        )

        for offset in 0..<totalDays {
            guard !Task.isCancelled else {
                Log.data.info("Backfill cancelled at offset \(offset, privacy: .public)/\(totalDays, privacy: .public)")
                isBackfilling = false
                return
            }
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else { continue }
            do {
                try await aggregator.aggregateDay(date)
            } catch is CancellationError {
                Log.data.info("Backfill cancelled during aggregation at offset \(offset, privacy: .public)")
                isBackfilling = false
                return
            } catch {
                let dateString = date.formatted(.iso8601.year().month().day())
                Log.data.error("Backfill failed for \(dateString, privacy: .public) (offset \(offset, privacy: .public)): \(error, privacy: .public)")
            }
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

        let lastSnapshot: HealthSnapshot?
        do {
            lastSnapshot = try context.fetch(descriptor).first
        } catch {
            Log.data.error("Failed to fetch last snapshot for gap fill: \(error, privacy: .public)")
            return
        }
        guard let lastSnapshot else { return }

        let dates = Self.gapDates(lastSnapshotDate: lastSnapshot.date, today: today)
        guard !dates.isEmpty else { return }

        let aggregator = SnapshotAggregator(
            healthKit: healthKit,
            modelContext: context
        )

        for date in dates {
            if Task.isCancelled { return }
            do {
                try await aggregator.aggregateDay(date)
            } catch is CancellationError {
                return
            } catch {
                let dateString = date.formatted(.iso8601.year().month().day())
                Log.data.error("Gap fill failed for \(dateString, privacy: .public): \(error, privacy: .public)")
            }
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
            healthKit: healthKit,
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
        await healthKit.startObserving { [weak self] in
            guard let coordinator = self else { return }
            Task { @MainActor in
                coordinator.scheduleRefresh()
            }
        }

        // All quantity types use anchored queries for individual sample caching.
        // Samples are buffered and saved in batches to avoid flooding the main
        // actor with individual saves (which cause excessive @Query re-evaluation).
        await healthKit.startAnchoredQueries { [weak self] newSamples in
            guard let coordinator = self else { return }
            Task { @MainActor in
                coordinator.bufferSamples(newSamples)
                coordinator.scheduleRefresh()
            }
        }
    }

    // MARK: - Background Task Scheduler

    static let backgroundRefreshIdentifier = "com.groundeffectsoftware.AnxietyWatch.refresh"

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
            Log.health.error("Background refresh scheduling failed: \(error, privacy: .public)")
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()

        let workTask = Task {
            await fillGaps()
            guard !Task.isCancelled else { return }

            // Mirror new HealthKit samples into SwiftData before aggregating so
            // the BG-refresh path matches the foreground-refresh path's ordering.
            await mirrorHealthKitSamples()
            guard !Task.isCancelled else { return }

            let context = ModelContext(modelContainer)
            let aggregator = SnapshotAggregator(
                healthKit: healthKit,
                modelContext: context
            )
            do {
                try await aggregator.aggregateDay(.now)
            } catch is CancellationError {
                // Expected when the background task expires and cancels workTask.
                return
            } catch {
                Log.data.error("Background refresh aggregation failed: \(error, privacy: .public)")
            }
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

            // Mirror new HealthKit samples into SwiftData BEFORE running the
            // aggregator so SnapshotAggregator-derived data (and the anytime
            // SwiftData consumers) sees the freshly-mirrored rows.
            await mirrorHealthKitSamples()
            guard !Task.isCancelled else { return }

            let context = ModelContext(modelContainer)
            let aggregator = SnapshotAggregator(
                healthKit: healthKit,
                modelContext: context
            )
            do {
                try await aggregator.aggregateDay(.now)
            } catch is CancellationError {
                return
            } catch {
                Log.data.error("Refresh aggregation failed: \(error, privacy: .public)")
            }

            guard !Task.isCancelled else { return }
            await importClinicalRecordsIfNeeded()
        }
    }

    // MARK: - Sample Mirroring (HealthKit -> SwiftData)

    /// Default lookback window used the first time a metric is mirrored — i.e.
    /// when no anchor has been written yet. Bounded so first-run pulls don't
    /// drag in years of data; historical backfill is handled separately.
    private static let initialMirrorLookbackDays = 7

    /// Run `descriptorBuilder` against successive chunks of `ids` (each
    /// ≤ `SQLiteLimits.predicateBatchSize`) and concatenate the fetched rows. Used
    /// by the sample-mirror prefetch paths to stay under SQLite's 999-parameter
    /// limit when the incoming UUID set is large (CGM, SpO2, multi-day catch-up).
    /// The caller passes a closure that builds a `FetchDescriptor` from a
    /// chunk-sized `Set<UUID>` so each metric type can keep its own predicate
    /// shape; the closure is invoked once per chunk.
    static func fetchInChunks<T: PersistentModel>(
        ids: Set<UUID>,
        in context: ModelContext,
        descriptorBuilder: (Set<UUID>) -> FetchDescriptor<T>
    ) throws -> [T] {
        guard !ids.isEmpty else { return [] }
        var results: [T] = []
        let allIDs = Array(ids)
        var index = 0
        while index < allIDs.count {
            let end = min(index + SQLiteLimits.predicateBatchSize, allIDs.count)
            let batch = Set(allIDs[index..<end])
            let descriptor = descriptorBuilder(batch)
            results.append(contentsOf: try context.fetch(descriptor))
            index = end
        }
        return results
    }

    /// Pull every registered HealthKit metric (and sleep stages) at sample
    /// resolution into SwiftData. Per-metric anchors are stored in `defaults`
    /// under `"sampleAnchor.<rawIdentifier>"` (or `"sampleAnchor.sleep"` for
    /// the sleep-stage path).
    ///
    /// Each pass queries `(max(anchor - SampleCaptureRegistry.mirrorLookbackInterval,
    /// epoch), now)` so retroactive HealthKit corrections within the past 48
    /// hours are picked up — CGM backfill, recalibration affecting yesterday's
    /// timestamps/values, sleep edits applied the next day. The anchor still
    /// advances to `now` only after a successful `context.save()`, so we don't
    /// keep re-fetching from origin every pass; the look-back just ensures
    /// recently-corrected samples are visible to the query. The UUID-keyed
    /// upsert logic already handles the "same UUID, updated fields" case
    /// correctly — the look-back simply makes sure those samples are surfaced.
    ///
    /// Replays are idempotent because `QuantityHealthSample.id` and
    /// `SleepStageEvent.id` are the HealthKit `HKSample.uuid`, which is
    /// `@Attribute(.unique)`.
    ///
    /// Wired from `setupIfNeeded()` (initial mirror at launch), `scheduleRefresh()`
    /// (foreground/observer-fire refresh, BEFORE aggregation), and
    /// `handleBackgroundRefresh()` (BG task, BEFORE aggregation).
    ///
    /// Serialized via `isMirroring` so overlapping callers (e.g., a fast
    /// observer fire while the BG-refresh path is still running) can't insert
    /// the same UUID set into two separate ModelContexts and race their saves
    /// into unique-constraint failures. While a mirror is in flight, additional
    /// calls return immediately as no-ops; the next anchor advance will catch
    /// any samples they would have pulled.
    @MainActor
    func mirrorHealthKitSamples() async {
        guard !isMirroring else { return }
        isMirroring = true
        defer { isMirroring = false }

        let context = ModelContext(modelContainer)
        let now = Date()

        // Stage proposed anchor advances per metric. We only commit these to
        // `defaults` after `context.save()` succeeds — otherwise a save failure
        // followed by an anchor write would permanently skip the failed window
        // because the next pass would query `(advancedAnchor, newNow)`.
        var pendingAnchors: [String: Date] = [:]

        for (identifier, unit) in SampleCaptureRegistry.quantityMetrics {
            await mirrorQuantityMetric(
                identifier: identifier,
                unit: unit,
                now: now,
                context: context,
                pendingAnchors: &pendingAnchors
            )
        }

        if SampleCaptureRegistry.captureSleep {
            await mirrorSleepStageEvents(
                now: now,
                context: context,
                pendingAnchors: &pendingAnchors
            )
        }

        do {
            try context.save()
        } catch {
            Log.data.error("mirrorHealthKitSamples save failed: \(error, privacy: .public)")
            // Do not advance anchors — next run will retry the same window.
            return
        }

        for (key, date) in pendingAnchors {
            saveAnchor(date, forKey: key)
        }
    }

    private func anchorKey(for identifier: HKQuantityTypeIdentifier) -> String {
        "sampleAnchor.\(identifier.rawValue)"
    }

    private static let sleepAnchorKey = "sampleAnchor.sleep"

    /// Read a previously-stored anchor or fall back to a bounded lookback so
    /// first-run mirroring doesn't pull years of data. Stored as
    /// `timeIntervalSince1970` so a missing key reads as `0`.
    private func loadAnchor(forKey key: String) -> Date {
        let stored = defaults.double(forKey: key)
        if stored > 0 {
            return Date(timeIntervalSince1970: stored)
        }
        let fallback = Calendar.current.date(
            byAdding: .day,
            value: -Self.initialMirrorLookbackDays,
            to: .now
        ) ?? Date(timeIntervalSinceNow: -Double(Self.initialMirrorLookbackDays) * 86400)
        return fallback
    }

    private func saveAnchor(_ date: Date, forKey key: String) {
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    private func mirrorQuantityMetric(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        now: Date,
        context: ModelContext,
        pendingAnchors: inout [String: Date]
    ) async {
        let key = anchorKey(for: identifier)
        let anchor = loadAnchor(forKey: key)
        // Avoid issuing inverted queries on clock-skew or test setups where
        // anchor briefly equals/exceeds `now`.
        guard anchor < now else {
            pendingAnchors[key] = now
            return
        }

        // Apply the rolling look-back so retroactive HealthKit corrections
        // within `mirrorLookbackInterval` are picked up. Clamp to epoch so we
        // never construct a negative-second Date on cold start when the anchor
        // is at the lookback fallback. The anchor still advances to `now` after
        // a successful save (see `pendingAnchors[key] = now` below), so we
        // don't re-fetch from origin every pass.
        let lookbackStart = anchor.addingTimeInterval(-SampleCaptureRegistry.mirrorLookbackInterval)
        let start = max(lookbackStart, Date(timeIntervalSince1970: 0))

        let samples: [SourcedQuantitySample]
        do {
            samples = try await healthKit.quantitySamplesWithSource(
                identifier, unit: unit, start: start, end: now
            )
        } catch {
            Log.data.error("Mirror failed for \(identifier.rawValue, privacy: .public): \(error, privacy: .public)")
            return
        }

        let unitString = unit.unitString

        // True upsert by HealthKit UUID: prefetch existing rows whose `id` is
        // in the incoming-UUID set (regardless of timestamp window) so we
        // catch retroactive HealthKit corrections — same UUID, different
        // timestamp/value/source. This mirrors the server's
        // ON CONFLICT (id) DO UPDATE semantics.
        //
        // Chunk the IN(...) lookup to stay under SQLite's default 999-parameter
        // limit. With CGM volumes (~288 samples/day × 7-day initial lookback ≈
        // 2016 samples) a single predicate would exceed the limit and the
        // mirror would fail repeatedly. See `SQLiteLimits.predicateBatchSize`.
        let incomingIDs: Set<UUID> = Set(samples.map(\.hkUUID))
        var existingByID: [UUID: QuantityHealthSample] = [:]
        if !incomingIDs.isEmpty {
            let existing: [QuantityHealthSample]
            // Use explicit do/catch (not `try?`) so a fetch failure is logged and
            // the anchor is NOT advanced — otherwise a swallowed error produces
            // an empty `existingByID` and the next insert path triggers a
            // unique-constraint save failure, with the anchor already past the
            // failed window.
            do {
                existing = try Self.fetchInChunks(
                    ids: incomingIDs,
                    in: context
                ) { batch in
                    FetchDescriptor<QuantityHealthSample>(
                        predicate: #Predicate { batch.contains($0.id) }
                    )
                }
            } catch {
                Log.data.error(
                    "Mirror prefetch failed for \(identifier.rawValue, privacy: .public): \(error, privacy: .public)"
                )
                // Bail without staging an anchor advance so the next pass retries the same window.
                return
            }
            for row in existing {
                existingByID[row.id] = row
            }
        }

        for sample in samples {
            // Future: link systolic/diastolic via HKCorrelationQuery so the
            // pair is stored as one row. The current protocol shape returns
            // each half independently with distinct `hkUUID`s, so we cannot
            // pair them here without additional information from HealthKit.
            if let existing = existingByID[sample.hkUUID] {
                // Update in place so retroactive HealthKit corrections
                // (same UUID, changed timestamp/value/source) are reflected
                // locally rather than silently dropped.
                //
                // Detect any field-level change before mutating so we only
                // flip `syncedToServer` back to `false` when the row's
                // server-mirror value actually drifts. Without this guard
                // the rolling-look-back overlap (which re-fetches the same
                // samples every pass) would mark every previously-synced
                // row dirty on every pass and cause a spurious re-upload
                // storm. Conversely, when a field DOES change, the row was
                // already uploaded with stale data and the server mirror
                // must be re-sent — otherwise the correction never reaches
                // the server.
                let changed = existing.timestamp != sample.timestamp
                    || existing.metricType != identifier.rawValue
                    || existing.value != sample.value
                    || existing.unitString != unitString
                    || existing.sourceBundleID != sample.sourceBundleID
                    || existing.sourceName != sample.sourceName
                    || existing.deviceModel != sample.deviceModel
                if changed {
                    existing.timestamp = sample.timestamp
                    existing.metricType = identifier.rawValue
                    existing.value = sample.value
                    existing.unitString = unitString
                    existing.sourceBundleID = sample.sourceBundleID
                    existing.sourceName = sample.sourceName
                    existing.deviceModel = sample.deviceModel
                    // Intentionally leave `existing.groupID` untouched on update.
                    // Incoming HKSamples currently always have groupID = nil (the
                    // protocol does not surface HKCorrelation linkage yet), so
                    // unconditionally writing nil here would wipe any
                    // previously-established correlation linkage. Once
                    // HKCorrelationQuery wiring lands, the producer can either
                    // call a separate update path that fills groupID or this
                    // code can be re-extended to set it explicitly.
                    existing.syncedToServer = false
                }
            } else {
                let row = QuantityHealthSample(
                    id: sample.hkUUID,
                    timestamp: sample.timestamp,
                    metricType: identifier.rawValue,
                    value: sample.value,
                    unitString: unitString,
                    sourceBundleID: sample.sourceBundleID,
                    sourceName: sample.sourceName,
                    deviceModel: sample.deviceModel,
                    groupID: nil
                )
                context.insert(row)
            }
        }

        pendingAnchors[key] = now
    }

    private func mirrorSleepStageEvents(
        now: Date,
        context: ModelContext,
        pendingAnchors: inout [String: Date]
    ) async {
        let key = Self.sleepAnchorKey
        let anchor = loadAnchor(forKey: key)
        guard anchor < now else {
            pendingAnchors[key] = now
            return
        }

        // Apply the rolling look-back so retroactive sleep edits within
        // `mirrorLookbackInterval` are picked up — Apple Watch can revise sleep
        // stages the morning after, and those updates would otherwise be
        // invisible once the anchor advanced past them. Clamp to epoch.
        let lookbackStart = anchor.addingTimeInterval(-SampleCaptureRegistry.mirrorLookbackInterval)
        let start = max(lookbackStart, Date(timeIntervalSince1970: 0))

        let events: [SourcedSleepStageEvent]
        do {
            events = try await healthKit.sleepStageEvents(start: start, end: now)
        } catch {
            Log.data.error("Mirror sleep events failed: \(error, privacy: .public)")
            return
        }

        // True upsert by HealthKit UUID: prefetch existing rows whose `id` is
        // in the incoming-UUID set (regardless of startTime window) so we
        // catch retroactive HealthKit corrections — same UUID, different
        // start/end/stage/source. This mirrors the server's
        // ON CONFLICT (id) DO UPDATE semantics.
        //
        // Chunk the IN(...) lookup to stay under SQLite's default 999-parameter
        // limit. See `SQLiteLimits.predicateBatchSize`.
        let incomingIDs: Set<UUID> = Set(events.map(\.hkUUID))
        var existingByID: [UUID: SleepStageEvent] = [:]
        if !incomingIDs.isEmpty {
            let existing: [SleepStageEvent]
            // Use explicit do/catch (not `try?`) so a fetch failure is logged and
            // the anchor is NOT advanced — otherwise a swallowed error produces
            // an empty `existingByID` and the next insert path triggers a
            // unique-constraint save failure, with the anchor already past the
            // failed window.
            do {
                existing = try Self.fetchInChunks(
                    ids: incomingIDs,
                    in: context
                ) { batch in
                    FetchDescriptor<SleepStageEvent>(
                        predicate: #Predicate { batch.contains($0.id) }
                    )
                }
            } catch {
                Log.data.error("Mirror sleep prefetch failed: \(error, privacy: .public)")
                // Bail without staging an anchor advance so the next pass retries the same window.
                return
            }
            for row in existing {
                existingByID[row.id] = row
            }
        }

        for event in events {
            if let existing = existingByID[event.hkUUID] {
                // Update in place for retroactive sleep-stage corrections.
                // Only flip `syncedToServer` back to `false` when at least
                // one mirrored field actually changes, so rolling-look-back
                // overlap (which re-fetches the same events every pass)
                // doesn't trigger a spurious re-upload storm. When a field
                // does change, the previously-uploaded row is now stale
                // and must be re-sent.
                let newStage = stageName(forRawValue: event.stage)
                let changed = existing.startTime != event.start
                    || existing.endTime != event.end
                    || existing.stage != newStage
                    || existing.sourceBundleID != event.sourceBundleID
                    || existing.sourceName != event.sourceName
                    || existing.deviceModel != event.deviceModel
                if changed {
                    existing.startTime = event.start
                    existing.endTime = event.end
                    existing.stage = newStage
                    existing.sourceBundleID = event.sourceBundleID
                    existing.sourceName = event.sourceName
                    existing.deviceModel = event.deviceModel
                    existing.syncedToServer = false
                }
            } else {
                let row = SleepStageEvent(
                    id: event.hkUUID,
                    startTime: event.start,
                    endTime: event.end,
                    stage: stageName(forRawValue: event.stage),
                    sourceBundleID: event.sourceBundleID,
                    sourceName: event.sourceName,
                    deviceModel: event.deviceModel
                )
                context.insert(row)
            }
        }

        pendingAnchors[key] = now
    }

    /// Map an `HKCategoryValueSleepAnalysis` raw value to the stable string
    /// names already used elsewhere in the app (matches `SleepData` field
    /// naming so server analysis can group consistently).
    private func stageName(forRawValue raw: Int) -> String {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: raw) else {
            return "unknown"
        }
        switch value {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake: return "awake"
        case .asleepCore: return "asleepCore"
        case .asleepDeep: return "asleepDeep"
        case .asleepREM: return "asleepREM"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Sample Cache

    /// Buffer for incoming samples — batched and saved periodically to avoid
    /// flooding the main actor with individual SwiftData saves.
    private var sampleBuffer: [(type: String, value: Double, timestamp: Date, source: String?)] = []
    private var flushTask: Task<Void, Never>?

    private let maxBufferSize = 500

    /// Queue samples for insertion. Saves are batched with a 2-second throttle
    /// so multiple anchored query callbacks don't each trigger a separate save
    /// (which would cause excessive @Query invalidation and body re-evaluations).
    /// Flushes immediately if the buffer exceeds `maxBufferSize`.
    private func bufferSamples(_ samples: [(type: String, value: Double, timestamp: Date, source: String?)]) {
        sampleBuffer.append(contentsOf: samples)

        if sampleBuffer.count >= maxBufferSize {
            flushTask?.cancel()
            flushTask = nil
            flushSampleBuffer()
            return
        }

        // Throttle: only schedule a flush if one isn't already pending.
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.flushSampleBuffer()
            self.flushTask = nil
        }
    }

    /// Write all buffered samples to SwiftData in one save.
    private func flushSampleBuffer() {
        guard !sampleBuffer.isEmpty else { return }
        let toInsert = sampleBuffer
        sampleBuffer.removeAll()

        let context = ModelContext(modelContainer)
        for sample in toInsert {
            context.insert(HealthSample(
                type: sample.type,
                value: sample.value,
                timestamp: sample.timestamp,
                source: sample.source
            ))
        }
        do {
            try context.save()
            Log.data.debug("Flushed \(toInsert.count, privacy: .public) health samples in one batch")
        } catch {
            Log.data.error("Failed to save \(toInsert.count, privacy: .public) health samples: \(error, privacy: .public)")
        }
    }

    /// Delete HealthSample rows older than 7 days using batch delete.
    func pruneOldSamples() {
        let context = ModelContext(modelContainer)
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)
            ?? Date(timeIntervalSinceNow: -7 * 86400)
        do {
            try context.delete(model: HealthSample.self, where: #Predicate {
                $0.timestamp < cutoff
            })
            try context.save()
        } catch {
            Log.data.error("Failed to prune old samples: \(error, privacy: .public)")
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
            do {
                try context.save()
            } catch {
                Log.data.error("Failed to save barometric reading: \(error, privacy: .public)")
            }
        }
        BarometerService.shared.startMonitoring()
    }
}
