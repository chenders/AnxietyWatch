import BackgroundTasks
import Combine
import os
import SwiftUI
import SwiftData
import UserNotifications

@main
struct AnxietyWatchApp: App {
    /// Versioned key for one-time medication reactivation fixup.
    private static let reactivateMedsKey = "didFixReactivateMeds_v1"

    /// Notification delegate — must be stored as a property to stay alive.
    private let notificationDelegate = NotificationDelegate()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
            Pharmacy.self,
            Prescription.self,
            PharmacyCallLog.self,
            HealthSample.self,
            PhysiologicalCorrelation.self,
            Song.self,
            SongOccurrence.self,
            // Sensor capture (synced from watch)
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
            // High-fidelity HealthKit sample mirror
            QuantityHealthSample.self,
            SleepStageEvent.self,
            // CNS-depression monitoring (local-only, klaxon Phase 2 decision 8)
            MonitoringSession.self,
            CNSRiskSampleRecord.self,
        ])
        // Resolve (and create, if this is a first launch) the Application
        // Support directory: `urls(...).first!` returns a URL that may not
        // exist yet, and passing a store URL under a missing directory can
        // fail ModelContainer init on a fresh install.
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        } catch {
            fatalError("Could not resolve Application Support directory: \(error)")
        }

        // SwiftData stores to Application Support by default, which iOS includes
        // in iCloud/iTunes backups. Exclude the whole directory so health data
        // never leaks into a backup without explicit opt-in — excluding the
        // directory (rather than only the files) durably covers the SQLite
        // `-wal`/`-shm` siblings whenever SQLite (re)creates them, closing the
        // race where a journal file created after launch would be backup-
        // eligible. The sync-to-personal-server path is the only deliberate
        // off-device route.
        AnxietyWatchApp.excludeFromBackup(appSupport)

        let storeURL = appSupport.appendingPathComponent("default.store")
        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            // Belt-and-suspenders: also flag the concrete store files now that
            // they exist, in case directory-level exclusion is unavailable.
            for suffix in ["", "-wal", "-shm"] {
                AnxietyWatchApp.excludeFromBackup(appSupport.appendingPathComponent("default.store\(suffix)"))
            }
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// Sets `isExcludedFromBackup` on `url` if it exists. `setResourceValues`
    /// throws `ENOENT` for a missing path (silently no-op'ing the exclusion),
    /// so guard on existence and log — don't `try?`-swallow — any real failure.
    private static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            os_log("Failed to exclude %@ from backup: %@", type: .error,
                   target.lastPathComponent, error.localizedDescription)
        }
    }

    @State private var coordinator: HealthDataCoordinator?
    @State private var polarService: PolarHRMService
    /// App-scoped like `polarService`: the EMAY SleepO2 supports a single
    /// central connection, so one owner must exist for the app's lifetime —
    /// a second view-local instance would race it for the peripheral. It
    /// also persists per-minute live samples, so it needs a ModelContext
    /// from the shared container. The only launch-time hook is the
    /// unconditional `startIfContinuousModeEnabled()` call in `.task` —
    /// all auto-start/restoration logic lives inside the service.
    @State private var emayService: EMAYRealtimeService
    /// App-scoped like `polarService`/`emayService`: owns the CNS-depression
    /// monitor's 1 Hz tick loop and session lifecycle for the app's whole
    /// runtime, and both dose-log sites (`MedicationsHubView`,
    /// `DoseAnxietyPromptView`) call `doseLogged` on the SAME injected
    /// instance. A fresh `ModelContext(sharedModelContainer)`, matching
    /// `emayService`'s own context.
    @State private var monitoringCoordinator: CNSMonitoringCoordinator
    /// Shared sheet-presentation state for the in-progress recording UI.
    /// Lives on the App so the in-app pill (rendered at ContentView root)
    /// and entry-point views (Dashboard card, Settings polar section) all
    /// flip the same flag — see `RecordingPresentationCoordinator`.
    @State private var recordingPresentation = RecordingPresentationCoordinator()
    /// Drives the Lock Screen + Dynamic Island Live Activity for an
    /// in-progress session. Constructed once and held as @State so the
    /// observation-tracking subscription installed in its init stays
    /// alive for the app's lifetime. No environment injection needed —
    /// the coordinator is internal; nothing reads it.
    @State private var liveActivityCoordinator: LiveActivityCoordinator?
    @Environment(\.scenePhase) private var scenePhase
    @State private var followUpDose: MedicationDose?
    @State private var followUpMedication: MedicationDefinition?
    @State private var showingRandomCheckIn = false
    /// First-launch restore-vs-fresh decision alert (see `RestoreMigrationGate`).
    @State private var showMigrationDecision = false
    /// Presents Settings → Server Sync directly when the user picks
    /// "Restore from Server" in the migration decision alert.
    @State private var showRestoreSettingsSheet = false
    /// True while `setupIfNeeded()` is intentionally held back pending the
    /// restore-vs-fresh decision. Cleared by `beginDeferredSetup()`.
    @State private var setupDeferredForMigration = false
    @State private var importAlert: ImportAlert?
    @State private var pendingImports: [URL] = []
    @State private var importDebounceTask: Task<Void, Never>?

    /// Coalesce window for batch imports — long enough to absorb a multi-file
    /// share sheet drop (iOS delivers each URL via a separate `.onOpenURL`
    /// call), short enough to feel instant for single-file imports.
    private static let importDebounceMillis: UInt64 = 300

    private struct ImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // BGTask registration must happen before app finishes launching.
    @MainActor
    init() {
        let coord = HealthDataCoordinator(modelContainer: sharedModelContainer)
        _coordinator = State(initialValue: coord)
        coord.registerBackgroundTask()

        let polar = PolarHRMService(modelContext: ModelContext(sharedModelContainer))
        _polarService = State(initialValue: polar)
        _liveActivityCoordinator = State(initialValue: LiveActivityCoordinator(polarService: polar))

        let emay = EMAYRealtimeService(modelContext: ModelContext(sharedModelContainer))
        _emayService = State(initialValue: emay)

        _monitoringCoordinator = State(initialValue: CNSMonitoringCoordinator(
            modelContext: ModelContext(sharedModelContainer),
            emayService: emay,
            polarService: polar
        ))

        // Set notification delegate so notifications show in foreground
        // and taps trigger the pending check-in/follow-up flow.
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(polarService)
                .environment(emayService)
                .environment(monitoringCoordinator)
                .environment(recordingPresentation)
                .overlay {
                    // Coordinator's @Observable properties (isBackfilling,
                    // backfillProgress, backfillTotal) were previously read
                    // inline here, which registered observation at the App
                    // scope. backfillProgress increments per-day during a
                    // multi-day backfill (~28 increments/sec), invalidating
                    // the entire WindowGroup→ContentView→TabView tree on
                    // every increment and pegging the main thread. Wrapping
                    // the reads in a child View struct scopes the
                    // observation to just that child.
                    if let coordinator {
                        BackfillOverlay(coordinator: coordinator)
                    }
                }
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    if RestoreDemoMode.isActive {
                        let context = ModelContext(sharedModelContainer)
                        do {
                            // Demo flow only: shift timestamps so the sim
                            // looks current. Production restores (Settings →
                            // Server Sync) keep truthful timestamps.
                            let report = try await SyncService.shared.restoreFromServer(
                                modelContext: context, demoDateShift: true
                            )
                            Log.sync.info("[autoRestore] \(report, privacy: .public)")
                        } catch {
                            Log.sync.error("[autoRestore] failed: \(error, privacy: .public)")
                        }
                    }
                    // Synthetic fictional data for README/marketing screenshots
                    // (no personal data). Idempotent; only seeds an empty store.
                    if SeedDemoMode.isActive {
                        DemoSeeder.seedIfNeeded(container: sharedModelContainer)
                        // Show a synthetic live EMAY readout for screenshots —
                        // the simulator has no BLE device. Setting .streaming
                        // here makes the later startIfContinuousModeEnabled()
                        // a no-op via start()'s active-session guard.
                        emayService.applyDemoStreamingState()
                    }
                    #endif
                    PhoneConnectivityManager.shared.modelContainer = sharedModelContainer
                    PhoneConnectivityManager.shared.activate()

                    // After CoreBluetooth has had a chance to call
                    // willRestoreState (it fires before SwiftUI views attach),
                    // try to recover any SensorSession that's still open. If
                    // state restoration brought a peripheral back, this
                    // attaches the recorder to it; if not (cold launch,
                    // peripheral gone), this finalizes stale rows.
                    polarService.recoverInFlightSessionIfNeeded()

                    // Re-arm EMAY continuous streaming (no-op unless the user
                    // enabled the toggle; the decision lives in the service).
                    emayService.startIfContinuousModeEnabled()

                    // CNS monitoring launch hook: mark any session left
                    // un-ended by a force-quit/crash as `.appTerminated`,
                    // then re-arm with `.doseWindow` if a persisted dose
                    // window is still active.
                    monitoringCoordinator.handleLaunch()

                    // Link any prescriptions missing a MedicationDefinition
                    let context = ModelContext(sharedModelContainer)
                    try? SyncService.backfillMedicationLinks(modelContext: context)

                    // One-time fixup: re-activate medications incorrectly deactivated
                    // by the removed deactivateStaleMedications() method
                    if !UserDefaults.standard.bool(forKey: Self.reactivateMedsKey) {
                        do {
                            let allMeds = try context.fetch(FetchDescriptor<MedicationDefinition>())
                            var fixed = false
                            for med in allMeds where !med.isActive {
                                med.isActive = true
                                fixed = true
                            }
                            if fixed {
                                try context.save()
                            }
                            UserDefaults.standard.set(true, forKey: Self.reactivateMedsKey)
                        } catch {
                            Log.data.error("ReactivateMeds fixup failed: \(error, privacy: .public)")
                        }
                    }

                    guard let coord = coordinator else { return }
                    // First-launch migration gate: setupIfNeeded() inserts a
                    // HealthSnapshot (backfill) and starts barometer
                    // persistence within seconds of first launch — tripping
                    // restoreFromServer's empty-store guard long before a
                    // human could configure the server and tap Restore. On a
                    // fresh store with the restore-vs-fresh decision
                    // unresolved, defer setup (and the BG-refresh schedule,
                    // whose handler also aggregates a snapshot) until the
                    // user chooses. Existing installs auto-resolve inside
                    // evaluateAtLaunch and never defer or see the prompt.
                    if RestoreMigrationGate.evaluateAtLaunch(context: ModelContext(sharedModelContainer)) {
                        setupDeferredForMigration = true
                        showMigrationDecision = true
                    } else {
                        // Don't await — let gap fill and observer setup run
                        // in background while the dashboard renders
                        // immediately with cached data. @Query properties
                        // react to SwiftData changes automatically.
                        Task { await coord.setupIfNeeded() }
                        coord.scheduleBackgroundRefresh()
                    }

                    // Schedule random check-in if enabled and none pending
                    if RandomCheckInManager.isEnabled && RandomCheckInManager.loadPending() == nil {
                        RandomCheckInManager.ensureAuthorization()
                        RandomCheckInManager.scheduleNextCheckIn()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        checkPendingFollowUp()
                        checkPendingRandomCheckIn()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .didTapLocalNotification)) { _ in
                    // User tapped a notification — check for pending follow-ups
                    checkPendingFollowUp()
                }
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                    // Periodic check so follow-ups appear even when app stays foregrounded.
                    // Only runs the full check (UserDefaults read + SwiftData fetch) when active.
                    if scenePhase == .active {
                        checkPendingFollowUp()
                    }
                }
                .sheet(item: $followUpMedication) { med in
                    if let dose = followUpDose {
                        DoseAnxietyPromptView(medication: med, existingDose: dose)
                    }
                }
                .sheet(isPresented: $showingRandomCheckIn) {
                    RandomCheckInPromptView()
                }
                .onOpenURL { url in
                    handleIncomingFile(url)
                }
                // Restore-vs-fresh migration decision. Exactly two explicit
                // choices, no cancel: an abandoned decision would leave setup
                // deferred with no visible reason. If the app dies with the
                // decision unresolved (e.g. user backgrounds mid-alert), the
                // next launch re-evaluates the gate and prompts again.
                .alert("Set Up This Device", isPresented: $showMigrationDecision) {
                    Button("Restore from Server") {
                        // Decision intentionally stays UNRESOLVED: setup
                        // remains deferred so the store stays empty for the
                        // restore, and an abandoned restore re-prompts on the
                        // next launch instead of silently starting fresh.
                        showRestoreSettingsSheet = true
                    }
                    Button("Start Fresh") {
                        RestoreMigrationGate.resolve()
                        beginDeferredSetup()
                    }
                } message: {
                    Text("This looks like a fresh install. You can restore your "
                        + "history from your sync server, or start fresh. Health "
                        + "history import waits until you choose, so a restore "
                        + "can run into an empty store.")
                }
                .sheet(isPresented: $showRestoreSettingsSheet) {
                    NavigationStack { SyncSettingsView() }
                }
                .onChange(of: showRestoreSettingsSheet) { _, isPresented in
                    // Abandoned-restore escape hatch: the sheet is swipe-
                    // dismissible, and without this the app would sit with
                    // setup deferred (blank dashboard, no backfill, no
                    // explanation) until the process actually dies — the
                    // alert's "next launch re-evaluates" promise only covers
                    // real relaunches, and iOS can keep a suspended process
                    // alive for days. If the sheet closes while the decision
                    // is still unresolved, re-present the decision alert.
                    if !isPresented && setupDeferredForMigration && !RestoreMigrationGate.isResolved() {
                        showMigrationDecision = true
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .serverRestoreCompleted)) { _ in
                    // Restore succeeded (the gate was resolved inside
                    // restoreFromServer): start the setup that launch
                    // deferred. Restore-then-backfill ordering is safe — the
                    // restored raw sensor rows are already saved, so
                    // backfill's aggregateDay recomputes recent days on top
                    // of them. The sheet stays up so the user can read the
                    // per-table restore report.
                    beginDeferredSetup()
                }
                .alert(item: $importAlert) { alert in
                    Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
        }
        .modelContainer(sharedModelContainer)
    }

    /// Runs the launch setup the migration gate deferred. No-op unless a
    /// deferral is actually pending, so a `.serverRestoreCompleted` posted
    /// when nothing was deferred (e.g. the simulator demo-restore path)
    /// can't double-run setup alongside the normal launch path.
    @MainActor
    private func beginDeferredSetup() {
        guard setupDeferredForMigration, let coord = coordinator else { return }
        setupDeferredForMigration = false
        Task { await coord.setupIfNeeded() }
        coord.scheduleBackgroundRefresh()
    }

    /// Buffers an incoming CSV URL and (re)arms the debounce timer. iOS
    /// delivers each URL in a multi-file share via a separate `.onOpenURL`
    /// call; coalescing them into one batch prevents N stacked alerts and
    /// lets us run a single snapshot backfill across the union date range.
    private func handleIncomingFile(_ url: URL) {
        pendingImports.append(url)
        importDebounceTask?.cancel()
        importDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.importDebounceMillis * 1_000_000)
            guard !Task.isCancelled else { return }
            let batch = pendingImports
            pendingImports = []
            await processImportBatch(batch)
        }
    }

    @MainActor
    private func processImportBatch(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let container = sharedModelContainer

        // Off-main: parsing and inserting an EMAY CSV (~36k rows for an
        // overnight session) takes long enough to visibly stutter the UI if
        // run on the main actor. Detach into a userInitiated task with a
        // fresh ModelContext owned by that task's isolation domain.
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.runImports(urls: urls, in: container)
        }.value

        let alert = MultiFileImportAlert.compose(results: outcome.results, errors: outcome.errors)
        importAlert = ImportAlert(title: alert.title, message: alert.message)

        if let range = outcome.snapshotBackfillRange {
            await backfillSnapshots(dateRange: range, context: ModelContext(container))
        }
    }

    /// Internal (not private) so tests can drive the backfill-gate logic —
    /// which import kinds trigger the per-day snapshot re-aggregation —
    /// without standing up the whole app (see F-006 regression tests).
    struct ImportBatchOutcome: Sendable {
        let results: [MultiFileImportAlert.PerFileResult]
        let errors: [MultiFileImportAlert.PerFileError]
        let snapshotBackfillRange: ClosedRange<Date>?
    }

    /// Pure import work — parses each URL into the given container's store and
    /// returns per-file results and the union of snapshot-affecting date
    /// ranges. Marked `nonisolated static` so it can run inside a detached
    /// task without capturing `self` or any actor-isolated state; internal
    /// (not private) for the same testability reason as `ImportBatchOutcome`.
    ///
    /// Uses a fresh `ModelContext` per file so a failed import (which may
    /// leave pending inserts in its context after throwing) cannot leak into
    /// the next file's successful `save()`. Each file is its own transaction.
    nonisolated static func runImports(
        urls: [URL],
        in container: ModelContainer
    ) -> ImportBatchOutcome {
        var results: [MultiFileImportAlert.PerFileResult] = []
        var errors: [MultiFileImportAlert.PerFileError] = []
        var backfillRange: ClosedRange<Date>?

        for url in urls {
            let filename = url.lastPathComponent
            let context = ModelContext(container)
            do {
                let result = try CSVImportRouter.importCSV(from: url, into: context)
                results.append(.init(filename: filename, result: result))
                // BOTH import kinds feed HealthSnapshot fields (CPAP → AHI/
                // usage stitch, EMAY → overnight SpO2/pulse precedence), so
                // both need the per-day re-aggregation. Gating on .cpap alone
                // meant an EMAY import for a night that already had a
                // snapshot silently never reached spo2Avg/nadir/T90 until a
                // manual "Rebuild All History" (F-006) — fillGaps() only
                // fills missing days, never re-aggregates existing ones.
                if result.kind == .cpap || result.kind == .emay,
                   let range = result.dateRange {
                    if let existing = backfillRange {
                        let lower = min(existing.lowerBound, range.lowerBound)
                        let upper = max(existing.upperBound, range.upperBound)
                        backfillRange = lower...upper
                    } else {
                        backfillRange = range
                    }
                }
            } catch let error as CSVImportRouter.ImportError {
                errors.append(.init(filename: filename, message: error.alertMessage))
            } catch {
                errors.append(.init(filename: filename, message: error.localizedDescription))
            }
        }
        return ImportBatchOutcome(results: results, errors: errors, snapshotBackfillRange: backfillRange)
    }

    @MainActor
    private func backfillSnapshots(dateRange: ClosedRange<Date>, context: ModelContext) async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )
        // Day-aligned walk including the morning-after day — raw-timestamp
        // stepping missed the one day whose noon-to-noon window actually
        // held an overnight import's samples. See backfillDays (F-006).
        for date in SnapshotAggregator.backfillDays(covering: dateRange) {
            do {
                try await aggregator.aggregateDay(date)
            } catch {
                let label = date.formatted(.dateTime.month().day())
                Log.data.error("Backfill snapshot failed for \(label, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private func checkPendingFollowUp() {
        DoseFollowUpManager.cleanupStale()

        guard let pending = DoseFollowUpManager.pendingFollowUpIfDue() else { return }

        // Look up the dose and its medication
        let context = ModelContext(sharedModelContainer)
        let doseID = pending.doseID
        let descriptor = FetchDescriptor<MedicationDose>(
            predicate: #Predicate<MedicationDose> { $0.id == doseID }
        )
        guard let dose = try? context.fetch(descriptor).first,
              let medication = dose.medication else {
            // Dose was deleted or medication unlinked — clean up
            DoseFollowUpManager.completeFollowUp(doseID: pending.doseID)
            return
        }

        // Check if a follow-up entry already exists for this dose
        let entryDescriptor = FetchDescriptor<AnxietyEntry>(
            predicate: #Predicate<AnxietyEntry> { $0.isFollowUp == true }
        )
        let followUpEntries = (try? context.fetch(entryDescriptor)) ?? []
        let alreadyCompleted = followUpEntries.contains { $0.triggerDose?.id == doseID }

        if alreadyCompleted {
            DoseFollowUpManager.completeFollowUp(doseID: pending.doseID)
            return
        }

        followUpDose = dose
        followUpMedication = medication
    }

    private func checkPendingRandomCheckIn() {
        RandomCheckInManager.cleanupStale()

        // Don't show if a dose follow-up is already being shown
        guard followUpMedication == nil else { return }
        guard RandomCheckInManager.pendingCheckInIfDue() else { return }

        showingRandomCheckIn = true
    }

}

/// Owns observation of the backfill progress so that increment-per-day updates
/// during a multi-day backfill invalidate only this view, not the entire App
/// body / WindowGroup. See the comment at the `.overlay` call site for why
/// this matters.
private struct BackfillOverlay: View {
    let coordinator: HealthDataCoordinator

    var body: some View {
        if coordinator.isBackfilling {
            VStack(spacing: 12) {
                ProgressView(value: Double(coordinator.backfillProgress),
                             total: Double(coordinator.backfillTotal))
                    .tint(.blue)
                Text("Loading health history… \(coordinator.backfillProgress)/\(coordinator.backfillTotal) days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }
}
