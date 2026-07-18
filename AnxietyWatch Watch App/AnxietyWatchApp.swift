import SwiftData
import SwiftUI
import WatchKit
import os
import AnxietyWatchKit

// MARK: - WKExtensionDelegate (lifecycle)

/// Handles watchOS lifecycle events that the SwiftUI `App` scene-phase
/// observer cannot: `applicationWillResignActive`→close, background-refresh
/// task budget, and extended-runtime invalidation.
final class WatchAppDelegate: NSObject, WKExtensionDelegate {

    /// Captured during bootstrap so the delegate can drive the close flow
    /// (Spec §1.1) without threading a reference through the SwiftUI hierarchy.
    var kit: DependencyContainer?
    var complicationFeed: ComplicationFeedService?

    func applicationWillResignActive() {
        // Spec §1.1 close flow: checkpoint + close. The delegate fires
        // BEFORE suspension — we have a bounded window (~2 s wall clock) to
        // flush. Do not await long-running work here; checkpoint and close
        // are synchronous.
        guard var kit else { return }
        Task {
            await complicationFeed?.stop()
            await kit.shutdown()
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refreshTask as WKApplicationRefreshBackgroundTask:
                // Reschedule for the next slot (Spec §6.1). Actual sync
                // work happens via BGTask/URLSession on the phone side;
                // the watch's refresh budget only covers scheduling.
                refreshTask.setTaskCompletedWithSnapshot(false)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

// MARK: - App entry point

@main
struct AnxietyWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchAppDelegate.self) var extensionDelegate

    private let log = Logger(subsystem: "AnxietyWatch", category: "WatchApp")

    // MARK: - SwiftData (existing, Phase 2A dual-write)

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
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

    private static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try target.setResourceValues(values) }
        catch {
            Logger(subsystem: "AnxietyWatch", category: "WatchApp").error(
                "Failed to exclude \(target.lastPathComponent) from backup: \(error.localizedDescription)")
        }
    }

    // MARK: - AnxietyWatchKit (v3 framework)

    /// Constructed once and shared with the delegate for the close flow.
    /// Provides the SQLite database, HLC, and stores. The transport layer
    /// (SyncEngine + WCSessionCoordinator) is NOT started yet — watchOS can
    /// only have one WCSession delegate, and the existing
    /// WatchConnectivityManager holds that role during Phase 2A dual-write.
    /// P2P sync will be wired when the delegate migration is complete.
    @State private var kit: DependencyContainer?

    /// Complication cache writer for watch face updates.
    private let complicationFeed = ComplicationFeedService()

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            TabView {
                QuickLogView()
                CurrentStatsView()
            }
            .task {
                await bootstrapKit()
                await startSensorCapture()
            }
        }
        .modelContainer(sharedModelContainer)
    }

    // MARK: - Kit bootstrap

    /// Constructs the v3 object graph, wires the delegate, and starts
    /// complication feed from HealthKit.
    @MainActor
    private func bootstrapKit() async {
        guard kit == nil else { return }

        let appGroup = WatchAppGroup.containerURL
        let dbURL = appGroup.appendingPathComponent("tsdb.sqlite")
        let cursorFileURL = appGroup.appendingPathComponent("sync_cursor.json")

        Self.excludeFromBackup(dbURL)
        Self.excludeFromBackup(appGroup.appendingPathComponent("tsdb.sqlite-wal"))
        Self.excludeFromBackup(appGroup.appendingPathComponent("tsdb.sqlite-shm"))

        // Node ID from Keychain, generated on first launch (§2.1).
        let nodeID: Data
        if let existing = WatchKeychainNodeID.load() {
            nodeID = existing
        } else {
            let generated = withUnsafeBytes(of: UUID().uuid) { Data($0) }
            WatchKeychainNodeID.store(generated)
            nodeID = generated
        }

        // Use a no-op sync endpoint for now — the watch primarily does P2P
        // sync through WCSession. Server sync can be added in Phase 2C.
        let endpoint = NoOpSyncEndpoint()

        let container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorFileURL,
            nodeID: nodeID,
            endpoint: endpoint
        )
        kit = container
        extensionDelegate.kit = container

        do {
            try await container.registerUDFs()
            try await container.bootstrap()
        } catch {
            Log.sync.error("Watch kit bootstrap failed: \(error)")
        }

        // P2P transport loop is NOT started on watchOS during Phase 2A —
        // the existing WatchConnectivityManager owns the WCSession delegate
        // slot. syncEngine will be activated in Phase 2B when the delegate
        // migration to AnxietyWatchKit's WCSessionCoordinator is complete.

        // Schedule background refresh (Spec §6.1).
        WKExtension.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: nil
        ) { error in
            if let error {
                Log.sync.error("Background refresh schedule failed: \(error.localizedDescription)")
            }
        }

        // ── Complication feed ──────────────────────────────────────
        // Create a HealthKit-only SensorRouter for watch face updates.
        // The watch reads vitals from HealthKit (Apple Watch sensors) and
        // publishes them to the App Group plist for the Complication
        // Extension to display.
        let hkAdapter = HealthKitAdapterActor()
        let watchRouter = SensorRouter(polar: nil, emay: nil, healthKit: hkAdapter)
        await complicationFeed.start(router: watchRouter)
        extensionDelegate.complicationFeed = complicationFeed
    }

    // MARK: - Sensor capture

    private func startSensorCapture() async {
        do {
            try await SensorCaptureSession.shared.start(modelContainer: sharedModelContainer)
        } catch {
            log.error("Sensor capture start failed: \(String(describing: type(of: error)), privacy: .public)")
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
                let context = ModelContext(sharedModelContainer)
                try await SensorCaptureSession.shared.flushPending(to: context)
                // Transfer via the existing WatchConnectivityManager for now
                // (Phase 2A — SwiftData rows still need their own path).
                WatchConnectivityManager.shared.transferSensorData(modelContainer: sharedModelContainer)
            } catch is CancellationError {
                break
            } catch {
                // Transient flush failure — continue; next iteration retries.
            }
        }
    }
}

// MARK: - App Group (watchOS)

/// Centralized App Group discovery for the watch side. Must match the
/// entitlement in the Watch App and Complication targets.
enum WatchAppGroup {
    static let identifier = AppGroupIdentifier.value

    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            fatalError("Watch App Group container '\(identifier)' not found. Check entitlements.")
        }
        return url
    }
}

// MARK: - Keychain stub (watchOS)

enum WatchKeychainNodeID {
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

// MARK: - No-op sync endpoint (Phase 2C placeholder)

/// A sync endpoint that always returns empty responses. The watch primarily
/// does direct P2P sync through WCSession; server sync is added in Phase 2C
/// when the backend delta endpoints are live.
struct NoOpSyncEndpoint: SyncEndpoint {
    func pull(cursor: TableCursors, maxBatchBytes: Int) async throws -> SyncPullResponse {
        SyncPullResponse(
            samples: [],
            sampleTombstones: [],
            syncLog: [],
            nextCursor: cursor,
            serverHLC: HLCStamped(physical: 0, logical: 0, nodeID: Data(repeating: 0, count: 16))
        )
    }
    func push(payload: SyncPushPayload) async throws -> SyncPushResponse {
        SyncPushResponse(
            ackCursor: TableCursors(),
            serverHLC: HLCStamped(physical: 0, logical: 0, nodeID: Data(repeating: 0, count: 16))
        )
    }
}
