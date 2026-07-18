import XCTest
import GRDB
@testable import AnxietyWatchKit

final class SyncLogStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var database: DatabaseManager!
    private var syncLogStore: SyncLogStore!
    
    override func setUp() {
        super.setUp()
        
        // Create a temporary directory for this test
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        dbURL = tempDirectory.appendingPathComponent("test.db")
        
        // Create database manager and open database
        database = DatabaseManager(url: dbURL)
        
        // Apply schema synchronously
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
        
        syncLogStore = SyncLogStore(database: database)
    }
    
    override func tearDown() {
        // Clean up temp files
        let teardownExpectation = expectation(description: "Database teardown")
        Task {
            await database.close()
            teardownExpectation.fulfill()
        }
        waitForExpectations(timeout: 10)
        
        try? FileManager.default.removeItem(at: tempDirectory)
        
        super.tearDown()
    }
    
    func testUpsertInserts() async throws {
        // Create a sync log entry
        let nodeID = UUID().uuidString.data(using: .utf8)!
        let entry = SyncLogEntry(
            tableName: "samples",
            rowPK: "1:1:1000.0",
            hlcPhysical: 1000000,
            hlcLogical: 1,
            nodeID: nodeID,
            operation: .upsert
        )
        
        // Insert the entry
        try await syncLogStore.upsert(entry)
        
        // Check count
        let count = try await syncLogStore.count()
        XCTAssertEqual(count, 1)
    }
    
    func testUpsertCoalescesLatestOp() async throws {
        // Create sync log entries with the same table_name and row_pk
        let nodeID = UUID().uuidString.data(using: .utf8)!
        let tableName = "samples"
        let rowPK = "1:1:1000.0"
        
        let entry1 = SyncLogEntry(
            tableName: tableName,
            rowPK: rowPK,
            hlcPhysical: 1000000,
            hlcLogical: 1,
            nodeID: nodeID,
            operation: .upsert
        )
        
        let entry2 = SyncLogEntry(
            tableName: tableName,
            rowPK: rowPK,
            hlcPhysical: 2000000,
            hlcLogical: 2,
            nodeID: nodeID,
            operation: .delete
        )
        
        // Insert both entries
        try await syncLogStore.upsert(entry1)
        try await syncLogStore.upsert(entry2)
        
        // Check count - should be 1 due to coalescing
        let count = try await syncLogStore.count()
        XCTAssertEqual(count, 1)
        
        // Fetch the entry and verify it has the latest values
        let entries = try await syncLogStore.fetchForSync(nodeID: nodeID, afterHLC: 0, lc: -1, limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hlcPhysical, 2000000)
        XCTAssertEqual(entries[0].hlcLogical, 2)
        XCTAssertEqual(entries[0].operation, .delete)
    }
    
    func testFetchForSyncPagination() async throws {
        // Create sync log entries with increasing HLC for one node
        let nodeID = UUID().uuidString.data(using: .utf8)!
        var entries: [SyncLogEntry] = []
        
        for i in 0..<5 {
            entries.append(SyncLogEntry(
                tableName: "samples",
                rowPK: "1:1:\(1000 + i * 100).0",
                hlcPhysical: Int64(1000000 + i * 1000),
                hlcLogical: Int32(i),
                nodeID: nodeID,
                operation: .upsert
            ))
        }
        
        // Insert all entries
        for entry in entries {
            try await syncLogStore.upsert(entry)
        }
        
        // Check total count
        let totalCount = try await syncLogStore.count()
        XCTAssertEqual(totalCount, 5)
        
        // Fetch in pages
        var allFetchedEntries: [SyncLogEntry] = []
        var lastPhysical: Int64 = 0
        var lastLogical: Int32 = -1
        
        for _ in 0..<3 {  // Should need at most 3 pages (5 items / 2 per page = 2.5)
            let page = try await syncLogStore.fetchForSync(
                nodeID: nodeID, afterHLC: lastPhysical, lc: lastLogical, limit: 2
            )
            
            if page.isEmpty {
                break
            }
            
            allFetchedEntries.append(contentsOf: page)
            
            // Update cursor for next page
            let lastEntry = page.last!
            lastPhysical = lastEntry.hlcPhysical
            lastLogical = lastEntry.hlcLogical
            
            // If we got fewer than 2 items, this was the last page
            if page.count < 2 {
                break
            }
        }
        
        // Verify we got all entries in correct order
        XCTAssertEqual(allFetchedEntries.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(allFetchedEntries[i].hlcPhysical, Int64(1000000 + i * 1000))
            XCTAssertEqual(allFetchedEntries[i].hlcLogical, Int32(i))
        }
    }
    
    func testGarbageCollectDeletesUpToCursor() async throws {
        // Create sync log entries - all for the same node
        let nodeID = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var entries: [SyncLogEntry] = []
        
        for i in 0..<5 {
            entries.append(SyncLogEntry(
                tableName: "samples",
                rowPK: "1:1:\(1000 + i * 100).0",
                hlcPhysical: Int64(1000000 + i * 1000000),
                hlcLogical: Int32(i),
                nodeID: nodeID,
                operation: .upsert
            ))
        }
        
        // Insert all entries
        for entry in entries {
            try await syncLogStore.upsert(entry)
        }
        
        // Check initial count
        var count = try await syncLogStore.count()
        XCTAssertEqual(count, 5)
        
        // Garbage collect up to HLC (3000000, 3) - should delete entries 0, 1, 2
        // Entry 3 has HLC (4000000, 3) which is > (3000000, 3) so it should remain
        // Entry 4 has HLC (5000000, 4) which is > (3000000, 3) so it should remain
        let deletedCount = try await syncLogStore.garbageCollect(
            nodeID: nodeID, upToHLC: 3000000, lc: 3
        )
        
        // Should delete 3 entries (entries 0, 1, 2)
        XCTAssertEqual(deletedCount, 3)
        
        // Check remaining count
        count = try await syncLogStore.count()
        XCTAssertEqual(count, 2)
        
        // Fetch remaining entries - should be entries #3 and #4
        let remainingEntries = try await syncLogStore.fetchForSync(
            nodeID: nodeID, afterHLC: 0, lc: -1, limit: 10
        )
        XCTAssertEqual(remainingEntries.count, 2)
        if remainingEntries.count >= 1 {
            XCTAssertEqual(remainingEntries[0].hlcPhysical, 4000000)
            XCTAssertEqual(remainingEntries[0].hlcLogical, 3)
        }
        if remainingEntries.count >= 2 {
            XCTAssertEqual(remainingEntries[1].hlcPhysical, 5000000)
            XCTAssertEqual(remainingEntries[1].hlcLogical, 4)
        }
    }
    
    func testUpsertHLCGuardRejectsOlder() async throws {
        // Create sync log entries with the same table_name and row_pk
        let nodeID = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let tableName = "samples"
        let rowPK = "1:1:1000.0"
        
        // Insert entry with newer HLC (100, 0)
        let newerEntry = SyncLogEntry(
            tableName: tableName,
            rowPK: rowPK,
            hlcPhysical: 100,
            hlcLogical: 0,
            nodeID: nodeID,
            operation: .upsert
        )
        
        try await syncLogStore.upsert(newerEntry)
        
        // Try to upsert with older HLC (50, 0) - should be rejected
        let olderEntry = SyncLogEntry(
            tableName: tableName,
            rowPK: rowPK,
            hlcPhysical: 50,
            hlcLogical: 0,
            nodeID: nodeID,
            operation: .delete
        )
        
        try await syncLogStore.upsert(olderEntry)
        
        // Fetch the entry and verify it still has the newer values
        let entries = try await syncLogStore.fetchForSync(nodeID: nodeID, afterHLC: 0, lc: -1, limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hlcPhysical, 100)
        XCTAssertEqual(entries[0].hlcLogical, 0)
        XCTAssertEqual(entries[0].operation, .upsert) // Should still be .upsert, not .delete
    }
}