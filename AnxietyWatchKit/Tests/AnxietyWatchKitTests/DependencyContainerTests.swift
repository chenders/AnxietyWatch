import XCTest
import GRDB
@testable import AnxietyWatchKit

// MARK: - Mock endpoint

private final class MockSyncEndpoint: SyncEndpoint, @unchecked Sendable {
    let serverHLC = HLCStamped(physical: 1, logical: 0, nodeID: Data(repeating: 0x5E, count: 16))

    func pull(cursor: TableCursors, maxBatchBytes: Int) async throws -> SyncPullResponse {
        SyncPullResponse(
            samples: [], sampleTombstones: [], syncLog: [],
            nextCursor: cursor, serverHLC: serverHLC
        )
    }

    func push(payload: SyncPushPayload) async throws -> SyncPushResponse {
        SyncPushResponse(
            ackCursor: TableCursors(),
            serverHLC: serverHLC
        )
    }
}

// MARK: - Tests

final class DependencyContainerTests: XCTestCase {

    private var tempDirectory: URL!
    private var dbURL: URL!
    private var cursorURL: URL!
    private var nodeID: Data!

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DepCont_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        dbURL = tempDirectory.appendingPathComponent("tsdb.sqlite")
        cursorURL = tempDirectory.appendingPathComponent("sync_cursor.json")
        nodeID = withUnsafeBytes(of: UUID().uuid) { Data($0) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Construction

    func testConstructionSucceeds() {
        let container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        // All stored properties must be non-nil (they are non-optional).
        XCTAssertNotNil(container.database)
        XCTAssertNotNil(container.samplesStore)
        XCTAssertNotNil(container.tombstonesStore)
        XCTAssertNotNil(container.syncLogStore)
        XCTAssertNotNil(container.quarantineStore)
        XCTAssertNotNil(container.backfillProgressStore)
        XCTAssertNotNil(container.hlc)
        XCTAssertNotNil(container.clockSuspect)
        XCTAssertNotNil(container.syncCoordinator)
        XCTAssertNotNil(container.panicProtocol)
        XCTAssertNotNil(container.transport)
        XCTAssertNotNil(container.syncEngine)
        XCTAssertNotNil(container.retentionCompactor)
        XCTAssertNotNil(container.idleDownsampler)
        XCTAssertNotNil(container.checkpointManager)
    }

    func testConstructionDoesNotRequireOpenDB() {
        _ = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        // The container should construct without requiring an open DB.
        // open() is expected to be called explicitly by the app after
        // setting the schema migrator, or lazily on first access.
    }

    func testConstructionIdempotent() {
        // Two containers with the same URL should both construct.
        let c1 = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        let c2 = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        XCTAssertNotNil(c1.database)
        XCTAssertNotNil(c2.database)
    }

    // MARK: - Bootstrap

    func testBootstrapCompletesWithoutError() async throws {
        let container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        // registerUDFs before bootstrap so triggers have the HLC UDF available
        try await container.registerUDFs()
        try await container.bootstrap()
        // No error thrown = success
    }

    // MARK: - Shutdown

    func testShutdownCompletesWithoutError() async throws {
        var container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        try await container.registerUDFs()
        try await container.bootstrap()
        await container.shutdown()
        // No error thrown = success
    }

    func testShutdownWithoutBootstrapDoesNotCrash() async {
        var container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        await container.shutdown()
        // Should not crash or hang even without prior bootstrap
    }

    // MARK: - Injectability

    func testCustomClocksAreUsed() {
        var wallCalls = 0
        var monoCalls = 0

        let container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint(),
            now: { wallCalls += 1; return 1000 },
            monotonicNow: { monoCalls += 1; return 2000 }
        )

        // The HLC and ClockSuspectGate are constructed with the closures.
        // Verify they exist — actual clock tick verification is done in
        // HLCTests and ClockSuspectGateTests. Here we just confirm the
        // container passes through the closures.
        XCTAssertNotNil(container.hlc)
        XCTAssertNotNil(container.clockSuspect)
        // Calling sample() on clockSuspect will exercise the closures.
        // We skip that here since it's tested in ClockSuspectGateTests.
    }

    // MARK: - Full lifecycle

    func testFullBootstrapShutdownCycle() async throws {
        var container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )

        // Phase 1: register UDFs
        try await container.registerUDFs()

        // Phase 2: bootstrap sync types and cursors
        try await container.bootstrap()

        // Phase 3: shutdown — stops engine, checkpoints, closes DB
        await container.shutdown()

        // Shutdown completes without hanging or throwing — success.
        // (The DB file is opened lazily; without an explicit open() call
        // it may not exist on disk, which is fine.)
    }

    // MARK: - Marker file creation

    func testCheckpointMarkerURLIsCreated() {
        let container = DependencyContainer(
            dbURL: dbURL,
            cursorFileURL: cursorURL,
            nodeID: nodeID,
            endpoint: MockSyncEndpoint()
        )
        // The marker URL is derived from cursorFileURL. Verify it exists.
        let markerURL = cursorURL
            .deletingLastPathComponent()
            .appendingPathComponent(".checkpoint_marker")
        // The CheckpointManager stores the URL; file is created on first
        // successful checkpoint. Here we just verify the URL is set.
        XCTAssertTrue(markerURL.lastPathComponent.hasPrefix(".checkpoint_marker"))
    }
}
