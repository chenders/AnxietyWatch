import Foundation
import os
import SwiftData

/// Single source of truth for the `-autoRestoreFromServer` launch argument —
/// referenced by AnxietyWatchApp, SnapshotAggregator, and HRVSessionCardView
/// so the literal can't drift between call sites. The launch-argument flow
/// (and its date-shifted demo data) is simulator-debug-only; the type itself
/// compiles everywhere so gated call sites don't need their own literal.
enum RestoreDemoMode {
    static let launchArgument = "-autoRestoreFromServer"
    /// Evaluated once — launch arguments can't change mid-process.
    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)
}

/// Single source of truth for the `-seedDemoData` launch argument — seeds
/// synthetic, obviously-fictional data for README/marketing screenshots (see
/// `DemoSeeder`, DEBUG+simulator only). Kept alongside `RestoreDemoMode` so
/// `SnapshotAggregator`'s aggregation-skip guard can reference the literal
/// without a DEBUG-only symbol. Harmless in production (the arg is never set).
enum SeedDemoMode {
    static let launchArgument = "-seedDemoData"
    static let isActive = ProcessInfo.processInfo.arguments.contains(launchArgument)
}

/// First-launch migration gate: decides whether the app should defer
/// HealthKit setup (`HealthDataCoordinator.setupIfNeeded()`) and offer the
/// user a "Restore from Server vs Start Fresh" choice before any local
/// writes can trip the restore empty-store guard.
///
/// Why this exists: on a genuinely fresh install (the bundle-ID-rename
/// migration case), `setupIfNeeded()` would otherwise insert a HealthSnapshot
/// (backfill runs whenever `hasBackfilledSnapshots_v3` is unset) and start
/// barometer persistence (BarometricReading rows) within seconds of first
/// launch — long before a human can enter the server URL and tap Restore —
/// so `restoreGuardTablesAreEmpty` would ALWAYS refuse the restore this flow
/// exists to serve. The debug demo flow was protected by
/// `RestoreDemoMode.isActive` inside `aggregateDay` (DEBUG+simulator only);
/// this gate is that protection, productionized as an explicit decision.
enum RestoreMigrationGate {
    /// Set once the restore-vs-fresh decision is final: immediately on
    /// "Start Fresh", on the first successful `restoreFromServer()`, or
    /// automatically when the store is already non-empty at launch
    /// (existing users, who must never see the prompt or a deferred setup).
    static let decisionResolvedKey = "restoreDecisionResolved_v1"

    /// Pure decision core (extracted for testability): defer setup only
    /// while the decision is unresolved AND the store still looks fresh.
    static func shouldDeferSetup(storeIsEmpty: Bool, decisionResolved: Bool) -> Bool {
        !decisionResolved && storeIsEmpty
    }

    /// Launch-time evaluation. Returns true when the app should defer
    /// `setupIfNeeded()` and present the decision UI. A non-fresh store
    /// resolves the flag permanently as a side effect, so existing installs
    /// (including upgrades that predate the gate) never defer and never
    /// prompt. Reads the SwiftData store but never writes to it — the
    /// deferral check must not itself trip the guard it protects.
    @MainActor
    static func evaluateAtLaunch(context: ModelContext, defaults: UserDefaults = .standard) -> Bool {
#if targetEnvironment(simulator)
        // Automated simulator demos have no real server to restore from. Keep
        // the production decision path testable for ordinary simulator runs.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-seedDemoData") || arguments.contains("-screenshotOuraData") || arguments.contains("-screenshotTab") {
            if !defaults.bool(forKey: decisionResolvedKey) {
                defaults.set(true, forKey: decisionResolvedKey)
            }
            return false
        }
#endif
        let resolved = defaults.bool(forKey: decisionResolvedKey)
        let storeIsEmpty = SyncService.restoreGuardTablesAreEmpty(context)
        guard shouldDeferSetup(storeIsEmpty: storeIsEmpty, decisionResolved: resolved) else {
            if !resolved {
                defaults.set(true, forKey: decisionResolvedKey)
            }
            return false
        }
        return true
    }

    static func resolve(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: decisionResolvedKey)
    }

    static func isResolved(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: decisionResolvedKey)
    }
}

extension Notification.Name {
    /// Posted after `restoreFromServer()` fully succeeds (rows saved, sync
    /// cursor advanced, migration gate resolved). `AnxietyWatchApp` listens
    /// so it can kick off the launch setup the `RestoreMigrationGate`
    /// deferred — restore first, backfill layered on top.
    static let serverRestoreCompleted = Notification.Name("serverRestoreCompleted")
}

/// How a server download should meet the local store.
///
/// Both modes run the same importers, and every importer is **skip-if-present**,
/// keyed on the same natural key the server uses as its PRIMARY KEY. The modes
/// differ only in their preconditions and their side effects on the sync cursor.
///
/// "Skip-if-present" is doing real work here and is NOT a synonym for "has a
/// unique constraint". SwiftData resolves a `#Unique` / `@Attribute(.unique)`
/// collision by **replacing the whole object**, not by skipping the insert — so a
/// re-import of a row the store already has would silently overwrite the local
/// copy with the server's. That is invisible on the restore path (empty store, no
/// collisions) but is data loss on a reconcile: `HealthSnapshot.syncedToServer` is
/// a dirty flag the aggregator clears on a corrected past day, and `CPAPSession`
/// rows are updated in place by `CPAPImporter` — a blind replace would revert both
/// to the server's older copy and mark them clean. Every importer therefore carries
/// an explicit existence check; the unique constraints are a backstop, not the
/// mechanism.
enum RestoreMode: Sendable {
    /// Fresh-install path. Requires an empty store, advances the sync cursor to
    /// the pre-download bound, and resolves the restore-vs-fresh migration gate.
    case restore

    /// Heal path: pull down anything the device is missing, leave everything else
    /// alone. Runs against a POPULATED store, so it does **not** take the
    /// empty-store guard, and — critically — does **not** advance the sync cursor
    /// (see the finalize block in `restoreFromServer`: a reconcile's store may
    /// hold rows the server has never seen, and advancing the cursor past them
    /// would strand them on-device forever).
    ///
    /// Exists because sync is upload-only and restore is all-or-nothing into a
    /// blank slate; before this there was no way to repair a store that was merely
    /// *incomplete* — the only recourse was to wipe the device and restore from
    /// scratch.
    case reconcile
}

enum RestoreError: Error, LocalizedError {
    case invalidJSON
    /// A sync (or another restore/reconcile) is already running.
    ///
    /// Restore and reconcile now take the same `isSyncing` mutex `sync()` does.
    /// Gating the Settings buttons is not sufficient: auto-sync fires from
    /// `AnxietyWatchApp` at launch and from the background-refresh handler, neither
    /// of which consults the UI. Both operations mutate the same `ModelContext`
    /// across `await` suspension points (network round trips), and reconcile is
    /// *designed* to run against a populated, actively-syncing store — so the
    /// interleaving is realistic rather than theoretical. The mutex has to live on
    /// the service, not the screen.
    case syncInProgress
    /// Carries the specific blockers (`"AnxietyEntry=3"`, or
    /// `"HRVReading=<fetch failed: …>"`). Without them this error is
    /// undiagnosable: the guard fails closed, so a *failed fetch* is
    /// indistinguishable from actual rows, and the user just sees "already
    /// contains data" on a demonstrably empty store with no way to tell which.
    case storeNotEmpty([String])

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Server response was not valid JSON"
        case .syncInProgress:
            return "A sync is already running — wait for it to finish and try again."
        case .storeNotEmpty(let blockers):
            return "Local store already contains data — restore only runs into an empty "
                + "store so it can't duplicate rows. On a fresh install, restore before "
                + "logging or importing anything.\nBlocked by: "
                + (blockers.isEmpty ? "<unknown>" : blockers.joined(separator: ", "))
        }
    }
}

