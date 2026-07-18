import Foundation
import GRDB

/// The unacked_overflow protocol (Spec §2.6) — LAST RESORT eviction of
/// un-ACKed raw samples, invoked when PanicProtocol (T18) throws
/// `PanicError.overflowPreconditionsMet`.
///
/// All four preconditions must hold before un-ACKed data is dropped:
/// 1. Ordinary eviction to 200 MB has already run (caller-attested).
/// 2. The Yellow-state urgent push failed or timed out (caller-attested; a
///    defensive last-chance push is retried here before any data loss).
/// 3. Raw un-ACKed samples for the target (source, type) are already
///    downsampled to `samples_1min` — if not, downsample SYNCHRONOUSLY now.
/// 4. No prior unacked_overflow for the same (source, type) in the last
///    60 minutes (hysteresis).
///
/// Eviction is capped at 6 hours of wall-clock coverage per (source, type)
/// per event; `samples_1min` rollups are NEVER deleted, so the gap is
/// coarse-grained, not total.
///
/// Preconditions (3) and (4) are PER-GROUP (§2.6: "one (source, type) at a
/// time"): a group blocked by hysteresis or missing rollups is SKIPPED, never
/// aborts the run — other groups' evictable data must still relieve the
/// pressure. All-groups-blocked is expected steady state ("wait for the next
/// window") and returns `.zero`, not an error. Only caller-misuse
/// preconditions (1) and (2) throw.
public actor UnackedOverflow {
    public struct Dependencies: Sendable {
        public let database: DatabaseManager
        public let samples: SamplesStore
        public let tombstones: SampleTombstonesStore
        public let downsampler: IdleDownsampler
        public let hlc: HLC
        /// Same shape as PanicProtocol's hook; injectable for tests. Used for
        /// the defensive last-chance push before dropping un-ACKed data.
        public let syncOnceHook: @Sendable () async throws -> Void

        public init(
            database: DatabaseManager,
            samples: SamplesStore,
            tombstones: SampleTombstonesStore,
            downsampler: IdleDownsampler,
            hlc: HLC,
            syncOnceHook: @escaping @Sendable () async throws -> Void
        ) {
            self.database = database
            self.samples = samples
            self.tombstones = tombstones
            self.downsampler = downsampler
            self.hlc = hlc
            self.syncOnceHook = syncOnceHook
        }
    }

    public struct OverflowResult: Sendable, Equatable {
        /// (source, type) pairs evicted.
        public let evictedGroups: Int
        /// Total raw sample rows dropped.
        public let evictedSamples: Int
        /// One per (source, type) per event.
        public let tombstonesInserted: Int
        /// How many groups needed on-demand downsampling.
        public let downsamplesRun: Int
        /// Groups skipped because a prior unacked_overflow fired within the
        /// hysteresis window (per-group precondition 4).
        public let hysteresisBlockedGroups: Int
        /// Groups skipped because no rollup coverage could be produced
        /// (per-group precondition 3).
        public let rollupUnavailableGroups: Int

        public static let zero = OverflowResult(
            evictedGroups: 0, evictedSamples: 0, tombstonesInserted: 0, downsamplesRun: 0,
            hysteresisBlockedGroups: 0, rollupUnavailableGroups: 0)

        public init(evictedGroups: Int, evictedSamples: Int, tombstonesInserted: Int,
                    downsamplesRun: Int, hysteresisBlockedGroups: Int, rollupUnavailableGroups: Int) {
            self.evictedGroups = evictedGroups
            self.evictedSamples = evictedSamples
            self.tombstonesInserted = tombstonesInserted
            self.downsamplesRun = downsamplesRun
            self.hysteresisBlockedGroups = hysteresisBlockedGroups
            self.rollupUnavailableGroups = rollupUnavailableGroups
        }
    }

    public enum OverflowError: Error, Sendable, Equatable {
        /// Precondition (1): T18 memory_panic eviction must have been attempted.
        case ordinaryEvictionNotAttempted
        /// Precondition (2): the 30 s urgent push must have been tried and failed.
        case urgentSyncNotAttempted
        /// Per-group precondition (3) failure. NOT thrown by `run()` — blocked
        /// groups are skipped and counted in `rollupUnavailableGroups`; kept
        /// for callers that probe a single group.
        case rollupUnavailable(source: Int32, type: Int32)
        /// Per-group precondition (4) failure. NOT thrown by `run()` — blocked
        /// groups are skipped and counted in `hysteresisBlockedGroups`; kept
        /// for callers that probe a single group.
        case hysteresisActive(source: Int32, type: Int32, minutesRemaining: Int)
    }

    private struct UrgentSyncTimeout: Error {}

    private let deps: Dependencies
    private let redThresholdBytes: Int64
    private let targetSizeBytes: Int64
    private let urgentSyncTimeoutSeconds: TimeInterval
    private let maxRawEvictionHours: Int
    private let hysteresisMinutes: Int

    public init(
        dependencies: Dependencies,
        redThresholdBytes: Int64 = 250 * 1024 * 1024,
        targetSizeBytes: Int64 = 200 * 1024 * 1024,
        urgentSyncTimeoutSeconds: TimeInterval = 30,
        maxRawEvictionHours: Int = 6,
        hysteresisMinutes: Int = 60
    ) {
        self.deps = dependencies
        self.redThresholdBytes = redThresholdBytes
        self.targetSizeBytes = targetSizeBytes
        self.urgentSyncTimeoutSeconds = urgentSyncTimeoutSeconds
        self.maxRawEvictionHours = maxRawEvictionHours
        self.hysteresisMinutes = hysteresisMinutes
    }

    // MARK: - Entry point

    /// Run the unacked_overflow protocol. Called by PanicProtocol (or an
    /// integration layer) after T18 signals overflowPreconditionsMet.
    /// - Parameters:
    ///   - currentSizeBytes: current DB size at the time of the call.
    ///   - ordinaryEvictionAttempted: caller must have already run T18
    ///     memory_panic eviction down to 200 MB (or attempted to).
    ///   - urgentSyncAttempted: whether the urgent-sync push was tried and
    ///     failed.
    public func run(
        currentSizeBytes: Int64,
        ordinaryEvictionAttempted: Bool,
        urgentSyncAttempted: Bool
    ) async throws -> OverflowResult {
        // Preconditions (1) and (2).
        guard ordinaryEvictionAttempted else {
            throw OverflowError.ordinaryEvictionNotAttempted
        }
        guard urgentSyncAttempted else {
            throw OverflowError.urgentSyncNotAttempted
        }

        // Defensive last-chance push before ANY un-ACKed data loss. If it
        // succeeds, the un-ACKed set just became ACKed — bail out with zero
        // evictions and let the caller re-run the ordinary panic check.
        if await attemptUrgentSync() {
            Log.panic.info("unacked_overflow: last-chance push succeeded; no eviction needed")
            return .zero
        }

        // Time reference: the HLC's wall view keeps hysteresis deterministic
        // under test clock injection.
        let nowStamp = await deps.hlc.now()
        let nowMillis = nowStamp.physical
        let nowSeconds = Double(nowMillis) / 1_000

        var evictedGroups = 0
        var evictedSamples = 0
        var tombstonesInserted = 0
        var downsamplesRun = 0
        var hysteresisBlockedGroups = 0
        var rollupUnavailableGroups = 0

        // Oldest-data-first across (source, type) groups.
        let groups = try await sampleGroups()

        for group in groups {
            // Per-group precondition (4): hysteresis. A blocked group is
            // SKIPPED — other groups must still be able to relieve pressure.
            if let minutesRemaining = try await hysteresisMinutesRemaining(
                source: group.source, type: group.type, nowMillis: nowMillis) {
                Log.panic.warning("unacked_overflow: (source=\(group.source), type=\(group.type)) hysteresis active (\(minutesRemaining) min remaining); skipping group")
                hysteresisBlockedGroups += 1
                continue
            }

            let chunkEnd = group.minTimestamp + Double(maxRawEvictionHours) * 3_600

            // Per-group precondition (3): rollups must exist before raw
            // eviction — downsample synchronously now if needed; skip the
            // group (don't abort the run) if coverage still can't be produced.
            let downsampled = try await deps.downsampler.downsample(
                now: nowSeconds, source: group.source, type: group.type)
            if downsampled.bucketsWritten > 0 {
                downsamplesRun += 1
            }
            let hasRollups = try await hasRollupCoverage(
                source: group.source, type: group.type,
                from: group.minTimestamp, to: chunkEnd)
            guard hasRollups else {
                Log.panic.warning("unacked_overflow: (source=\(group.source), type=\(group.type)) rollup coverage unavailable; skipping group")
                rollupUnavailableGroups += 1
                continue
            }

            // Fresh HLC for the tombstone (never the dropped rows' HLCs).
            let stamp = await deps.hlc.now()

            let dropped = try await evictChunk(
                source: group.source, type: group.type,
                upTo: chunkEnd, tombstoneHLC: stamp)
            guard dropped > 0 else { continue }

            evictedGroups += 1
            evictedSamples += dropped
            tombstonesInserted += 1

            Log.panic.fault("sync.unacked_overflow.fired: (source=\(group.source), type=\(group.type)) dropped \(dropped) raw row(s)")

            // Reclaim freelist pages so the size check reflects reality
            // (auto_vacuum=INCREMENTAL; see PanicProtocol/T18 fix).
            try await deps.database.incrementalVacuum()
            if try await measuredDatabaseSize() <= targetSizeBytes {
                break
            }
        }

        // All-groups-blocked is expected steady state ("wait for the next
        // window"): an empty result, not an error.
        return OverflowResult(
            evictedGroups: evictedGroups,
            evictedSamples: evictedSamples,
            tombstonesInserted: tombstonesInserted,
            downsamplesRun: downsamplesRun,
            hysteresisBlockedGroups: hysteresisBlockedGroups,
            rollupUnavailableGroups: rollupUnavailableGroups
        )
    }

    // MARK: - Preconditions

    private func attemptUrgentSync() async -> Bool {
        let hook = deps.syncOnceHook
        let timeout = urgentSyncTimeoutSeconds
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await hook() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw UrgentSyncTimeout()
                }
                try await group.next()
                group.cancelAll()
            }
            return true
        } catch {
            return false
        }
    }

    /// Returns the remaining hysteresis minutes for the group, or nil when the
    /// group is clear to evict.
    private func hysteresisMinutesRemaining(source: Int32, type: Int32, nowMillis: Int64) async throws -> Int? {
        let windowMillis = Int64(hysteresisMinutes) * 60_000
        let cutoff = nowMillis - windowMillis

        let lastFired: Int64? = try await deps.database.reader { db in
            try Int64.fetchOne(db, sql: """
                SELECT hlc_physical FROM sample_tombstones
                 WHERE source = ? AND type = ? AND reason = 'unacked_overflow'
                   AND hlc_physical > ?
                 ORDER BY hlc_physical DESC
                 LIMIT 1
                """, arguments: [source, type, cutoff])
        }

        guard let lastFired else { return nil }
        let elapsedMillis = nowMillis - lastFired
        let remainingMillis = max(0, windowMillis - elapsedMillis)
        return Int((Double(remainingMillis) / 60_000).rounded(.up))
    }

    private func hasRollupCoverage(source: Int32, type: Int32, from: Double, to: Double) async throws -> Bool {
        let bucketStart = Int64(from / 60)
        let bucketEnd = Int64(to / 60)
        return try await deps.database.reader { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM samples_1min
                     WHERE source = ? AND type = ?
                       AND minute_bucket BETWEEN ? AND ?
                )
                """, arguments: [source, type, bucketStart, bucketEnd]) ?? false
        }
    }

    // MARK: - Eviction

    private struct SampleGroup: Sendable {
        let source: Int32
        let type: Int32
        let minTimestamp: Double
    }

    private func sampleGroups() async throws -> [SampleGroup] {
        try await deps.database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT source, type, MIN(timestamp) AS min_ts
                  FROM samples
                 GROUP BY source, type
                 ORDER BY min_ts
                """).map {
                SampleGroup(source: $0["source"], type: $0["type"], minTimestamp: $0["min_ts"])
            }
        }
    }

    /// Inserts the unacked_overflow data_gap tombstone and deletes the covered
    /// raw rows in ONE transaction. `samples_1min` rollups are untouched.
    private func evictChunk(
        source: Int32,
        type: Int32,
        upTo chunkEnd: Double,
        tombstoneHLC: HLCStamped
    ) async throws -> Int {
        try await deps.database.writer { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(timestamp) AS ts_min, MAX(timestamp) AS ts_max, COUNT(*) AS n
                  FROM samples
                 WHERE source = ? AND type = ? AND timestamp < ?
                """, arguments: [source, type, chunkEnd])

            guard let row, let count: Int = row["n"], count > 0,
                  let tsMin: Double = row["ts_min"], let tsMax: Double = row["ts_max"] else {
                return 0
            }

            try db.execute(sql: """
                INSERT INTO sample_tombstones
                    (source, type, ts_start, ts_end,
                     hlc_physical, hlc_logical, node_id, dropped_row_count, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'unacked_overflow')
                """, arguments: [
                    source, type, tsMin, tsMax,
                    tombstoneHLC.physical, tombstoneHLC.logical, tombstoneHLC.nodeID,
                    count
                ])

            // Raw rows only — rollups in samples_1min MUST survive so the gap
            // is coarse-grained, not total (Spec §2.6 step 3).
            try db.execute(sql: """
                DELETE FROM samples
                 WHERE source = ? AND type = ? AND timestamp < ?
                """, arguments: [source, type, chunkEnd])

            return db.changesCount
        }
    }

    private func measuredDatabaseSize() async throws -> Int64 {
        try await deps.database.reader { db in
            let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return pageCount * pageSize
        }
    }
}
