import XCTest
import GRDB
@testable import AnxietyWatchKit

// MARK: - Mock endpoint

private final class MockSyncEndpoint: SyncEndpoint, @unchecked Sendable {
    private let lock = NSLock()

    var pullResponses: [SyncPullResponse] = []
    private(set) var pullCalls: [(cursor: TableCursors, maxBatchBytes: Int)] = []
    var pushResponse: SyncPushResponse?
    private(set) var pushCalls: [SyncPushPayload] = []

    let serverHLC = HLCStamped(physical: 1, logical: 0, nodeID: Data(repeating: 0x5E, count: 16))

    func pull(cursor: TableCursors, maxBatchBytes: Int) async throws -> SyncPullResponse {
        lock.lock()
        defer { lock.unlock() }
        pullCalls.append((cursor, maxBatchBytes))
        if pullResponses.isEmpty {
            return SyncPullResponse(
                samples: [], sampleTombstones: [], syncLog: [],
                nextCursor: cursor, serverHLC: serverHLC
            )
        }
        return pullResponses.removeFirst()
    }

    func push(payload: SyncPushPayload) async throws -> SyncPushResponse {
        lock.lock()
        defer { lock.unlock() }
        pushCalls.append(payload)
        guard let pushResponse else {
            throw SyncEndpointError.permanent("no scripted push response")
        }
        return pushResponse
    }
}

// MARK: - Manual Syncable fixture (bootstrap completeness)

private struct TestSyncableType: Syncable {
    static let syncDirection: SyncDirection = .upOnly
    static let syncTableName: String = "test_syncable"
    static let syncTriggerDDL: String = "-- none"
    static func registerForSync(_ registry: SyncRegistry) async {
        await registry.register(Self.self)
    }
}

// MARK: - Tests

