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
        //
        // Resolve-and-create the directory (a bare `urls(...).first!` can point
        // at a not-yet-created path and fail container init on a fresh install),
        // then exclude the directory itself so the SQLite `-wal`/`-shm` siblings
        // are covered whenever SQLite (re)creates them.
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
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            for suffix in ["", "-wal", "-shm"] {
                AnxietyWatchApp.excludeFromBackup(appSupport.appendingPathComponent("default.store\(suffix)"))
            }
            return container
        } catch {
            fatalError("Could not create watch ModelContainer: \(error)")
        }
    }()

    /// Sets `isExcludedFromBackup` on `url` if it exists, logging (not
    /// swallowing) any real failure. `setResourceValues` throws `ENOENT` for a
    /// missing path, so guard on existence first.
    private static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            Logger(subsystem: "AnxietyWatch", category: "WatchApp").error(
                "Failed to exclude \(target.lastPathComponent) from backup: \(error.localizedDescription)")
        }
    }

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
