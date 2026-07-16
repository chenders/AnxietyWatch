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

/// Storage layer for the samples table
public actor SamplesStore {
    private let database: DatabaseManager
    
    /// Errors that can occur when working with the samples store
    public enum SamplesStoreError: Error, Sendable {
        case healthKitOwnedType(source: Int32, type: Int32)
        case notOpen
    }
    
    /// HealthKit-owned types for Apple Watch (source == 2)
    /// HR=1, HRV=4
    /// TODO: Spec §1.7 lists five HK-owned kinds (HR, HRV, resting HR, VO2max, respiratory rate)
    /// but only HR (1) and HRV (4) have type numbers in §1.2 today; expand the set when
    /// new numbers land.
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