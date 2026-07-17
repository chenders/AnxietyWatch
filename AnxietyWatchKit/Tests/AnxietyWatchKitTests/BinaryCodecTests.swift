import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite("BinaryCodec")
struct BinaryCodecTests {
    private let nodeID = Data("0123456789abcdef".utf8)

    private func samples(count: Int) -> [SampleRow] {
        var rows: [SampleRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            let timestamp = 750_000_000.0 + Double(index) / 10.0
            let value = 97.5 + Double(index % 5) / 10.0
            let extra: Data? = index.isMultiple(of: 2) ? Data([1, 2, 3, 4]) : nil
            rows.append(SampleRow(
                source: 1,
                type: 2,
                timestamp: timestamp,
                value: value,
                extra: extra,
                hlcPhysical: 1_720_000_000_000 + Int64(index),
                hlcLogical: Int32(index % 10),
                nodeID: nodeID
            ))
        }
        return rows
    }

    @Test("Samples round trip")
    func samplesRoundTrip() throws {
        let original = samples(count: 3)
        let encoded = try BinaryCodec.encodeSamplePayload(original)
        #expect(try BinaryCodec.decodeSamplePayload(encoded) == original)
    }

    @Test("Tombstones round trip")
    func tombstonesRoundTrip() throws {
        let original = SampleTombstoneRow.Reason.allCases.enumerated().map { index, reason in
            SampleTombstoneRow(
                source: 1,
                type: 2,
                tsStart: 100 + Double(index),
                tsEnd: 200 + Double(index),
                hlcPhysical: 1_720_000_000_000 + Int64(index),
                hlcLogical: Int32(index),
                nodeID: nodeID,
                droppedRowCount: Int64(25 + index),
                reason: reason
            )
        }
        let encoded = try BinaryCodec.encodeTombstonePayload(original)
        #expect(try BinaryCodec.decodeTombstonePayload(encoded) == original)
    }

    @Test("Compression reduces a representative batch")
    func compressionReducesSize() throws {
        let encoded = try BinaryCodec.encodeSamplePayload(samples(count: 150))
        let compressed = encoded.dropFirst(4)
        let uncompressed = try (compressed as NSData).decompressed(using: .zlib)
        #expect(compressed.count < uncompressed.length)
    }

    @Test("Length prefix describes compressed bytes")
    func lengthPrefix() throws {
        let encoded = try BinaryCodec.encodeSamplePayload(samples(count: 10))
        let declared = encoded.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int(declared) == encoded.count - 4)
    }

    @Test("Empty payloads round trip")
    func emptyPayloads() throws {
        #expect(try BinaryCodec.decodeSamplePayload(BinaryCodec.encodeSamplePayload([])).isEmpty)
        #expect(try BinaryCodec.decodeTombstonePayload(BinaryCodec.encodeTombstonePayload([])).isEmpty)
    }

    @Test("A thousand samples encode and decode in under 100 ms")
    func largePayloadPerformance() throws {
        let original = samples(count: 1_100)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let encoded = try BinaryCodec.encodeSamplePayload(original)
            let decoded = try BinaryCodec.decodeSamplePayload(encoded)
            #expect(decoded == original)
        }
        #expect(elapsed < .milliseconds(100))
    }
}
