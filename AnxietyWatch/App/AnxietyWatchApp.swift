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
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var coordinator: HealthDataCoordinator?
    @State private var polarService: PolarHRMService
    @Environment(\.scenePhase) private var scenePhase
    @State private var followUpDose: MedicationDose?
    @State private var followUpMedication: MedicationDefinition?
    @State private var showingRandomCheckIn = false
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

        // Set notification delegate so notifications show in foreground
        // and taps trigger the pending check-in/follow-up flow.
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(polarService)
                .overlay {
                    if let coordinator, coordinator.isBackfilling {
                        backfillOverlay(coordinator)
                    }
                }
                .task {
                    PhoneConnectivityManager.shared.modelContainer = sharedModelContainer
                    PhoneConnectivityManager.shared.activate()

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

                    // Don't await — let gap fill and observer setup run in background
                    // while the dashboard renders immediately with cached data.
                    // @Query properties react to SwiftData changes automatically.
                    guard let coord = coordinator else { return }
                    Task { await coord.setupIfNeeded() }
                    coord.scheduleBackgroundRefresh()

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

        if let range = outcome.cpapRange {
            await backfillSnapshots(dateRange: range, context: ModelContext(container))
        }
    }

    private struct ImportBatchOutcome: Sendable {
        let results: [MultiFileImportAlert.PerFileResult]
        let errors: [MultiFileImportAlert.PerFileError]
        let cpapRange: ClosedRange<Date>?
    }

    /// Pure import work — parses each URL into the given container's store and
    /// returns per-file results and the union of CPAP date ranges. Marked
    /// `nonisolated static` so it can run inside a detached task without
    /// capturing `self` or any actor-isolated state.
    ///
    /// Uses a fresh `ModelContext` per file so a failed import (which may
    /// leave pending inserts in its context after throwing) cannot leak into
    /// the next file's successful `save()`. Each file is its own transaction.
    private nonisolated static func runImports(
        urls: [URL],
        in container: ModelContainer
    ) -> ImportBatchOutcome {
        var results: [MultiFileImportAlert.PerFileResult] = []
        var errors: [MultiFileImportAlert.PerFileError] = []
        var cpapRange: ClosedRange<Date>?

        for url in urls {
            let filename = url.lastPathComponent
            let context = ModelContext(container)
            do {
                let result = try CSVImportRouter.importCSV(from: url, into: context)
                results.append(.init(filename: filename, result: result))
                if result.kind == .cpap, let range = result.dateRange {
                    if let existing = cpapRange {
                        let lower = min(existing.lowerBound, range.lowerBound)
                        let upper = max(existing.upperBound, range.upperBound)
                        cpapRange = lower...upper
                    } else {
                        cpapRange = range
                    }
                }
            } catch let error as CSVImportRouter.ImportError {
                errors.append(.init(filename: filename, message: error.alertMessage))
            } catch {
                errors.append(.init(filename: filename, message: error.localizedDescription))
            }
        }
        return ImportBatchOutcome(results: results, errors: errors, cpapRange: cpapRange)
    }

    @MainActor
    private func backfillSnapshots(dateRange: ClosedRange<Date>, context: ModelContext) async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )
        var date = dateRange.lowerBound
        while date <= dateRange.upperBound {
            do {
                try await aggregator.aggregateDay(date)
            } catch {
                Log.data.error("Backfill snapshot failed for \(date.formatted(.dateTime.month().day()), privacy: .public): \(error, privacy: .public)")
            }
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? dateRange.upperBound.addingTimeInterval(1)
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

    private func backfillOverlay(_ coordinator: HealthDataCoordinator) -> some View {
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
