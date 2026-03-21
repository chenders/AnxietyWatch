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
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    PhoneConnectivityManager.shared.modelContainer = sharedModelContainer
                    PhoneConnectivityManager.shared.activate()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
