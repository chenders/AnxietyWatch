import SwiftData
import SwiftUI
import os

@main
struct AnxietyWatchApp: App {
    private let connectivity = WatchConnectivityManager.shared
    private let log = Logger(subsystem: "AnxietyWatch", category: "WatchApp")

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
        ])
        // Exclude the Watch store from iCloud backups — sensor-derived
        // health data (accelerometer spectrograms, HRV readings, breathing
        // rates) must not silently leak into the user's iCloud account.
        // Matches the iPhone-side exclusion.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let storeURL = appSupport.appendingPathComponent("default.store")
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])

            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true

            for suffix in ["", "-wal", "-shm"] {
                var fileURL = appSupport.appendingPathComponent("default.store\(suffix)")
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        try fileURL.setResourceValues(resourceValues)
                    } catch {
                        Logger(subsystem: "com.anxietywatch", category: "App").error("Failed to exclude \(fileURL.lastPathComponent) from backup: \(error.localizedDescription)")
                    }
                }
            }
            return container
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
            // Sensor capture is non-critical — app continues without it.
            // Log the error TYPE (not the error string, which could embed
            // sensor data) so a production failure isn't undiagnosable.
            log.error("Sensor capture start failed: \(String(describing: type(of: error)), privacy: .public)")
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
