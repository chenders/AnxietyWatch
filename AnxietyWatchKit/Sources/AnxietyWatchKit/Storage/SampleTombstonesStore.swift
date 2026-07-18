import Foundation
import GRDB

/// A row in the `sample_tombstones` table. Each row represents a range of samples that
/// have been deleted from `samples` and must be advertised to peers so they don't
/// treat the gap as continuous data. See Spec §1.2 and §2.5 / §2.6.
public struct SampleTombstoneRow: Sendable, Equatable {
    public let source: Int32
    public let type: Int32
    public let tsStart: Double
    public let tsEnd: Double
    public let hlcPhysical: Int64
    public let hlcLogical: Int32
    /// 16 raw bytes. See `HLCStamped.nodeID`.
    public let nodeID: Data
    public let droppedRowCount: Int64
    public let reason: Reason

    /// Distinguishes eviction sources so the diagnostics UI and CNS pipeline can
    /// react appropriately. Matches the CHECK-constrained enum on the table.
    public enum Reason: String, Sendable, Codable, CaseIterable {
        case memoryPanic = "memory_panic"
        case corruption
        case manual
        case retention
        case unackedOverflow = "unacked_overflow"
    }

    public init(source: Int32,
                type: Int32,
                tsStart: Double,
                tsEnd: Double,
                hlcPhysical: Int64,
                hlcLogical: Int32,
                nodeID: Data,
                droppedRowCount: Int64,
                reason: Reason) {
        self.source = source
        self.type = type
        self.tsStart = tsStart
        self.tsEnd = tsEnd
        self.hlcPhysical = hlcPhysical
        self.hlcLogical = hlcLogical
        self.nodeID = nodeID
        self.droppedRowCount = droppedRowCount
        self.reason = reason
    }
}

/// Wire encoding per Spec §2.7 style: snake_case throughout.
/// Keys are load-bearing — changing them breaks the server contract.
extension SampleTombstoneRow: Codable {
    private enum CodingKeys: String, CodingKey {
        case source
        case type
        case tsStart = "ts_start"
        case tsEnd = "ts_end"
        case hlcPhysical = "hlc_physical"
        case hlcLogical = "hlc_logical"
        case nodeID = "node_id"
        case droppedRowCount = "dropped_row_count"
        case reason
    }
}

