import XCTest
import GRDB
@testable import AnxietyWatchKit

final class BackfillProgressStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var dbManager: DatabaseManager!
    private var store: BackfillProgressStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory,
                                                withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.sqlite")
        dbManager = DatabaseManager(url: dbURL)
        try await dbManager.open()
        try await dbManager.writer { db in
            try SchemaV1.apply(to: db)
        }
        store = BackfillProgressStore(database: dbManager)
    }

    override func tearDown() async throws {
        await dbManager.close()
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testSetAndGetProgress() async throws {
        let progress = BackfillProgress(source: 1, type: 2, lastTs: 1234567.89)
        try await store.setProgress(progress)
        
        let retrieved = try await store.progress(source: 1, type: 2)
        XCTAssertEqual(retrieved, 1234567.89)
    }

    func testUpsertOverwritesLastTs() async throws {
        let progress1 = BackfillProgress(source: 1, type: 2, lastTs: 1000.0)
        let progress2 = BackfillProgress(source: 1, type: 2, lastTs: 2000.0)
        
        try await store.setProgress(progress1)
        try await store.setProgress(progress2)
        
        let retrieved = try await store.progress(source: 1, type: 2)
        XCTAssertEqual(retrieved, 2000.0)
    }

    func testAllProgressReturnsAll() async throws {
        let progress1 = BackfillProgress(source: 1, type: 2, lastTs: 1000.0)
        let progress2 = BackfillProgress(source: 3, type: 4, lastTs: 2000.0)
        let progress3 = BackfillProgress(source: 5, type: 6, lastTs: 3000.0)
        
        try await store.setProgress(progress1)
        try await store.setProgress(progress2)
        try await store.setProgress(progress3)
        
        let allProgress = try await store.allProgress()
        XCTAssertEqual(allProgress.count, 3)
        
        // Check that all three progress entries are present
        XCTAssertTrue(allProgress.contains { $0.source == 1 && $0.type == 2 && $0.lastTs == 1000.0 })
        XCTAssertTrue(allProgress.contains { $0.source == 3 && $0.type == 4 && $0.lastTs == 2000.0 })
        XCTAssertTrue(allProgress.contains { $0.source == 5 && $0.type == 6 && $0.lastTs == 3000.0 })
    }

    func testClearRemovesAll() async throws {
        let progress1 = BackfillProgress(source: 1, type: 2, lastTs: 1000.0)
        let progress2 = BackfillProgress(source: 3, type: 4, lastTs: 2000.0)
        
        try await store.setProgress(progress1)
        try await store.setProgress(progress2)
        
        var count = try await store.allProgress()
        XCTAssertEqual(count.count, 2)
        
        try await store.clear()
        
        count = try await store.allProgress()
        XCTAssertEqual(count.count, 0)
    }

    func testProgressReturnsNilWhenAbsent() async throws {
        let retrieved = try await store.progress(source: 99, type: 99)
        XCTAssertNil(retrieved)
    }
    
    func testSetProgressInDatabaseAtomicallyWithSampleInsert() async throws {
        // First, create the samples table for this test
        try await dbManager.writer { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS samples (
                  source        INTEGER NOT NULL,
                  type          INTEGER NOT NULL,
                  timestamp     REAL    NOT NULL,
                  value         REAL    NOT NULL,
                  extra         BLOB,
                  hlc_physical  INTEGER NOT NULL,
                  hlc_logical   INTEGER NOT NULL,
                  node_id       BLOB    NOT NULL,
                  PRIMARY KEY (source, type, timestamp)
                ) WITHOUT ROWID, STRICT
                """)
        }
        
        // Test successful transaction with both operations
        try await dbManager.writer { db in
            // Insert a sample row
            try db.execute(sql: """
                INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [1, 2, 1234567.89, 72.5, 1000, 0, Data(repeating: 0x01, count: 16)])
            
            // Set progress in the same transaction
            let progress = BackfillProgress(source: 1, type: 2, lastTs: 1234567.89)
            try BackfillProgressStore.setProgress(progress, in: db)
        }
        
        // Verify both were committed
        let sampleCount = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples") ?? 0
        }
        XCTAssertEqual(sampleCount, 1)
        
        let progressValue = try await store.progress(source: 1, type: 2)
        XCTAssertEqual(progressValue, 1234567.89)
        
        // Test rollback by forcing an error in a transaction
        do {
            try await dbManager.writer { db in
                // Insert another sample row
                try db.execute(sql: """
                    INSERT INTO samples (source, type, timestamp, value, hlc_physical, hlc_logical, node_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [2, 3, 2345678.90, 75.0, 2000, 0, Data(repeating: 0x02, count: 16)])
                
                // Set progress in the same transaction
                let progress2 = BackfillProgress(source: 2, type: 3, lastTs: 2345678.90)
                try BackfillProgressStore.setProgress(progress2, in: db)
                
                // Force an error to trigger rollback
                throw NSError(domain: "TestError", code: 1, userInfo: nil)
            }
            XCTFail("Should have thrown an error")
        } catch {
            // Expected error, continue
        }
        
        // Verify neither operation from the failed transaction was committed
        let finalSampleCount = try await dbManager.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples") ?? 0
        }
        XCTAssertEqual(finalSampleCount, 1, "Should still only have the first sample")
        
        let progress2Value = try await store.progress(source: 2, type: 3)
        XCTAssertNil(progress2Value, "Progress for second operation should not exist")
    }
}