// AnxietyWatch/Services/RRArchiveWriter.swift
import Foundation

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
/// Declared `nonisolated` so `PolarHRMService.finalizeOffline` can close the
/// file from a background `Task.detached` and not block the main actor
/// during session stop. Instances are owned by a single caller (the BLE
/// service) and never shared across threads at a time, so internal state
/// is safe under that ownership invariant.
nonisolated final class RRArchiveWriter: @unchecked Sendable {

    enum WriteError: Error, Equatable {
        case rrOutOfRange
        case createFileFailed
        case truncatedArchive(byteCount: Int)
        case timestampOutOfRange
    }

    private static let recordSize = 10
    private static let flushThreshold = 65_536

    private let url: URL
    private var pending = Data()

    convenience init(url: URL) throws {
        try self.init(url: url, append: false)
    }

    /// `append: true` opens an existing per-session file without truncating,
    /// used during state-restoration recovery so RR data flowing in after
    /// app relaunch lands at the end of the archive rather than rewriting
    /// the recording from scratch.
    init(url: URL, append: Bool) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let exists = FileManager.default.fileExists(atPath: url.path)
        if append && exists {
            // Verify the file is record-aligned; if it isn't, truncate so we
            // don't append into a partial record and produce a misaligned
            // archive that read() would refuse with .truncatedArchive.
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            if size % Self.recordSize == 0 {
                return  // good to go; file stays as-is, FileHandle will seekToEnd in flush
            }
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
    /// doesn't exist or its byte count isn't an exact multiple of the
    /// record size — both indistinguishable from "nothing usable here"
    /// from the caller's perspective.
    ///
    /// Pairs with `init(url:append:true)`'s alignment behavior: that
    /// initializer truncates an unaligned file before appending, so any
    /// caller that wants a count consistent with what the writer will
    /// actually preserve should use this helper rather than dividing the
    /// raw byte count by `recordSize`.
    static func recordCount(url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            return 0
        }
        guard size % recordSize == 0 else { return 0 }
        return size / recordSize
    }

    static func read(url: URL) throws -> [RRIntervalSample] {
        let raw = try Data(contentsOf: url)
        guard raw.count % Self.recordSize == 0 else {
            // Trailing partial record: signal truncation/corruption rather than
            // silently dropping the last bytes. Phase 3 sync will be able to
            // surface this so the upload doesn't ship a corrupt archive.
            throw WriteError.truncatedArchive(byteCount: raw.count)
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