extension SyncService {
    /// Pulls the server's full dataset (`GET /api/data`) and rebuilds the
    /// local SwiftData store from it. This is the production data-migration
    /// path for a fresh install (e.g. after a bundle-ID change wipes the
    /// container): the empty-store guard plus the #Unique-id merge semantics
    /// of the raw-sensor importers make the operation idempotent.
    ///
    /// - Parameter demoDateShift: Simulator-debug-only. When true (and the
    ///   build is DEBUG + simulator), all restored timestamps are shifted
    ///   forward so the most recent row aligns with today — purely a demo
    ///   convenience so a fresh simulator looks "current". Real migrations
    ///   MUST keep truthful timestamps: shifting medical data would corrupt
    ///   every day-keyed aggregate, baseline, and correlation downstream, and
    ///   a later second restore would re-shift rows by a different offset.
    ///   Release/device builds always restore with shift = 0 regardless of
    ///   this flag.
    /// - Parameter now: clock for the post-restore sync-cursor upper bound.
    ///   Injectable so tests can assert the cursor lands on the captured
    ///   bound. Defaults to `Date.now`.
    /// - Parameter performRequest: network transport for the /api/data GET.
    ///   Injectable so tests can run the full restore orchestration without
    ///   a live URLSession (mirrors `sync()`). Defaults to
    ///   `URLSession.shared.data(for:)`.
    /// - Parameter defaults: UserDefaults for the `RestoreMigrationGate`
    ///   resolution on success. Injectable for test isolation.
    @MainActor
    func restoreFromServer(
        modelContext: ModelContext,
        mode: RestoreMode = .restore,
        demoDateShift: Bool = false,
        now: @MainActor () -> Date = { Date.now },
        performRequest: (@MainActor (URLRequest) async throws -> (Data, URLResponse))? = nil,
        defaults: UserDefaults = .standard
    ) async throws -> String {
        guard isConfigured else { throw SyncError.notConfigured }

        // Take the same mutex `sync()` uses. Gating the Settings buttons isn't
        // enough — auto-sync fires from AnxietyWatchApp at launch and from the
        // background-refresh handler, neither of which consults the UI — and both
        // paths mutate this same ModelContext across `await` suspension points.
        guard !isSyncing else { throw RestoreError.syncInProgress }
        isSyncing = true
        defer { isSyncing = false }

        // The empty-store guard is a RESTORE precondition only — a reconcile is
        // defined as running against a populated store.
        if mode == .restore {
            let blockers = Self.restoreGuardBlockers(modelContext)
            guard blockers.isEmpty else {
                // Log the TABLE NAMES public, the counts not at all. A blocker
                // string is "HealthSnapshot=91": the table name is a schema
                // constant (no health data), but the count is a fact about the
                // user's records, and `.public` os_log values land in Console and
                // sysdiagnose bundles that get shared off-device. Marking the whole
                // string `.private` would render it `<private>` and destroy the
                // diagnostic — knowing WHICH table blocked is the entire reason
                // this line exists (its absence once cost an hour of guessing). The
                // names carry that; the user still sees full counts in the
                // on-device error text.
                let blockedTables = Self.logSafeBlockers(blockers).joined(separator: ", ")
                Log.sync.error("[restore] blocked by: \(blockedTables, privacy: .public)")
                throw RestoreError.storeNotEmpty(blockers)
            }
        }
        guard var components = URLComponents(string: serverURL) else { throw SyncError.invalidURL }
        components.path = "/api/data"
        guard let url = components.url else { throw SyncError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180

        // Pin the sync cursor's upper bound BEFORE the download starts, per
        // the documented incremental-sync cursor rule (see CLAUDE.md and
        // `sync()`'s cursorUpperBound): records the user creates DURING the
        // round trip get timestamps greater than this bound, so the next
        // incremental sync still picks them up. Setting `.now` after the
        // trip would skip them forever. The cursor is assigned only after
        // the restore fully succeeds (see below).
        let restoreCursorUpperBound = now()

        let (data, response): (Data, URLResponse)
        if let performRequest {
            (data, response) = try await performRequest(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError.noConnection }
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.serverError(http.statusCode, String(data: data, encoding: .utf8))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RestoreError.invalidJSON
        }

        // Demo-only date shift: align the most-recent row with today so a
        // fresh sim looks "current" instead of every Dashboard card reading
        // "13 nights ago". Known tradeoff: the shift is a fixed
        // absolute-seconds offset, so rows on the far side of a DST
        // transition land ±1h off wall-clock — acceptable for demo data,
        // NEVER acceptable for a real migration. Production restores are
        // hard-wired to shift = 0 (truthful timestamps), which also keeps
        // restore idempotent — a blocked-then-retried restore on a later
        // day must not re-shift rows by a different offset.
        // `demoShiftActive` is a compile-time `false` on device/release builds, so
        // spelling the demo branches as `demoShiftActive ? compute(...) : 0` makes
        // the true-branch provably dead there and emits "will never be executed"
        // — which CI (SWIFT_TREAT_WARNINGS_AS_ERRORS) would fail on if it ever
        // built for a non-simulator destination. Compute the demo shifts inside
        // the #if instead: production keeps truthful timestamps (shift 0) and the
        // demo-only code isn't compiled at all rather than compiled-and-unreachable.
        #if DEBUG && targetEnvironment(simulator)
        let shift: TimeInterval = demoDateShift ? Self.computeDateShift(json: json) : 0
        #else
        let shift: TimeInterval = 0
        #endif

        var report: [String: Int] = ["shiftDays": Int(shift / 86_400)]

        if let rows = json["medicationDefinitions"] as? [[String: Any]] {
            report["medicationDefinitions"] = try Self.importMedDefinitions(rows, into: modelContext)
        }
        if let rows = json["medicationDoses"] as? [[String: Any]] {
            report["medicationDoses"] = try Self.importMedDoses(rows, shift: shift, into: modelContext)
        }
        if let rows = json["anxietyEntries"] as? [[String: Any]] {
            report["anxietyEntries"] = try Self.importAnxietyEntries(rows, shift: shift, into: modelContext)
        }
        if let rows = json["healthSnapshots"] as? [[String: Any]] {
            report["healthSnapshots"] = try Self.importHealthSnapshots(rows, shift: shift, into: modelContext)
        }
        if let rows = json["cpapSessions"] as? [[String: Any]] {
            report["cpapSessions"] = try Self.importCPAPSessions(rows, shift: shift, into: modelContext)
        }
        if let rows = json["barometricReadings"] as? [[String: Any]] {
            report["barometricReadings"] = try Self.importBarometricReadings(rows, shift: shift, into: modelContext)
        }
        if let rows = json["pharmacies"] as? [[String: Any]] {
            report["pharmacies"] = try Self.importPharmacies(rows, into: modelContext)
        }
        if let rows = json["prescriptions"] as? [[String: Any]] {
            // Insert-only: filter to genuinely-new rx numbers first so a
            // reconcile can never overwrite a locally-edited prescription
            // with the server's older copy.
            let newRows = try Self.prescriptionRowsNotAlreadyPresent(rows, in: modelContext)
            // NOT `try?`. Swallowing the error would report `prescriptions: 0` and let
            // the reconcile finish "successfully" having imported none of them —
            // indistinguishable, in the report the user actually reads, from "nothing
            // was missing". Every other importer here fails closed; this one too.
            report["prescriptions"] = try Self.importPrescriptions(newRows, into: modelContext)
        }
        // After pharmacies so the `pharmacy` relationship can re-link by name.
        if let rows = json["pharmacyCallLogs"] as? [[String: Any]] {
            report["pharmacyCallLogs"] = try Self.importPharmacyCallLogs(rows, shift: shift, into: modelContext)
        }

        var sessionIdMap: [String: UUID] = [:]
        if let rows = json["sensorSessions"] as? [[String: Any]] {
            let (n, map) = try Self.importSensorSessions(rows, shift: shift, into: modelContext)
            report["sensorSessions"] = n
            sessionIdMap = map
        }
        if let rows = json["hrvReadings"] as? [[String: Any]] {
            report["hrvReadings"] = try Self.importHRVReadings(rows, shift: shift, sessionMap: sessionIdMap, into: modelContext)
        }
        if let rows = json["accelSpectrograms"] as? [[String: Any]] {
            report["accelSpectrograms"] = try Self.importAccelSpectrograms(
                rows, shift: shift, sessionMap: sessionIdMap, into: modelContext
            )
        }
        if let rows = json["derivedBreathingRates"] as? [[String: Any]] {
            report["derivedBreathingRates"] = try Self.importDerivedBreathingRates(
                rows, shift: shift, sessionMap: sessionIdMap, into: modelContext
            )
        }
        var songServerIDMap: [Int: Song] = [:]
        if let rows = json["songs"] as? [[String: Any]] {
            let (n, map) = try Self.importSongs(rows, into: modelContext)
            report["songs"] = n
            songServerIDMap = map
        }
        if let rows = json["songOccurrences"] as? [[String: Any]] {
            report["songOccurrences"] = try Self.importSongOccurrences(rows, shift: shift, songMap: songServerIDMap, into: modelContext)
        }
        if let rows = json["sleepStageEvents"] as? [[String: Any]] {
            // Demo mode only: sleep events lag snapshots in prod (auto-sync
            // vs. manual import), so use a per-entity shift to land the most
            // recent sleep night on today — otherwise the LastNight card
            // can't find events for the latest snapshot. Production restores
            // keep truthful timestamps (shift 0), like every other entity.
            #if DEBUG && targetEnvironment(simulator)
            let sleepShift: TimeInterval = demoDateShift
                ? Self.computeMaxAlignedShift(rows: rows, dateKey: "start_time")
                : 0
            #else
            let sleepShift: TimeInterval = 0
            #endif
            report["sleepStageEvents"] = try Self.importSleepStageEvents(rows, shift: sleepShift, into: modelContext)
        }

        try modelContext.save()

        // QuantityHealthSample is deliberately NOT in the bulk /api/data
        // payload — it is ~250k rows / ~79 MB of JSON, which would blow up
        // both the response and the parsed [[String: Any]] held in memory.
        // It is paged down separately instead.
        //
        // This table used to sync UP but had no way back DOWN, so a fresh
        // install silently lost every EMAY oximetry sample. Those are app-only
        // (the app never writes to HealthKit), so unlike Apple/Polar/Dexcom
        // rows, nothing else can re-derive them — they were simply gone.
        report["quantityHealthSamples"] = try await Self.restorePagedQuantitySamples(
            serverURL: serverURL,
            apiKey: apiKey,
            shift: shift,
            modelContext: modelContext,
            performRequest: performRequest
        )

        // Post-restore re-aggregation: restored AccelSpectrogram /
        // DerivedBreathingRate rows never feed HealthSnapshot's
        // sensor-derived aggregates on their own — SnapshotAggregator runs
        // for today (and backfill gap-fill is capped and may run before the
        // restore), so historical days would show restored raw rows but nil
        // tremor/breathing/fidget averages forever. Re-run just the
        // sensor-derived block per affected day. Deliberately NOT a full
        // aggregateDay: HealthKit is typically empty right after a fresh
        // install, and a full re-aggregation would blank restored
        // HealthKit-derived fields with nils.
        report["sensorAggregatedDays"] = try Self.reaggregateSensorDerivedSnapshots(in: modelContext)
        try modelContext.save()

        // Everything imported and saved — finalize.
        //
        // RESTORE ONLY. A reconcile must do NONE of this:
        //
        // 1. Advancing the sync cursor is correct after a restore (the store now
        //    mirrors the server, so nothing is pending upload) but is a DATA-LOSS
        //    BUG after a reconcile. A reconcile runs against a POPULATED store
        //    that may hold rows the server has never seen — the whole point of
        //    sync. Advancing `lastSyncDate` past them means the next incremental
        //    sync's `since` filter skips them forever: they exist only on a device
        //    that now believes they're backed up. This is the cursor race
        //    documented in CLAUDE.md, in its most destructive form. Reconcile
        //    pulls DOWN; it must not touch the UP cursor.
        //
        // 2. Resolving the migration gate / posting `.serverRestoreCompleted` is
        //    meaningless for a reconcile: a populated store already auto-resolved
        //    the gate at launch, and re-posting would re-trigger the deferred
        //    HealthKit setup that has long since run.
        if mode == .restore {
            lastSyncDate = restoreCursorUpperBound
            RestoreMigrationGate.resolve(defaults: defaults)
            NotificationCenter.default.post(name: .serverRestoreCompleted, object: nil)
        }

        return report
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }

    /// Pull down every row the server has that this device is missing, leaving
    /// existing rows **untouched** — not merged, not overwritten, skipped. Safe to
    /// run repeatedly and safe to interrupt: every importer checks for the row's
    /// natural key before inserting, so a re-run adds nothing and a second run
    /// reports zeros.
    ///
    /// The local copy always wins on conflict. That's deliberate: a row that
    /// differs from the server's is far more likely to be a local correction
    /// pending upload (a re-aggregated `HealthSnapshot`, a re-imported
    /// `CPAPSession`) than it is to be stale, and clobbering it would destroy the
    /// only copy. Reconcile fills holes; it does not arbitrate.
    ///
    /// This is the "heal" complement to the other two paths: `sync()` only pushes
    /// UP, and `restoreFromServer()` only pulls DOWN into a blank store. Neither
    /// could repair a store that was merely *incomplete*.
    ///
    /// It does NOT delete local rows the server lacks — this is a one-way merge,
    /// not a mirror. A row the server has never seen is far more likely to be
    /// pending upload than to be garbage, and deleting it would be unrecoverable.
    @MainActor
    @discardableResult
    func reconcileFromServer(
        modelContext: ModelContext,
        performRequest: (@MainActor (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> String {
        try await restoreFromServer(
            modelContext: modelContext,
            mode: .reconcile,
            performRequest: performRequest
        )
    }

    // MARK: - Empty-store guard

    /// One-shot guard: several importers (entries, doses, snapshots, CPAP,
    /// sensor sessions, songs) do not dedupe, so a restore into a non-empty
    /// store would silently duplicate rows. The proxy set must cover EVERY
    /// major table the restore writes — a store holding ONLY raw sensor rows
    /// (e.g. from a prior partial restore) is NOT empty, which is also what
    /// makes a second restore a hard no-op instead of a duplicate-and-reshift
    /// hazard. Name-deduped tables (medication definitions, pharmacies,
    /// prescriptions) are deliberately excluded: a fresh install may hold
    /// user-entered rows there, and their importers merge safely.
    /// PharmacyCallLog IS counted even though its importer dedupes: a call
    /// log implies real prior use of the device, exactly the "not actually
    /// fresh" signal this guard exists to detect (same reasoning as
    /// BarometricReading, whose importer also dedupes).
    /// `internal` so RestoreFromServerTests can exercise the guard directly.
    static func restoreGuardTablesAreEmpty(_ ctx: ModelContext) -> Bool {
        restoreGuardBlockers(ctx).isEmpty
    }

    /// The specific reasons a restore is blocked — each either `"Type=<count>"`
    /// (real rows) or `"Type=<fetch failed: …>"` (unreadable).
    ///
    /// A fetch error counts as blocking (fail closed): proceeding on an
    /// unreadable store risks the duplication this guard exists to stop. But
    /// failing closed *silently* made this guard undiagnosable — a thrown fetch
    /// was coerced to `Int.max` and surfaced as "store already contains data" on
    /// a store that was demonstrably empty, with no way to tell which of the 14
    /// types was at fault or whether it even had rows. Naming the blocker is the
    /// difference between a five-minute fix and an hour of guessing.
    /// The set of ids a table already holds, for skip-if-present importing.
    ///
    /// Every importer needs this because a `#Unique` / `@Attribute(.unique)`
    /// constraint does **not** make an insert idempotent — SwiftData resolves a
    /// unique-key collision by REPLACING the whole object. On the restore path
    /// (empty store) that never fires and the distinction is invisible; on a
    /// reconcile it means a blind re-insert would (a) clobber locally-modified rows
    /// and (b) report every row on the server as "added" while doing a full
    /// rewrite of the table. Skipping known ids is what makes the reported counts
    /// mean "rows added" and keeps a repair on a healthy store nearly free.
    ///
    /// **Throws rather than returning an empty set on a failed fetch.** This is the
    /// whole point: `try? … ?? []` would report "no existing rows" for an unreadable
    /// table, which silently DISABLES the skip check and re-enables the very
    /// replace-clobber it exists to prevent — a guard that fails open is worse than
    /// no guard, because it looks like protection. Failing closed aborts the whole
    /// reconcile before a single row is touched. (Same principle as
    /// `restoreGuardBlockers`: a guard that can't evaluate must not assume it's
    /// safe to proceed.)
    ///
    /// `propertiesToFetch` so SwiftData hydrates only the id column rather than the
    /// whole row. Without it a reconcile would fault in every field of ~250k
    /// `QuantityHealthSample`s (and the spectrogram payloads) purely to read their
    /// UUIDs — a memory spike on exactly the table where this runs hottest. Same
    /// pattern as `ClinicalRecordImporter`.
    static func existingIDs<T: PersistentModel>(
        _ type: T.Type, _ id: KeyPath<T, UUID>, in ctx: ModelContext
    ) throws -> Set<UUID> {
        var descriptor = FetchDescriptor<T>()
        descriptor.propertiesToFetch = [id]
        return Set(try ctx.fetch(descriptor).map { $0[keyPath: id] })
    }

    /// Fail-closed sibling of `existingIDs` for importers keyed on something other
    /// than a `UUID` id (a timestamp, a start-of-day, a composite). Same rule: a
    /// fetch that throws must abort the import, never degrade to "nothing exists".
    static func existingKeys<T: PersistentModel, K: Hashable>(
        _ type: T.Type, in ctx: ModelContext, key: (T) -> K
    ) throws -> Set<K> {
        Set(try ctx.fetch(FetchDescriptor<T>()).map(key))
    }

    /// Drop prescription rows whose `rx_number` the store already has.
    ///
    /// `importPrescriptions` is insert-only — it has no update branch — and
    /// `Prescription` carries no `#Unique` constraint on `rxNumber`, so calling it
    /// unfiltered against every server row would insert a fresh duplicate for every
    /// prescription the device already has, on every single reconcile. Filtering to
    /// genuinely-new rx numbers first is what makes prescriptions skip-if-present,
    /// like every other importer here. `internal` for ReconcileFromServerTests.
    static func prescriptionRowsNotAlreadyPresent(
        _ rows: [[String: Any]], in ctx: ModelContext
    ) throws -> [[String: Any]] {
        let existing = try existingKeys(Prescription.self, in: ctx) { $0.rxNumber }
        return rows.filter { row in
            guard let rx = row["rx_number"] as? String, !rx.isEmpty else { return false }
            return !existing.contains(rx)
        }
    }

    /// Strip the row counts from `restoreGuardBlockers` output, leaving only the
    /// table names — the projection that is safe to emit to `os_log` at
    /// `privacy: .public`.
    ///
    /// `"HealthSnapshot=91"` → `"HealthSnapshot"`. The table name is a schema
    /// constant and carries no health data; the count is a fact about the user's
    /// records, and `.public` os_log values are captured into Console and
    /// sysdiagnose bundles that routinely get shared off-device. Marking the whole
    /// string `.private` instead would render it `<private>` and destroy the
    /// diagnostic — knowing WHICH table blocked is the entire reason the log line
    /// exists. The user still sees the full counts in the on-device error text
    /// (`RestoreError.storeNotEmpty`), which never leaves the device.
    ///
    /// Also strips a `<fetch failed: …>` payload, whose message could in principle
    /// quote row contents.
    static func logSafeBlockers(_ blockers: [String]) -> [String] {
        blockers.map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0 }
    }

    static func restoreGuardBlockers(_ ctx: ModelContext) -> [String] {
        var blockers: [String] = []

        func check<T: PersistentModel>(_ type: T.Type, _ name: String) {
            do {
                let count = try ctx.fetchCount(FetchDescriptor<T>())
                if count > 0 { blockers.append("\(name)=\(count)") }
            } catch {
                blockers.append("\(name)=<fetch failed: \(error.localizedDescription)>")
            }
        }

        check(AnxietyEntry.self, "AnxietyEntry")
        check(HealthSnapshot.self, "HealthSnapshot")
        check(SensorSession.self, "SensorSession")
        check(HRVReading.self, "HRVReading")
        check(BarometricReading.self, "BarometricReading")
        check(AccelSpectrogram.self, "AccelSpectrogram")
        check(DerivedBreathingRate.self, "DerivedBreathingRate")
        check(MedicationDose.self, "MedicationDose")
        check(CPAPSession.self, "CPAPSession")
        check(SleepStageEvent.self, "SleepStageEvent")
        check(Song.self, "Song")
        check(SongOccurrence.self, "SongOccurrence")
        check(PharmacyCallLog.self, "PharmacyCallLog")
        // The restore writes QuantityHealthSample too, so it belongs in the proxy
        // set. It is also the table a partially-completed restore is most likely
        // to leave behind on its own: it is paged, so an interrupted restore can
        // save several pages of samples and nothing else. Without this, that
        // half-restored store would still look "empty" and a retry would re-page
        // a quarter-million rows on top of the ones already there.
        check(QuantityHealthSample.self, "QuantityHealthSample")

        return blockers
    }

    // MARK: - Post-restore re-aggregation

    /// Recompute `HealthSnapshot`'s sensor-derived aggregates
    /// (tremorBandPowerAvg / fidgetIndexAvg / breathingRateAvg) for every
    /// calendar day that holds AccelSpectrogram or DerivedBreathingRate rows,
    /// creating the day's snapshot when none exists. Runs after a restore,
    /// where the guard guarantees every such row was just imported. Touches
    /// ONLY the three sensor-derived fields (via
    /// `SnapshotAggregator.applySensorDerivedMetrics`) — restored
    /// HealthKit-derived fields are left exactly as the server sent them.
    /// Deliberately does NOT flip `syncedToServer` on the snapshots it
    /// touches: the three sensor-derived averages have no columns in the
    /// server schema (see `health_snapshots` in server/schema.sql) and are
    /// never synced, so recomputing them cannot make a snapshot dirty —
    /// marking it dirty would only cause a pointless full-row re-upload.
    /// Returns the number of days recomputed. `internal` for test access.
    @MainActor
    static func reaggregateSensorDerivedSnapshots(in ctx: ModelContext) throws -> Int {
        let calendar = Calendar.current
        var days = Set<Date>()
        for spectrogram in try ctx.fetch(FetchDescriptor<AccelSpectrogram>()) {
            days.insert(calendar.startOfDay(for: spectrogram.timestamp))
        }
        for rate in try ctx.fetch(FetchDescriptor<DerivedBreathingRate>()) {
            days.insert(calendar.startOfDay(for: rate.timestamp))
        }
        // Set iteration order is arbitrary — sort for deterministic writes.
        for day in days.sorted() {
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let existing = try ctx.fetch(
                FetchDescriptor<HealthSnapshot>(predicate: #Predicate { $0.date == day })
            )
            // Synthesizing a snapshot for a day the restore didn't bring one
            // is safe only because GET /api/data is UNPAGINATED: the response
            // carries the server's complete health_snapshots set, so a day
            // missing locally right after import is guaranteed missing
            // server-side too. If the endpoint ever paginates or windows its
            // export, this must re-check the server before creating rows —
            // otherwise a synthesized sensor-only snapshot would shadow the
            // server's real one (unique-date constraint) on a later restore.
            let snapshot = existing.first ?? HealthSnapshot(date: day)
            if existing.isEmpty {
                ctx.insert(snapshot)
            }
            try SnapshotAggregator.applySensorDerivedMetrics(
                to: snapshot, dayStart: day, dayEnd: end, context: ctx
            )
        }
        return days.count
    }

    // MARK: - Per-entity importers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        if let d = iso.date(from: s) { return d }
        let fallback = ISO8601DateFormatter()
        if let d = fallback.date(from: s) { return d }
        // Bare dates ("2026-05-11") come from Postgres DATE columns
        // (health_snapshots.date, cpap_sessions.date) and represent LOCAL
        // calendar days. Parse directly through Calendar so DST transitions
        // can't shift the result: a DateFormatter with .current timezone
        // interprets "2026-03-08" as midnight in the current zone, which on
        // a DST-spring-forward day maps to the previous UTC midnight (23:00
        // UTC) — and Calendar.current.startOfDay then normalizes it to "March
        // 7", one full day off. Calendar.date(from: DateComponents) computes
        // the start of the correct local day without the timezone indirection.
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        // Use an explicit Gregorian calendar (the server DATE strings are
        // Gregorian) in the local time zone: `Calendar.current` could be a
        // non-Gregorian user calendar (Buddhist, Japanese, …), which would
        // mis-map these year/month/day components to a different absolute day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    /// Name-keyed. See `importPharmacies` for why this is a seen-set rather than a
    /// per-row predicate fetch (fail-open + O(rows) queries + no within-payload dedupe).
    ///
    /// `cns_depressant_class` (server migration 0013): the user's explicit
    /// classification override — the source of truth that arms §14.1
    /// dose-window monitoring — restored so a device migration can't
    /// silently re-default an explicit opioidER (24 h) to a name-guessed
    /// opioidIR (8 h) or nil (the under-monitoring failure direction). The
    /// seen-set skip above also guarantees a restore NEVER nulls out an
    /// explicit LOCAL value with a server nil: a definition already present
    /// by name is never touched at all.
    ///
    /// `internal` (not `private`), matching `importMedDoses` et al., so the
    /// restore tests can drive it directly with server-shaped rows.
    static func importMedDefinitions(_ rows: [[String: Any]], into ctx: ModelContext) throws -> Int {
        var seen = try Self.existingKeys(MedicationDefinition.self, in: ctx) { $0.name }
        var n = 0
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            let def = MedicationDefinition(
                name: name,
                defaultDoseMg: (row["default_dose_mg"] as? Double) ?? 0,
                category: (row["category"] as? String) ?? "",
                isActive: (row["is_active"] as? Bool) ?? true,
                cnsDepressantClass: row["cns_depressant_class"] as? String
            )
            ctx.insert(def)
            n += 1
        }
        return n
    }

    /// Per-entity helper: shifts the entity's most recent row to today.
    private static func computeMaxAlignedShift(rows: [[String: Any]], dateKey: String) -> TimeInterval {
        var maxDate: Date?
        for row in rows {
            if let d = parseDate(row[dateKey]) {
                if maxDate == nil || d > maxDate! { maxDate = d }
            }
        }
        guard let maxDate else { return 0 }
        let today = Calendar.current.startOfDay(for: .now)
        let anchor = Calendar.current.startOfDay(for: maxDate)
        return today.timeIntervalSince(anchor)
    }

    private static func computeDateShift(json: [String: Any]) -> TimeInterval {
        var maxDate: Date?
        let candidateKeys: [(String, String)] = [
            ("anxietyEntries", "timestamp"),
            ("medicationDoses", "timestamp"),
            ("healthSnapshots", "date"),
            ("cpapSessions", "date")
        ]
        for (entity, field) in candidateKeys {
            guard let rows = json[entity] as? [[String: Any]] else { continue }
            for row in rows {
                if let d = parseDate(row[field]) {
                    if maxDate == nil || d > maxDate! { maxDate = d }
                }
            }
        }
        guard let maxDate else { return 0 }
        let today = Calendar.current.startOfDay(for: .now)
        let anchor = Calendar.current.startOfDay(for: maxDate)
        return today.timeIntervalSince(anchor)
    }

    /// Deduped by `(timestamp, medicationName)` — the server's own composite
    /// PRIMARY KEY for `medication_doses`. See `importAnxietyEntries` for why
    /// the server's key, and not a UUID, is the right identity here.
    /// `internal` (not private) for ReconcileFromServerTests.
    static func importMedDoses(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) throws -> Int {
        var n = 0
        let allDefs = (try? ctx.fetch(FetchDescriptor<MedicationDefinition>())) ?? []
        let defsByName = Dictionary(uniqueKeysWithValues: allDefs.map { ($0.name, $0) })

        struct DoseKey: Hashable { let timestamp: Date; let name: String }
        var seen = try Self.existingKeys(MedicationDose.self, in: ctx) {
            DoseKey(timestamp: $0.timestamp, name: $0.medicationName)
        }

        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let name = row["medication_name"] as? String,
                  let mg = row["dose_mg"] as? Double else { continue }
            let shifted = ts.addingTimeInterval(shift)
            guard seen.insert(DoseKey(timestamp: shifted, name: name)).inserted else { continue }
            let dose = MedicationDose(
                timestamp: shifted,
                medicationName: name,
                doseMg: mg,
                notes: row["notes"] as? String,
                isPRN: true,
                medication: defsByName[name]
            )
            ctx.insert(dose)
            n += 1
        }
        return n
    }

    /// Deduped by `timestamp` — the server's own PRIMARY KEY for
    /// `anxiety_entries`. `AnxietyEntry` carries no unique constraint, so a
    /// blind `insert` would duplicate every row on a re-import; keying on what
    /// the server upserts on gives both directions identical identity semantics.
    /// `internal` (not private) for ReconcileFromServerTests.
    static func importAnxietyEntries(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) throws -> Int {
        var seen = try Self.existingKeys(AnxietyEntry.self, in: ctx) { $0.timestamp }
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let severity = row["severity"] as? Int else { continue }
            let shifted = ts.addingTimeInterval(shift)
            guard seen.insert(shifted).inserted else { continue }
            let tags = (row["tags"] as? [String]) ?? []
            let entry = AnxietyEntry(
                timestamp: shifted,
                severity: severity,
                notes: (row["notes"] as? String) ?? "",
                tags: tags
            )
            ctx.insert(entry)
            n += 1
        }
        return n
    }

    /// Per-field medians across non-null values. Used to fill any null
    /// fields on individual snapshots so the demo Dashboard / Trends views
    /// don't show "—" for the most recent day when real recording was sparse.
    private static func computeMedians(rows: [[String: Any]]) -> [String: Double] {
        let fields = [
            "hrv_avg", "hrv_min", "resting_hr", "sleep_duration_min",
            "sleep_deep_min", "sleep_rem_min", "sleep_core_min", "sleep_awake_min",
            "skin_temp_deviation", "respiratory_rate", "spo2_avg",
            "spo2_nadir_overnight", "steps", "active_calories",
            "exercise_minutes", "environmental_sound_avg"
        ]
        var medians: [String: Double] = [:]
        for field in fields {
            var values: [Double] = []
            for row in rows {
                if let d = row[field] as? Double { values.append(d) }
                else if let i = row[field] as? Int { values.append(Double(i)) }
            }
            guard !values.isEmpty else { continue }
            values.sort()
            medians[field] = values[values.count / 2]
        }
        return medians
    }

    /// `internal` (not private) for ReconcileFromServerTests.
    static func importHealthSnapshots(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) throws -> Int {
        let medians = computeMedians(rows: rows)
        func dbl(_ row: [String: Any], _ k: String) -> Double? {
            if let v = row[k] as? Double { return v }
            if let v = row[k] as? Int { return Double(v) }
            return medians[k]
        }
        func intf(_ row: [String: Any], _ k: String) -> Int? {
            if let v = row[k] as? Int { return v }
            if let v = row[k] as? Double { return Int(v) }
            if let m = medians[k] { return Int(m) }
            return nil
        }
        // Skip dates the store already has. `#Unique<HealthSnapshot>([\.date])` does
        // NOT make this importer idempotent: SwiftData resolves a unique-key
        // collision by REPLACING the whole object, not by skipping it. That's
        // harmless on the restore path (empty store, no collisions) but is data
        // loss on a reconcile:
        //
        //   • `syncedToServer` is a dirty flag — `SnapshotAggregator.aggregateDay`
        //     clears it on an arbitrary PAST day when a late HealthKit backfill
        //     corrects it. A blind replace would overwrite that corrected snapshot
        //     with the server's older copy AND set `syncedToServer = true` below,
        //     so the re-upload the flag exists to guarantee never happens. The local
        //     correction isn't merely stale at that point — it's unrecoverable.
        //
        // Skip-if-present is the same shape the hand-deduped importers use, and it
        // is what actually makes "Repair Missing Data" mean what its name says.
        //
        // The key must be `startOfDay`, not the raw parsed instant: `HealthSnapshot.init`
        // normalizes its date that way (which is what makes the unique constraint work on
        // calendar days at all). Keying on the unnormalized value silently never matches —
        // the guard passes, the insert fires, and the replace happens anyway.
        var seenDates = try Self.existingKeys(HealthSnapshot.self, in: ctx) { $0.date }
        var n = 0
        for row in rows {
            guard let date = parseDate(row["date"]) else { continue }
            let shiftedDate = date.addingTimeInterval(shift)
            let dayKey = Calendar.current.startOfDay(for: shiftedDate)
            guard seenDates.insert(dayKey).inserted else { continue }
            let snap = HealthSnapshot(date: shiftedDate)
            snap.hrvAvg = dbl(row, "hrv_avg")
            snap.hrvMin = dbl(row, "hrv_min")
            snap.restingHR = dbl(row, "resting_hr")
            snap.sleepDurationMin = intf(row, "sleep_duration_min")
            snap.sleepDeepMin = intf(row, "sleep_deep_min")
            snap.sleepREMMin = intf(row, "sleep_rem_min")
            snap.sleepCoreMin = intf(row, "sleep_core_min")
            snap.sleepAwakeMin = intf(row, "sleep_awake_min")
            snap.skinTempDeviation = dbl(row, "skin_temp_deviation")
            snap.skinTempWrist = row["skin_temp_wrist"] as? Double
            snap.respiratoryRate = dbl(row, "respiratory_rate")
            snap.spo2Avg = dbl(row, "spo2_avg")
            snap.spo2NadirOvernight = dbl(row, "spo2_nadir_overnight")
            snap.spo2NadirOpportunistic = row["spo2_nadir_opportunistic"] as? Double
            snap.spo2TimeBelow90Min = intf(row, "spo2_time_below_90_min")
            snap.spo2DesatsCount = intf(row, "spo2_desats_count")
            // SpO₂ source basis (F-092). Text columns — no median fill.
            snap.spo2AggregateSource = row["spo2_aggregate_source"] as? String
            snap.spo2BurdenSource = row["spo2_burden_source"] as? String
            snap.steps = intf(row, "steps")
            snap.activeCalories = dbl(row, "active_calories")
            snap.exerciseMinutes = intf(row, "exercise_minutes")
            snap.environmentalSoundAvg = dbl(row, "environmental_sound_avg")
            snap.bpSystolic = row["bp_systolic"] as? Double
            snap.bpDiastolic = row["bp_diastolic"] as? Double
            snap.bloodGlucoseAvg = row["blood_glucose_avg"] as? Double
            snap.glucoseStdDev = row["glucose_std_dev"] as? Double
            snap.glucoseCV = row["glucose_cv"] as? Double
            snap.glucoseMin = row["glucose_min"] as? Double
            snap.glucoseMax = row["glucose_max"] as? Double
            snap.cpapAHI = row["cpap_ahi"] as? Double
            snap.cpapUsageMinutes = row["cpap_usage_minutes"] as? Int
            snap.barometricPressureAvgKPa = row["barometric_pressure_avg_kpa"] as? Double
            snap.barometricPressureChangeKPa = row["barometric_pressure_change_kpa"] as? Double
            if let dq = row["data_quality"] {
                if let dqString = dq as? String {
                    snap.dataQuality = dqString
                } else if let dqDict = dq as? [String: Any],
                          let dqData = try? JSONSerialization.data(withJSONObject: dqDict) {
                    snap.dataQuality = String(data: dqData, encoding: .utf8)
                }
            }
            snap.syncedToServer = true
            ctx.insert(snap)
            n += 1
        }
        return n
    }

    /// `internal` (not private) so RestoreFromServerTests can verify a
    /// null-AHI (EDF-only) row still imports rather than being skipped (F-094).
    static func importCPAPSessions(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) throws -> Int {
        // Skip dates the store already has, for the same reason as
        // `importHealthSnapshots`: `#Unique<CPAPSession>([\.date])` resolves a
        // collision by REPLACING the object wholesale, and `CPAPSession` is
        // locally mutable — `CPAPImporter.updateSession` / `preservingRealPressure`
        // correct existing rows in place on a re-import. A reconcile that blindly
        // re-inserted would silently revert those corrections to the server's older
        // copy.
        //
        // Keyed on `startOfDay` because `CPAPSession.init` normalizes its date that way —
        // see the same note in `importHealthSnapshots`.
        var seenDates = try Self.existingKeys(CPAPSession.self, in: ctx) { $0.date }
        var n = 0
        for row in rows {
            guard let date = parseDate(row["date"]),
                  let usage = row["total_usage_minutes"] as? Int else { continue }
            let dayKey = Calendar.current.startOfDay(for: date.addingTimeInterval(shift))
            guard seenDates.insert(dayKey).inserted else { continue }
            // AHI is NULL for EDF-only nights (server stores null rather than a
            // fabricated 0, F-068). Import the row regardless — its leak/usage/
            // pressure are still valuable — carrying ahi through as nil rather
            // than skipping the whole session (the F-094 data-loss bug).
            let ahi = row["ahi"] as? Double
            let session = CPAPSession(
                date: date.addingTimeInterval(shift),
                ahi: ahi,
                totalUsageMinutes: usage,
                leakRate95th: row["leak_rate_95th"] as? Double,
                pressureMin: (row["pressure_min"] as? Double) ?? 0,
                pressureMax: (row["pressure_max"] as? Double) ?? 0,
                pressureMean: (row["pressure_mean"] as? Double) ?? 0,
                obstructiveEvents: (row["obstructive_events"] as? Int) ?? 0,
                centralEvents: (row["central_events"] as? Int) ?? 0,
                hypopneaEvents: (row["hypopnea_events"] as? Int) ?? 0,
                importSource: (row["import_source"] as? String) ?? "oscar",
                // By-session fields (migration 0010): NULL means "source
                // didn't report" — carry through as nil, never coerce to 0.
                rdiEvents: row["rdi_events"] as? Double,
                reraEvents: row["rera_events"] as? Int,
                spo2Avg: row["spo2_avg"] as? Double,
                spo2Min: row["spo2_min"] as? Double,
                pulseAvg: row["pulse_avg"] as? Double,
                pressure95th: row["pressure_95th"] as? Double,
                leakAvg: row["leak_avg"] as? Double,
                leakMax: row["leak_max"] as? Double
            )
            ctx.insert(session)
            n += 1
        }
        return n
    }

    // MARK: - Quantity health samples (paged)

    /// Rows per page when restoring `QuantityHealthSample`. The server clamps
    /// to its own maximum; this is sized so a ~250k-row history restores in a
    /// few dozen round trips while each page stays a couple of MB.
    static let quantitySamplePageSize = 5000

    /// Pull `QuantityHealthSample` down page-by-page and insert it.
    ///
    /// Paged rather than bulk because this is by far the largest table (~250k
    /// rows / ~79 MB of JSON on a real device); inlining it in `/api/data`
    /// would make the response — and the parsed dictionary the app holds in
    /// memory — large enough to get the restore jetsammed. Each page is saved
    /// before the next is fetched so peak memory stays bounded.
    ///
    /// Tolerates a server that predates the endpoint (404) by returning what it
    /// has, so an app update can't hard-fail a restore against an older server.
    ///
    /// `@MainActor` is load-bearing, not decoration. This is the only `async`
    /// step in the restore, and `SyncService` is a plain class (isolation is
    /// per-member, not type-wide), so without it a call from the `@MainActor`
    /// `restoreFromServer` would hop OFF the main actor — and the continuation
    /// after `await` then mutates the `ModelContext` (`importQuantityHealthSamples`
    /// + `save()`) off-main, which is a SwiftData thread violation. The other
    /// importers get away with being nonisolated only because they're
    /// synchronous and inherit the caller's context.
    @MainActor
    static func restorePagedQuantitySamples(
        serverURL: String,
        apiKey: String,
        shift: TimeInterval,
        modelContext: ModelContext,
        performRequest: (@MainActor (URLRequest) async throws -> (Data, URLResponse))?
    ) async throws -> Int {
        var imported = 0
        var offset = 0
        var total: Int?

        // Built ONCE and threaded through every page. On a restore this fetch
        // returns nothing (empty store); on a reconcile it can hold ~250k ids, and
        // rebuilding it inside the loop would mean ~52 full-table fetches instead
        // of one. Each page's newly-inserted ids are added to it as they land, so
        // duplicates *within* the payload are also skipped.
        var existing = try Self.existingIDs(QuantityHealthSample.self, \.id, in: modelContext)

        while true {
            guard var components = URLComponents(string: serverURL) else { throw SyncError.invalidURL }
            components.path = "/api/data/quantityHealthSamples"
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(quantitySamplePageSize)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            guard let url = components.url else { throw SyncError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 180

            let (data, response): (Data, URLResponse)
            if let performRequest {
                (data, response) = try await performRequest(request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw SyncError.noConnection }
            // Older server without this entity — don't fail the whole restore.
            if http.statusCode == 404 { return imported }
            guard (200...299).contains(http.statusCode) else {
                throw SyncError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["quantityHealthSamples"] as? [[String: Any]] else {
                throw RestoreError.invalidJSON
            }
            if total == nil { total = json["total"] as? Int }

            imported += Self.importQuantityHealthSamples(
                rows, shift: shift, existing: &existing, into: modelContext
            )
            // Save per page: a quarter-million unsaved inserts in one context is
            // exactly the peak-memory shape that gets the app killed.
            try modelContext.save()

            // Advance by rows RECEIVED, not rows inserted — dedupe drops some
            // rows, and paging off the inserted count would re-request them
            // forever.
            offset += rows.count
            if rows.count < quantitySamplePageSize { break }
            if let total, offset >= total { break }
        }
        return imported
    }

    /// Insert restored quantity samples.
    ///
    /// Two non-obvious invariants, both load-bearing:
    /// - **The server's `id` is preserved.** `HealthDataCoordinator` mirrors
    ///   HealthKit using `sample.hkUUID` as the row id and does update-or-insert
    ///   on it. Minting fresh UUIDs here would make the first post-restore
    ///   HealthKit backfill re-insert every Apple/Polar/Dexcom sample as a
    ///   duplicate instead of matching the restored row.
    /// - **`syncedToServer` is `true`.** These rows came FROM the server, and
    ///   bulk types are exported on `syncedToServer == false` (not by the date
    ///   cursor), so the default `false` would make the next sync re-upload the
    ///   entire restored history.
    /// Single-shot convenience: builds its own known-id set. Fine for a one-off
    /// import; the paged restore MUST use the `existing:` overload instead so the
    /// (potentially ~250k-element) set is built once rather than per page.
    static func importQuantityHealthSamples(
        _ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext
    ) throws -> Int {
        var existing = try Self.existingIDs(QuantityHealthSample.self, \.id, in: ctx)
        return importQuantityHealthSamples(rows, shift: shift, existing: &existing, into: ctx)
    }

    /// Skips ids the store already has, threading the known-id set across pages.
    ///
    /// `@Attribute(.unique) var id` does NOT make a re-insert a no-op — SwiftData
    /// resolves the collision by replacing the row. Harmless for this table's
    /// contents (samples are immutable once written) but catastrophic for a
    /// reconcile's cost and honesty: without the skip, every repair would rewrite
    /// all ~250k rows and report them all as "added".
    ///
    /// `existing` is `inout` rather than rebuilt per call because
    /// `restorePagedQuantitySamples` invokes this once per 5k-row page — ~52 times
    /// on the real dataset. Re-fetching a quarter-million ids on each of those is
    /// the difference between one fetch and fifty-two.
    static func importQuantityHealthSamples(
        _ rows: [[String: Any]], shift: TimeInterval, existing: inout Set<UUID>, into ctx: ModelContext
    ) -> Int {
        var n = 0
        for row in rows {
            guard let idString = row["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let ts = parseDate(row["timestamp"]),
                  let metricType = row["metric_type"] as? String,
                  let value = row["value"] as? Double,
                  let unitString = row["unit_string"] as? String,
                  let sourceBundleID = row["source_bundle_id"] as? String else { continue }
            guard existing.insert(id).inserted else { continue }
            let groupID = (row["group_id"] as? String).flatMap(UUID.init(uuidString:))
            ctx.insert(QuantityHealthSample(
                id: id,
                timestamp: ts.addingTimeInterval(shift),
                metricType: metricType,
                value: value,
                unitString: unitString,
                sourceBundleID: sourceBundleID,
                sourceName: row["source_name"] as? String ?? "",
                deviceModel: row["device_model"] as? String,
                groupID: groupID,
                syncedToServer: true
            ))
            n += 1
        }
        return n
    }

    // MARK: - Barometric readings

    /// Barometric readings are the one restored table with NO other source of
    /// truth — they come from this app's own `CMAltimeter` capture and are not
    /// re-derivable from HealthKit, CPAP, or anything else. Losing them in a
    /// migration is permanent, which is why the restore path must carry them.
    /// The server PK is `timestamp` (see `barometric_readings` in schema.sql)
    /// and `BarometricReading` has no #Unique column, so dedupe by shifted
    /// timestamp to keep the importer idempotent like its #Unique-id siblings.
    /// `internal` (not private) for RestoreFromServerTests.
    /// Fail-closed, like every other importer's guard: an unreadable table aborts
    /// the import rather than degrading to "nothing exists". BarometricReading has no
    /// unique constraint, so a lost guard here duplicates rows rather than clobbering
    /// them — less destructive than the HealthSnapshot case, but still a guard that
    /// would silently stop guarding.
    static func importBarometricReadings(
        _ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext
    ) throws -> Int {
        var seenTimestamps = try Self.existingKeys(BarometricReading.self, in: ctx) { $0.timestamp }
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let pressure = row["pressure_kpa"] as? Double,
                  let altitude = row["relative_altitude_m"] as? Double else { continue }
            let shifted = ts.addingTimeInterval(shift)
            guard seenTimestamps.insert(shifted).inserted else { continue }
            ctx.insert(BarometricReading(
                timestamp: shifted,
                pressureKPa: pressure,
                relativeAltitudeM: altitude
            ))
            n += 1
        }
        return n
    }

    /// Returns (imported count, map of original server UUID string -> new local SensorSession UUID).
    /// HRVReading rows reference sensor_sessions.id; the map lets us re-link them after import.
    /// `internal` (not private) for RestoreFromServerTests.
    /// Deduped by the server's `id` (a real UUID PK on `sensor_sessions`), which
    /// this importer already preserves so `hrv_readings.session_id` re-links 1:1.
    /// `SensorSession` has no unique constraint, so without the `existing` check a
    /// re-import would duplicate every session.
    ///
    /// Sessions that already exist are skipped for insertion but **still added to
    /// the returned map** — `importHRVReadings` looks sessions up through it, so
    /// omitting them would orphan the HRV readings of every pre-existing session.
    static func importSensorSessions(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) throws -> (Int, [String: UUID]) {
        var n = 0
        var map: [String: UUID] = [:]
        var existing = try Self.existingIDs(SensorSession.self, \.id, in: ctx)
        for row in rows {
            guard let serverIDString = row["id"] as? String,
                  let startStr = row["start_time"] as? String,
                  let startTime = parseDate(startStr) else { continue }
            if let serverUUID = UUID(uuidString: serverIDString), existing.contains(serverUUID) {
                // Already present: don't re-insert, but keep it reachable for
                // this restore's HRV readings.
                map[serverIDString] = serverUUID
                continue
            }
            let session = SensorSession(
                startTime: startTime.addingTimeInterval(shift),
                batteryAtStart: (row["battery_at_start"] as? Int) ?? 100
            )
            // Preserve the server's UUID so a restored session keeps its
            // identity (and so hrv_readings.session_id rows re-link 1:1).
            //
            // Record it as existing NOW, not just in the returned map: SensorSession
            // has no unique constraint on `id`, so a payload carrying the same session
            // twice would otherwise insert it twice. The store-backed set alone only
            // catches rows that were already persisted, never duplicates *within* the
            // payload. Same fix as `importSongs` — both read their existence set
            // instead of also inserting into it, so both covered only half the problem.
            if let serverUUID = UUID(uuidString: serverIDString) {
                session.id = serverUUID
                existing.insert(serverUUID)
            }
            if let endStr = row["end_time"] as? String, let endTime = parseDate(endStr) {
                session.endTime = endTime.addingTimeInterval(shift)
            }
            session.source = row["source"] as? String
            if let summary = row["summary_json"] {
                if let str = summary as? String {
                    session.summaryJSON = str
                } else if let dict = summary as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: dict) {
                    session.summaryJSON = String(data: data, encoding: .utf8)
                }
            }
            session.syncedToServer = true
            ctx.insert(session)
            map[serverIDString] = session.id
            n += 1
        }
        return (n, map)
    }

    /// `internal` (not private) for RestoreFromServerTests.
    static func importHRVReadings(_ rows: [[String: Any]], shift: TimeInterval, sessionMap: [String: UUID], into ctx: ModelContext) throws -> Int {
        // Skip ids the store already has. These tables are append-only in
        // practice, so a blind re-insert wouldn't corrupt them the way it would
        // HealthSnapshot/CPAPSession — but a `#Unique` collision REPLACES the
        // row rather than skipping it, so without this every reconcile would
        // rewrite the entire remote history and report all of it as "added".
        var existing = try Self.existingIDs(HRVReading.self, \.id, in: ctx)
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let rmssd = row["rmssd"] as? Double,
                  let sdnn = row["sdnn"] as? Double,
                  let pnn50 = row["pnn50"] as? Double else { continue }
            let serverSessionID = row["session_id"] as? String
            let mappedSessionID = serverSessionID.flatMap { sessionMap[$0] }
            // Preserve the server UUID — HRVReading declares #Unique on id,
            // so passing it through keeps the documented idempotency
            // invariant instead of minting a fresh UUID per import.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            guard existing.insert(serverID).inserted else { continue }
            let reading = HRVReading(
                id: serverID,
                timestamp: ts.addingTimeInterval(shift),
                rmssd: rmssd,
                sdnn: sdnn,
                pnn50: pnn50,
                lfPower: (row["lf_power"] as? Double) ?? 0,
                hfPower: (row["hf_power"] as? Double) ?? 0,
                lfHfRatio: (row["lf_hf_ratio"] as? Double) ?? 0,
                sensorSessionID: mappedSessionID,
                source: row["source"] as? String
            )
            reading.syncedToServer = true
            ctx.insert(reading)
            n += 1
        }
        return n
    }

    /// `internal` (not private) for RestoreFromServerTests.
    static func importAccelSpectrograms(
        _ rows: [[String: Any]], shift: TimeInterval, sessionMap: [String: UUID], into ctx: ModelContext
    ) throws -> Int {
        // Skip ids the store already has. These tables are append-only in
        // practice, so a blind re-insert wouldn't corrupt them the way it would
        // HealthSnapshot/CPAPSession — but a `#Unique` collision REPLACES the
        // row rather than skipping it, so without this every reconcile would
        // rewrite the entire remote history and report all of it as "added".
        var existing = try Self.existingIDs(AccelSpectrogram.self, \.id, in: ctx)
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let tremor = row["tremor_band_power"] as? Double,
                  let breathing = row["breathing_band_power"] as? Double,
                  let fidget = row["fidget_band_power"] as? Double,
                  let activity = row["activity_level"] as? Double else { continue }
            // session_id is nullable server-side; Watch-local session IDs
            // that never synced as sensor_sessions rows won't be in the map
            // and re-link to nil — matching importHRVReadings.
            let serverSessionID = row["session_id"] as? String
            let mappedSessionID = serverSessionID.flatMap { sessionMap[$0] }
            // Preserve the server UUID — AccelSpectrogram declares #Unique
            // on id, keeping the documented idempotency invariant.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            guard existing.insert(serverID).inserted else { continue }
            let spectrogram = AccelSpectrogram(
                id: serverID,
                timestamp: ts.addingTimeInterval(shift),
                tremorBandPower: tremor,
                breathingBandPower: breathing,
                fidgetBandPower: fidget,
                activityLevel: activity,
                sensorSessionID: mappedSessionID
            )
            spectrogram.syncedToServer = true
            ctx.insert(spectrogram)
            n += 1
        }
        return n
    }

    /// `internal` (not private) for RestoreFromServerTests.
    static func importDerivedBreathingRates(
        _ rows: [[String: Any]], shift: TimeInterval, sessionMap: [String: UUID], into ctx: ModelContext
    ) throws -> Int {
        // Skip ids the store already has. These tables are append-only in
        // practice, so a blind re-insert wouldn't corrupt them the way it would
        // HealthSnapshot/CPAPSession — but a `#Unique` collision REPLACES the
        // row rather than skipping it, so without this every reconcile would
        // rewrite the entire remote history and report all of it as "added".
        var existing = try Self.existingIDs(DerivedBreathingRate.self, \.id, in: ctx)
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let bpm = row["breaths_per_minute"] as? Double,
                  let confidence = row["confidence"] as? Double,
                  let source = row["source"] as? String else { continue }
            let serverSessionID = row["session_id"] as? String
            let mappedSessionID = serverSessionID.flatMap { sessionMap[$0] }
            // Preserve the server UUID — DerivedBreathingRate declares
            // #Unique on id, keeping the documented idempotency invariant.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            guard existing.insert(serverID).inserted else { continue }
            let rate = DerivedBreathingRate(
                id: serverID,
                timestamp: ts.addingTimeInterval(shift),
                breathsPerMinute: bpm,
                confidence: confidence,
                source: source,
                sensorSessionID: mappedSessionID
            )
            rate.syncedToServer = true
            ctx.insert(rate)
            n += 1
        }
        return n
    }

