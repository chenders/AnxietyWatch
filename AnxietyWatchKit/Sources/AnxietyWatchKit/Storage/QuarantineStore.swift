import Foundation
import GRDB

public struct QuarantineRow: Sendable, Equatable {
    public let tableName: String
    public let rowPK: String
    public let hlcPhysical: Int64
    public let hlcLogical: Int32
    /// 16 raw bytes. See HLCStamped.nodeID.
    public let nodeID: Data
    public let reason: String     // free-text per Spec §2.1; enum-tighten later
    public let payload: Data      // serialized original row
    /// Local wall-clock ms at quarantine time. Trusted local ingest timestamp
    /// used for diagnostics ordering because `hlcPhysical` is by definition
    /// untrusted on rows that got quarantined (drift-exceeded).
    /// Populated by the schema default when omitted at insert.
    public let capturedAt: Int64
    public init(tableName: String, rowPK: String, hlcPhysical: Int64, hlcLogical: Int32,
                nodeID: Data, reason: String, payload: Data, capturedAt: Int64? = nil) {
        self.tableName = tableName
        self.rowPK = rowPK
        self.hlcPhysical = hlcPhysical
        self.hlcLogical = hlcLogical
        self.nodeID = nodeID
        self.reason = reason
        self.payload = payload
        // If the caller omits, we fall back to Date().timeIntervalSince1970 * 1000;
        // the schema DEFAULT ((julianday - ...) * 86400000) would otherwise fill it
        // on INSERT, but keeping this value in the struct makes round-trip Equatable.
        self.capturedAt = capturedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public actor QuarantineStore {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    /// Insert a quarantined row. Uses INSERT OR IGNORE — PK is
    /// (table_name, row_pk, hlc_physical, hlc_logical, node_id) which includes
    /// the HLC, so genuine duplicates cannot arise (HLC is monotone per node).
    /// - Returns: 1 if inserted, 0 if PK-duplicate.
    @discardableResult
    public func insert(_ row: QuarantineRow) async throws -> Int {
        return try await database.writer { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO _sync_quarantine
                    (table_name, row_pk, hlc_physical, hlc_logical, node_id, reason, payload, captured_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    row.tableName, row.rowPK, row.hlcPhysical, row.hlcLogical,
                    row.nodeID, row.reason, row.payload, row.capturedAt
                ])
            return db.changesCount
        }
    }

    /// All quarantined rows for a given (table_name, row_pk) — usually one, but
    /// duplicates may exist across HLCs if the same row was seen under
    /// multiple drifty clock states.
    public func fetch(tableName: String, rowPK: String) async throws -> [QuarantineRow] {
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT table_name, row_pk, hlc_physical, hlc_logical, node_id, reason, payload, captured_at
                FROM _sync_quarantine
                WHERE table_name = ? AND row_pk = ?
                ORDER BY captured_at
                """, arguments: [tableName, rowPK])
            return rows.map { Self.decodeRow($0) }
        }
    }

    /// Everything, for diagnostics. Ordered by trusted local capture time,
    /// NOT by hlc_physical (which is untrusted on quarantined rows).
    public func fetchAll(limit: Int = 100) async throws -> [QuarantineRow] {
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT table_name, row_pk, hlc_physical, hlc_logical, node_id, reason, payload, captured_at
                FROM _sync_quarantine
                ORDER BY captured_at DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map { Self.decodeRow($0) }
        }
    }

    /// Delete a specific quarantined row by full PK (after operator resolves).
    @discardableResult
    public func delete(tableName: String, rowPK: String,
                       hlcPhysical: Int64, hlcLogical: Int32, nodeID: Data) async throws -> Int {
        return try await database.writer { db in
            try db.execute(sql: """
                DELETE FROM _sync_quarantine
                WHERE table_name = ? AND row_pk = ? AND hlc_physical = ? AND hlc_logical = ? AND node_id = ?
                """, arguments: [tableName, rowPK, hlcPhysical, hlcLogical, nodeID])
            return db.changesCount
        }
    }

    public func count() async throws -> Int {
        return try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM _sync_quarantine") ?? 0
        }
    }

    // MARK: - Internal decode

    private static func decodeRow(_ row: Row) -> QuarantineRow {
        return QuarantineRow(
            tableName: row["table_name"],
            rowPK: row["row_pk"],
            hlcPhysical: row["hlc_physical"],
            hlcLogical: row["hlc_logical"],
            nodeID: row["node_id"],
            reason: row["reason"],
            payload: row["payload"],
            capturedAt: row["captured_at"]
        )
    }
}