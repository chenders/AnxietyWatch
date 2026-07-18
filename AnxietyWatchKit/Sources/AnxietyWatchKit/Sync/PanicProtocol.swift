import Foundation
import GRDB

/// The 225/250 MB panic protocol state machine (Spec §2.5).
///
/// | State    | Trigger                                    | Action |
/// |----------|--------------------------------------------|--------|
/// | Normal   | size < 225 MB                              | none   |
/// | Yellow   | size >= 225 MB                             | urgent push (30 s timeout), keep accepting writes |
/// | Red      | size >= 250 MB after Yellow attempt failed | data_gap(reason: memory_panic) per (source, type); evict oldest ACKed ranges |
/// | Overflow | size >= 250 MB and NO ACKed rows remain    | throw `overflowPreconditionsMet` — the unacked_overflow protocol (T19) takes over |
///
/// Un-ACKed row protection: memory_panic eviction NEVER deletes rows with
/// `(hlc_physical, hlc_logical) > per-node ackedCursor`. Only the T19 overflow
/// path may.
public actor PanicProtocol {
    public struct Dependencies: Sendable {
        public let database: DatabaseManager
        public let samples: SamplesStore
        public let tombstones: SampleTombstonesStore
        public let hlc: HLC
        /// Entry point for the Yellow-state urgent push. In production wire
        /// this to `SyncCoordinator.syncOnce()`; injected as a closure so
        /// tests don't need the real coordinator (and PanicProtocol doesn't
        /// take a hard dependency on it).
        public let syncOnceHook: @Sendable () async throws -> Void

        public init(
            database: DatabaseManager,
            samples: SamplesStore,
            tombstones: SampleTombstonesStore,
            hlc: HLC,
            syncOnceHook: @escaping @Sendable () async throws -> Void
        ) {
            self.database = database
            self.samples = samples
            self.tombstones = tombstones
            self.hlc = hlc
            self.syncOnceHook = syncOnceHook
        }
    }

    public enum PanicResult: Sendable, Equatable {
        /// < 225 MB.
        case normal
        /// >= 225 MB, urgent push OK.
        case yellowSyncSucceeded
        /// Yellow band (>= 225 MB, < 250 MB) and the urgent push failed —
        /// keep accepting writes (spec), but callers can distinguish this
        /// from truly-normal for scheduling/telemetry.
        case yellowSyncFailedNoActionNeeded
        /// >= 250 MB after failed push: memory_panic eviction ran.
        case yellowSyncFailedThenRed(dropped: Int, gapsInserted: Int)
        /// T19 must take over (returned only by T19's override path; T18
        /// signals via `PanicError.overflowPreconditionsMet`).
        case overflowPreconditionsMet
    }

    public enum PanicError: Error, Sendable {
        case databaseSizeUnavailable
        /// >= 250 MB and no ACKed rows to evict — the unacked_overflow
        /// protocol (T19) must handle this; T18 never touches un-ACKed rows.
        case overflowPreconditionsMet
    }

    /// Internal marker for the urgent-push timeout race.
    private struct UrgentSyncTimeout: Error {}

    private let deps: Dependencies
    private let yellowThresholdBytes: Int64
    private let redThresholdBytes: Int64
    private let targetSizeBytes: Int64
    private let syncTimeoutSeconds: TimeInterval

    /// 6 hours — the maximum wall-clock coverage per data_gap tombstone (§2.6
    /// applies the same cap to overflow; memory_panic uses it for chunking).
    private let chunkSpanSeconds: Double = 6 * 3600

    public init(
        dependencies: Dependencies,
        yellowThresholdBytes: Int64 = 225 * 1024 * 1024,
        redThresholdBytes: Int64 = 250 * 1024 * 1024,
        targetSizeBytes: Int64 = 200 * 1024 * 1024,
        syncTimeoutSeconds: TimeInterval = 30
    ) {
        self.deps = dependencies
        self.yellowThresholdBytes = yellowThresholdBytes
        self.redThresholdBytes = redThresholdBytes
        self.targetSizeBytes = targetSizeBytes
        self.syncTimeoutSeconds = syncTimeoutSeconds
    }

    // MARK: - Entry point

    /// Run one pass of the panic protocol. Idempotent; safe to call from
    /// arbitrary schedulers (RetentionCompactor, WK background refresh, etc.).
    /// - Parameters:
    ///   - currentSizeBytes: DB size measured by the caller
    ///     (`PRAGMA page_count * page_size`) — injected for testability.
    ///   - ackedCursorPerNode: per-node HLC watermark; rows at-or-below it are
    ///     ACKed and safe to evict.
    public func runPanicCheck(
        currentSizeBytes: Int64,
        ackedCursorPerNode: [Data: (physical: Int64, logical: Int32)]
    ) async throws -> PanicResult {
        // Normal: nothing to do.
        if currentSizeBytes < yellowThresholdBytes {
            return .normal
        }

        // Yellow: attempt the urgent push with a timeout.
        Log.panic.warning("PanicProtocol: Yellow at \(currentSizeBytes) bytes — attempting urgent push")
        let syncSucceeded = await attemptUrgentSync()
        if syncSucceeded {
            Log.panic.info("PanicProtocol: urgent push succeeded")
            return .yellowSyncSucceeded
        }

        // Below Red: keep accepting writes; nothing else to do this pass.
        if currentSizeBytes < redThresholdBytes {
            Log.panic.warning("PanicProtocol: urgent push failed but size < red threshold; continuing")
            return .yellowSyncFailedNoActionNeeded
        }

        // Red: memory_panic eviction of ACKed rows only.
        Log.panic.fault("PanicProtocol: Red at \(currentSizeBytes) bytes — evicting ACKed rows (sync.memory_panic.fired)")
        return try await runRedEviction(ackedCursorPerNode: ackedCursorPerNode)
    }

    // MARK: - Yellow

    private func attemptUrgentSync() async -> Bool {
        let hook = deps.syncOnceHook
        let timeout = syncTimeoutSeconds
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await hook()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw UrgentSyncTimeout()
                }
                // First finisher wins; cancel the loser.
                try await group.next()
                group.cancelAll()
            }
            return true
        } catch {
            Log.panic.warning("PanicProtocol: urgent push failed/timed out: \(error)")
            return false
        }
    }

    // MARK: - Red

    private struct AckedGroup: Sendable, Equatable {
        let source: Int32
        let type: Int32
        let nodeID: Data
        let minTimestamp: Double
    }

    private func runRedEviction(
        ackedCursorPerNode: [Data: (physical: Int64, logical: Int32)]
    ) async throws -> PanicResult {
        var totalDropped = 0
        var totalGaps = 0

        evictionLoop: while true {
            let groups = try await ackedGroups(ackedCursorPerNode: ackedCursorPerNode)

            if groups.isEmpty {
                if totalGaps == 0 {
                    // Nothing ACKed at all: everything is un-ACKed and
                    // protected. T19's unacked_overflow protocol takes over.
                    throw PanicError.overflowPreconditionsMet
                }
                break
            }

            for group in groups {
                guard let cursor = ackedCursorPerNode[group.nodeID] else { continue }

                // Fresh HLC minted at eviction time (Spec §2.6 tombstone
                // semantics) — NEVER reuse the dropped rows' HLCs.
                let stamp = await deps.hlc.now()

                let (dropped, inserted) = try await evictChunk(
                    group: group,
                    ackedCursor: cursor,
                    tombstoneHLC: stamp
                )
                totalDropped += dropped
                totalGaps += inserted

                // Under auto_vacuum=INCREMENTAL, DELETE only moves pages to
                // the freelist — page_count doesn't shrink until an explicit
                // incremental_vacuum returns them to the OS. Without this the
                // size check below never improves: we'd over-evict everything
                // and still cascade into an unnecessary T19 overflow.
                try await deps.database.incrementalVacuum()

                if try await measuredDatabaseSize() <= targetSizeBytes {
                    break evictionLoop
                }
            }
        }

        Log.panic.fault("PanicProtocol: memory_panic evicted \(totalDropped) row(s) across \(totalGaps) gap(s)")
        return .yellowSyncFailedThenRed(dropped: totalDropped, gapsInserted: totalGaps)
    }

    /// All (source, type, node) groups that still contain ACKed rows, with
    /// each group's oldest ACKed timestamp. One query per node keeps the
    /// predicate on the composite HLC index.
    private func ackedGroups(
        ackedCursorPerNode: [Data: (physical: Int64, logical: Int32)]
    ) async throws -> [AckedGroup] {
        var groups: [AckedGroup] = []
        for (nodeID, cursor) in ackedCursorPerNode {
            let nodeGroups: [AckedGroup] = try await deps.database.reader { db in
                try Row.fetchAll(db, sql: """
                    SELECT source, type, MIN(timestamp) AS min_ts
                      FROM samples
                     WHERE node_id = ?
                       AND (hlc_physical, hlc_logical) <= (?, ?)
                     GROUP BY source, type
                    """, arguments: [nodeID, cursor.physical, cursor.logical]).map {
                    AckedGroup(source: $0["source"], type: $0["type"],
                               nodeID: nodeID, minTimestamp: $0["min_ts"])
                }
            }
            groups.append(contentsOf: nodeGroups)
        }
        // Oldest data first across groups.
        return groups.sorted { $0.minTimestamp < $1.minTimestamp }
    }

    /// Evicts the oldest <= 6 h chunk of ACKed rows for one group: inserts the
    /// data_gap tombstone and deletes the covered rows in ONE transaction.
    private func evictChunk(
        group: AckedGroup,
        ackedCursor: (physical: Int64, logical: Int32),
        tombstoneHLC: HLCStamped
    ) async throws -> (dropped: Int, gapsInserted: Int) {
        let chunkEnd = group.minTimestamp + chunkSpanSeconds
        let source = group.source
        let type = group.type
        let nodeID = group.nodeID

        return try await deps.database.writer { db in
            // Coverage stats for the chunk.
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(timestamp) AS ts_min, MAX(timestamp) AS ts_max, COUNT(*) AS n
                  FROM samples
                 WHERE source = ? AND type = ? AND node_id = ?
                   AND (hlc_physical, hlc_logical) <= (?, ?)
                   AND timestamp < ?
                """, arguments: [source, type, nodeID,
                                 ackedCursor.physical, ackedCursor.logical, chunkEnd])

            guard let row, let count: Int = row["n"], count > 0,
                  let tsMin: Double = row["ts_min"], let tsMax: Double = row["ts_max"] else {
                return (0, 0)
            }

            // data_gap tombstone advertising the eviction to peers.
            try db.execute(sql: """
                INSERT INTO sample_tombstones
                    (source, type, ts_start, ts_end,
                     hlc_physical, hlc_logical, node_id, dropped_row_count, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'memory_panic')
                """, arguments: [
                    source, type, tsMin, tsMax,
                    tombstoneHLC.physical, tombstoneHLC.logical, tombstoneHLC.nodeID,
                    count
                ])

            // Evict — ACKed rows in the chunk only.
            try db.execute(sql: """
                DELETE FROM samples
                 WHERE source = ? AND type = ? AND node_id = ?
                   AND (hlc_physical, hlc_logical) <= (?, ?)
                   AND timestamp < ?
                """, arguments: [source, type, nodeID,
                                 ackedCursor.physical, ackedCursor.logical, chunkEnd])
            let deleted = db.changesCount

            return (deleted, 1)
        }
    }

    /// Actual on-disk size, re-measured between chunks so eviction stops as
    /// soon as the target is reached.
    private func measuredDatabaseSize() async throws -> Int64 {
        try await deps.database.reader { db in
            let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return pageCount * pageSize
        }
    }
}
