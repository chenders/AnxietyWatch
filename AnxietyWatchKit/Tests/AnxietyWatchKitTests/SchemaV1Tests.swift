import XCTest
import GRDB
@testable import AnxietyWatchKit

final class SchemaV1Tests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var dbQueue: DatabaseQueue!
    
    override func setUp() {
        super.setUp()
        
        // Create a temporary directory for this test
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.db")
        
        // Create database queue
        dbQueue = try! DatabaseQueue(path: dbURL.path)
    }
    
    override func tearDown() {
        // Clean up temp files
        try? FileManager.default.removeItem(at: tempDirectory)
        
        super.tearDown()
    }
    
    func testSchemaTablesExist() throws {
        // Apply the schema
        try dbQueue.write { db in
            try SchemaV1.apply(to: db)
        }
        
        // Check that all tables exist
        let tableNames = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master 
                WHERE type = 'table' AND name IN (
                    'samples', 'samples_1min', 'sample_tombstones', 
                    '_sync_log', '_backfill_progress', '_sync_quarantine'
                )
                ORDER BY name
            """)
        }
        
        XCTAssertEqual(tableNames.count, 6)
        XCTAssertTrue(tableNames.contains("samples"))
        XCTAssertTrue(tableNames.contains("samples_1min"))
        XCTAssertTrue(tableNames.contains("sample_tombstones"))
        XCTAssertTrue(tableNames.contains("_sync_log"))
        XCTAssertTrue(tableNames.contains("_backfill_progress"))
        XCTAssertTrue(tableNames.contains("_sync_quarantine"))
        
        // Check that indexes exist
        let indexNames = try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master 
                WHERE type = 'index' AND name IN (
                    'idx_samples_hlc', 'idx_sample_tombstones_hlc', 'idx_samples_1min_hlc'
                )
                ORDER BY name
            """)
        }
        
        XCTAssertEqual(indexNames.count, 3)
        XCTAssertTrue(indexNames.contains("idx_samples_hlc"))
        XCTAssertTrue(indexNames.contains("idx_sample_tombstones_hlc"))
        XCTAssertTrue(indexNames.contains("idx_samples_1min_hlc"))
    }
    
    func testSchemaVersionIsSet() throws {
        // Apply the schema
        try dbQueue.write { db in
            try SchemaV1.apply(to: db)
        }
        
        // Check that user_version is set to 1
        let version = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        
        XCTAssertEqual(version, 1)
    }
    
    func testSamplesTableInsertAndDedupe() throws {
        // Apply the schema
        try dbQueue.write { db in
            try SchemaV1.apply(to: db)
        }
        
        // Insert a sample
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO samples(source,type,timestamp,value,hlc_physical,hlc_logical,node_id) 
                VALUES(1, 2, 1234567890.5, 98.6, 1234567890000, 1, X'0123456789ABCDEF0123456789ABCDEF')
            """)
        }
        
        // Insert duplicate - should succeed but not create new row (INSERT OR IGNORE effect)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO samples(source,type,timestamp,value,hlc_physical,hlc_logical,node_id) 
                VALUES(1, 2, 1234567890.5, 99.0, 1234567890001, 2, X'0123456789ABCDEF0123456789ABCDEF')
            """)
        }
        
        // Verify only one row exists
        let count: Int? = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples")
        }
        
        XCTAssertEqual(count, 1)
    }
    
    func testSampleTombstonesPKRejectsDuplicates() throws {
        // Apply the schema
        try dbQueue.write { db in
            try SchemaV1.apply(to: db)
        }
        
        // Insert a tombstone
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sample_tombstones(
                    source, type, ts_start, ts_end, hlc_physical, hlc_logical, node_id, 
                    dropped_row_count, reason
                ) VALUES(
                    1, 2, 1234567890.0, 1234567900.0, 1234567890000, 1, 
                    X'0123456789ABCDEF0123456789ABCDEF', 100, 'memory_panic'
                )
            """)
        }
        
        // Try to insert duplicate - should fail
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sample_tombstones(
                    source, type, ts_start, ts_end, hlc_physical, hlc_logical, node_id, 
                    dropped_row_count, reason
                ) VALUES(
                    1, 2, 1234567890.0, 1234567900.0, 1234567890000, 1, 
                    X'0123456789ABCDEF0123456789ABCDEF', 200, 'corruption'
                )
            """)
        }) { error in
            // Should be a SQLite error about constraint violation
            XCTAssertTrue(String(describing: error).contains("constraint"))
        }
    }
    
    func testSampleTombstonesCheckConstraint() throws {
        // Apply the schema
        try dbQueue.write { db in
            try SchemaV1.apply(to: db)
        }
        
        // Try to insert invalid reason - should fail
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sample_tombstones(
                    source, type, ts_start, ts_end, hlc_physical, hlc_logical, node_id, 
                    dropped_row_count, reason
                ) VALUES(
                    1, 2, 1234567890.0, 1234567900.0, 1234567890000, 1, 
                    X'0123456789ABCDEF0123456789ABCDEF', 100, 'invalid_reason'
                )
            """)
        }) { error in
            // Should be a SQLite error about constraint violation
            XCTAssertTrue(String(describing: error).contains("constraint"))
        }
    }
}