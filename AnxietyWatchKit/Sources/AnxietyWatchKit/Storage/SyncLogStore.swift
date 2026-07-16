import Foundation
import GRDB

/// A log entry in the _sync_log table
///
/// The _sync_log PK is (table_name, row_pk) — only the latest operation per row is retained.
/// Intermediate updates between server ACKs are silently coalesced by design.
/// The log is a delta cursor, not an audit trail; do not rely on it to reconstruct history.
public struct SyncLogEntry: Sendable, Equatable {
    public let tableName: String
    public let rowPK: String
    public let hlcPhysical: Int64
    public let hlcLogical: Int32
    /// 16 raw bytes. See `HLCStamped.nodeID`.
    public let nodeID: Data
    public let operation: Operation
    
    public enum Operation: String, Sendable, Codable {
        case upsert
        case delete
    }
    
    public init(tableName: String, rowPK: String, hlcPhysical: Int64, hlcLogical: Int32, nodeID: Data, operation: Operation) {
        self.tableName = tableName
        self.rowPK = rowPK
        self.hlcPhysical = hlcPhysical
        self.hlcLogical = hlcLogical
        self.nodeID = nodeID
        self.operation = operation
    }
}

/// Storage layer for the _sync_log table
public actor SyncLogStore {
    private let database: DatabaseManager
    
    /// Errors that can occur when working with the sync log store
    public enum SyncLogStoreError: Error, Sendable {
        case notOpen
        case unknownOperation(String)
    }
    
    /// Creates a new SyncLogStore
    /// - Parameter database: The database manager to use
    public init(database: DatabaseManager) {
        self.database = database
    }
    
    /// Inserts or updates a sync log entry
    /// - Parameter entry: The entry to insert or update
    public func upsert(_ entry: SyncLogEntry) async throws {
        try await database.writer { db in
            let sql = """
                INSERT INTO _sync_log
                (table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(table_name, row_pk) DO UPDATE SET
                    hlc_physical = excluded.hlc_physical,
                    hlc_logical  = excluded.hlc_logical,
                    node_id      = excluded.node_id,
                    operation    = excluded.operation
                WHERE (excluded.hlc_physical, excluded.hlc_logical)
                    > (_sync_log.hlc_physical, _sync_log.hlc_logical)
            """
            
            try db.execute(sql: sql, arguments: [
                entry.tableName, entry.rowPK, entry.hlcPhysical, entry.hlcLogical,
                entry.nodeID, entry.operation.rawValue
            ])
        }
    }
    
    /// Fetches sync log entries for sync push, per-node cursor
    /// - Parameters:
    ///   - nodeID: The node ID to filter by
    ///   - pt: The HLC physical timestamp to start after
    ///   - lc: The HLC logical timestamp to start after
    ///   - limit: The maximum number of entries to return
    /// - Returns: The matching sync log entries
    public func fetchForSync(nodeID: Data, afterHLC pt: Int64, lc: Int32, limit: Int) async throws -> [SyncLogEntry] {
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT table_name, row_pk, hlc_physical, hlc_logical, node_id, operation
                FROM _sync_log
                WHERE node_id = ? AND (hlc_physical, hlc_logical) > (?, ?)
                ORDER BY hlc_physical, hlc_logical
                LIMIT ?
            """, arguments: [nodeID, pt, lc, limit])
            
            return try rows.map { row in
                guard let op = SyncLogEntry.Operation(rawValue: row[5]) else {
                    throw SyncLogStoreError.unknownOperation(row[5])
                }
                
                return SyncLogEntry(
                    tableName: row[0],
                    rowPK: row[1],
                    hlcPhysical: row[2],
                    hlcLogical: row[3],
                    nodeID: row[4],
                    operation: op
                )
            }
        }
    }
    
    /// Deletes sync log entries up to a given HLC cursor for a specific node
    /// - Parameters:
    ///   - nodeID: The node ID to filter by
    ///   - pt: The HLC physical timestamp to delete up to (inclusive)
    ///   - lc: The HLC logical timestamp to delete up to (inclusive)
    /// - Returns: The number of entries deleted
    public func garbageCollect(nodeID: Data, upToHLC pt: Int64, lc: Int32) async throws -> Int {
        return try await database.writer { db in
            try db.execute(sql: """
                DELETE FROM _sync_log
                WHERE node_id = ? AND (hlc_physical, hlc_logical) <= (?, ?)
            """, arguments: [nodeID, pt, lc])
            
            return db.changesCount
        }
    }
    
    /// Returns the total count of sync log entries
    /// - Returns: The total count
    public func count() async throws -> Int {
        return try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM _sync_log") ?? 0
        }
    }
}