    /// Returns (count, map of server songs.id -> local Song instance).
    /// Deduped by `serverId` (the `songs.id` SERIAL PK). `Song` has no unique
    /// constraint, so a re-import would otherwise duplicate the catalogue and,
    /// worse, re-point occurrences at the duplicates.
    ///
    /// Songs that already exist are skipped for insertion but **still added to the
    /// returned map**, which `importSongOccurrences` resolves `song_id` through —
    /// omitting them would leave every occurrence of a pre-existing song with a
    /// nil `song` relationship.
    /// `internal` (not private) for ReconcileFromServerTests.
    static func importSongs(_ rows: [[String: Any]], into ctx: ModelContext) throws -> (Int, [Int: Song]) {
        var n = 0
        var map: [Int: Song] = [:]
        // Sorted for a deterministic tie-break if two rows somehow share a
        // serverId (CLAUDE.md deterministic-ordering pitfall).
        let existing = try ctx.fetch(FetchDescriptor<Song>(sortBy: [SortDescriptor(\.id)]))
        var existingByServerID: [Int: Song] = [:]
        for song in existing {
            guard let sid = song.serverId else { continue }
            if existingByServerID[sid] == nil { existingByServerID[sid] = song }
        }
        for row in rows {
            guard let serverID = row["id"] as? Int,
                  let title = row["title"] as? String,
                  let artist = row["artist"] as? String else { continue }
            if let already = existingByServerID[serverID] {
                map[serverID] = already
                continue
            }
            let song = Song(
                title: title,
                artist: artist,
                album: row["album"] as? String,
                geniusId: row["genius_id"] as? Int,
                albumArtURL: row["album_art_url"] as? String,
                geniusURL: row["genius_url"] as? String
            )
            song.serverId = serverID
            song.lyrics = row["lyrics"] as? String
            song.lyricsSource = row["lyrics_source"] as? String
            ctx.insert(song)
            // Record it as existing NOW, not just in the returned map. `Song` has no
            // unique constraint on `serverId`, so a payload carrying the same song
            // twice would otherwise insert it twice — the store-backed set alone only
            // catches rows that were already persisted, never duplicates *within* the
            // payload. Every other importer folds new keys into its `seen` set as it
            // goes; this was the one that didn't.
            existingByServerID[serverID] = song
            map[serverID] = song
            n += 1
        }
        return (n, map)
    }

