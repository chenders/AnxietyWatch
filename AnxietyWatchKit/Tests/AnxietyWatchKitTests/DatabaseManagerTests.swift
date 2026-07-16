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
        
        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        
        // Verify PRAGMAs
        let journalMode = try await dbManager.reader { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode, "wal")
        
        let foreignKeys = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(foreignKeys, 1)
        
        await dbManager.close()
    }
    
    func testCloseSetsCleanShutdown() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        
        try await dbManager.open()
        await dbManager.close()
        
        // Verify clean shutdown marker file exists
        let cleanShutdownMarker = dbURL.deletingLastPathComponent().appendingPathComponent(".cleanshutdown-\(dbURL.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanShutdownMarker.path))
    }
    
    func testCorruptionRecoveryDeletesFilesAndReopens() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        
        // Open database
        try await dbManager.open()
        
        // Create a table to verify DB functionality
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY)")
        }
        
        // Close database
        await dbManager.close()
        
        // Verify main file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        // WAL and SHM files may not exist immediately after close, that's OK
        
        // Delete files manually to simulate corruption
        try? FileManager.default.removeItem(at: dbURL)
        let walFile = URL(fileURLWithPath: "\(dbURL.path)-wal")
        let shmFile = URL(fileURLWithPath: "\(dbURL.path)-shm")
        try? FileManager.default.removeItem(at: walFile)
        try? FileManager.default.removeItem(at: shmFile)
        
        // Reopen should work and create new files
        try await dbManager.open()
        
        // Verify database is usable with a fresh schema
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS test2 (id INTEGER PRIMARY KEY)")
        }
        
        await dbManager.close()
    }
    
    func testCorruptionCircuitBreakerTrips() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        
        // Open database first
        try await dbManager.open()
        await dbManager.close()
        
        // Manually trigger recovery multiple times to test circuit breaker
        var caughtThresholdError = false
        
        for i in 0..<4 {
            do {
                try await dbManager.forceCorruptionRecovery()
                if i < 3 {
                    await dbManager.close()
                }
            } catch DatabaseManager.DatabaseError.corruptionThresholdExceeded {
                caughtThresholdError = true
                break
            }
        }
        
        // Verify circuit breaker tripped
        XCTAssertTrue(caughtThresholdError, "Should have caught corruptionThresholdExceeded")
        
        // Acknowledge circuit breaker and try again
        await dbManager.acknowledgeCorruptionCircuit()
        
        // This should now succeed
        try await dbManager.forceCorruptionRecovery()
        await dbManager.close()
    }
    
    func testWriterAndReaderRoundTrip() async throws {
        let dbManager = DatabaseManager(url: dbURL)
        
        try await dbManager.open()
        
        // Writer creates table and inserts row
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO test (id) VALUES (42)")
        }
        
        // Reader selects the row back
        let result = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT id FROM test WHERE id = 42")
        }
        
        XCTAssertEqual(result, 42)
        
        await dbManager.close()
    }
}

final class DatabaseManagerWALFilesTests: XCTestCase {
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
    
    func testCorruptionRecoveryDeletesFilesWithCorrectNames() async throws {
        // Create a test database and write some data
        let dbManager = DatabaseManager(url: dbURL)
        
        // Open database to create files
        try await dbManager.open()
        
        // Write some data to ensure WAL is created
        try await dbManager.writer { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO test (id) VALUES (1)")
        }
        
        // Close database to ensure WAL files are flushed
        await dbManager.close()
        
        // Verify WAL and SHM files exist with correct names
        let walFile = URL(fileURLWithPath: "\(dbURL.path)-wal")
        let shmFile = URL(fileURLWithPath: "\(dbURL.path)-shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walFile.path), "WAL file should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmFile.path), "SHM file should exist")
        
        // Manually delete the main database file to simulate corruption
        try FileManager.default.removeItem(at: dbURL)
        
        // Now when we try to open, it should detect corruption and recover
        try await dbManager.open()
        
        // Verify that we have a fresh database (table should not exist)
        let tableExists = try await dbManager.reader { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'test'")
            return count ?? 0 > 0
        }
        XCTAssertFalse(tableExists, "Table should not exist after recovery")
        
        await dbManager.close()
    }
}