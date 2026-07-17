import BackgroundTasks
import Combine
import os
import SwiftUI
import SwiftData
import UserNotifications
import AnxietyWatchKit

@main
struct AnxietyWatchApp: App {
    /// Versioned key for one-time medication reactivation fixup.
    private static let reactivateMedsKey = "didFixReactivateMeds_v1"

    /// Notification delegate — must be stored as a property to stay alive.
    private let notificationDelegate = NotificationDelegate()

    // MARK: - SwiftData (existing, Phase 2A dual-write until cutover)

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
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
            QuantityHealthSample.self,
            SleepStageEvent.self,
            MonitoringSession.self,
            CNSRiskSampleRecord.self,
        ])
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        } catch {
            fatalError("Could not resolve Application Support directory: \(error)")
        }
        AnxietyWatchApp.excludeFromBackup(appSupport)
        let storeURL = appSupport.appendingPathComponent("default.store")
        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            for suffix in ["", "-wal", "-shm"] {
                AnxietyWatchApp.excludeFromBackup(appSupport.appendingPathComponent("default.store\(suffix)"))
            }
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    private static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try target.setResourceValues(values) }
        catch { os_log("Failed to exclude %@ from backup: %@", type: .error,
                        target.lastPathComponent, error.localizedDescription) }
    }

    // MARK: - AnxietyWatchKit (v3 framework)

    /// Constructed once at launch. Held as app-scoped state for the process
    /// lifetime. Provides the SQLite database, HLC, sync engine, and
    /// transport layer. BLE adapters and the CNS pipeline are wired separately
    /// because they depend on platform entitlements.
    @State private var kit: DependencyContainer?

    /// v3 pipeline service: BLE actors → SensorRouter → CNS coordinator → ViewModel.
    @StateObject private var pipelineService = KitPipelineService()

    // MARK: - Existing services (during Phase 2A dual-write)

    @State private var coordinator: HealthDataCoordinator?
    @State private var polarService: PolarHRMService
    @State private var emayService: EMAYRealtimeService
    @State private var monitoringCoordinator: CNSMonitoringCoordinator
    @State private var recordingPresentation = RecordingPresentationCoordinator()
    @State private var liveActivityCoordinator: LiveActivityCoordinator?
    @Environment(\.scenePhase) private var scenePhase
    @State private var followUpDose: MedicationDose?
    @State private var followUpMedication: MedicationDefinition?
    @State private var showingRandomCheckIn = false
    @State private var showMigrationDecision = false
    @State private var showRestoreSettingsSheet = false
    @State private var setupDeferredForMigration = false
    @State private var importAlert: ImportAlert?
    @State private var pendingImports: [URL] = []
    @State private var importDebounceTask: Task<Void, Never>?

    private static let importDebounceMillis: UInt64 = 300

    private struct ImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: - Init

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

        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(polarService)
                .environment(emayService)
                .environment(monitoringCoordinator)
                .environment(recordingPresentation)
                .environmentObject(pipelineService)
                .overlay {
                    if let coordinator {
                        BackfillOverlay(coordinator: coordinator)
                    }
                }
                .task {
                    // ── AnxietyWatchKit bootstrap ──────────────────────
                    // Must happen before any sync or trigger DDL.
                    await bootstrapKit()
                    // ── v3 Pipeline service ────────────────────────────
                    // BLE actors + SensorRouter + CNS coordinator + ViewModel.
                    await pipelineService.start()
                    // ── Existing launch logic ─────────────────────────
                    await existingLaunchSetup()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        checkPendingFollowUp()
                        checkPendingRandomCheckIn()
                    }
                    // Spec §1.1 close flow: checkpoint + close on background.
                    if newPhase == .background {
                        saveCleanShutdownFlag()
                        Task {
                            await pipelineService.stop()
                            if var k = kit {
                                await k.shutdown()
                                kit = k
                            }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .didTapLocalNotification)) { _ in
                    checkPendingFollowUp()
                }
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                    if scenePhase == .active { checkPendingFollowUp() }
                }
                .sheet(item: $followUpMedication) { med in
                    if let dose = followUpDose {
                        DoseAnxietyPromptView(medication: med, existingDose: dose)
                    }
                }
                .sheet(isPresented: $showingRandomCheckIn) {
                    RandomCheckInPromptView()
                }
                .onOpenURL { url in handleIncomingFile(url) }
                .alert("Set Up This Device", isPresented: $showMigrationDecision) {
                    Button("Restore from Server") { showRestoreSettingsSheet = true }
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
                    if !isPresented && setupDeferredForMigration && !RestoreMigrationGate.isResolved() {
                        showMigrationDecision = true
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .serverRestoreCompleted)) { _ in
                    beginDeferredSetup()
                }
                .alert(item: $importAlert) { alert in
                    Alert(title: Text(alert.title), message: Text(alert.message),
                          dismissButton: .default(Text("OK")))
                }
        }
        .modelContainer(sharedModelContainer)
    }

    // MARK: - AnxietyWatchKit lifecycle

    /// Constructs the v3 framework's object graph and starts background
    /// transport loops. Must be called once on launch.
    @MainActor
    private func bootstrapKit() async {
        // Only construct once. State is permanent for the process lifetime,
        // but the .task modifier fires each time the scene activates. Guard
        // against reentry with a property check (State is stable).
        guard kit == nil else { return }

        let appGroup = AppGroup.containerURL
        let dbURL = appGroup.appendingPathComponent("tsdb.sqlite")
        let cursorFileURL = appGroup.appendingPathComponent("sync_cursor.json")

        // Exclude the SQLite files from backups (Spec §1.1).
        Self.excludeFromBackup(dbURL)
        Self.excludeFromBackup(appGroup.appendingPathComponent("tsdb.sqlite-wal"))
        Self.excludeFromBackup(appGroup.appendingPathComponent("tsdb.sqlite-shm"))

        // Node ID from Keychain (Spec §2.1). If missing due to first launch,
        // generate a fresh 16-byte UUID and store it.
        let nodeID: Data
        if let existing = KeychainNodeID.load() {
            nodeID = existing
        } else {
            let generated = withUnsafeBytes(of: UUID().uuid) { Data($0) }
            KeychainNodeID.store(generated)
            nodeID = generated
        }

        // REST endpoint for server sync (§2.7). Replace with real server URL.
        let endpoint: SyncEndpoint = RESTClient(baseURL: URL(string: "https://sync.anxietywatch.com")!)

        let container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorFileURL,
            nodeID: nodeID,
            endpoint: endpoint
        )
        kit = container

        do {
            // Register HLC UDFs for @Syncable triggers.
            try await container.registerUDFs()
            // Register sync types and load persisted cursors.
            try await container.bootstrap()
        } catch {
            Log.sync.error("Kit bootstrap failed: \(error)")
        }

        // Start the transport message loop for P2P sync.
        await container.syncEngine.start()
    }

    // MARK: - Existing launch logic

    @MainActor
    private func existingLaunchSetup() async {
        #if DEBUG && targetEnvironment(simulator)
        if RestoreDemoMode.isActive {
            let context = ModelContext(sharedModelContainer)
            do {
                let report = try await SyncService.shared.restoreFromServer(
                    modelContext: context, demoDateShift: true
                )
                Log.sync.info("[autoRestore] \(report, privacy: .public)")
            } catch {
                Log.sync.error("[autoRestore] failed: \(error, privacy: .public)")
            }
        }
        if SeedDemoMode.isActive {
            DemoSeeder.seedIfNeeded(container: sharedModelContainer)
            emayService.applyDemoStreamingState()
        }
        #endif
        PhoneConnectivityManager.shared.modelContainer = sharedModelContainer
        PhoneConnectivityManager.shared.activate()

        polarService.recoverInFlightSessionIfNeeded()
        emayService.startIfContinuousModeEnabled()
        monitoringCoordinator.handleLaunch()

        let context = ModelContext(sharedModelContainer)
        try? SyncService.backfillMedicationLinks(modelContext: context)

        if !UserDefaults.standard.bool(forKey: Self.reactivateMedsKey) {
            do {
                let allMeds = try context.fetch(FetchDescriptor<MedicationDefinition>())
                var fixed = false
                for med in allMeds where !med.isActive {
                    med.isActive = true
                    fixed = true
                }
                if fixed { try context.save() }
                UserDefaults.standard.set(true, forKey: Self.reactivateMedsKey)
            } catch {
                Log.data.error("ReactivateMeds fixup failed: \(error, privacy: .public)")
            }
        }

        guard let coord = coordinator else { return }
        if RestoreMigrationGate.evaluateAtLaunch(context: ModelContext(sharedModelContainer)) {
            setupDeferredForMigration = true
            showMigrationDecision = true
        } else {
            Task { await coord.setupIfNeeded() }
            coord.scheduleBackgroundRefresh()
        }

        if RandomCheckInManager.isEnabled && RandomCheckInManager.loadPending() == nil {
            RandomCheckInManager.ensureAuthorization()
            RandomCheckInManager.scheduleNextCheckIn()
        }
    }

    // MARK: - Clean shutdown flag

    /// Sets the `LastCleanShutdown` flag in App Group UserDefaults (§1.1).
    /// Cleared on launch; set here on transition to background. A missing
    /// flag on next launch indicates crash/force-quit and triggers the
    /// checkpoint-marker recovery path in DatabaseManager.
    private func saveCleanShutdownFlag() {
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        defaults?.set(true, forKey: "LastCleanShutdown")
    }

    // MARK: - Deferred setup

    @MainActor
    private func beginDeferredSetup() {
        guard setupDeferredForMigration, let coord = coordinator else { return }
        setupDeferredForMigration = false
        Task { await coord.setupIfNeeded() }
        coord.scheduleBackgroundRefresh()
    }

    // MARK: - File import

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
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.runImports(urls: urls, in: container)
        }.value
        let alert = MultiFileImportAlert.compose(results: outcome.results, errors: outcome.errors)
        importAlert = ImportAlert(title: alert.title, message: alert.message)
        if let range = outcome.snapshotBackfillRange {
            await backfillSnapshots(dateRange: range, context: ModelContext(container))
        }
    }

    struct ImportBatchOutcome: Sendable {
        let results: [MultiFileImportAlert.PerFileResult]
        let errors: [MultiFileImportAlert.PerFileError]
        let snapshotBackfillRange: ClosedRange<Date>?
    }

    nonisolated static func runImports(urls: [URL], in container: ModelContainer) -> ImportBatchOutcome {
        var results: [MultiFileImportAlert.PerFileResult] = []
        var errors: [MultiFileImportAlert.PerFileError] = []
        var backfillRange: ClosedRange<Date>?
        for url in urls {
            let filename = url.lastPathComponent
            let context = ModelContext(container)
            do {
                let result = try CSVImportRouter.importCSV(from: url, into: context)
                results.append(.init(filename: filename, result: result))
                if result.kind == .cpap || result.kind == .emay, let range = result.dateRange {
                    if let existing = backfillRange {
                        backfillRange = min(existing.lowerBound, range.lowerBound)...max(existing.upperBound, range.upperBound)
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
        let aggregator = SnapshotAggregator(healthKit: HealthKitManager.shared, modelContext: context)
        for date in SnapshotAggregator.backfillDays(covering: dateRange) {
            do { try await aggregator.aggregateDay(date) }
            catch {
                let label = date.formatted(.dateTime.month().day())
                Log.data.error("Backfill snapshot failed for \(label, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Follow-ups

    private func checkPendingFollowUp() {
        DoseFollowUpManager.cleanupStale()
        guard let pending = DoseFollowUpManager.pendingFollowUpIfDue() else { return }
        let context = ModelContext(sharedModelContainer)
        let doseID = pending.doseID
        let descriptor = FetchDescriptor<MedicationDose>(predicate: #Predicate<MedicationDose> { $0.id == doseID })
        guard let dose = try? context.fetch(descriptor).first, let medication = dose.medication else {
            DoseFollowUpManager.completeFollowUp(doseID: pending.doseID)
            return
        }
        let entryDescriptor = FetchDescriptor<AnxietyEntry>(predicate: #Predicate<AnxietyEntry> { $0.isFollowUp == true })
        let followUpEntries = (try? context.fetch(entryDescriptor)) ?? []
        if followUpEntries.contains(where: { $0.triggerDose?.id == doseID }) {
            DoseFollowUpManager.completeFollowUp(doseID: pending.doseID)
            return
        }
        followUpDose = dose
        followUpMedication = medication
    }

    private func checkPendingRandomCheckIn() {
        RandomCheckInManager.cleanupStale()
        guard followUpMedication == nil else { return }
        guard RandomCheckInManager.pendingCheckInIfDue() else { return }
        showingRandomCheckIn = true
    }
}

// MARK: - Backfill overlay

private struct BackfillOverlay: View {
    let coordinator: HealthDataCoordinator
    var body: some View {
        if coordinator.isBackfilling {
            VStack(spacing: 12) {
                ProgressView(value: Double(coordinator.backfillProgress),
                             total: Double(coordinator.backfillTotal))
                    .tint(.blue)
                Text("Loading health history… \(coordinator.backfillProgress)/\(coordinator.backfillTotal) days")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - App Group identifier

/// Centralized App Group discovery. The suite name and container URL are
/// derived from the provisioning profile's entitlement at runtime; this
/// namespace avoids hardcoding the team ID in source.
enum AppGroup {
    /// Must match the `com.apple.security.application-groups` entitlement
    /// value in the iOS, Watch, and Complication targets.
    static let identifier = "group.com.anxietywatch"

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) {
            return url
        }
#if targetEnvironment(simulator)
        // Simulator may not have the App Group provisioned — fall back
        // to a synthetic directory under the app's container.
        let fallback = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .deletingLastPathComponent()
            .appendingPathComponent("AppGroup-\(identifier)")
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
#else
        fatalError("App Group container '\(identifier)' not found. Check entitlements.")
#endif
    }
}

// MARK: - Keychain stub for node ID

/// Keychain persistence for the HLC node ID (Spec §2.1).
/// Replace with full Keychain wrapper from AnxietyWatchKit when T13a lands.
enum KeychainNodeID {
    private static let service = "com.anxietywatch.hlc.node"
    private static let account = "install"

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    static func store(_ data: Data) {
        // Delete any existing item first — upsert pattern.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