    /// Deduped by `(song, timestamp, source)` — the server's own
    /// `song_occurrences_natural_key_unique` constraint. Keyed on the song's
    /// *serverId* rather than its local object so the key survives a re-import
    /// that resolved `songMap` to a pre-existing `Song`.
    private static func importSongOccurrences(
        _ rows: [[String: Any]], shift: TimeInterval, songMap: [Int: Song], into ctx: ModelContext
    ) throws -> Int {
        struct OccurrenceKey: Hashable {
            let songServerID: Int?
            let timestamp: Date
            let source: String?
        }
        var seen = try Self.existingKeys(SongOccurrence.self, in: ctx) {
            OccurrenceKey(songServerID: $0.song?.serverId, timestamp: $0.timestamp, source: $0.source)
        }
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let songServerID = row["song_id"] as? Int else { continue }
            let shifted = ts.addingTimeInterval(shift)
            let source = row["source"] as? String
            let key = OccurrenceKey(songServerID: songServerID, timestamp: shifted, source: source)
            guard seen.insert(key).inserted else { continue }
            let occurrence = SongOccurrence(timestamp: shifted, source: source)
            occurrence.notes = row["notes"] as? String
            occurrence.song = songMap[songServerID]
            ctx.insert(occurrence)
            n += 1
        }
        return n
    }

    private static func importSleepStageEvents(_ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext) throws -> Int {
        // Skip ids the store already has. These tables are append-only in
        // practice, so a blind re-insert wouldn't corrupt them the way it would
        // HealthSnapshot/CPAPSession — but a `#Unique` collision REPLACES the
        // row rather than skipping it, so without this every reconcile would
        // rewrite the entire remote history and report all of it as "added".
        var existing = try Self.existingIDs(SleepStageEvent.self, \.id, in: ctx)
        var n = 0
        for row in rows {
            guard let startStr = row["start_time"] as? String,
                  let endStr = row["end_time"] as? String,
                  let startTime = parseDate(startStr),
                  let endTime = parseDate(endStr),
                  let stage = row["stage"] as? String,
                  let bundleID = row["source_bundle_id"] as? String else { continue }
            // Preserve the server id — SleepStageEvent.id is documented as
            // "the HealthKit sample UUID, making sync end-to-end idempotent";
            // minting a fresh UUID would break that invariant for restored rows.
            let serverID = (row["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            guard existing.insert(serverID).inserted else { continue }
            let event = SleepStageEvent(
                id: serverID,
                startTime: startTime.addingTimeInterval(shift),
                endTime: endTime.addingTimeInterval(shift),
                stage: stage,
                sourceBundleID: bundleID,
                sourceName: (row["source_name"] as? String) ?? "",
                deviceModel: row["device_model"] as? String,
                syncedToServer: true
            )
            ctx.insert(event)
            n += 1
        }
        return n
    }

    /// Name-keyed, like `importMedDefinitions`. Uses one up-front seen-set rather
    /// than a per-row predicate fetch: the old form was fail-open (`try?` → a fetch
    /// error read as "doesn't exist" → duplicate insert) and issued one query per
    /// row. Folding new names into the set as they're inserted also dedupes within
    /// the payload, not just against the store.
    private static func importPharmacies(_ rows: [[String: Any]], into ctx: ModelContext) throws -> Int {
        var seen = try Self.existingKeys(Pharmacy.self, in: ctx) { $0.name }
        var n = 0
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty else { continue }
            guard seen.insert(name).inserted else { continue }
            let pharmacy = Pharmacy(
                name: name,
                address: (row["address"] as? String) ?? "",
                phoneNumber: (row["phone_number"] as? String) ?? (row["phone"] as? String) ?? ""
            )
            ctx.insert(pharmacy)
            n += 1
        }
        return n
    }

    /// Insert prescriptions from restore/reconcile JSON rows. Insert-only by
    /// design: callers filter to genuinely-new rx numbers via
    /// `prescriptionRowsNotAlreadyPresent`, so no update branch exists and a
    /// locally-edited prescription can never be reverted to the server's copy.
    /// Deduped by `rx_number` with a seen-set, like `importPharmacies`:
    /// `Prescription` has no #Unique on `rxNumber`, and the caller's filter only
    /// checks the STORE — a payload carrying the same new rx_number twice would
    /// otherwise insert it twice. Folding accepted keys into the set as rows land
    /// covers within-payload duplicates, not just rows already persisted.
    static func importPrescriptions(
        _ rows: [[String: Any]], into modelContext: ModelContext
    ) throws -> Int {
        var seen = try Self.existingKeys(Prescription.self, in: modelContext) { $0.rxNumber }
        var count = 0
        for row in rows {
            guard let rxNumber = row["rx_number"] as? String, !rxNumber.isEmpty else { continue }
            // date_filled is NOT NULL server-side, so absence means a corrupt
            // row — fabricating a date (e.g. defaulting to .now) would falsify
            // the record's fill history. Checked before the seen-set so a
            // corrupt row can't claim its rx_number and block a valid duplicate.
            guard let dateFilled = parseDate(row["date_filled"]) else { continue }
            guard seen.insert(rxNumber).inserted else { continue }
            let rx = Prescription(
                rxNumber: rxNumber,
                medicationName: row["medication_name"] as? String ?? "",
                doseMg: row["dose_mg"] as? Double ?? 0,
                doseDescription: row["dose_description"] as? String ?? "",
                dateFilled: dateFilled,
                pharmacyName: row["pharmacy_name"] as? String ?? "",
                notes: row["notes"] as? String ?? ""
            )
            modelContext.insert(rx)
            rx.medication = try SyncService.findOrCreateMedication(
                name: rx.medicationName, doseMg: rx.doseMg, in: modelContext
            )
            count += 1
        }
        return count
    }

    /// The server's upsert key is `(timestamp, pharmacy_name)` — the PK of
    /// `pharmacy_call_logs` in server/schema.sql — and `PharmacyCallLog` has
    /// no #Unique column, so dedupe on that same pair (with the shifted
    /// timestamp) to keep the importer idempotent like its siblings. Must run
    /// AFTER `importPharmacies` so the `pharmacy` relationship can re-link by
    /// name; a log whose pharmacy no longer exists re-links to nil — the
    /// model denormalizes `pharmacyName` precisely so logs survive pharmacy
    /// deletion. `internal` (not private) for RestoreFromServerTests.
    /// Fail-closed, like every other importer's guard — see `importBarometricReadings`.
    static func importPharmacyCallLogs(
        _ rows: [[String: Any]], shift: TimeInterval, into ctx: ModelContext
    ) throws -> Int {
        // Sorted fetch: Pharmacy has no #Unique on name, so two same-named
        // rows are possible; an unsorted fetch would make the "first wins"
        // collapse below nondeterministic (CLAUDE.md deterministic-ordering
        // pitfall). Sorting by id makes the tie-break stable across runs.
        let pharmacies = try ctx.fetch(FetchDescriptor<Pharmacy>(
            sortBy: [SortDescriptor(\.id)]
        ))
        let pharmaciesByName = Dictionary(pharmacies.map { ($0.name, $0) }) { first, _ in first }
        var seen: [String: Set<Date>] = [:]
        for log in try ctx.fetch(FetchDescriptor<PharmacyCallLog>()) {
            seen[log.pharmacyName, default: []].insert(log.timestamp)
        }
        var n = 0
        for row in rows {
            guard let ts = parseDate(row["timestamp"]),
                  let name = row["pharmacy_name"] as? String, !name.isEmpty else { continue }
            let shifted = ts.addingTimeInterval(shift)
            guard seen[name, default: []].insert(shifted).inserted else { continue }
            ctx.insert(PharmacyCallLog(
                timestamp: shifted,
                direction: (row["direction"] as? String) ?? "attempted",
                pharmacyName: name,
                notes: (row["notes"] as? String) ?? "",
                durationSeconds: row["duration_seconds"] as? Int,
                pharmacy: pharmaciesByName[name]
            ))
            n += 1
        }
        return n
    }
}
