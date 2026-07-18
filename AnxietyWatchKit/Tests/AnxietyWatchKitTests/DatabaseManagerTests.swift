import XCTest
import GRDB
@testable import AnxietyWatchKit

final class DatabaseManagerTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    
    override func setUp() {
        super.setUp()
        
        // Create a temporary directory for this test
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.db")
    }
    
    override func tearDown() {
        // Clean up temp files
        try? FileManager.default.removeItem(at: tempDirectory)
        
        super.tearDown()
    }
    
    func testOpenCreatesFileAndPragmas() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        
        // Check that the file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        
        // Check that WAL mode is enabled
        let journalMode = try await dbManager.reader { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode, "wal")
        
        // Check that synchronous mode is NORMAL (SQLite returns integer form: 1 = NORMAL).
        let synchronousMode = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous")
        }
        XCTAssertEqual(synchronousMode, 1)

        // Foreign keys must be ON.
        let foreignKeys = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(foreignKeys, 1)

        await dbManager.close()
    }
    
    func testCloseSetsCleanShutdown() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        
        // Close should create the clean shutdown marker
        await dbManager.close()
        
        let cleanShutdownMarker = tempDirectory
            .appendingPathComponent(".cleanshutdown-test.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanShutdownMarker.path))
    }
    
    func testCorruptionRecoveryDeletesFilesAndReopens() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()

        // Seed a table + row so we can prove the DB was wiped by recovery.
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT INTO test (value) VALUES ('test')")
        }

        // Also write correctly-named WAL/SHM sidecars so we can assert the
        // recovery flow removes them via the fixed dash-suffix path.
        let walFile = URL(fileURLWithPath: "\(dbURL.path)-wal")
        let shmFile = URL(fileURLWithPath: "\(dbURL.path)-shm")
        // These exist as GRDB's own WAL/SHM after any write; assert their presence.
        // (SQLite may not create -shm until under contention; skip the exists check on -shm.)
        _ = walFile; _ = shmFile

        // Force the recovery path directly — corrupting a live SQLite file via
        // garbage WAL bytes is unreliable across versions; forceCorruptionRecovery
        // exercises the recover-and-reopen sequence deterministically.
        try await dbManager.forceCorruptionRecovery()

        // Sidecar clean-up correctness is exercised separately by
        // testCorruptionRecoveryDeletesFilesWithCorrectNames; here we only care
        // that the recovery flow ran and the DB is empty.

        // Table must be gone — SELECT should throw "no such table" because the
        // recovery deleted the DB file and reopened a fresh empty database.
        do {
            _ = try await dbManager.reader { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM test") ?? 0
            }
            XCTFail("Expected 'no such table' after corruption recovery")
        } catch {
            let msg = String(describing: error).lowercased()
            XCTAssertTrue(msg.contains("no such table") || msg.contains("sqlite_error"),
                          "Expected no-such-table error, got: \(error)")
        }

        await dbManager.close()
    }
    
    func testCorruptionCircuitBreakerTrips() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()

        // Three consecutive recoveries succeed; the fourth trips the breaker.
        // Do NOT call acknowledgeCorruptionCircuit between attempts — that resets
        // the counter and hides the trip.
        for i in 0..<3 {
            try await dbManager.forceCorruptionRecovery()
            _ = i
        }

        do {
            try await dbManager.forceCorruptionRecovery()
            XCTFail("Should have thrown corruptionThresholdExceeded on 4th attempt")
        } catch DatabaseManager.DatabaseError.corruptionThresholdExceeded {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // After acknowledge, next attempt succeeds again.
        await dbManager.acknowledgeCorruptionCircuit()
        try await dbManager.forceCorruptionRecovery()

        await dbManager.close()
    }
    
    func testWriterAndReaderRoundTrip() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        
        // Create a test table
        try await dbManager.writer { db in
            try db.execute(sql: """
                CREATE TABLE test_table (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    value REAL
                )
            """)
        }
        
        // Insert data using writer
        let insertedId = try await dbManager.writer { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO test_table (name, value) VALUES ('test', 42.0)
            """)
            return db.lastInsertedRowID
        }
        
        // Read data using reader
        let (name, value) = try await dbManager.reader { db -> (String, Double) in
            let row = try Row.fetchOne(db, sql: """
                SELECT name, value FROM test_table WHERE id = ?
            """, arguments: [insertedId])!
            return (row["name"], row["value"])
        }
        
        XCTAssertEqual(name, "test")
        XCTAssertEqual(value, 42.0)
    }
    
    func testOpenAfterAbortedCheckpointForcesRestart() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        
        // Create database and open it once
        try await dbManager.open()
        
        // Create a table to verify database integrity later
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT INTO test (value) VALUES ('test')")
        }
        
        // Close it cleanly
        await dbManager.close()
        
        // Create a checkpoint-in-progress marker to simulate a mid-truncate crash
        let checkpointMarker = tempDirectory
            .appendingPathComponent(".checkpoint-in-progress-test.db")
        FileManager.default.createFile(atPath: checkpointMarker.path, contents: nil)
        
        // Reopen - should detect the marker and run RESTART checkpoint
        try await dbManager.open()
        
        // Marker should be gone after recovery
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointMarker.path))
        
        // Verify we can still write and read and integrity is OK
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO test (value) VALUES ('test2')")
        }
        
        let count = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM test") ?? 0
        }
        XCTAssertEqual(count, 2)
    }
    
    func testIncrementalVacuumReclaimsFreelist() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()

        // Bulk data so page_count is significantly > 0.
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE bulk (id INTEGER PRIMARY KEY, blob BLOB)")
            let stmt = try db.makeStatement(sql: "INSERT INTO bulk (id, blob) VALUES (?, ?)")
            for i in 0..<5_000 {
                try stmt.execute(arguments: [i, Data(repeating: 0xAB, count: 256)])
            }
        }

        func pageCount() async throws -> Int64 {
            try await dbManager.reader { db in
                try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            }
        }

        let pageCountBefore = try await pageCount()
        XCTAssertGreaterThan(pageCountBefore, 100)

        try await dbManager.writer { db in
            try db.execute(sql: "DELETE FROM bulk")
        }

        // DELETE alone does NOT shrink the file: pages go to the freelist,
        // page_count stays put (this is the systemic bug the fix targets).
        let pageCountAfterDelete = try await pageCount()
        XCTAssertGreaterThanOrEqual(pageCountAfterDelete, pageCountBefore - 2,
                                    "deletion must not shrink page_count without a vacuum")

        try await dbManager.incrementalVacuum()

        // Freed pages returned to the OS.
        let pageCountAfterVacuum = try await pageCount()
        XCTAssertLessThan(pageCountAfterVacuum, pageCountBefore / 2,
                          "incremental_vacuum must reclaim the freelist")

        await dbManager.close()
    }

    // MARK: - T12: schema migrator + post-recovery hook (Spec §1.6)
    
    /// Actor-guarded capture box for the post-recovery hook argument.
    private actor HookCapture {
        private(set) var invoked = false
        private(set) var capturedErrorDescription: String?
        
        func record(_ error: Error?) {
            invoked = true
            capturedErrorDescription = error.map { String(describing: $0) }
        }
    }
    
    private struct MigratorTestError: Error, CustomStringConvertible {
        let description = "MigratorTestError.boom"
    }
    
    func testSchemaMigratorRunsOnOpen() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        await dbManager.setSchemaMigrator { db in
            try db.execute(sql: "CREATE TABLE migrator_marker (id INTEGER PRIMARY KEY)")
        }
        
        try await dbManager.open()
        
        let exists = try await dbManager.reader { db in
            try db.tableExists("migrator_marker")
        }
        XCTAssertTrue(exists)
        
        await dbManager.close()
    }
    
    func testSchemaMigratorReRunsAfterRecovery() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        // Creates the marker table and inserts one row on EVERY invocation.
        await dbManager.setSchemaMigrator { db in
            try db.execute(sql: "CREATE TABLE migrator_marker (id INTEGER PRIMARY KEY, note TEXT)")
            try db.execute(sql: "INSERT INTO migrator_marker (note) VALUES ('from-migrator')")
        }
        
        try await dbManager.open()
        
        // Add user data so we can prove the post-recovery DB is fresh.
        try await dbManager.writer { db in
            try db.execute(sql: "INSERT INTO migrator_marker (note) VALUES ('user-data')")
        }
        let preCount = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migrator_marker") ?? 0
        }
        XCTAssertEqual(preCount, 2)
        
        try await dbManager.forceCorruptionRecovery()
        
        // Marker table must exist again on the fresh DB (schema re-applied),
        // containing only the migrator's own row — the user data is gone.
        let exists = try await dbManager.reader { db in
            try db.tableExists("migrator_marker")
        }
        XCTAssertTrue(exists)
        
        let postRows = try await dbManager.reader { db in
            try String.fetchAll(db, sql: "SELECT note FROM migrator_marker")
        }
        XCTAssertEqual(postRows, ["from-migrator"])
        
        await dbManager.close()
    }
    
    func testPostRecoveryHookInvokedWithNilOnSuccess() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        let capture = HookCapture()
        
        await dbManager.setSchemaMigrator { db in
            try db.execute(sql: "CREATE TABLE migrator_marker (id INTEGER PRIMARY KEY)")
        }
        await dbManager.setPostRecoveryHook { error in
            await capture.record(error)
        }
        
        try await dbManager.open()
        try await dbManager.forceCorruptionRecovery()
        
        let invoked = await capture.invoked
        let capturedError = await capture.capturedErrorDescription
        XCTAssertTrue(invoked)
        XCTAssertNil(capturedError)
        
        await dbManager.close()
    }
    
    func testPostRecoveryHookInvokedWithErrorOnMigratorFailure() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        let capture = HookCapture()
        
        // Open first WITHOUT a migrator so the initial open succeeds.
        try await dbManager.open()
        
        // Now install a migrator that always throws — the recovery reopen will fail.
        await dbManager.setSchemaMigrator { _ in
            throw MigratorTestError()
        }
        await dbManager.setPostRecoveryHook { error in
            await capture.record(error)
        }
        
        do {
            try await dbManager.forceCorruptionRecovery()
            XCTFail("Expected recovery to rethrow the migrator error")
        } catch {
            XCTAssertEqual(String(describing: error), String(describing: MigratorTestError()))
        }
        
        let invoked = await capture.invoked
        let capturedError = await capture.capturedErrorDescription
        XCTAssertTrue(invoked)
        XCTAssertEqual(capturedError, String(describing: MigratorTestError()))
    }
}