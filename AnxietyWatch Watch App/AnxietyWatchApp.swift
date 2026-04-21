import SwiftData
import SwiftUI

@main
struct AnxietyWatchApp: App {
    private let connectivity = WatchConnectivityManager.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create watch ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            TabView {
                QuickLogView()
                CurrentStatsView()
            }
            .onAppear {
                connectivity.activate()
            }
            .task {
                await startSensorCapture()
            }
        }
        .modelContainer(sharedModelContainer)
    }

    private func startSensorCapture() async {
        do {
            try await SensorCaptureSession.shared.start(modelContainer: sharedModelContainer)
        } catch {
            // Sensor capture is non-critical — app continues without it
            return
        }

        // Periodic flush: save pending sensor data every 60 seconds
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
                let context = ModelContext(sharedModelContainer)
                try await SensorCaptureSession.shared.flushPending(to: context)
                connectivity.transferSensorData(modelContainer: sharedModelContainer)
            } catch is CancellationError {
                break
            } catch {
                // Transient flush failure — continue; next iteration will retry
            }
        }
    }
}
