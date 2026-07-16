import Foundation
import GRDB

public struct BackfillProgress: Sendable, Equatable {
    public let source: Int32
    public let type: Int32
    public let lastTs: Double
    public init(source: Int32, type: Int32, lastTs: Double) {
        self.source = source; self.type = type; self.lastTs = lastTs
    }
}

public actor BackfillProgressStore {
    private let database: DatabaseManager
    public enum BackfillProgressStoreError: Error, Sendable { }
    public init(database: DatabaseManager) { self.database = database }

    /// Upsert progress for (source, type); overwrites previous last_ts.
    public func setProgress(_ p: BackfillProgress) async throws {
        try await database.writer { db in
            try Self.setProgress(p, in: db)
        }
    }

    /// Synchronous variant intended for callers who already own an open GRDB
    /// `Database` inside a writer block. This lets the caller compose the
    /// samples INSERT and the progress checkpoint into a single transaction as
    /// Spec §1.4 / §7.2 require. Idempotent: uses the same ON CONFLICT DO UPDATE
    /// as `setProgress(_:)`.
    public nonisolated static func setProgress(_ p: BackfillProgress, in db: Database) throws {
        let sql = """
            INSERT INTO _backfill_progress (source, type, last_ts) 
            VALUES (?, ?, ?) 
            ON CONFLICT(source, type) DO UPDATE SET last_ts = excluded.last_ts
            WHERE excluded.last_ts > _backfill_progress.last_ts
        """
        try db.execute(sql: sql, arguments: [p.source, p.type, p.lastTs])
    }

    /// Returns the persisted last_ts for (source, type), or nil if never set.
    public func progress(source: Int32, type: Int32) async throws -> Double? {
        return try await database.reader { db in
            let sql = "SELECT last_ts FROM _backfill_progress WHERE source = ? AND type = ?"
            return try Double.fetchOne(db, sql: sql, arguments: [source, type])
        }
    }

    /// Returns every persisted checkpoint.
    public func allProgress() async throws -> [BackfillProgress] {
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: "SELECT source, type, last_ts FROM _backfill_progress")
            return rows.map { row in
                BackfillProgress(
                    source: row[0],
                    type: row[1],
                    lastTs: row[2]
                )
            }
        }
    }

    /// Clears all progress rows (used when backfill is complete OR when a
    /// rollback wants to start fresh).
    public func clear() async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM _backfill_progress")
        }
    }
}