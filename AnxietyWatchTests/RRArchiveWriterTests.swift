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

    // F-067: recovery/orphan summaries seed rrCount from the archive; the
    // count must use the same artifact filter as the live tick path so a
    // recovered session's beat count matches an uninterrupted one.
    @Test("physiologicalRecordCount excludes out-of-range artifacts that recordCount includes")
    func physiologicalRecordCountFiltersArtifacts() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try RRArchiveWriter(url: url)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let rrValues: [Double] = [800, 120, 850, 2_400, 900]  // 2 artifacts
        for (i, rr) in rrValues.enumerated() {
            try writer.append(RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: rr))
        }
        try writer.finalize()

        #expect(RRArchiveWriter.recordCount(url: url) == 5)
        #expect(RRArchiveWriter.physiologicalRecordCount(url: url) == 3)
    }

    @Test("physiologicalRecordCount returns 0 for a missing archive")
    func physiologicalRecordCountMissingFile() {
        #expect(RRArchiveWriter.physiologicalRecordCount(url: tempURL()) == 0)
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

    // F-025: a partial trailing record (interrupted flush) must not discard
    // the intact aligned prefix — throwing here made every caller treat the
    // whole night's archive as "no archive".
    @Test("read salvages the aligned prefix of a file with a partial trailing record")
    func readSalvagesAlignedPrefix() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write 3 real records, then simulate an interrupted flush by
        // appending 5 junk bytes (half a record).
        let writer = try RRArchiveWriter(url: url)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            try writer.append(RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: Double(800 + i)))
        }
        try writer.finalize()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 5))
        try handle.close()

        let read = try RRArchiveWriter.read(url: url)
        #expect(read.count == 3)
        #expect(read.map(\.rrMs) == [800, 801, 802])
    }

    @Test("append=true over a zero-byte existing file starts cleanly")
    func appendToZeroByteFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)

        let writer = try RRArchiveWriter(url: url, append: true)
        try writer.append(RRIntervalSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000), rrMs: 800))
        try writer.finalize()

        #expect(try RRArchiveWriter.read(url: url).count == 1)
    }

    @Test("append=true over a file smaller than one record truncates to empty, then appends")
    func appendToSubRecordFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // 4 junk bytes — less than one 10-byte record; the aligned prefix is 0.
        try Data(repeating: 0xAB, count: 4).write(to: url)

        let writer = try RRArchiveWriter(url: url, append: true)
        try writer.append(RRIntervalSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000), rrMs: 800))
        try writer.finalize()

        let read = try RRArchiveWriter.read(url: url)
        #expect(read.count == 1)
        #expect(read.first?.rrMs == 800)
    }

    @Test("recordCount counts the aligned prefix of a misaligned file")
    func recordCountCountsAlignedPrefix() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // 2 full records + half a record of junk.
        try Data(repeating: 0xAB, count: 25).write(to: url)
        #expect(RRArchiveWriter.recordCount(url: url) == 2)
    }

    @Test("alignedPrefix drops only the partial trailing record bytes")
    func alignedPrefixTrimsPartialTail() {
        let misaligned = Data(repeating: 0xCD, count: 25)
        #expect(RRArchiveWriter.alignedPrefix(of: misaligned).count == 20)
        let aligned = Data(repeating: 0xCD, count: 20)
        #expect(RRArchiveWriter.alignedPrefix(of: aligned).count == 20)
        #expect(RRArchiveWriter.alignedPrefix(of: Data()).isEmpty)
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

    // F-025: append-mode used to recreate a misaligned file EMPTY, silently
    // destroying every beat recorded before the crash that misaligned it.
    // It must truncate only the partial trailing record and keep the rest.
    @Test("append=true keeps the aligned prefix when existing file isn't record-aligned")
    func appendKeepsAlignedPrefixOfUnalignedFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // 4 real records, then 5 junk bytes simulating an interrupted flush.
        let writer1 = try RRArchiveWriter(url: url)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<4 {
            try writer1.append(RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: Double(800 + i)))
        }
        try writer1.finalize()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 5))
        try handle.close()

        // Append-mode repairs the tail and appends after the intact records.
        let writer2 = try RRArchiveWriter(url: url, append: true)
        try writer2.append(RRIntervalSample(timestamp: t0.addingTimeInterval(10), rrMs: 900))
        try writer2.finalize()

        let read = try RRArchiveWriter.read(url: url)
        #expect(read.count == 5)
        #expect(read.map(\.rrMs) == [800, 801, 802, 803, 900])
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
