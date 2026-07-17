import XCTest
@testable import AnxietyWatchKit

final class SyncMessageCodecTests: XCTestCase {

    // MARK: - Helpers

    private var sampleCursor: SyncCursor {
        var c = SyncCursor()
        let nodeID = Data("0123456789abcdef".utf8) // 16 bytes
        _ = c.advance(nodeID: nodeID, physical: 1_720_000_000_000, logical: 7)
        return c
    }

    private var sampleHLC: HLCStamped {
        HLCStamped(
            physical: 1_720_000_001_000,
            logical: 3,
            nodeID: Data("fedcba9876543210".utf8) // 16 bytes
        )
    }

    private func dummyRecordsData() -> Data {
        let records: [[String: Any]] = [
            ["id": 1, "value": 0.85],
            ["id": 2, "value": 0.92]
        ]
        return try! JSONSerialization.data(withJSONObject: records)
    }

    // MARK: - Round-trip tests

    func testPingRoundTrip() throws {
        let cursor = sampleCursor
        let original = SyncMessage.ping(nodeID: "watch-1", cursor: cursor)
        let dict = try SyncMessageCodec.encode(original)
        let decoded = try SyncMessageCodec.decode(dict)
        XCTAssertEqual(original, decoded)
        guard case .ping(let nodeID, let decodedCursor) = decoded else {
            return XCTFail("Expected .ping, got \(decoded)")
        }
        XCTAssertEqual(nodeID, "watch-1")
        XCTAssertEqual(decodedCursor, cursor)
    }

    func testPongRoundTrip() throws {
        let cursor = sampleCursor
        let original = SyncMessage.pong(nodeID: "phone-1", cursor: cursor)
        let dict = try SyncMessageCodec.encode(original)
        let decoded = try SyncMessageCodec.decode(dict)
        XCTAssertEqual(original, decoded)
        guard case .pong(let nodeID, let decodedCursor) = decoded else {
            return XCTFail("Expected .pong, got \(decoded)")
        }
        XCTAssertEqual(nodeID, "phone-1")
        XCTAssertEqual(decodedCursor, cursor)
    }

    func testFetchRoundTrip() throws {
        let cursor = sampleCursor
        let original = SyncMessage.fetch(nodeID: "watch-1", after: cursor, limit: 200)
        let dict = try SyncMessageCodec.encode(original)
        let decoded = try SyncMessageCodec.decode(dict)
        XCTAssertEqual(original, decoded)
        guard case .fetch(let nodeID, let after, let limit) = decoded else {
            return XCTFail("Expected .fetch, got \(decoded)")
        }
        XCTAssertEqual(nodeID, "watch-1")
        XCTAssertEqual(after, cursor)
        XCTAssertEqual(limit, 200)
    }

    func testBatchRoundTrip() throws {
        let cursor = sampleCursor
        let recordsData = dummyRecordsData()
        let original = SyncMessage.batch(
            nodeID: "watch-1",
            cursor: cursor,
            recordsData: recordsData
        )
        let dict = try SyncMessageCodec.encode(original)
        let decoded = try SyncMessageCodec.decode(dict)
        XCTAssertEqual(original, decoded)
        guard case .batch(let nodeID, let decodedCursor, let decodedRecordsData) = decoded else {
            return XCTFail("Expected .batch, got \(decoded)")
        }
        XCTAssertEqual(nodeID, "watch-1")
        XCTAssertEqual(decodedCursor, cursor)
        XCTAssertEqual(decodedRecordsData, recordsData)
    }

    func testUrgentRoundTrip() throws {
        let hlc = sampleHLC
        let original = SyncMessage.urgent(nodeID: "watch-1", latestHLC: hlc)
        let dict = try SyncMessageCodec.encode(original)
        let decoded = try SyncMessageCodec.decode(dict)
        XCTAssertEqual(original, decoded)
        guard case .urgent(let nodeID, let decodedHLC) = decoded else {
            return XCTFail("Expected .urgent, got \(decoded)")
        }
        XCTAssertEqual(nodeID, "watch-1")
        XCTAssertEqual(decodedHLC, hlc)
    }

    // MARK: - Error tests

    func testDecodeFailsOnMissingPayload() {
        let empty: [String: Any] = [:]
        do {
            _ = try SyncMessageCodec.decode(empty)
            XCTFail("Should throw on empty payload")
        } catch SyncMessageCodec.CodecError.missingPayload {
            // Expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testDecodeFailsOnInvalidData() {
        // Key "p" is present but the Data is not valid JSON.
        let bad: [String: Any] = ["p": Data([0xff, 0xfe, 0xfd])]
        do {
            _ = try SyncMessageCodec.decode(bad)
            XCTFail("Should throw on invalid data")
        } catch SyncMessageCodec.CodecError.decodingFailed {
            // Expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}
