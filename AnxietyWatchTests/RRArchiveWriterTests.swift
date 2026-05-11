// AnxietyWatchTests/RRArchiveWriterTests.swift
import Foundation
import Testing

@testable import AnxietyWatch

struct RRArchiveWriterTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rr-\(UUID().uuidString).rr")
    }

    @Test("round-trip: writing then reading returns the same intervals in order")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try RRArchiveWriter(url: url)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let inputs: [RRIntervalSample] = (0..<100).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: Double(800 + i))
        }
        for s in inputs {
            try writer.append(s)
        }
        try writer.finalize()

        let read = try RRArchiveWriter.read(url: url)
        #expect(read.count == inputs.count)
        #expect(read.first?.rrMs == 800)
        #expect(read.last?.rrMs == 899)
        #expect(abs(read.first!.timestamp.timeIntervalSince1970 - t0.timeIntervalSince1970) < 0.001)
    }

    @Test("writing and reading 30,000 intervals succeeds at realistic overnight scale")
    func largeStream() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try RRArchiveWriter(url: url)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<30_000 {
            try writer.append(RRIntervalSample(
                timestamp: t0.addingTimeInterval(Double(i) * 0.8),
                rrMs: 800
            ))
        }
        try writer.finalize()

        let read = try RRArchiveWriter.read(url: url)
        #expect(read.count == 30_000)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        // 30_000 * 10 bytes = 300_000 exactly.
        #expect(size == 300_000)
    }

    @Test("read throws when the file's byte count isn't an exact multiple of the record size")
    func readDetectsTruncation() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Write 15 bytes — 1 full record (10) + 5 trailing bytes.
        try Data(repeating: 0xAB, count: 15).write(to: url)

        #expect(throws: RRArchiveWriter.WriteError.truncatedArchive(byteCount: 15)) {
            _ = try RRArchiveWriter.read(url: url)
        }
    }

    @Test("init throws when the file cannot be created at an invalid path")
    func initFailsOnUncreatableFile() {
        // /dev/null/foo is a path under a non-directory; createFile fails.
        let bogus = URL(fileURLWithPath: "/dev/null/forbidden.rr")
        #expect(throws: (any Error).self) {
            _ = try RRArchiveWriter(url: bogus)
        }
    }

    @Test("rrMs values outside uint16 range fail to append")
    func rejectsOutOfRangeRR() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RRArchiveWriter(url: url)
        #expect(throws: RRArchiveWriter.WriteError.rrOutOfRange) {
            try writer.append(RRIntervalSample(timestamp: Date(), rrMs: 99_999))
        }
        try writer.finalize()
    }

    @Test("append=true preserves existing aligned content")
    func appendPreservesAlignedContent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // First writer: write 5 records and finalize.
        let writer1 = try RRArchiveWriter(url: url)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            try writer1.append(RRIntervalSample(
                timestamp: t0.addingTimeInterval(Double(i)),
                rrMs: Double(800 + i)
            ))
        }
        try writer1.finalize()

        // Second writer: append-mode, add 3 more records.
        let writer2 = try RRArchiveWriter(url: url, append: true)
        for i in 5..<8 {
            try writer2.append(RRIntervalSample(
                timestamp: t0.addingTimeInterval(Double(i)),
                rrMs: Double(800 + i)
            ))
        }
        try writer2.finalize()

        let read = try RRArchiveWriter.read(url: url)
        #expect(read.count == 8)
        #expect(read.map(\.rrMs) == [800, 801, 802, 803, 804, 805, 806, 807])
    }

    @Test("append=true truncates when existing file isn't record-aligned")
    func appendTruncatesUnalignedFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write 15 bytes — 1 complete record (10) + 5 trailing junk bytes.
        try Data(repeating: 0xAB, count: 15).write(to: url)

        // Append-mode should treat this as corrupt and start fresh.
        let writer = try RRArchiveWriter(url: url, append: true)
        try writer.append(RRIntervalSample(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rrMs: 800
        ))
        try writer.finalize()

        let read = try RRArchiveWriter.read(url: url)
        #expect(read.count == 1)
        #expect(read.first?.rrMs == 800)
    }

    @Test("non-finite or pre-1970 timestamps throw rather than trapping")
    func rejectsBadTimestamps() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RRArchiveWriter(url: url)

        let nan = Date(timeIntervalSince1970: .nan)
        #expect(throws: RRArchiveWriter.WriteError.timestampOutOfRange) {
            try writer.append(RRIntervalSample(timestamp: nan, rrMs: 800))
        }

        let pre1970 = Date(timeIntervalSince1970: -1_000)
        #expect(throws: RRArchiveWriter.WriteError.timestampOutOfRange) {
            try writer.append(RRIntervalSample(timestamp: pre1970, rrMs: 800))
        }

        try writer.finalize()
    }
}
