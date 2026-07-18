import Foundation
import GRDB

/// Aggregates raw `samples` into `samples_1min` rollups. See Spec §1.5 (idle-time
/// downsampling) and §2.6 precondition (3) (on-demand rollup before
/// unacked_overflow eviction).
///
/// Bucket definition: `minute_bucket = floor(timestamp / 60)` in seconds (integer
/// minutes since Unix epoch). Value semantics per aggregator; default is mean.
public actor IdleDownsampler {
    private let database: DatabaseManager

    public enum Aggregator: String, Sendable, Codable, CaseIterable {
        case mean
        case max
        case min
        case sum
    }

    public struct DownsampleResult: Sendable, Equatable {
        public let source: Int32
        public let type: Int32
        public let bucketsWritten: Int
    }

    public enum IdleDownsamplerError: Error, Sendable {
        case cancelled
    }

    public init(database: DatabaseManager) { self.database = database }

    /// Downsample raw samples for (source, type) whose minute_bucket does not yet
    /// have a rollup in samples_1min. Only aggregates buckets that are fully
    /// closed (bucket_end <= now) so we don't rollup partial minutes.
    /// - Parameters:
    ///   - now: current time (seconds since epoch); injected for tests.
    ///   - source, type: which (source, type) partition to downsample.
    ///   - aggregator: aggregation function (defaults to .mean).
    /// - Returns: how many new buckets were written to samples_1min.
    public func downsample(
        now: Double,
        source: Int32,
        type: Int32,
        aggregator: Aggregator = .mean
    ) async throws -> DownsampleResult {
        // Skip HealthKit-owned types
        if SamplesStore.isHealthKitOwned(source: source, type: type) {
            return DownsampleResult(source: source, type: type, bucketsWritten: 0)
        }
        
        let cutoff = floor(now / 60) * 60  // Start of current minute
        
        let aggFunction: String
        switch aggregator {
        case .mean: aggFunction = "AVG"
        case .max: aggFunction = "MAX"
        case .min: aggFunction = "MIN"
        case .sum: aggFunction = "SUM"
        }
        
        let sql = """
            INSERT INTO samples_1min
                (source, type, minute_bucket, value, sample_count,
                 hlc_physical, hlc_logical, node_id)
            SELECT
                s.source, s.type,
                CAST(s.timestamp / 60 AS INTEGER) AS minute_bucket,
                \(aggFunction)(s.value) AS value,
                COUNT(*) AS sample_count,
                (SELECT s2.hlc_physical FROM samples s2
                  WHERE s2.source = s.source AND s2.type = s.type
                    AND s2.node_id = s.node_id
                    AND CAST(s2.timestamp / 60 AS INTEGER) = CAST(s.timestamp / 60 AS INTEGER)
                  ORDER BY s2.hlc_physical DESC, s2.hlc_logical DESC LIMIT 1) AS hlc_physical,
                (SELECT s2.hlc_logical FROM samples s2
                  WHERE s2.source = s.source AND s2.type = s.type
                    AND s2.node_id = s.node_id
                    AND CAST(s2.timestamp / 60 AS INTEGER) = CAST(s.timestamp / 60 AS INTEGER)
                  ORDER BY s2.hlc_physical DESC, s2.hlc_logical DESC LIMIT 1) AS hlc_logical,
                s.node_id
            FROM samples s
            WHERE s.source = ? AND s.type = ?
              AND s.timestamp < ?  -- fully-closed bucket boundary
              AND (CAST(s.timestamp / 60 AS INTEGER), s.node_id) NOT IN (
                SELECT minute_bucket, node_id FROM samples_1min WHERE source = ? AND type = ?
              )
            GROUP BY minute_bucket, s.node_id
        """
        
        let rowsInserted = try await database.writer { db in
            try db.execute(sql: sql, arguments: [source, type, cutoff, source, type])
            return db.changesCount
        }
        
        if rowsInserted > 0 {
            Log.storage.info("Downsampled \(rowsInserted) buckets for (source=\(source), type=\(type))")
        }
        
        return DownsampleResult(source: source, type: type, bucketsWritten: rowsInserted)
    }

    /// Downsample ALL (source, type) partitions that have unrolluped closed buckets.
    /// Yields between (source, type) partitions for cooperative scheduling.
    public func downsampleAll(now: Double, aggregator: Aggregator = .mean) async throws -> [DownsampleResult] {
        // Get all distinct (source, type) pairs
        let sourceTypes = try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT DISTINCT source, type FROM samples")
        }.map { row in
            (source: row[0] as Int32, type: row[1] as Int32)
        }
        
        var results: [DownsampleResult] = []
        
        for (source, type) in sourceTypes {
            try Task.checkCancellation()
            
            let result = try await downsample(now: now, source: source, type: type, aggregator: aggregator)
            results.append(result)
            
            await Task.yield()
        }
        
        return results
    }
}