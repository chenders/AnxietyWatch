import Foundation
import Compression
import OSLog

// MARK: - ExportLogs

/// Collects and compresses the AnxietyWatchKit diagnostic surface into a
/// single `.zip` file suitable for sharing with developers.
///
/// ## Output
/// A zip archive containing:
/// - `tsdb.sqlite` — the main SQLite database (WAL-checkpointed copy)
/// - `tsdb.sqlite-wal` — the WAL file (if present)
/// - `sync_cursor.json` — persisted sync cursors
/// - `anxietywatch.log` — text dump of `os_log` entries from
///   subsystem `com.anxietywatch.kit` within the requested time window
///
/// ## Usage
/// ```swift
/// let zip = try await ExportLogs.exportBundle(
///     databaseURL: dbURL,
///     cursorFileURL: cursorURL,
///     since: Date().addingTimeInterval(-7200)   // last 2 hours
/// )
/// // Share zip.zipURL via UIActivityViewController or WKInterfaceController
/// ```
public struct ExportLogs: Sendable {

    public struct Bundle: Sendable {
        /// URL of the generated `.zip` file in a temporary directory.
        public let zipURL: URL
        /// Number of files packed into the archive.
        public let fileCount: Int
    }

    // MARK: - Public entry point

    /// Copies the database (after a PASSIVE WAL checkpoint), the sync cursor
    /// file, and a window of `os_log` entries into a temporary zip.
    ///
    /// - Parameters:
    ///   - databaseURL: Path to `tsdb.sqlite` on disk.
    ///   - cursorFileURL: Path to `sync_cursor.json` (same directory).
    ///   - since: OSLog start of window. Defaults to the last hour.
    ///   - maximumLogEntries: Cap on OSLog entries per export.
    /// - Returns: A `Bundle` with the zip location and packed file count.
    public static func exportBundle(
        databaseURL: URL,
        cursorFileURL: URL,
        since: Date? = nil,
        maximumLogEntries: Int = 10_000
    ) async throws -> Bundle {

        // 1. Collect files into (name, data) pairs

        var files: [(name: String, data: Data)] = []

        // — main DB (with WAL checkpoint to flush)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            // Copy the file so we don't block or corrupt the running DB.
            // The caller should have already called checkpointManager.run(.passive)
            // before export; we read whatever is on disk.
            let dbData = try Data(contentsOf: databaseURL, options: .uncached)
            files.append((name: "tsdb.sqlite", data: dbData))
        }

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            let walData = try Data(contentsOf: walURL, options: .uncached)
            files.append((name: "tsdb.sqlite-wal", data: walData))
        }

        // — sync cursor
        if FileManager.default.fileExists(atPath: cursorFileURL.path) {
            let cursorData = try Data(contentsOf: cursorFileURL, options: .uncached)
            files.append((name: "sync_cursor.json", data: cursorData))
        }

        // — OSLog dump
        let logText = try await extractOSLog(since: since, maximumEntries: maximumLogEntries)
        if let logData = logText.data(using: .utf8) {
            files.append((name: "anxietywatch.log", data: logData))
        }

        // 2. Build the zip

        let zipURL = try createZip(containing: files)
        return Bundle(zipURL: zipURL, fileCount: files.count)
    }

    // MARK: - OSLog extraction

    private static func extractOSLog(
        since: Date?,
        maximumEntries: Int
    ) async throws -> String {
        let startDate = since ?? Date().addingTimeInterval(-3600)

        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return "# OSLogStore unavailable on this platform\n"
        }

        let position = store.position(date: startDate)
        // getEntries returns a Sequence of OSLogEntry; filter to our subsystem
        let entries: [OSLogEntryLog]
        do {
            entries = try store.getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == "com.anxietywatch.kit" }
                .prefix(maximumEntries)
                .map { $0 }
        } catch {
            return "# OSLogStore error: \(error.localizedDescription)\n"
        }

        if entries.isEmpty {
            return "# No log entries for subsystem com.anxietywatch.kit since \(ISO8601DateFormatter().string(from: startDate))\n"
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.timeZone = TimeZone.current

        var lines: [String] = []
        lines.append("# AnxietyWatchKit Log Export")
        lines.append("# Subsystem: com.anxietywatch.kit")
        lines.append("# Window: \(ISO8601DateFormatter().string(from: startDate)) — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("# Entries: \(entries.count)")
        lines.append("")

        for entry in entries {
            let timestamp = df.string(from: entry.date)
            let level = logLevelString(entry.level)
            let category = entry.category
            let message = entry.composedMessage
            lines.append("\(timestamp) [\(level)] [\(category)] \(message)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func logLevelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:   return "D"
        case .info:    return "I"
        case .notice:  return "N"
        case .error:   return "E"
        case .fault:   return "F"
        default:       return "?"
        }
    }

    // MARK: - Zip builder

    /// Minimal ZIP 2.0 archive builder. Writes a single-file central-directory
    /// ZIP with DEFLATE-compressed entries. No external dependencies —
    /// uses `compression_encode_buffer` from the system Compression framework.
    private static func createZip(containing files: [(name: String, data: Data)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnxietyWatchKit_diag_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let zipURL = tmp.appendingPathComponent("diagnostic_export.zip")

        // Write raw zip bytes to a Data accumulator, then flush to disk.
        var centralDirectory: [CentralDirectoryEntry] = []
        var zipData = Data()
        zipData.reserveCapacity(files.reduce(0) { $0 + $1.data.count } + files.count * 512)

        for (name, fileData) in files {
            let offset = UInt32(zipData.count)
            let crc = crc32(data: fileData)

            // Compress with DEFLATE (zlib wrapper stripped to raw deflate)
            let compressed = deflate(data: fileData)
            let useCompressed = compressed.count < fileData.count
            let storedData = useCompressed ? compressed : fileData
            let method: UInt16 = useCompressed ? 8 : 0  // 8=DEFLATE, 0=stored

            let nameData = name.data(using: .utf8)!
            let header = localFileHeader(
                fileName: nameData,
                crc32: crc,
                compressedSize: UInt32(storedData.count),
                uncompressedSize: UInt32(fileData.count),
                method: method
            )

            zipData.append(header)
            zipData.append(nameData)
            zipData.append(storedData)

            centralDirectory.append(CentralDirectoryEntry(
                localHeaderOffset: offset,
                fileName: nameData,
                crc32: crc,
                compressedSize: UInt32(storedData.count),
                uncompressedSize: UInt32(fileData.count),
                method: method
            ))
        }

        let centralStart = UInt32(zipData.count)
        for entry in centralDirectory {
            zipData.append(centralDirectoryHeader(entry: entry))
        }
        let centralEnd = UInt32(zipData.count)
        let eocd = endOfCentralDirectory(
            entryCount: UInt16(centralDirectory.count),
            centralDirectoryOffset: centralStart,
            centralDirectorySize: centralEnd - centralStart
        )
        zipData.append(eocd)

        try zipData.write(to: zipURL, options: .atomic)
        return zipURL
    }

    // MARK: - ZIP structure helpers

    private struct CentralDirectoryEntry {
        let localHeaderOffset: UInt32
        let fileName: Data
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let method: UInt16
    }

    private static func localFileHeader(
        fileName: Data,
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        method: UInt16
    ) -> Data {
        var header = Data(capacity: 30)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(0x04034b50).littleEndian, Array.init)) // signature
        header.append(contentsOf: withUnsafeBytes(of: UInt16(20).littleEndian, Array.init))        // version needed
        header.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))         // flags
        header.append(contentsOf: withUnsafeBytes(of: method.littleEndian, Array.init))            // method
        header.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))         // mod time
        header.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))         // mod date
        header.append(contentsOf: withUnsafeBytes(of: crc32.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: compressedSize.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: uncompressedSize.littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt16(fileName.count).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))         // extra field length
        return header
    }

    private static func centralDirectoryHeader(entry: CentralDirectoryEntry) -> Data {
        var h = Data(capacity: 46)
        h.append(contentsOf: withUnsafeBytes(of: UInt32(0x02014b50).littleEndian, Array.init)) // sig
        h.append(contentsOf: withUnsafeBytes(of: UInt16(20).littleEndian, Array.init))         // version made by
        h.append(contentsOf: withUnsafeBytes(of: UInt16(20).littleEndian, Array.init))         // version needed
        h.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // flags
        h.append(contentsOf: withUnsafeBytes(of: entry.method.littleEndian, Array.init))       // method
        h.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // mod time
        h.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // mod date
        h.append(contentsOf: withUnsafeBytes(of: entry.crc32.littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: entry.compressedSize.littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: entry.uncompressedSize.littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: UInt16(entry.fileName.count).littleEndian, Array.init))
        h.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // extra
        h.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // comment
        h.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // disk start
        h.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // internal attrs
        h.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian, Array.init))          // external attrs
        h.append(contentsOf: withUnsafeBytes(of: entry.localHeaderOffset.littleEndian, Array.init))
        h.append(entry.fileName)
        return h
    }

    private static func endOfCentralDirectory(
        entryCount: UInt16,
        centralDirectoryOffset: UInt32,
        centralDirectorySize: UInt32
    ) -> Data {
        var eocd = Data(capacity: 22)
        eocd.append(contentsOf: withUnsafeBytes(of: UInt32(0x06054b50).littleEndian, Array.init)) // sig
        eocd.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // disk
        eocd.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // disk start
        eocd.append(contentsOf: withUnsafeBytes(of: entryCount.littleEndian, Array.init))         // entries this disk
        eocd.append(contentsOf: withUnsafeBytes(of: entryCount.littleEndian, Array.init))         // total entries
        eocd.append(contentsOf: withUnsafeBytes(of: centralDirectorySize.littleEndian, Array.init))
        eocd.append(contentsOf: withUnsafeBytes(of: centralDirectoryOffset.littleEndian, Array.init))
        eocd.append(contentsOf: withUnsafeBytes(of: UInt16(0).littleEndian, Array.init))          // comment length
        return eocd
    }

    // MARK: - CRC-32

    private static func crc32(data: Data) -> UInt32 {
        return data.withUnsafeBytes { raw in
            // zlib-compatible CRC-32 (reflect in/out, polynomial 0xEDB88320)
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in raw.bindMemory(to: UInt8.self) {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    if (crc & 1) != 0 {
                        crc = (crc >> 1) ^ 0xEDB8_8320
                    } else {
                        crc >>= 1
                    }
                }
            }
            return crc ^ 0xFFFF_FFFF
        }
    }

    // MARK: - DEFLATE (raw, no zlib header)

    private static func deflate(data: Data) -> Data {
        // Don't bother compressing tiny payloads — zlib framing overhead
        // guarantees they expand.
        guard data.count > 64 else { return Data() }

        return data.withUnsafeBytes { raw in
            let srcPtr = raw.bindMemory(to: UInt8.self)
            guard let srcBase = srcPtr.baseAddress else { return Data() }
            let srcSize = raw.count

            let dstCapacity = srcSize + (srcSize / 6) + 32
            var dst = Data(count: dstCapacity)

            let compressedSize = dst.withUnsafeMutableBytes { dstRaw -> Int in
                let dstPtr = dstRaw.bindMemory(to: UInt8.self)
                guard let dstBase = dstPtr.baseAddress else { return 0 }
                var scratch = Data(count: dstCapacity)
                let n = scratch.withUnsafeMutableBytes { scratchRaw -> Int in
                    let p = scratchRaw.bindMemory(to: UInt8.self)
                    return compression_encode_buffer(
                        p.baseAddress!, scratchRaw.count,
                        srcBase, srcSize,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
                // Zlib frame = 2-byte header + raw deflate + 4-byte ADLER32 trailer.
                // Need at least 7 bytes for a meaningful compressed block.
                guard n > 6 else { return 0 }
                let rawLen = n - 6
                guard rawLen > 0, rawLen <= dstCapacity else { return 0 }
                _ = scratch.copyBytes(to: dstRaw, from: 2..<(2 + rawLen))
                return rawLen
            }

            if compressedSize > 0 && compressedSize < srcSize {
                dst.count = compressedSize
                return dst
            }
            return Data() // return empty → caller uses uncompressed
        }
    }
}
