import XCTest
@testable import AnxietyWatchKit

final class SyncCursorTests: XCTestCase {
    
    func testWatermarkFallbackForUnknownNode() throws {
        let cursor = SyncCursor()
        let nodeID = Data([0x01, 0x02, 0x03])
        let watermark = cursor.watermark(for: nodeID)
        XCTAssertEqual(watermark.physical, 0)
        XCTAssertEqual(watermark.logical, -1)
    }
    
    func testAdvanceUpdatesOnStrictlyGreater() throws {
        var cursor = SyncCursor()
        let nodeID = Data([0x01, 0x02, 0x03])
        
        // Advance to (100, 0)
        let updated1 = cursor.advance(nodeID: nodeID, physical: 100, logical: 0)
        XCTAssertTrue(updated1)
        let watermark1 = cursor.watermark(for: nodeID)
        XCTAssertEqual(watermark1.physical, 100)
        XCTAssertEqual(watermark1.logical, 0)
        
        // Try to advance to (99, 0) - should not update
        let updated2 = cursor.advance(nodeID: nodeID, physical: 99, logical: 0)
        XCTAssertFalse(updated2)
        let watermark2 = cursor.watermark(for: nodeID)
        XCTAssertEqual(watermark2.physical, 100)
        XCTAssertEqual(watermark2.logical, 0)
        
        // Advance to (100, 1) - should update
        let updated3 = cursor.advance(nodeID: nodeID, physical: 100, logical: 1)
        XCTAssertTrue(updated3)
        let watermark3 = cursor.watermark(for: nodeID)
        XCTAssertEqual(watermark3.physical, 100)
        XCTAssertEqual(watermark3.logical, 1)
    }
    
    func testAdvanceRetainsDistinctNodes() throws {
        var cursor = SyncCursor()
        let nodeID1 = Data([0x01, 0x02, 0x03])
        let nodeID2 = Data([0x04, 0x05, 0x06])
        
        // Advance node1 to (100, 0)
        cursor.advance(nodeID: nodeID1, physical: 100, logical: 0)
        
        // Advance node2 to (200, 0)
        cursor.advance(nodeID: nodeID2, physical: 200, logical: 0)
        
        // Check both nodes have their own watermarks
        XCTAssertEqual(cursor.knownNodes.count, 2)
        let watermark1 = cursor.watermark(for: nodeID1)
        XCTAssertEqual(watermark1.physical, 100)
        XCTAssertEqual(watermark1.logical, 0)
        let watermark2 = cursor.watermark(for: nodeID2)
        XCTAssertEqual(watermark2.physical, 200)
        XCTAssertEqual(watermark2.logical, 0)
    }
    
    func testCodableRoundTrip() throws {
        var cursor = SyncCursor()
        let nodeID1 = Data([0x01, 0x02, 0x03])
        let nodeID2 = Data([0x04, 0x05, 0x06])
        let nodeID3 = Data([0x07, 0x08, 0x09])
        
        // Set up cursor with 3 nodes
        cursor.advance(nodeID: nodeID1, physical: 100, logical: 0)
        cursor.advance(nodeID: nodeID2, physical: 200, logical: 5)
        cursor.advance(nodeID: nodeID3, physical: 300, logical: 10)
        
        // Encode and decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(cursor)
        let decoder = JSONDecoder()
        let decodedCursor = try decoder.decode(SyncCursor.self, from: data)
        
        // Check equality
        XCTAssertEqual(cursor, decodedCursor)
    }
    
    func testCodableEncodingIsSorted() throws {
        var cursor = SyncCursor()
        // Create node IDs that would be out of order if not sorted
        let nodeID_B = Data([0x02]) // 'B'
        let nodeID_A = Data([0x01]) // 'A'
        
        // Insert in reverse order
        cursor.advance(nodeID: nodeID_B, physical: 200, logical: 0)
        cursor.advance(nodeID: nodeID_A, physical: 100, logical: 0)
        
        // Encode to JSON string
        let encoder = JSONEncoder()
        let data = try encoder.encode(cursor)
        let jsonString = String(data: data, encoding: .utf8)!
        
        // The entries should be sorted by node ID (A then B)
        // So "n":"AQ==" (A) should come before "n":"Ag==" (B) in the JSON
        XCTAssertTrue(jsonString.range(of: "AQ==.*Ag==", options: .regularExpression) != nil,
                      "Entries should be sorted by node ID lexicographically")
    }
    
    func testCursorFormatVersion() throws {
        XCTAssertEqual(SyncCursor.cursorFormatVersion, 2)
    }
    
    func testTableCursorsRoundTrip() throws {
        var samplesCursor = SyncCursor()
        var tombstonesCursor = SyncCursor()
        var syncLogCursor = SyncCursor()
        
        let nodeID = Data([0x01, 0x02, 0x03])
        samplesCursor.advance(nodeID: nodeID, physical: 100, logical: 0)
        tombstonesCursor.advance(nodeID: nodeID, physical: 200, logical: 5)
        syncLogCursor.advance(nodeID: nodeID, physical: 300, logical: 10)
        
        let tableCursors = TableCursors(
            samples: samplesCursor,
            sampleTombstones: tombstonesCursor,
            syncLog: syncLogCursor
        )
        
        // Encode and decode
        let encoder = JSONEncoder()
        let data = try encoder.encode(tableCursors)
        let decoder = JSONDecoder()
        let decodedTableCursors = try decoder.decode(TableCursors.self, from: data)
        
        // Check equality
        XCTAssertEqual(tableCursors, decodedTableCursors)
    }

    /// TableCursors wire keys MUST match Spec §2.7 exactly: samples /
    /// sample_tombstones / sync_log. Any drift here is a guaranteed 2C break
    /// against the server contract.
    func testTableCursorsWireKeysMatchSpec() throws {
        let cursors = TableCursors(
            samples: SyncCursor(),
            sampleTombstones: SyncCursor(),
            syncLog: SyncCursor()
        )
        let data = try JSONEncoder().encode(cursors)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"samples\""),
                      "Wire must carry 'samples' — got: \(json)")
        XCTAssertTrue(json.contains("\"sample_tombstones\""),
                      "Wire must carry 'sample_tombstones' (snake), NOT 'sampleTombstones' — got: \(json)")
        XCTAssertTrue(json.contains("\"sync_log\""),
                      "Wire must carry 'sync_log' (snake), NOT 'syncLog' — got: \(json)")

        // Round-trip through the snake_case wire form.
        let decoded = try JSONDecoder().decode(TableCursors.self, from: data)
        XCTAssertEqual(cursors, decoded)
    }
}