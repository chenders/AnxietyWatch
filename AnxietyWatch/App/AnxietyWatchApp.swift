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
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var coordinator: HealthDataCoordinator?
    @Environment(\.scenePhase) private var scenePhase
    @State private var followUpDose: MedicationDose?
    @State private var followUpMedication: MedicationDefinition?

    // BGTask registration must happen before app finishes launching.
    init() {
        let coord = HealthDataCoordinator(modelContainer: sharedModelContainer)
        _coordinator = State(initialValue: coord)
        coord.registerBackgroundTask()

        // Set notification delegate so notifications show in foreground
        // and taps trigger the pending check-in/follow-up flow.
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        checkPendingFollowUp()
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
        }
        .modelContainer(sharedModelContainer)
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
