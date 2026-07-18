import Foundation
import GRDB

/// Runs the ordinary retention pass: deletes samples older than the retention
/// window, in bounded chunks that yield between iterations so BLE ingest can
/// always win the next writer-queue slot (Spec §2.5).
///
/// Compaction is COOPERATIVE, not preemptive. It never calls
/// `wal_checkpoint(TRUNCATE)` — that runs only inside the WKApplicationRefresh
/// background task from CheckpointManager (T11) when BLE is idle (Spec §1.5).
///
/// This actor does NOT enforce un-ACKed protection by itself — the caller
/// (SyncCoordinator + PanicProtocol composition, T18-T19) must supply the
/// ackedCursor so we only ever delete rows whose HLC is <= ackedCursor.
///
/// Note on the DELETE shape: `samples` and `sample_tombstones` are
/// `WITHOUT ROWID` tables (SchemaV1), so the classic
/// `DELETE ... WHERE rowid IN (SELECT rowid ... LIMIT ?)` chunking idiom is
/// not available. We use the equivalent primary-key row-value form instead:
///
/// ```sql
/// DELETE FROM samples
///  WHERE (source, type, timestamp) IN (
///    SELECT source, type, timestamp FROM samples
///     WHERE node_id = ? AND timestamp < ?
///       AND (hlc_physical, hlc_logical) <= (?, ?)
///     LIMIT ?
///  )
/// ```
///
/// The un-ACKed protection cursor is per-node, so we loop one DELETE per
/// node_id in the cursor map (Opus round-4: expanding the map into a single
/// OR chain defeats the composite `idx_samples_hlc` index).
public actor RetentionCompactor {
    private let database: DatabaseManager

    public struct RetentionResult: Sendable, Equatable {
        public let samplesDeleted: Int
        public let tombstonesDeleted: Int
        public let elapsedMillis: Int

        public init(samplesDeleted: Int, tombstonesDeleted: Int, elapsedMillis: Int) {
            self.samplesDeleted = samplesDeleted
            self.tombstonesDeleted = tombstonesDeleted
            self.elapsedMillis = elapsedMillis
        }
    }

    /// Errors specific to the compactor.
    public enum RetentionCompactorError: Error, Sendable, Equatable {
        case cancelled
    }

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// Run one retention pass.
    /// - Parameters:
    ///   - now: current time in seconds since epoch (injected for tests).
    ///   - retentionWindow: seconds. Rows with timestamp < now - retentionWindow are eligible.
    ///   - ackedCursorPerNode: per-node HLC watermark below which rows are safe to evict.
    ///     Rows whose (hlc_physical, hlc_logical) > cursor for their node are NEVER deleted,
    ///     regardless of age (Opus round-3 E.5: un-ACKed rows are protected). Rows whose
    ///     node_id is absent from the map are likewise never deleted.
    ///   - chunkSize: max rows to delete per DELETE ... LIMIT batch.
    /// - Returns: how many samples + tombstones were deleted.
    public func runRetention(
        now: Double,
        retentionWindow: TimeInterval,
        ackedCursorPerNode: [Data: (physical: Int64, logical: Int32)],
        chunkSize: Int = 5000
    ) async throws -> RetentionResult {
        let start = DispatchTime.now()
        let cutoff = now - retentionWindow

        try checkCancelled()

        var samplesDeleted = 0
        var tombstonesDeleted = 0

        // Per-node chunked delete loops. One node at a time so each DELETE's
        // subquery stays on the (node_id, hlc_physical, hlc_logical) index.
        //
        // CORRECTNESS SEAM: the outer DELETE ... WHERE (source, type, timestamp) IN (...)
        // is safe ONLY because SchemaV1.samples PK is exactly (source, type, timestamp),
        // guaranteeing the tuple uniquely identifies one row across all nodes. If a
        // future schema revision ever adds node_id to the samples PK to allow
        // same-(source,type,timestamp) rows across different writing nodes, this DELETE
        // will silently over-delete un-ACKed sibling rows from other nodes. In that case
        // extend the outer WHERE to include node_id as well.
        for (nodeID, cursor) in ackedCursorPerNode {
            samplesDeleted += try await chunkedDelete(
                sql: """
                DELETE FROM samples
                 WHERE (source, type, timestamp) IN (
                   SELECT source, type, timestamp FROM samples
                    WHERE node_id = ? AND timestamp < ?
                      AND (hlc_physical, hlc_logical) <= (?, ?)
                    LIMIT ?
                 )
                """,
                arguments: [nodeID, cutoff, cursor.physical, cursor.logical, chunkSize],
                chunkSize: chunkSize
            )
        }

        for (nodeID, cursor) in ackedCursorPerNode {
            tombstonesDeleted += try await chunkedDelete(
                sql: """
                DELETE FROM sample_tombstones
                 WHERE (source, type, ts_start, hlc_physical, hlc_logical, node_id) IN (
                   SELECT source, type, ts_start, hlc_physical, hlc_logical, node_id
                     FROM sample_tombstones
                    WHERE node_id = ? AND ts_end < ?
                      AND (hlc_physical, hlc_logical) <= (?, ?)
                    LIMIT ?
                 )
                """,
                arguments: [nodeID, cutoff, cursor.physical, cursor.logical, chunkSize],
                chunkSize: chunkSize
            )
        }

        // PASSIVE checkpoint only — never TRUNCATE here (Spec §1.5: TRUNCATE
        // runs solely inside the WKApplicationRefresh background task, T11).
        try await database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }

        let elapsedMillis = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        let result = RetentionResult(
            samplesDeleted: samplesDeleted,
            tombstonesDeleted: tombstonesDeleted,
            elapsedMillis: elapsedMillis
        )

        Log.storage.info(
            "Retention pass complete: \(samplesDeleted) samples, \(tombstonesDeleted) tombstones deleted in \(elapsedMillis) ms"
        )

        return result
    }

    /// Executes chunked DELETEs until a batch removes fewer than `chunkSize`
    /// rows, yielding between batches so BLE ingest can win the writer queue.
    private func chunkedDelete(
        sql: String,
        arguments: StatementArguments,
        chunkSize: Int
    ) async throws -> Int {
        var totalDeleted = 0
        while true {
            try checkCancelled()

            let deleted = try await database.writer { db -> Int in
                try db.execute(sql: sql, arguments: arguments)
                return db.changesCount
            }
            totalDeleted += deleted

            if deleted < chunkSize {
                break
            }

            // Cooperative yield: give BLE ingest a chance at the writer queue.
            await Task.yield()
        }
        return totalDeleted
    }

    private func checkCancelled() throws {
        if Task.isCancelled {
            throw RetentionCompactorError.cancelled
        }
    }
}
