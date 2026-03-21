import SwiftUI
import SwiftData

@main
struct AnxietyWatchApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var coordinator: HealthDataCoordinator?

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

                    let coord = HealthDataCoordinator(modelContainer: sharedModelContainer)
                    coordinator = coord
                    await coord.setupIfNeeded()
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
