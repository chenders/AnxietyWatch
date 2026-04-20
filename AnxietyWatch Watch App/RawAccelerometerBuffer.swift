// AnxietyWatch Watch App/RawAccelerometerBuffer.swift
import Foundation
import os

/// File-based rolling buffer of raw accelerometer data on the watch.
/// Stores 10-minute chunks as binary files with Int16 quantization.
/// Retains 48 hours of data; older files are automatically pruned.
///
/// Binary format per file:
///   Header: sampleCount (UInt32) + startTimestamp (Double) + sampleRate (Float)
///   Body: [Int16] × 3 axes × sampleCount (x0,y0,z0, x1,y1,z1, ...)
///
/// Int16 quantization: acceleration in g × 4096 (±8g range at ~0.00024g resolution)
enum RawAccelerometerBuffer {

    static let bufferDirectory = "accel_buffer"
    static let retentionInterval: TimeInterval = 48 * 3600 // 48 hours
    static let chunkDuration: TimeInterval = 600           // 10 minutes
    private static let quantizationScale: Float = 4096.0   // g → Int16

    private static let log = Logger(subsystem: "AnxietyWatch", category: "AccelBuffer")

    /// Base directory for buffer files in the app's documents directory.
    static var baseURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(bufferDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a chunk of raw accelerometer data to disk.
    static func writeChunk(
        x: [Float], y: [Float], z: [Float],
        startTime: Date, sampleRate: Float
    ) {
        guard x.count == y.count, y.count == z.count, !x.isEmpty else { return }

        let sampleCount = UInt32(x.count)
        let timestamp = startTime.timeIntervalSinceReferenceDate
        let filename = "accel_\(Int(timestamp)).bin"
        let url = baseURL.appendingPathComponent(filename)

        var data = Data()
        // Header
        var count = sampleCount
        data.append(Data(bytes: &count, count: MemoryLayout<UInt32>.size))
        var ts = timestamp
        data.append(Data(bytes: &ts, count: MemoryLayout<Double>.size))
        var rate = sampleRate
        data.append(Data(bytes: &rate, count: MemoryLayout<Float>.size))

        // Body: interleaved Int16 triples
        for i in 0..<Int(sampleCount) {
            var qx = Int16(clamping: Int(x[i] * quantizationScale))
            var qy = Int16(clamping: Int(y[i] * quantizationScale))
            var qz = Int16(clamping: Int(z[i] * quantizationScale))
            data.append(Data(bytes: &qx, count: 2))
            data.append(Data(bytes: &qy, count: 2))
            data.append(Data(bytes: &qz, count: 2))
        }

        do {
            try data.write(to: url)
        } catch {
            log.error("Failed to write accel chunk: \(error.localizedDescription)")
        }
    }

    /// Read a chunk back from disk. Returns (x, y, z, startTime, sampleRate) or nil.
    static func readChunk(at url: URL) -> (x: [Float], y: [Float], z: [Float], startTime: Date, sampleRate: Float)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let headerSize = MemoryLayout<UInt32>.size + MemoryLayout<Double>.size + MemoryLayout<Float>.size
        guard data.count >= headerSize else { return nil }

        let sampleCount = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let timestamp = data.advanced(by: 4).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let sampleRate = data.advanced(by: 12).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }

        let expectedBodySize = Int(sampleCount) * 6 // 3 axes × 2 bytes
        guard data.count >= headerSize + expectedBodySize else { return nil }

        var x = [Float]()
        var y = [Float]()
        var z = [Float]()
        x.reserveCapacity(Int(sampleCount))
        y.reserveCapacity(Int(sampleCount))
        z.reserveCapacity(Int(sampleCount))

        let bodyData = data.advanced(by: headerSize)
        bodyData.withUnsafeBytes { ptr in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            for i in 0..<Int(sampleCount) {
                x.append(Float(int16Ptr[i * 3]) / quantizationScale)
                y.append(Float(int16Ptr[i * 3 + 1]) / quantizationScale)
                z.append(Float(int16Ptr[i * 3 + 2]) / quantizationScale)
            }
        }

        return (x, y, z, Date(timeIntervalSinceReferenceDate: timestamp), sampleRate)
    }

    /// Delete buffer files older than the retention interval.
    static func pruneOldChunks(now: Date = .now) {
        let cutoff = now.timeIntervalSinceReferenceDate - retentionInterval
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else { return }

        for file in files where file.pathExtension == "bin" {
            // Extract timestamp from filename: accel_<timestamp>.bin
            let name = file.deletingPathExtension().lastPathComponent
            if let tsString = name.split(separator: "_").last,
               let ts = Double(tsString),
               ts < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Total size of all buffer files in bytes.
    static func totalSizeBytes() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.compactMap { try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int }.reduce(0, +)
    }
}
