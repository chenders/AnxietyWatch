import Foundation
import XCTest
@testable import AnxietyWatchKit

final class HLCStampedTests: XCTestCase {
    private func data(_ bytes: [UInt8]) -> Data { Data(bytes) }

    func testInitAndPropertiesRoundTrip() {
        let node = data(Array(repeating: 0xAB, count: 16))
        let s = HLCStamped(physical: 1_725_000_000_000, logical: 42, nodeID: node)
        XCTAssertEqual(s.physical, 1_725_000_000_000)
        XCTAssertEqual(s.logical, 42)
        XCTAssertEqual(s.nodeID, node)
    }

    func testCodableRoundTripJSON() throws {
        let node = data((0..<16).map { UInt8($0) })
        let original = HLCStamped(physical: 1_700_000_123_456, logical: 7, nodeID: node)

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let encoded = try enc.encode(original)

        let dec = JSONDecoder()
        let decoded = try dec.decode(HLCStamped.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testComparableOrdering() {
        let nodeA = data(Array(repeating: 0x00, count: 16))
        let nodeB = data(Array(repeating: 0xFF, count: 16))

        let p0l0a = HLCStamped(physical: 1000, logical: 0, nodeID: nodeA)
        let p0l0b = HLCStamped(physical: 1000, logical: 0, nodeID: nodeB)
        let p0l1a = HLCStamped(physical: 1000, logical: 1, nodeID: nodeA)
        let p1l0a = HLCStamped(physical: 1001, logical: 0, nodeID: nodeA)

        // physical tier
        XCTAssertTrue(p0l0a < p1l0a)
        XCTAssertFalse(p1l0a < p0l0a)

        // logical tier (same physical)
        XCTAssertTrue(p0l0a < p0l1a)
        XCTAssertFalse(p0l1a < p0l0a)

        // nodeID tiebreaker (same physical, logical)
        XCTAssertTrue(p0l0a < p0l0b)
        XCTAssertFalse(p0l0b < p0l0a)
        XCTAssertNotEqual(p0l0a, p0l0b)
    }

    func testHashableAndEquatable() {
        let node = data(Array(repeating: 0xCC, count: 16))
        let a = HLCStamped(physical: 123, logical: 2, nodeID: node)
        let b = HLCStamped(physical: 123, logical: 2, nodeID: node)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        var set: Set<HLCStamped> = []
        set.insert(a)
        set.insert(b) // should not duplicate
        XCTAssertEqual(set.count, 1)
    }
}
