import BackgroundTasks
import SwiftUI
import SwiftData

@main
struct AnxietyWatchApp: App {
    /// Versioned key for one-time medication reactivation fixup.
    private static let reactivateMedsKey = "didFixReactivateMeds_v1"

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
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var coordinator: HealthDataCoordinator?

    // BGTask registration must happen before app finishes launching.
    init() {
        let coord = HealthDataCoordinator(modelContainer: sharedModelContainer)
        _coordinator = State(initialValue: coord)
        coord.registerBackgroundTask()
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
                            // Leave flag unset so we retry on next launch
                            print("ReactivateMeds fixup failed: \(error)")
                        }
                    }

                    guard let coord = coordinator else { return }
                    await coord.setupIfNeeded()
                    coord.scheduleBackgroundRefresh()
                }
        }
        .modelContainer(sharedModelContainer)
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
