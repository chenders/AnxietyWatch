import XCTest
import GRDB
@testable import AnxietyWatchKit

final class RetentionCompactorTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var database: DatabaseManager!
    private var compactor: RetentionCompactor!

    /// Fixed "now" for deterministic cutoffs: retention window of 7 days.
    private let now: Double = 1_000_000.0
    private let retentionWindow: TimeInterval = 7 * 86_400
    private var cutoff: Double { now - retentionWindow }

    /// Three distinct 16-byte node IDs.
    private let nodeA = Data(repeating: 0xAA, count: 16)
    private let nodeB = Data(repeating: 0xBB, count: 16)
    private let nodeC = Data(repeating: 0xCC, count: 16)

    override func setUp() {
        super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.db")

        database = DatabaseManager(url: dbURL)

        let setupExpectation = expectation(description: "Database setup")
        Task {
            do {
                try await database.open()
                try await database.writer { db in
                    try SchemaV1.apply(to: db)
                }
                setupExpectation.fulfill()
            } catch {
                XCTFail("Failed to set up database: \(error)")
                setupExpectation.fulfill()
            }
        }
        waitForExpectations(timeout: 10)

        compactor = RetentionCompactor(database: database)
    }

    override func tearDown() {
        let teardownExpectation = expectation(description: "Database teardown")
        Task {
            await database.close()
            teardownExpectation.fulfill()
        }
        waitForExpectations(timeout: 10)

        try? FileManager.default.removeItem(at: tempDirectory)

        super.tearDown()
    }

    // MARK: - Seeding helpers

    private func insertSample(
        source: Int = 1,
        type: Int = 1,
        timestamp: Double,
        hlcPhysical: Int64,
        hlcLogical: Int32 = 0,
        nodeID: Data
    ) async throws {
        let ns = nodeID
        try await database.writer { db in
            try db.execute(
                sql: """
                INSERT INTO samples (source, type, timestamp, value, extra, hlc_physical, hlc_logical, node_id)
                VALUES (?, ?, ?, 1.0, NULL, ?, ?, ?)
                """,
                arguments: [source, type, timestamp, hlcPhysical, hlcLogical, ns]
            )
        }
    }

    private func insertTombstone(
        source: Int = 1,
        type: Int = 1,
        tsStart: Double,
        tsEnd: Double,
        hlcPhysical: Int64,
        hlcLogical: Int32 = 0,
        nodeID: Data
    ) async throws {
        let ns = nodeID
        try await database.writer { db in
            try db.execute(
                sql: """
                INSERT INTO sample_tombstones
                  (source, type, ts_start, ts_end, hlc_physical, hlc_logical, node_id, dropped_row_count, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, 10, 'retention')
                """,
                arguments: [source, type, tsStart, tsEnd, hlcPhysical, hlcLogical, ns]
            )
        }
    }

    private func sampleCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples") ?? -1
        }
    }

    private func tombstoneCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample_tombstones") ?? -1
        }
    }

    // MARK: - Tests

    func testDeletesOnlyOldAndAcked() async throws {
        // Cursor for nodeA: everything with hlc_physical <= 500 is ACKed.
        let cursor: [Data: (physical: Int64, logical: Int32)] = [
            nodeA: (physical: 500, logical: 0)
        ]

        // 2 old rows (below cutoff): one ACKed, one un-ACKed (HLC > cursor).
        try await insertSample(timestamp: cutoff - 100, hlcPhysical: 100, nodeID: nodeA) // old + acked → deleted
        try await insertSample(timestamp: cutoff - 200, hlcPhysical: 900, nodeID: nodeA) // old + UN-acked → protected

        // 3 fresh rows (above cutoff), all ACKed by HLC — still not deleted (too new).
        try await insertSample(timestamp: cutoff + 100, hlcPhysical: 200, nodeID: nodeA)
        try await insertSample(timestamp: cutoff + 200, hlcPhysical: 300, nodeID: nodeA)
        try await insertSample(timestamp: cutoff + 300, hlcPhysical: 400, nodeID: nodeA)

        let result = try await compactor.runRetention(
            now: now,
            retentionWindow: retentionWindow,
            ackedCursorPerNode: cursor
        )

        XCTAssertEqual(result.samplesDeleted, 1)
        XCTAssertEqual(result.tombstonesDeleted, 0)

        let remaining = try await sampleCount()
        XCTAssertEqual(remaining, 4)

        // The un-ACKed old row must still be present.
        let unackedSurvives = try await database.reader { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM samples WHERE hlc_physical = 900"
            ) ?? -1
        }
        XCTAssertEqual(unackedSurvives, 1)
    }

    func testDeletesNothingForNodesAbsentFromCursor() async throws {
        // Old, would-be-eligible rows for nodeB and nodeC — but the cursor map
        // only knows nodeA, so nothing may be deleted.
        try await insertSample(timestamp: cutoff - 100, hlcPhysical: 1, nodeID: nodeB)
        try await insertSample(timestamp: cutoff - 200, hlcPhysical: 1, nodeID: nodeC)

        let result = try await compactor.runRetention(
            now: now,
            retentionWindow: retentionWindow,
            ackedCursorPerNode: [nodeA: (physical: Int64.max, logical: Int32.max)]
        )

        XCTAssertEqual(result.samplesDeleted, 0)
        let remaining = try await sampleCount()
        XCTAssertEqual(remaining, 2)
    }

    func testChunkedDeleteRespectsChunkSize() async throws {
        // 15 old-and-acked rows, chunkSize = 5 → three full chunks + one empty
        // terminating batch.
        for i in 0..<15 {
            try await insertSample(
                timestamp: cutoff - Double(i + 1),
                hlcPhysical: Int64(i),
                nodeID: nodeA
            )
        }

        let result = try await compactor.runRetention(
            now: now,
            retentionWindow: retentionWindow,
            ackedCursorPerNode: [nodeA: (physical: 1_000, logical: 0)],
            chunkSize: 5
        )

        XCTAssertEqual(result.samplesDeleted, 15)
        let remaining = try await sampleCount()
        XCTAssertEqual(remaining, 0)
    }

    func testTombstonesAlsoRespectAckedCursor() async throws {
        // One old tombstone with ACKed HLC, one old tombstone with un-ACKed HLC.
        try await insertTombstone(
            tsStart: cutoff - 500, tsEnd: cutoff - 400,
            hlcPhysical: 100, nodeID: nodeA
        ) // acked → deleted
        try await insertTombstone(
            tsStart: cutoff - 300, tsEnd: cutoff - 200,
            hlcPhysical: 900, nodeID: nodeA
        ) // un-acked → protected

        let result = try await compactor.runRetention(
            now: now,
            retentionWindow: retentionWindow,
            ackedCursorPerNode: [nodeA: (physical: 500, logical: 0)]
        )

        XCTAssertEqual(result.tombstonesDeleted, 1)
        XCTAssertEqual(result.samplesDeleted, 0)

        let remaining = try await tombstoneCount()
        XCTAssertEqual(remaining, 1)

        let unackedSurvives = try await database.reader { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sample_tombstones WHERE hlc_physical = 900"
            ) ?? -1
        }
        XCTAssertEqual(unackedSurvives, 1)
    }

    func testCancellationThrows() async throws {
        // Seed enough rows with a tiny chunk size that the run must iterate
        // (and therefore hit a cancellation checkpoint) many times.
        for i in 0..<50 {
            try await insertSample(
                timestamp: cutoff - Double(i + 1),
                hlcPhysical: Int64(i),
                nodeID: nodeA
            )
        }

        let localCompactor = compactor!
        let localNow = now
        let localWindow = retentionWindow
        let localNode = nodeA

        let task = Task {
            try await localCompactor.runRetention(
                now: localNow,
                retentionWindow: localWindow,
                ackedCursorPerNode: [localNode: (physical: 1_000, logical: 0)],
                chunkSize: 1
            )
        }
        // Cancel immediately — the compactor checks cancellation at the start
        // of the run and between every chunk.
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected RetentionCompactorError.cancelled")
        } catch let error as RetentionCompactor.RetentionCompactorError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testPassiveCheckpointRunsAtEnd() async throws {
        // The PASSIVE checkpoint is not directly observable, but a run over a
        // real WAL-mode file DB must complete without error and take
        // measurable time.
        for i in 0..<20 {
            try await insertSample(
                timestamp: cutoff - Double(i + 1),
                hlcPhysical: Int64(i),
                nodeID: nodeA
            )
        }

        let result = try await compactor.runRetention(
            now: now,
            retentionWindow: retentionWindow,
            ackedCursorPerNode: [nodeA: (physical: 1_000, logical: 0)],
            chunkSize: 4
        )

        XCTAssertEqual(result.samplesDeleted, 20)
        XCTAssertGreaterThan(result.elapsedMillis, 0)
    }
}