final class SyncCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: DatabaseManager!
    private var endpoint: MockSyncEndpoint!
    private var gate: ClockSuspectGate!
    private var hlc: HLC!
    private var coordinator: SyncCoordinator!
    private var cursorURL: URL!

    /// Fixed local wall clock (ms since epoch) injected into the HLC.
    private let wall: Int64 = 1_000_000_000

    private let ourNode = Data(repeating: 0xAA, count: 16)
    private let peerNode = Data(repeating: 0xBB, count: 16)

    override func setUp() {
        super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let dbURL = tempDirectory.appendingPathComponent("test.db")
        cursorURL = tempDirectory.appendingPathComponent("sync_cursor.json")

        database = DatabaseManager(url: dbURL)
        endpoint = MockSyncEndpoint()
        gate = ClockSuspectGate()
        let localWall = wall
        hlc = HLC(nodeID: ourNode, now: { localWall }, monotonicNow: { 0 })

        let setupExpectation = expectation(description: "setup")
        Task {
            do {
                try await database.open()
                try await database.writer { db in
                    try SchemaV1.apply(to: db)
                }
                setupExpectation.fulfill()
            } catch {
                XCTFail("setup failed: \(error)")
                setupExpectation.fulfill()
            }
        }
        waitForExpectations(timeout: 10)

        coordinator = makeCoordinator()
    }

    override func tearDown() {
        SyncCoordinator.registeredSyncableTypes = []

        let teardownExpectation = expectation(description: "teardown")
        Task {
            await database.close()
            teardownExpectation.fulfill()
        }
        waitForExpectations(timeout: 10)

        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeCoordinator(gate: ClockSuspectGate? = nil) -> SyncCoordinator {
        SyncCoordinator(dependencies: .init(
            database: database,
            samples: SamplesStore(database: database),
            tombstones: SampleTombstonesStore(database: database),
            syncLog: SyncLogStore(database: database),
            quarantine: QuarantineStore(database: database),
            hlc: hlc,
            clockSuspect: gate ?? self.gate,
            endpoint: endpoint,
            cursorFileURL: cursorURL
        ))
    }

    private func makeSample(pt: Int64, lc: Int32 = 0, node: Data? = nil,
                            source: Int32 = 1, type: Int32 = 1, timestamp: Double = 100) -> SampleRow {
        SampleRow(source: source, type: type, timestamp: timestamp, value: 1.0, extra: nil,
                  hlcPhysical: pt, hlcLogical: lc, nodeID: node ?? peerNode)
    }

    private func pullResponse(samples: [SampleRow] = [],
                              tombstones: [SampleTombstoneRow] = [],
                              syncLog: [SyncLogEntry] = []) -> SyncPullResponse {
        SyncPullResponse(samples: samples, sampleTombstones: tombstones, syncLog: syncLog,
                         nextCursor: TableCursors(), serverHLC: endpoint.serverHLC)
    }

    private func loadCursorFile() throws -> SyncCursorStore.Persisted? {
        try SyncCursorStore(url: cursorURL).load()
    }

    // MARK: - Tests

    func testSyncOnceIsNoopOnFirstRunWithEmptyServer() async throws {
        try await coordinator.bootstrap()
        let result = try await coordinator.syncOnce()

        XCTAssertEqual(result, SyncCoordinator.SyncOnceResult(
            pulledSamples: 0, pulledTombstones: 0, pulledSyncLog: 0,
            pushedSamples: 0, pushedTombstones: 0, pushedSyncLog: 0
        ))
        XCTAssertTrue(endpoint.pushCalls.isEmpty, "nothing local to push — endpoint.push must not be called")
    }

    func testPullInsertsSamplesAndAdvancesCursorTransactionally() async throws {
        endpoint.pullResponses = [pullResponse(samples: [
            makeSample(pt: 500_000, lc: 0, timestamp: 100),
            makeSample(pt: 500_000, lc: 3, timestamp: 200),
        ])]

        try await coordinator.bootstrap()
        let result = try await coordinator.syncOnce()
        XCTAssertEqual(result.pulledSamples, 2)

        let count = try await SamplesStore(database: database).count()
        XCTAssertEqual(count, 2)

        let persisted = try XCTUnwrap(loadCursorFile())
        let watermark = persisted.pull.samples.watermark(for: peerNode)
        XCTAssertEqual(watermark.physical, 500_000)
        XCTAssertEqual(watermark.logical, 3)
    }

    func testPullQuarantinesDriftedRow() async throws {
        // One good row, one row > 24 h ahead of local wall — quarantined.
        let driftedPT = wall + 86_400_001
        endpoint.pullResponses = [pullResponse(samples: [
            makeSample(pt: 500_000, lc: 0, timestamp: 100),
            makeSample(pt: driftedPT, lc: 0, timestamp: 200),
        ])]

        try await coordinator.bootstrap()
        let result = try await coordinator.syncOnce()

        // Sync continues; only the good row applied.
        XCTAssertEqual(result.pulledSamples, 1)
        let samplesCount = try await SamplesStore(database: database).count()
        XCTAssertEqual(samplesCount, 1)

        let quarantine = QuarantineStore(database: database)
        let qCount = try await quarantine.count()
        XCTAssertEqual(qCount, 1)
        let qRows = try await quarantine.fetchAll()
        XCTAssertEqual(qRows.first?.hlcPhysical, driftedPT)
        XCTAssertEqual(qRows.first?.tableName, "samples")

        // Cursor must NOT advance past the quarantined HLC for that node —
        // otherwise the row is skipped forever on retry.
        let persisted = try XCTUnwrap(loadCursorFile())
        let watermark = persisted.pull.samples.watermark(for: peerNode)
        let watermarkStamp = HLCStamped(physical: watermark.physical, logical: watermark.logical, nodeID: peerNode)
        XCTAssertLessThan(watermarkStamp, HLCStamped(physical: driftedPT, logical: 0, nodeID: peerNode))
    }

    func testPullPersistsIncomingHLCNotLocalView() async throws {
        // Remote is 70 s ahead: within 24 h (no quarantine) but beyond the
        // 60 s bounded-merge cap — observe() returns a CLAMPED local view.
        let futurePT = wall + 70_000
        endpoint.pullResponses = [pullResponse(samples: [
            makeSample(pt: futurePT, lc: 7, timestamp: 100),
        ])]

        try await coordinator.bootstrap()
        _ = try await coordinator.syncOnce()

        let rows = try await SamplesStore(database: database)
            .fetch(source: 1, type: 1, from: 0, to: 1_000)
        XCTAssertEqual(rows.count, 1)
        // INCOMING HLC persisted verbatim — NOT observe()'s clamped view.
        XCTAssertEqual(rows.first?.hlcPhysical, futurePT)
        XCTAssertEqual(rows.first?.hlcLogical, 7)
        XCTAssertEqual(rows.first?.nodeID, peerNode)

        // And the local clock really was clamped (proves the local view would
        // have differed — the assertion above is not vacuous).
        let local = await hlc.currentLocal
        XCTAssertLessThanOrEqual(local.physical, wall + 60_000)
        XCTAssertLessThan(local.physical, futurePT)
    }

    func testPushSendsUnackedSyncLogRowsAndAdvancesCursor() async throws {
        // Seed local (our-node) rows.
        let samplesStore = SamplesStore(database: database)
        _ = try await samplesStore.insert([
            makeSample(pt: 42, lc: 0, node: ourNode, timestamp: 100)
        ])
        let syncLogStore = SyncLogStore(database: database)
        try await syncLogStore.upsert(SyncLogEntry(
            tableName: "journal", rowPK: "7",
            hlcPhysical: 43, hlcLogical: 0, nodeID: ourNode, operation: .upsert
        ))

        // Server ACKs everything up to (43, 0) for our node.
        var ack = TableCursors()
        ack.samples.advance(nodeID: ourNode, physical: 42, logical: 0)
        ack.syncLog.advance(nodeID: ourNode, physical: 43, logical: 0)
        endpoint.pushResponse = SyncPushResponse(ackCursor: ack, serverHLC: endpoint.serverHLC)

        try await coordinator.bootstrap()
        let result = try await coordinator.syncOnce()

        XCTAssertEqual(result.pushedSamples, 1)
        XCTAssertEqual(result.pushedTombstones, 0)
        XCTAssertEqual(result.pushedSyncLog, 1)

        XCTAssertEqual(endpoint.pushCalls.count, 1)
        XCTAssertEqual(endpoint.pushCalls.first?.samples.first?.hlcPhysical, 42)
        XCTAssertEqual(endpoint.pushCalls.first?.syncLog.first?.rowPK, "7")

        // Push cursor advanced to the server's ACK and persisted.
        let persisted = try XCTUnwrap(loadCursorFile())
        XCTAssertEqual(persisted.push, ack)

        // Second cycle: nothing left un-ACKed → no push call.
        let second = try await coordinator.syncOnce()
        XCTAssertEqual(second.pushedSamples, 0)
        XCTAssertEqual(endpoint.pushCalls.count, 1)
    }

    func testPushPausesWhenClockSuspect() async throws {
        // Force the gate suspect: huge divergence, zero sustain requirement.
        let suspectGate = ClockSuspectGate(
            wallNow: { 10_000_000 },
            monotonicNow: { 0 },
            setSustainedFor: 0
        )
        await suspectGate.sample()
        let isSuspect = await suspectGate.isSuspect
        XCTAssertTrue(isSuspect)

        coordinator = makeCoordinator(gate: suspectGate)

        // Local rows exist (would normally push) AND server has a pull row.
        _ = try await SamplesStore(database: database).insert([
            makeSample(pt: 42, lc: 0, node: ourNode, timestamp: 100)
        ])
        endpoint.pullResponses = [pullResponse(samples: [
            makeSample(pt: 500_000, lc: 0, timestamp: 200)
        ])]

        try await coordinator.bootstrap()
        let result = try await coordinator.syncOnce()

        // Pull still works; push fully paused.
        XCTAssertEqual(result.pulledSamples, 1)
        XCTAssertEqual(result.pushedSamples, 0)
        XCTAssertEqual(result.pushedTombstones, 0)
        XCTAssertEqual(result.pushedSyncLog, 0)
        XCTAssertTrue(endpoint.pushCalls.isEmpty)
    }

    func testCursorPersistedAcrossBootstrap() async throws {
        endpoint.pullResponses = [pullResponse(samples: [
            makeSample(pt: 500_000, lc: 2, timestamp: 100)
        ])]

        try await coordinator.bootstrap()
        _ = try await coordinator.syncOnce()

        // Rebuild a fresh coordinator from the same disk state.
        let rebuilt = makeCoordinator()
        try await rebuilt.bootstrap()
        _ = try await rebuilt.syncOnce()

        // The second pull must carry the advanced cursor, not a fresh one.
        XCTAssertEqual(endpoint.pullCalls.count, 2)
        let secondCursor = try XCTUnwrap(endpoint.pullCalls.last?.cursor)
        let watermark = secondCursor.samples.watermark(for: peerNode)
        XCTAssertEqual(watermark.physical, 500_000)
        XCTAssertEqual(watermark.logical, 2)
    }

    func testFullRestoreOnPostRecoveryHook() async throws {
        // Establish a non-empty cursor first so the reset is observable.
        endpoint.pullResponses = [pullResponse(samples: [
            makeSample(pt: 500_000, lc: 0, timestamp: 100)
        ])]
        try await coordinator.bootstrap()
        _ = try await coordinator.syncOnce()

        try await coordinator.fullRestore()

        // fullRestore must pull from the very beginning: empty TableCursors.
        XCTAssertEqual(endpoint.pullCalls.count, 2)
        XCTAssertEqual(endpoint.pullCalls.last?.cursor, TableCursors())
    }

    func testCursorNotAdvancedIfInsertFails() async throws {
        endpoint.pullResponses = [pullResponse(samples: [
            makeSample(pt: 500_000, lc: 0, timestamp: 100)
        ])]

        try await coordinator.bootstrap()

        // Sabotage the batch insert: the writer transaction must throw.
        try await database.writer { db in
            try db.execute(sql: "DROP TABLE samples")
        }

        do {
            _ = try await coordinator.syncOnce()
            XCTFail("Expected syncOnce to throw when the insert transaction fails")
        } catch {
            // expected
        }

        // Cursor file must NOT have been written.
        XCTAssertNil(try loadCursorFile())
    }

    func testBootstrapCompletenessCatchesForgottenType() async throws {
        // INDEPENDENT completeness gate (T16 forward-note). This set is
        // hardcoded on purpose — it must NOT be derived from
        // SyncCoordinator.registeredSyncableTypes, or the check is circular.
        // Every production @Syncable type in AnxietyWatchKit MUST appear here
        // AND in registeredSyncableTypes; updating only one fails this test,
        // which is the point.
        let expected: Set<String> = [
            // Populate with the actual snake_case syncTableName values.
            // Currently no production @Syncable types exist beyond test fixtures.
        ]

        try await coordinator.bootstrap()
        let actual = Set(await coordinator.registeredSyncTables())

        XCTAssertEqual(actual, expected,
                       "New @Syncable type not registered; add to registeredSyncableTypes AND update this test's expected set.")
    }

    func testBootstrapRegistrationMechanicsWork() async throws {
        // Mechanics (not completeness): a type placed in the manual list ends
        // up in the registry after bootstrap.
        SyncCoordinator.registeredSyncableTypes = [TestSyncableType.self]

        try await coordinator.bootstrap()
        let tables = await coordinator.registeredSyncTables()
        XCTAssertTrue(tables.contains("test_syncable"))
    }

    func testFullRestoreDrainsMultipleServerPages() async throws {
        // Three pages of history, then the server is empty. A single-page
        // fullRestore would leave the post-recovery DB permanently partial.
        endpoint.pullResponses = [
            pullResponse(samples: [makeSample(pt: 100, lc: 0, timestamp: 1)]),
            pullResponse(samples: [makeSample(pt: 200, lc: 0, timestamp: 2)]),
            pullResponse(samples: [makeSample(pt: 300, lc: 0, timestamp: 3)]),
        ]

        try await coordinator.bootstrap()
        try await coordinator.fullRestore()

        // All three pages applied locally.
        let count = try await SamplesStore(database: database).count()
        XCTAssertEqual(count, 3)

        // 3 data pages + 1 terminating empty page.
        XCTAssertEqual(endpoint.pullCalls.count, 4)

        let persisted = try XCTUnwrap(loadCursorFile())
        XCTAssertEqual(persisted.pull.samples.watermark(for: peerNode).physical, 300)
    }

    func testPullOfUnregisteredTableIsIgnoredWithWarning() async throws {
        // No types registered — a CRUD delta for an unknown table must be
        // ignored (warned), not applied and not fatal.
        endpoint.pullResponses = [pullResponse(syncLog: [
            SyncLogEntry(tableName: "not_registered", rowPK: "1",
                         hlcPhysical: 500_000, hlcLogical: 0, nodeID: peerNode, operation: .upsert)
        ])]

        try await coordinator.bootstrap()
        let result = try await coordinator.syncOnce()

        XCTAssertEqual(result.pulledSyncLog, 0, "ignored entries must not count as applied")
        let logCount = try await SyncLogStore(database: database).count()
        XCTAssertEqual(logCount, 0)

        // Cursor still advances past the ignored entry so the pull can't stall.
        let persisted = try XCTUnwrap(loadCursorFile())
        XCTAssertEqual(persisted.pull.syncLog.watermark(for: peerNode).physical, 500_000)
    }

    func testPullReplacesLowerHLCSamples() async throws {
        // Local row at HLC 100; remote same (source,type,timestamp) at HLC 200
        // — LWW: the remote value must replace.
        _ = try await SamplesStore(database: database).insert([
            SampleRow(source: 1, type: 1, timestamp: 100, value: 1.0, extra: nil,
                      hlcPhysical: 100, hlcLogical: 0, nodeID: ourNode)
        ])
        endpoint.pullResponses = [pullResponse(samples: [
            SampleRow(source: 1, type: 1, timestamp: 100, value: 9.9, extra: nil,
                      hlcPhysical: 200, hlcLogical: 0, nodeID: peerNode)
        ])]

        try await coordinator.bootstrap()
        _ = try await coordinator.syncOnce()

        let rows = try await SamplesStore(database: database).fetch(source: 1, type: 1, from: 0, to: 1_000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.value, 9.9)
        XCTAssertEqual(rows.first?.hlcPhysical, 200)
        XCTAssertEqual(rows.first?.nodeID, peerNode)
    }

    func testPullDoesNotReplaceHigherHLCSamples() async throws {
        // Local row at HLC 200; remote same PK at HLC 100 — local must win.
        _ = try await SamplesStore(database: database).insert([
            SampleRow(source: 1, type: 1, timestamp: 100, value: 1.0, extra: nil,
                      hlcPhysical: 200, hlcLogical: 0, nodeID: ourNode)
        ])
        endpoint.pullResponses = [pullResponse(samples: [
            SampleRow(source: 1, type: 1, timestamp: 100, value: 9.9, extra: nil,
                      hlcPhysical: 100, hlcLogical: 0, nodeID: peerNode)
        ])]
        // The surviving local (our-node) row gets pushed — script an ACK.
        var ack = TableCursors()
        ack.samples.advance(nodeID: ourNode, physical: 200, logical: 0)
        endpoint.pushResponse = SyncPushResponse(ackCursor: ack, serverHLC: endpoint.serverHLC)

        try await coordinator.bootstrap()
        _ = try await coordinator.syncOnce()

        let rows = try await SamplesStore(database: database).fetch(source: 1, type: 1, from: 0, to: 1_000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.value, 1.0)
        XCTAssertEqual(rows.first?.hlcPhysical, 200)
        XCTAssertEqual(rows.first?.nodeID, ourNode)
    }

    func testPushClampsOverreachingAckCursor() async throws {
        // We push one sample at HLC 42, but the server ACKs up to 99_999.
        // Trusting it would skip every un-pushed local row below 99_999.
        _ = try await SamplesStore(database: database).insert([
            makeSample(pt: 42, lc: 0, node: ourNode, timestamp: 100)
        ])
        var overreachingAck = TableCursors()
        overreachingAck.samples.advance(nodeID: ourNode, physical: 99_999, logical: 0)
        endpoint.pushResponse = SyncPushResponse(ackCursor: overreachingAck, serverHLC: endpoint.serverHLC)

        try await coordinator.bootstrap()
        let result = try await coordinator.syncOnce()
        XCTAssertEqual(result.pushedSamples, 1)

        // Persisted push cursor capped to the actually-sent maximum (42).
        let persisted = try XCTUnwrap(loadCursorFile())
        let watermark = persisted.push.samples.watermark(for: ourNode)
        XCTAssertEqual(watermark.physical, 42)
        XCTAssertEqual(watermark.logical, 0)
    }
}
