// AnxietyWatch/Services/RRArchiveWriter.swift
import Foundation
import os

/// Streams per-session RR intervals to an uncompressed binary file.
/// Format per record (10 bytes, big-endian):
///   uint64 timestamp_ms (Unix epoch ms)
///   uint16 rr_ms        (must fit uint16; H10 produces 300..2000 — values
///                        outside 0..65535 cause `append` to throw `.rrOutOfRange`)
///
/// Phase 1 keeps the format raw on disk. Compression is applied at upload
/// time in Phase 3 since the on-device size (~300 KB/night) doesn't justify
/// the streaming-compression complexity locally.
///
/// Declared `nonisolated` so the BLE service can drive it (append RR intervals
/// during recording, flush on stop) without hopping to the main actor for
/// every tick. As of the F-090 fix `finalizeOffline` calls `finalize()`
/// synchronously on the @MainActor at session stop (so the file is complete
/// before `endTime` becomes visible to the sync path) — no longer via a
/// background `Task.detached`. Instances are owned by a single caller (the BLE
/// service) and never shared across threads at a time, so internal state is
/// safe under that ownership invariant.
nonisolated final class RRArchiveWriter: @unchecked Sendable {

    enum WriteError: Error, Equatable {
        case rrOutOfRange
        case createFileFailed
        case timestampOutOfRange
    }

    private static let recordSize = 10
    private static let flushThreshold = 65_536

    /// Canonical on-disk location for a session's RR-interval archive. The
    /// path is derived purely from `sessionID`, so any subsystem that knows
    /// a `SensorSession.id` can locate its archive — the BLE writer, the
    /// sync uploader, and (future) the chart pipeline don't need to share
    /// state, only the UUID.
    ///
    /// Falls back to `temporaryDirectory` if `applicationSupportDirectory`
    /// is unavailable — only happens in extreme low-storage / corrupted
    /// container states, where any write is going to fail anyway. Returning
    /// a temp path keeps the failure mode "write fails when archive opens"
    /// rather than "force-unwrap crashes here".
    static func archiveURL(for sessionID: UUID) -> URL {
        let supportDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return supportDir
            .appendingPathComponent("rr_archives", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).rr")
    }

    private let url: URL
    private var pending = Data()

    convenience init(url: URL) throws {
        try self.init(url: url, append: false)
    }

    /// `append: true` opens an existing per-session file without truncating,
    /// used during state-restoration recovery so RR data flowing in after
    /// app relaunch lands at the end of the archive rather than rewriting
    /// the recording from scratch. A misaligned file (partial trailing
    /// record from an interrupted flush) has only that partial tail
    /// truncated — see the inline comment in the body (F-025).
    init(url: URL, append: Bool) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let exists = FileManager.default.fileExists(atPath: url.path)
        if append && exists {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            if size % Self.recordSize == 0 {
                return  // good to go; file stays as-is, FileHandle will seekToEnd in flush
            }
            // Misaligned = a crash/jetsam interrupted flushToDisk mid-write,
            // leaving a partial trailing record. Truncate ONLY that partial
            // tail so subsequent appends stay record-aligned. The previous
            // behavior recreated the file empty — silently destroying every
            // beat recorded before the crash for a multi-hour session, the
            // exact data recovery exists to preserve (F-025).
            let alignedSize = size - (size % Self.recordSize)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(alignedSize))
            Log.data.warning("""
                RR archive at \(url.lastPathComponent, privacy: .public) was misaligned \
                (\(size) bytes); truncated partial trailing record to \(alignedSize) bytes
                """)
            return
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw WriteError.createFileFailed
        }
    }

    func append(_ sample: RRIntervalSample) throws {
        let rrInt = Int(sample.rrMs.rounded())
        guard rrInt >= 0 && rrInt <= 65_535 else { throw WriteError.rrOutOfRange }

        // Validate the timestamp before the UInt64 conversion: NaN, infinity,
        // negatives (pre-1970), and values that overflow UInt64 would all trap
        // on the next line otherwise. BLE arrival timestamps come from external
        // clocks; we don't trust them blindly.
        let tsSeconds = sample.timestamp.timeIntervalSince1970
        let tsMsDouble = tsSeconds * 1000
        guard tsSeconds.isFinite,
              tsSeconds >= 0,
              tsMsDouble <= Double(UInt64.max) else {
            throw WriteError.timestampOutOfRange
        }
        let tsMs = UInt64(tsMsDouble)
        let tsBE = tsMs.bigEndian
        let rrBE = UInt16(rrInt).bigEndian
        // Append directly from the stack-allocated values; avoids the per-sample
        // Data(bytes:count:) allocations that would otherwise pile up at 30k+
        // intervals per session.
        withUnsafeBytes(of: tsBE) { pending.append(contentsOf: $0) }
        withUnsafeBytes(of: rrBE) { pending.append(contentsOf: $0) }

        if pending.count >= Self.flushThreshold {
            try flushToDisk()
        }
    }

    func finalize() throws {
        try flushToDisk()
    }

    private func flushToDisk() throws {
        guard !pending.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// Count the records in an existing archive file. Returns 0 if the file
    /// doesn't exist. A misaligned file (partial trailing record from an
    /// interrupted write) counts its aligned prefix — matching what
    /// `read(url:)` salvages and what `init(url:append:true)` preserves
    /// after truncating the partial tail (F-025).
    static func recordCount(url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            return 0
        }
        return size / recordSize  // integer division floors away a partial tail
    }

    /// The record-aligned prefix of raw archive bytes — drops a partial
    /// trailing record left by an interrupted write. Used by the sync
    /// uploader so the server never stores a misaligned archive even for
    /// sessions whose file is never reopened by a writer (F-025).
    static func alignedPrefix(of data: Data) -> Data {
        let alignedCount = data.count - (data.count % recordSize)
        return alignedCount == data.count ? data : data.prefix(alignedCount)
    }

    /// Count only the archive records whose RR value passes the shared
    /// physiological artifact filter. Session-recovery and orphan-finalize
    /// seed a summary's `rrCount` from the archive; the raw `recordCount`
    /// includes artifacts that every other rrCount contributor (the live
    /// tick path) excludes, so a recovered session's beat count was
    /// inflated relative to an identical uninterrupted one (F-067).
    /// Returns 0 for a missing or unreadable archive, matching
    /// `recordCount`'s "nothing usable here" semantics.
    static func physiologicalRecordCount(
        url: URL,
        validRange: ClosedRange<Double> = HRVCalculator.physiologicalRRRangeMs
    ) -> Int {
        guard let samples = try? read(url: url) else { return 0 }
        return samples.count(where: { validRange.contains($0.rrMs) })
    }

    static func read(url: URL) throws -> [RRIntervalSample] {
        var raw = try Data(contentsOf: url)
        if raw.count % Self.recordSize != 0 {
            // Trailing partial record from an interrupted write. Salvage the
            // aligned prefix (hours of intact per-beat data) rather than
            // refusing the whole file: every caller treated the old
            // .truncatedArchive throw as "no archive" (`try? … ?? []`),
            // discarding the intact portion along with the corrupt tail —
            // the HR detail chart and recovery silently lost the whole
            // night for one partial record (F-025).
            let alignedCount = raw.count - (raw.count % Self.recordSize)
            Log.data.warning("""
                RR archive at \(url.lastPathComponent, privacy: .public) has a partial \
                trailing record (\(raw.count) bytes); reading aligned prefix of \(alignedCount) bytes
                """)
            raw = raw.prefix(alignedCount)
        }
        let count = raw.count / Self.recordSize
        var out: [RRIntervalSample] = []
        out.reserveCapacity(count)

        // `loadUnaligned(fromByteOffset:as:)` avoids the alignment trap that
        // `subdata(in:).withUnsafeBytes { $0.load(as:) }` can hit on Data
        // slices whose backing pointer isn't 8-aligned, and skips the
        // per-record allocation `subdata` would require.
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let offset = i * Self.recordSize
                let tsBE = buf.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                let rrBE = buf.loadUnaligned(fromByteOffset: offset + 8, as: UInt16.self)
                let ts = UInt64(bigEndian: tsBE)
                let rr = UInt16(bigEndian: rrBE)
                out.append(RRIntervalSample(
                    timestamp: Date(timeIntervalSince1970: Double(ts) / 1000),
                    rrMs: Double(rr)
                ))
            }
        }
        return out
    }
}