/// Storage layer for the `sample_tombstones` table.
///
/// Callers (PanicProtocol, RetentionCompactor, corruption recovery, and manual
/// deletion paths) insert tombstones covering ranges of samples that were dropped
/// locally. The sync engine (T17) unions these with the `samples` payload so peers
/// see the gap explicitly (Spec §2.3 UNION ALL push).
///
/// Insert semantics: PK includes the eviction HLC, so multiple evictions within the
/// same (source, type, ts_start) window remain distinct — the HLC is minted fresh at
/// eviction time per Spec §2.6, so genuine duplicates are impossible.
public actor SampleTombstonesStore {
    private let database: DatabaseManager

    public enum SampleTombstonesStoreError: Error, Sendable {
        case notOpen
        case unknownReason(String)
    }

    public init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Insert

    /// Inserts tombstone rows. Uses INSERT OR IGNORE so a duplicate insert (same PK
    /// tuple: source, type, ts_start, hlc_physical, hlc_logical, node_id) is silently
    /// dropped — this preserves idempotency for retry-safe callers.
    /// - Returns: the number of rows actually inserted.
    @discardableResult
    public func insert(_ rows: [SampleTombstoneRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await database.writer { db in
            var inserted = 0
            for row in rows {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO sample_tombstones
                        (source, type, ts_start, ts_end,
                         hlc_physical, hlc_logical, node_id,
                         dropped_row_count, reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        row.source, row.type, row.tsStart, row.tsEnd,
                        row.hlcPhysical, row.hlcLogical, row.nodeID,
                        row.droppedRowCount, row.reason.rawValue
                    ])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    /// HLC-guarded upsert (sync pull-apply path), symmetric with
    /// `SamplesStore.upsertHLCLatest`. NOTE: the tombstone PK already includes
    /// (hlc_physical, hlc_logical, node_id), so a "same range, newer HLC"
    /// arrival is a NEW row by construction; a conflict can only be an exact
    /// duplicate, which the HLC guard drops. Semantically equivalent to
    /// INSERT OR IGNORE but kept in the guarded-upsert shape so the pull-apply
    /// path has one uniform semantic across tables.
    /// - Returns: how many rows were newly inserted vs LWW-updated.
    @discardableResult
    public func upsertHLCLatest(_ rows: [SampleTombstoneRow]) async throws -> (inserted: Int, updated: Int) {
        guard !rows.isEmpty else { return (0, 0) }
        return try await database.writer { db in
            try Self.upsertHLCLatest(rows, in: db)
        }
    }

    /// Transaction-composable core of `upsertHLCLatest(_:)` — callable from an
    /// enclosing writer block (SyncCoordinator applies a whole pulled batch in
    /// ONE transaction).
    @discardableResult
    public static func upsertHLCLatest(_ rows: [SampleTombstoneRow], in db: Database) throws -> (inserted: Int, updated: Int) {
        var inserted = 0
        var updated = 0
        for row in rows {
            let exists = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM sample_tombstones
                    WHERE source = ? AND type = ? AND ts_start = ?
                      AND hlc_physical = ? AND hlc_logical = ? AND node_id = ?)
                """, arguments: [
                    row.source, row.type, row.tsStart,
                    row.hlcPhysical, row.hlcLogical, row.nodeID
                ]) ?? false
            try db.execute(sql: """
                INSERT INTO sample_tombstones
                    (source, type, ts_start, ts_end,
                     hlc_physical, hlc_logical, node_id, dropped_row_count, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, type, ts_start, hlc_physical, hlc_logical, node_id) DO UPDATE SET
                    ts_end            = excluded.ts_end,
                    dropped_row_count = excluded.dropped_row_count,
                    reason            = excluded.reason
                WHERE (excluded.hlc_physical, excluded.hlc_logical)
                    > (sample_tombstones.hlc_physical, sample_tombstones.hlc_logical)
                """, arguments: [
                    row.source, row.type, row.tsStart, row.tsEnd,
                    row.hlcPhysical, row.hlcLogical, row.nodeID,
                    row.droppedRowCount, row.reason.rawValue
                ])
            if db.changesCount > 0 {
                if exists { updated += 1 } else { inserted += 1 }
            }
        }
        return (inserted, updated)
    }

    // MARK: - Range queries

    /// Returns tombstones whose covered range intersects `[from, to]` for a given
    /// (source, type). Used by the CNS pipeline to decide whether a query window
    /// contains an eviction gap.
    public func fetchOverlapping(source: Int32,
                                 type: Int32,
                                 from ts0: Double,
                                 to ts1: Double) async throws -> [SampleTombstoneRow] {
        try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, type, ts_start, ts_end,
                       hlc_physical, hlc_logical, node_id,
                       dropped_row_count, reason
                  FROM sample_tombstones
                 WHERE source = ? AND type = ?
                   AND ts_start <= ? AND ts_end >= ?
                 ORDER BY ts_start
                """, arguments: [source, type, ts1, ts0])
            return try rows.map { try Self.decodeRow($0) }
        }
    }

    // MARK: - Sync pagination

    /// Per-node HLC-cursor pagination for the sync push payload. Matches the same
    /// index shape used by SamplesStore, so peer replication is symmetrical.
    public func fetchForSync(nodeID: Data,
                             afterHLC pt: Int64,
                             lc: Int32,
                             limit: Int) async throws -> [SampleTombstoneRow] {
        try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, type, ts_start, ts_end,
                       hlc_physical, hlc_logical, node_id,
                       dropped_row_count, reason
                  FROM sample_tombstones
                 WHERE node_id = ?
                   AND (hlc_physical, hlc_logical) > (?, ?)
                 ORDER BY hlc_physical, hlc_logical
                 LIMIT ?
                """, arguments: [nodeID, pt, lc, limit])
            return try rows.map { try Self.decodeRow($0) }
        }
    }

    // MARK: - Counts

    public func count() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample_tombstones") ?? 0
        }
    }

    public func countByReason(_ reason: SampleTombstoneRow.Reason) async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM sample_tombstones WHERE reason = ?",
                arguments: [reason.rawValue]) ?? 0
        }
    }

    // MARK: - Internal decode

    private static func decodeRow(_ row: Row) throws -> SampleTombstoneRow {
        let reasonRaw: String = row["reason"]
        guard let reason = SampleTombstoneRow.Reason(rawValue: reasonRaw) else {
            throw SampleTombstonesStoreError.unknownReason(reasonRaw)
        }
        return SampleTombstoneRow(
            source: row["source"],
            type: row["type"],
            tsStart: row["ts_start"],
            tsEnd: row["ts_end"],
            hlcPhysical: row["hlc_physical"],
            hlcLogical: row["hlc_logical"],
            nodeID: row["node_id"],
            droppedRowCount: row["dropped_row_count"],
            reason: reason
        )
    }
}
