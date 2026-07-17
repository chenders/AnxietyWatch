import Foundation

/// Centralized construction and wiring of all AnxietyWatchKit components.
///
/// Acts as the single root for the framework's object graph. Apps instantiate
/// one `DependencyContainer` at launch and hold it for the process lifetime.
///
/// ## Ordering
///
/// Construction is ordered so downstream components never reference an
/// uninitialized upstream:
///
/// 1. Storage layer: DatabaseManager → stores
/// 2. HLC + ClockSuspectGate
/// 3. Sync layer: SyncCoordinator, PanicProtocol
/// 4. Transport: WCSessionCoordinator, SyncEngine
/// 5. Compaction: RetentionCompactor, IdleDownsampler, CheckpointManager
///
/// Apps wire BLE adapters (PolarActor, EMAYActor, HealthKitAdapterActor) into
/// a `SensorRouter` and attach it to `CNSMonitoringCoordinator` separately —
/// they are not constructed here because they depend on platform-specific
/// entitlements (HealthKit, Bluetooth).
public struct DependencyContainer: Sendable {

    // MARK: - Storage

    public let database: DatabaseManager
    public let samplesStore: SamplesStore
    public let tombstonesStore: SampleTombstonesStore
    public let syncLogStore: SyncLogStore
    public let quarantineStore: QuarantineStore
    public let backfillProgressStore: BackfillProgressStore

    // MARK: - Sync

    public let hlc: HLC
    public let clockSuspect: ClockSuspectGate
    public let syncCoordinator: SyncCoordinator
    public let panicProtocol: PanicProtocol

    // MARK: - Transport

    public let transport: WCSessionCoordinator
    public let syncEngine: SyncEngine

    // MARK: - Compaction

    public let retentionCompactor: RetentionCompactor
    public let idleDownsampler: IdleDownsampler
    public let checkpointManager: CheckpointManager

    // MARK: - Oura (Phase 2)

    /// Optional Oura Ring integration service. Created on-demand after the
    /// user completes the OAuth2 flow and a token is available.
    /// Set via `configureOura(token:)`.
    public private(set) var ouraService: OuraService?

    // MARK: - Factory

    /// Builds the full object graph.
    ///
    /// - Parameters:
    ///   - dbURL: Full path to `tsdb.sqlite` in the App Group container.
    ///   - cursorFileURL: Full path to `sync_cursor.json` (same directory).
    ///   - nodeID: 16 raw bytes from Keychain (§2.1). Unique per device.
    ///   - endpoint: Server sync endpoint.
    ///   - session: WCSession wrapper. Defaults to `WCSession.default`.
    ///   - now: Injectable wall clock (for tests).
    ///   - monotonicNow: Injectable monotonic clock (for tests).
    public init(
        dbURL: URL,
        cursorFileURL: URL,
        nodeID: Data,
        endpoint: SyncEndpoint,
        session: WCSessionProtocol = WCSession.default,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        monotonicNow: @escaping @Sendable () -> Int64 = { HLC.defaultMonotonic() }
    ) {
        // 1. Storage
        let db = DatabaseManager(url: dbURL)
        database = db
        samplesStore = SamplesStore(database: db)
        tombstonesStore = SampleTombstonesStore(database: db)
        syncLogStore = SyncLogStore(database: db)
        quarantineStore = QuarantineStore(database: db)
        backfillProgressStore = BackfillProgressStore(database: db)

        // 2. HLC + clock gate
        let clock = HLC(nodeID: nodeID, now: now, monotonicNow: monotonicNow)
        hlc = clock
        clockSuspect = ClockSuspectGate(
            wallNow: now,
            monotonicNow: monotonicNow
        )

        // 3. Sync
        let syncDeps = SyncCoordinator.Dependencies(
            database: db,
            samples: samplesStore,
            tombstones: tombstonesStore,
            syncLog: syncLogStore,
            quarantine: quarantineStore,
            hlc: clock,
            clockSuspect: clockSuspect,
            endpoint: endpoint,
            cursorFileURL: cursorFileURL
        )
        syncCoordinator = SyncCoordinator(dependencies: syncDeps)

        let panicDeps = PanicProtocol.Dependencies(
            database: db,
            samples: samplesStore,
            tombstones: tombstonesStore,
            hlc: clock,
            syncOnceHook: { [syncCoordinator] in
                _ = try await syncCoordinator.syncOnce()
            }
        )
        panicProtocol = PanicProtocol(dependencies: panicDeps)

        // 4. Transport
        let wcsCoordinator = WCSessionCoordinator(session: session)
        transport = wcsCoordinator

        syncEngine = SyncEngine(
            database: db,
            hlc: clock,
            transport: wcsCoordinator
        )

        // 5. Compaction
        retentionCompactor = RetentionCompactor(database: db)
        idleDownsampler = IdleDownsampler(database: db)

        let markerURL = cursorFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".checkpoint_marker")
        checkpointManager = CheckpointManager(database: db, markerURL: markerURL)
    }

    // MARK: - Bootstrap

    /// Call once after construction. Registers `@Syncable` types, loads
    /// persisted cursors, and registers the corruption-recovery hook.
    public func bootstrap() async throws {
        try await syncCoordinator.bootstrap()
    }

    /// Registers HLC UDFs on the database. Must be called before any
    /// `@Syncable` table registration writes DDL triggers.
    public func registerUDFs() async throws {
        try await hlc.registerUDFs(on: database)
    }

    // MARK: - Lifecycle

    /// Graceful shutdown: stops background loops, runs a PASSIVE checkpoint,
    /// and closes the database (Spec §1.1 close flow).
    public mutating func shutdown() async {
        await syncEngine.stop()
        await ouraService?.stopPolling()

        do {
            _ = try await checkpointManager.run(mode: .passive)
            await database.close()
        } catch {
            Log.sync.error("Shutdown checkpoint/close failed: \(error)")
        }
    }

    // MARK: - Oura (Phase 2)

    /// Configure the Oura Ring integration after the user completes OAuth2.
    /// Creates the service on first call; subsequent calls update the token
    /// on the existing service.
    public mutating func configureOura(
        token: OuraTokenStore.Token,
        router: SensorRouter? = nil
    ) async {
        if ouraService == nil {
            ouraService = OuraService()
        }
        await ouraService?.configure(token: token)
        if let router {
            await ouraService?.startPolling(router: router)
        }
    }
}
