import Foundation
import GRDB

/// A row in the samples table
public struct SampleRow: Sendable, Equatable {
    public let source: Int32
    public let type: Int32
    public let timestamp: Double
    public let value: Double
    public let extra: Data?
    public let hlcPhysical: Int64
    public let hlcLogical: Int32
    /// 16 raw bytes. See `HLCStamped.nodeID`.
    public let nodeID: Data
    
    public init(source: Int32, type: Int32, timestamp: Double, value: Double, extra: Data?, hlcPhysical: Int64, hlcLogical: Int32, nodeID: Data) {
        self.source = source
        self.type = type
        self.timestamp = timestamp
        self.value = value
        self.extra = extra
        self.hlcPhysical = hlcPhysical
        self.hlcLogical = hlcLogical
        self.nodeID = nodeID
    }
}

/// Wire encoding per Spec §2.7 style: snake_case for HLC fields + node_id.
/// Keys are load-bearing — changing them breaks the server contract.
extension SampleRow: Codable {
    private enum CodingKeys: String, CodingKey {
        case source
        case type
        case timestamp
        case value
        case extra
        case hlcPhysical = "hlc_physical"
        case hlcLogical = "hlc_logical"
        case nodeID = "node_id"
    }
}

/// Storage layer for the samples table
public actor SamplesStore {
    private let database: DatabaseManager
    
    /// Errors that can occur when working with the samples store
    public enum SamplesStoreError: Error, Sendable {
        case healthKitOwnedType(source: Int32, type: Int32)
        case notOpen
    }
    
    /// HealthKit-owned types for Apple Watch (source == 2).
    /// HR=1, HRV=4. Per §1.7, these types must not appear in the samples
    /// table — inserts are guarded by insert() with a preconditionFailure
    /// (debug) or SamplesStoreError (release).
    public static let healthKitOwnedTypes: Set<Int32> = [1, 4]
    
    /// Creates a new SamplesStore
    /// - Parameter database: The database manager to use
    public init(database: DatabaseManager) {
        self.database = database
    }
    
    /// Checks if a (source, type) pair is owned by HealthKit
    /// - Parameters:
    ///   - source: The source identifier
    ///   - type: The type identifier
    /// - Returns: true if the pair is owned by HealthKit
    public static func isHealthKitOwned(source: Int32, type: Int32) -> Bool {
        return source == 2 && healthKitOwnedTypes.contains(type)
    }
    
    /// Inserts sample rows, deduplicating on (source, type, timestamp) primary key
    /// - Parameter rows: The rows to insert
    /// - Returns: The number of rows actually inserted
    public func insert(_ rows: [SampleRow]) async throws -> Int {
        // Check for HealthKit-owned types
        for row in rows {
            if Self.isHealthKitOwned(source: row.source, type: row.type) {
                #if DEBUG
                preconditionFailure("Attempted to insert HealthKit-owned type (source: \(row.source), type: \(row.type))")
                #else
                throw SamplesStoreError.healthKitOwnedType(source: row.source, type: row.type)
                #endif
            }
        }
        
        // Insert rows using prepared statement
        return try await database.writer { db in
            // Prepare statement
            let sql = """
                INSERT OR IGNORE INTO samples
                (source, type, timestamp, value, extra, hlc_physical, hlc_logical, node_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try db.makeStatement(sql: sql)
            
            // Insert all rows and track total changes
            var totalChanges = 0
            for row in rows {
                try statement.execute(arguments: [
                    row.source, row.type, row.timestamp, row.value, row.extra,
                    row.hlcPhysical, row.hlcLogical, row.nodeID
                ])
                totalChanges += db.changesCount
            }
            
            // Return number of rows inserted
            return totalChanges
        }
    }
    
    /// HLC-guarded last-writer-wins upsert (sync pull-apply path). Unlike
    /// `insert(_:)` (INSERT OR IGNORE — first-writer-wins), an incoming row
    /// with a HIGHER HLC replaces the existing (source, type, timestamp) row;
    /// a lower-or-equal HLC is dropped. This matches the _sync_log semantic
    /// and is required because the samples PK has no node_id: two nodes can
    /// legitimately write the same tuple.
    /// - Returns: how many rows were newly inserted vs LWW-updated.
    @discardableResult
    public func upsertHLCLatest(_ rows: [SampleRow]) async throws -> (inserted: Int, updated: Int) {
        for row in rows {
            if Self.isHealthKitOwned(source: row.source, type: row.type) {
                #if DEBUG
                preconditionFailure("Attempted to upsert HealthKit-owned type (source: \(row.source), type: \(row.type))")
                #else
                throw SamplesStoreError.healthKitOwnedType(source: row.source, type: row.type)
                #endif
            }
        }
        return try await database.writer { db in
            try Self.upsertHLCLatest(rows, in: db)
        }
    }

    /// Transaction-composable core of `upsertHLCLatest(_:)` — callable from an
    /// enclosing writer block (SyncCoordinator applies a whole pulled batch in
    /// ONE transaction).
    @discardableResult
    public static func upsertHLCLatest(_ rows: [SampleRow], in db: Database) throws -> (inserted: Int, updated: Int) {
        var inserted = 0
        var updated = 0
        for row in rows {
            let exists = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM samples WHERE source = ? AND type = ? AND timestamp = ?)
                """, arguments: [row.source, row.type, row.timestamp]) ?? false
            try db.execute(sql: """
                INSERT INTO samples
                    (source, type, timestamp, value, extra, hlc_physical, hlc_logical, node_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, type, timestamp) DO UPDATE SET
                    value        = excluded.value,
                    extra        = excluded.extra,
                    hlc_physical = excluded.hlc_physical,
                    hlc_logical  = excluded.hlc_logical,
                    node_id      = excluded.node_id
                WHERE (excluded.hlc_physical, excluded.hlc_logical)
                    > (samples.hlc_physical, samples.hlc_logical)
                """, arguments: [
                    row.source, row.type, row.timestamp, row.value, row.extra,
                    row.hlcPhysical, row.hlcLogical, row.nodeID
                ])
            if db.changesCount > 0 {
                if exists { updated += 1 } else { inserted += 1 }
            }
        }
        return (inserted, updated)
    }

    /// Fetches sample rows within a time range
    /// - Parameters:
    ///   - source: The source identifier
    ///   - type: The type identifier
    ///   - ts0: The start timestamp (inclusive)
    ///   - ts1: The end timestamp (inclusive)
    /// - Returns: The matching sample rows
    public func fetch(source: Int32, type: Int32, from ts0: Double, to ts1: Double) async throws -> [SampleRow] {
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, type, timestamp, value, extra, hlc_physical, hlc_logical, node_id
                FROM samples
                WHERE source = ? AND type = ? AND timestamp >= ? AND timestamp <= ?
                ORDER BY timestamp
            """, arguments: [source, type, ts0, ts1])
            
            return rows.map { row in
                SampleRow(
                    source: row[0],
                    type: row[1],
                    timestamp: row[2],
                    value: row[3],
                    extra: row[4],
                    hlcPhysical: row[5],
                    hlcLogical: row[6],
                    nodeID: row[7]
                )
            }
        }
    }
    
    /// Fetches sample rows for sync pagination
    /// - Parameters:
    ///   - nodeID: The node ID to filter by
    ///   - pt: The HLC physical timestamp to start after
    ///   - lc: The HLC logical timestamp to start after
    ///   - limit: The maximum number of rows to return
    /// - Returns: The matching sample rows
    public func fetchForSync(nodeID: Data, afterHLC pt: Int64, lc: Int32, limit: Int) async throws -> [SampleRow] {
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, type, timestamp, value, extra, hlc_physical, hlc_logical, node_id
                FROM samples
                WHERE node_id = ? AND (hlc_physical, hlc_logical) > (?, ?)
                ORDER BY hlc_physical, hlc_logical
                LIMIT ?
            """, arguments: [nodeID, pt, lc, limit])
            
            return rows.map { row in
                SampleRow(
                    source: row[0],
                    type: row[1],
                    timestamp: row[2],
                    value: row[3],
                    extra: row[4],
                    hlcPhysical: row[5],
                    hlcLogical: row[6],
                    nodeID: row[7]
                )
            }
        }
    }
    
    /// Deletes sample rows older than a cutoff timestamp
    /// - Parameter cutoff: The timestamp cutoff (exclusive)
    /// - Returns: The total number of rows deleted
    public func deleteRowsOlderThan(_ cutoff: Double) async throws -> Int {
        var totalDeleted = 0
        
        while true {
            let n = try await database.writer { db in
                try db.execute(sql: "DELETE FROM samples WHERE timestamp < ? LIMIT 5000",
                               arguments: [cutoff])
                return db.changesCount
            }
            totalDeleted += n
            if n < 5000 { break }
            try Task.checkCancellation()
            await Task.yield()
        }
        
        return totalDeleted
    }
    
    /// Returns the total count of sample rows
    /// - Returns: The total count
    public func count() async throws -> Int {
        return try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples") ?? 0
        }
    }
}