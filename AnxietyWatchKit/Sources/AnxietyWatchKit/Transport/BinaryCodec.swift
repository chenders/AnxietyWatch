import Foundation

/// Compact, zlib-compressed wire encoding for high-volume WCSession rows.
///
/// Each result is one frame: a four-byte big-endian compressed-payload length,
/// followed by the zlib data. The uncompressed body starts with a format version,
/// a payload kind, and a row count, then contains fixed-width numeric fields and
/// length-prefixed byte/string fields. This deliberately avoids JSON's keys,
/// decimal conversion, and base-64 expansion.
public enum BinaryCodec {
    public enum CodecError: Error, Equatable {
        case truncated
        case invalidLengthPrefix
        case unsupportedVersion(UInt8)
        case unexpectedPayloadKind
        case invalidUTF8
        case invalidReason(String)
        case valueOutOfRange
        case trailingBytes
        case compressionFailed
        case decompressionFailed
    }

    private static let version: UInt8 = 1
    private static let sampleKind: UInt8 = 1
    private static let tombstoneKind: UInt8 = 2

    public static func encodeSamplePayload(_ samples: [SampleRow]) throws -> Data {
        var writer = Writer()
        writer.append(version)
        writer.append(sampleKind)
        try writer.appendCount(samples.count)
        for row in samples {
            writer.append(row.source)
            writer.append(row.type)
            writer.append(row.timestamp)
            writer.append(row.value)
            try writer.appendOptionalData(row.extra)
            writer.append(row.hlcPhysical)
            writer.append(row.hlcLogical)
            try writer.appendData(row.nodeID)
        }
        return try frame(writer.data)
    }

    public static func decodeSamplePayload(_ frame: Data) throws -> [SampleRow] {
        var reader = Reader(data: try unframe(frame))
        try reader.readHeader(kind: sampleKind)
        let count = try reader.readCount()
        var rows: [SampleRow] = []
        rows.reserveCapacity(count)
        for _ in 0..<count {
            rows.append(SampleRow(
                source: try reader.readInt32(),
                type: try reader.readInt32(),
                timestamp: try reader.readDouble(),
                value: try reader.readDouble(),
                extra: try reader.readOptionalData(),
                hlcPhysical: try reader.readInt64(),
                hlcLogical: try reader.readInt32(),
                nodeID: try reader.readData()
            ))
        }
        try reader.requireEnd()
        return rows
    }

    public static func encodeTombstonePayload(_ tombstones: [SampleTombstoneRow]) throws -> Data {
        var writer = Writer()
        writer.append(version)
        writer.append(tombstoneKind)
        try writer.appendCount(tombstones.count)
        for row in tombstones {
            guard let droppedCount = Int32(exactly: row.droppedRowCount) else {
                throw CodecError.valueOutOfRange
            }
            writer.append(row.source)
            writer.append(row.type)
            writer.append(row.tsStart)
            writer.append(row.tsEnd)
            writer.append(row.hlcPhysical)
            writer.append(row.hlcLogical)
            try writer.appendData(row.nodeID)
            writer.append(droppedCount)
            try writer.appendData(Data(row.reason.rawValue.utf8))
        }
        return try frame(writer.data)
    }

    public static func decodeTombstonePayload(_ frame: Data) throws -> [SampleTombstoneRow] {
        var reader = Reader(data: try unframe(frame))
        try reader.readHeader(kind: tombstoneKind)
        let count = try reader.readCount()
        var rows: [SampleTombstoneRow] = []
        rows.reserveCapacity(count)
        for _ in 0..<count {
            let source = try reader.readInt32()
            let type = try reader.readInt32()
            let tsStart = try reader.readDouble()
            let tsEnd = try reader.readDouble()
            let physical = try reader.readInt64()
            let logical = try reader.readInt32()
            let nodeID = try reader.readData()
            let droppedCount = try reader.readInt32()
            let reasonData = try reader.readData()
            guard let reasonString = String(data: reasonData, encoding: .utf8) else {
                throw CodecError.invalidUTF8
            }
            guard let reason = SampleTombstoneRow.Reason(rawValue: reasonString) else {
                throw CodecError.invalidReason(reasonString)
            }
            rows.append(SampleTombstoneRow(
                source: source,
                type: type,
                tsStart: tsStart,
                tsEnd: tsEnd,
                hlcPhysical: physical,
                hlcLogical: logical,
                nodeID: nodeID,
                droppedRowCount: Int64(droppedCount),
                reason: reason
            ))
        }
        try reader.requireEnd()
        return rows
    }

    private static func frame(_ body: Data) throws -> Data {
        let compressed: Data
        do {
            compressed = try (body as NSData).compressed(using: .zlib) as Data
        } catch {
            throw CodecError.compressionFailed
        }
        guard let length = UInt32(exactly: compressed.count) else {
            throw CodecError.valueOutOfRange
        }
        var result = Data()
        result.reserveCapacity(4 + compressed.count)
        result.appendBigEndian(length)
        result.append(compressed)
        return result
    }

    private static func unframe(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw CodecError.truncated }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) == frame.count - 4 else { throw CodecError.invalidLengthPrefix }
        do {
            return try (frame.dropFirst(4) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw CodecError.decompressionFailed
        }
    }
}

private struct Writer {
    var data = Data()

    mutating func append(_ value: UInt8) { data.append(value) }
    mutating func append(_ value: Int32) { data.appendBigEndian(UInt32(bitPattern: value)) }
    mutating func append(_ value: Int64) { data.appendBigEndian(UInt64(bitPattern: value)) }
    mutating func append(_ value: Double) { data.appendBigEndian(value.bitPattern) }

    mutating func appendCount(_ count: Int) throws {
        guard let value = UInt32(exactly: count) else { throw BinaryCodec.CodecError.valueOutOfRange }
        data.appendBigEndian(value)
    }

    mutating func appendData(_ value: Data) throws {
        try appendCount(value.count)
        data.append(value)
    }

    mutating func appendOptionalData(_ value: Data?) throws {
        guard let value else {
            data.appendBigEndian(UInt32.max)
            return
        }
        try appendData(value)
    }
}

private struct Reader {
    let data: Data
    var offset = 0

    mutating func readHeader(kind: UInt8) throws {
        let decodedVersion = try readUInt8()
        guard decodedVersion == 1 else { throw BinaryCodec.CodecError.unsupportedVersion(decodedVersion) }
        guard try readUInt8() == kind else { throw BinaryCodec.CodecError.unexpectedPayloadKind }
    }

    mutating func readCount() throws -> Int { Int(try readUInt32()) }
    mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }
    mutating func readInt64() throws -> Int64 { Int64(bitPattern: try readUInt64()) }
    mutating func readDouble() throws -> Double { Double(bitPattern: try readUInt64()) }

    mutating func readOptionalData() throws -> Data? {
        let length = try readUInt32()
        if length == UInt32.max { return nil }
        return try readData(length: Int(length))
    }

    mutating func readData() throws -> Data { try readData(length: readCount()) }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw BinaryCodec.CodecError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(length: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(length: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readData(length: Int) throws -> Data {
        guard length >= 0, length <= data.count - offset else { throw BinaryCodec.CodecError.truncated }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }

    func requireEnd() throws {
        guard offset == data.count else { throw BinaryCodec.CodecError.trailingBytes }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
