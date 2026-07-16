import XCTest
import GRDB
@testable import AnxietyWatchKit

final class SamplesStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var dbURL: URL!
    private var database: DatabaseManager!
    private var samplesStore: SamplesStore!
    
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
        
        samplesStore = SamplesStore(database: database)
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
    
    func testInsertAndFetch() async throws {
        // Create sample rows
        let nodeID = UUID().uuidString.data(using: .utf8)!
        let rows = [
            SampleRow(source: 1, type: 1, timestamp: 1000.0, value: 72.5, extra: nil, 
                     hlcPhysical: 1000000, hlcLogical: 1, nodeID: nodeID),
            SampleRow(source: 1, type: 1, timestamp: 2000.0, value: 75.0, extra: nil, 
                     hlcPhysical: 2000000, hlcLogical: 1, nodeID: nodeID),
            SampleRow(source: 1, type: 1, timestamp: 3000.0, value: 70.2, extra: nil, 
                     hlcPhysical: 3000000, hlcLogical: 1, nodeID: nodeID)
        ]
        
        // Insert rows
        let insertedCount = try await samplesStore.insert(rows)
        XCTAssertEqual(insertedCount, 3)
        
        // Fetch rows
        let fetchedRows = try await samplesStore.fetch(source: 1, type: 1, from: 500.0, to: 3500.0)
        XCTAssertEqual(fetchedRows.count, 3)
        XCTAssertEqual(fetchedRows[0].timestamp, 1000.0)
        XCTAssertEqual(fetchedRows[0].value, 72.5)
        XCTAssertEqual(fetchedRows[1].timestamp, 2000.0)
        XCTAssertEqual(fetchedRows[1].value, 75.0)
        XCTAssertEqual(fetchedRows[2].timestamp, 3000.0)
        XCTAssertEqual(fetchedRows[2].value, 70.2)
    }
    
    func testInsertDedupesOnPK() async throws {
        // Create sample rows with duplicate PK
        let nodeID = UUID().uuidString.data(using: .utf8)!
        let row1 = SampleRow(source: 1, type: 1, timestamp: 1000.0, value: 72.5, extra: nil, 
                            hlcPhysical: 1000000, hlcLogical: 1, nodeID: nodeID)
        let row2 = SampleRow(source: 1, type: 1, timestamp: 1000.0, value: 75.0, extra: nil, 
                            hlcPhysical: 2000000, hlcLogical: 1, nodeID: nodeID) // Same PK as row1
        
        // Insert rows
        let insertedCount1 = try await samplesStore.insert([row1])
        XCTAssertEqual(insertedCount1, 1)
        
        let insertedCount2 = try await samplesStore.insert([row2])
        XCTAssertEqual(insertedCount2, 0) // Should not insert duplicate
        
        // Verify count
        let totalCount = try await samplesStore.count()
        XCTAssertEqual(totalCount, 1)
    }
    
    func testHealthKitOwnedTypeThrowsInRelease() async throws {
        // Create a sample row with HealthKit-owned type (AppleWatch HR)
        let nodeID = UUID().uuidString.data(using: .utf8)!
        let row = SampleRow(source: 2, type: 1, timestamp: 1000.0, value: 72.5, extra: nil, 
                           hlcPhysical: 1000000, hlcLogical: 1, nodeID: nodeID)
        
        // In release mode, this should throw
        #if !DEBUG
        await XCTAssertThrowsError(try await samplesStore.insert([row])) { error in
            XCTAssertTrue(error is SamplesStore.SamplesStoreError)
            if case SamplesStore.SamplesStoreError.healthKitOwnedType(let source, let type) = error {
                XCTAssertEqual(source, 2)
                XCTAssertEqual(type, 1)
            } else {
                XCTFail("Expected healthKitOwnedType error")
            }
        }
        #else
        // In debug mode, this would trap, so we can't test it directly
        // Comment: precondition trap in debug is not testable via XCTest; test the release throw path.
        #endif
    }
    
    func testFetchForSyncPagination() async throws {
        // Create sample rows with increasing HLC for one node
        let nodeID = UUID().uuidString.data(using: .utf8)!
        var rows: [SampleRow] = []
        for i in 0..<10 {
            rows.append(SampleRow(
                source: 1, type: 1, timestamp: Double(1000 + i * 100), 
                value: Double(70 + i), extra: nil,
                hlcPhysical: Int64(1000000 + i * 1000), hlcLogical: Int32(i), 
                nodeID: nodeID
            ))
        }
        
        // Insert rows
        let insertedCount = try await samplesStore.insert(rows)
        XCTAssertEqual(insertedCount, 10)
        
        // Fetch in pages
        var allFetchedRows: [SampleRow] = []
        var lastPhysical: Int64 = 0
        var lastLogical: Int32 = -1
        
        for _ in 0..<4 {  // Should need at most 4 pages (10 items / 3 per page = 3.33)
            let page = try await samplesStore.fetchForSync(
                nodeID: nodeID, afterHLC: lastPhysical, lc: lastLogical, limit: 3
            )
            
            if page.isEmpty {
                break
            }
            
            allFetchedRows.append(contentsOf: page)
            
            // Update cursor for next page
            let lastRow = page.last!
            lastPhysical = lastRow.hlcPhysical
            lastLogical = lastRow.hlcLogical
            
            // If we got fewer than 3 items, this was the last page
            if page.count < 3 {
                break
            }
        }
        
        // Verify we got all rows in correct order
        XCTAssertEqual(allFetchedRows.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(allFetchedRows[i].hlcPhysical, Int64(1000000 + i * 1000))
            XCTAssertEqual(allFetchedRows[i].hlcLogical, Int32(i))
        }
    }
    
    func testFetchForSyncOnlyReturnsMatchingNode() async throws {
        // Create sample rows for two different nodes
        let nodeID1 = UUID().uuidString.data(using: .utf8)!
        let nodeID2 = UUID().uuidString.data(using: .utf8)!
        
        let rows1 = [
            SampleRow(source: 1, type: 1, timestamp: 1000.0, value: 72.5, extra: nil, 
                     hlcPhysical: 1000000, hlcLogical: 1, nodeID: nodeID1),
            SampleRow(source: 1, type: 1, timestamp: 2000.0, value: 75.0, extra: nil, 
                     hlcPhysical: 2000000, hlcLogical: 1, nodeID: nodeID1)
        ]
        
        let rows2 = [
            SampleRow(source: 1, type: 1, timestamp: 1500.0, value: 73.0, extra: nil, 
                     hlcPhysical: 1500000, hlcLogical: 1, nodeID: nodeID2),
            SampleRow(source: 1, type: 1, timestamp: 2500.0, value: 76.0, extra: nil, 
                     hlcPhysical: 2500000, hlcLogical: 1, nodeID: nodeID2)
        ]
        
        // Insert rows for both nodes
        _ = try await samplesStore.insert(rows1)
        _ = try await samplesStore.insert(rows2)
        
        // Fetch rows for nodeID1 only
        let fetchedRows = try await samplesStore.fetchForSync(
            nodeID: nodeID1, afterHLC: 0, lc: -1, limit: 10
        )
        
        // Verify only rows from nodeID1 are returned
        XCTAssertEqual(fetchedRows.count, 2)
        XCTAssertTrue(fetchedRows.allSatisfy { $0.nodeID == nodeID1 })
    }
    
    func testDeleteRowsOlderThan() async throws {
        // Create sample rows with various timestamps
        let nodeID = UUID().uuidString.data(using: .utf8)!
        let rows = [
            SampleRow(source: 1, type: 1, timestamp: 1000.0, value: 72.5, extra: nil, 
                     hlcPhysical: 1000000, hlcLogical: 1, nodeID: nodeID),
            SampleRow(source: 1, type: 1, timestamp: 2000.0, value: 75.0, extra: nil, 
                     hlcPhysical: 2000000, hlcLogical: 1, nodeID: nodeID),
            SampleRow(source: 1, type: 1, timestamp: 3000.0, value: 70.2, extra: nil, 
                     hlcPhysical: 3000000, hlcLogical: 1, nodeID: nodeID),
            SampleRow(source: 1, type: 1, timestamp: 4000.0, value: 78.1, extra: nil, 
                     hlcPhysical: 4000000, hlcLogical: 1, nodeID: nodeID),
            SampleRow(source: 1, type: 1, timestamp: 5000.0, value: 69.8, extra: nil, 
                     hlcPhysical: 5000000, hlcLogical: 1, nodeID: nodeID)
        ]
        
        // Insert rows
        _ = try await samplesStore.insert(rows)
        
        // Delete rows older than 3500.0
        let deletedCount = try await samplesStore.deleteRowsOlderThan(3500.0)
        XCTAssertEqual(deletedCount, 3)
        
        // Verify remaining rows
        let remainingCount = try await samplesStore.count()
        XCTAssertEqual(remainingCount, 2)
        
        let remainingRows = try await samplesStore.fetch(source: 1, type: 1, from: 0.0, to: 10000.0)
        XCTAssertEqual(remainingRows.count, 2)
        XCTAssertTrue(remainingRows.allSatisfy { $0.timestamp >= 3500.0 })
    }
    
    func testDeleteRowsOlderThanExact10kMultiple() async throws {
        // Insert exactly 10000 rows with timestamps below cutoff
        var rows: [SampleRow] = []
        for i in 0..<10000 {
            rows.append(SampleRow(
                source: 1,
                type: 1,
                timestamp: Double(i),
                value: Double(i),
                extra: nil,
                hlcPhysical: Int64(1000000 + i),
                hlcLogical: Int32(i % 1000),
                nodeID: Data([0x01, 0x02, 0x03, 0x04, 0x05])
            ))
        }
        
        try await samplesStore.insert(rows)
        
        // Verify initial count
        let initialCount = try await samplesStore.count()
        XCTAssertEqual(initialCount, 10000)
        
        // Delete rows older than 15000 (all rows)
        let deletedCount = try await samplesStore.deleteRowsOlderThan(15000.0)
        
        // Should have deleted all 10000 rows without hanging
        XCTAssertEqual(deletedCount, 10000)
        
        // Verify final count
        let finalCount = try await samplesStore.count()
        XCTAssertEqual(finalCount, 0)
    }
    
    func testIsHealthKitOwned() {
        // Test HealthKit-owned types
        XCTAssertTrue(SamplesStore.isHealthKitOwned(source: 2, type: 1)) // AppleWatch HR
        XCTAssertTrue(SamplesStore.isHealthKitOwned(source: 2, type: 4)) // AppleWatch HRV
        
        // Test non-HealthKit-owned types
        XCTAssertFalse(SamplesStore.isHealthKitOwned(source: 1, type: 1)) // Non-AppleWatch HR
        XCTAssertFalse(SamplesStore.isHealthKitOwned(source: 2, type: 2)) // AppleWatch non-HK type
        XCTAssertFalse(SamplesStore.isHealthKitOwned(source: 3, type: 1)) // Non-AppleWatch HR
    }
}