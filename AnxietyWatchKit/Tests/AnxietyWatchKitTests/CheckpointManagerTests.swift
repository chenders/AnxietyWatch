import XCTest
import GRDB
@testable import AnxietyWatchKit

final class CheckpointManagerTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var markerURL: URL!
    private var dbManager: DatabaseManager!
    private var checkpointManager: CheckpointManager!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.sqlite")
        markerURL = tempDirectory.appendingPathComponent(".checkpoint-in-progress-test")
        dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        try await dbManager.writer { db in
            try SchemaV1.apply(to: db)
        }
        checkpointManager = CheckpointManager(database: dbManager, markerURL: markerURL)
    }

    override func tearDown() async throws {
        await dbManager.close()
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testPassiveCheckpointRuns() async throws {
        // Seed some data to create WAL
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id) VALUES (1, 1, 100, 10.0, 1000, 0, zeroblob(16))")
        }
        
        let result = try await checkpointManager.run(mode: .passive)
        XCTAssertEqual(result.mode, .passive)
        XCTAssertGreaterThanOrEqual(result.log, 0)
        XCTAssertGreaterThanOrEqual(result.checkpointed, 0)
    }
    
    func testTruncateRequiresBlePrecondition() async throws {
        // Seed some data to create WAL
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id) VALUES (1, 1, 200, 20.0, 1001, 0, zeroblob(16))")
        }
        
        do {
            let _ = try await checkpointManager.run(mode: .truncate, blePrecondition: { false }, syncPrecondition: { true })
            XCTFail("Should have thrown blePreconditionFailed")
        } catch CheckpointManager.CheckpointManagerError.blePreconditionFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        // Marker should not exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
    
    func testTruncateRefusesWhenBleClosureNil() async throws {
        // Seed some data to create WAL
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id) VALUES (1, 1, 250, 25.0, 1005, 0, zeroblob(16))")
        }
        
        do {
            let _ = try await checkpointManager.run(mode: .truncate, blePrecondition: nil, syncPrecondition: { true })
            XCTFail("Should have thrown blePreconditionFailed")
        } catch CheckpointManager.CheckpointManagerError.blePreconditionFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        // Marker should not exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
    
    func testTruncateRequiresSyncPrecondition() async throws {
        // Seed some data to create WAL
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id) VALUES (1, 1, 300, 30.0, 1002, 0, zeroblob(16))")
        }
        
        do {
            let _ = try await checkpointManager.run(mode: .truncate, blePrecondition: { true }, syncPrecondition: { false })
            XCTFail("Should have thrown syncPreconditionFailed")
        } catch CheckpointManager.CheckpointManagerError.syncPreconditionFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        // Marker should not exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
    
    func testTruncateRefusesWhenSyncClosureNil() async throws {
        // Seed some data to create WAL
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id) VALUES (1, 1, 350, 35.0, 1006, 0, zeroblob(16))")
        }
        
        do {
            let _ = try await checkpointManager.run(mode: .truncate, blePrecondition: { true }, syncPrecondition: nil)
            XCTFail("Should have thrown syncPreconditionFailed")
        } catch CheckpointManager.CheckpointManagerError.syncPreconditionFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        // Marker should not exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
    
    func testTruncateWritesAndRemovesMarker() async throws {
        // Seed some data to create WAL
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id) VALUES (1, 1, 400, 40.0, 1003, 0, zeroblob(16))")
        }
        
        // Add a small delay to ensure file system operations can be observed
        let result = try await checkpointManager.run(mode: .truncate, blePrecondition: { true }, syncPrecondition: { true })
        XCTAssertEqual(result.mode, .truncate)
        
        // Marker should be removed after checkpoint completes
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
    
    func testResultParses() async throws {
        // Seed some data to create WAL
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id) VALUES (1, 1, 500, 50.0, 1004, 0, zeroblob(16))")
        }
        
        let result = try await checkpointManager.run(mode: .passive)
        XCTAssertGreaterThanOrEqual(result.log, 0)
        XCTAssertGreaterThanOrEqual(result.checkpointed, 0)
    }
}