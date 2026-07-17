import Foundation
import GRDB

// MARK: - Cursor persistence

/// JSON-file persistence for the sync cursors (`sync_cursor.json`, same
/// directory as the DB). Written ONLY after a successful local apply (pull) or
/// server ACK (push) — never speculatively (Spec §5.4).
public struct SyncCursorStore: Sendable {
    public struct Persisted: Codable, Equatable, Sendable {
        public var pull: TableCursors
        public var push: TableCursors

        public init(pull: TableCursors = .init(), push: TableCursors = .init()) {
            self.pull = pull
            self.push = push
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Persisted? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Persisted.self, from: data)
    }

    public func save(_ persisted: Persisted) throws {
        let data = try JSONEncoder().encode(persisted)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - SyncCoordinator

/// Orchestrates pull/push sync cycles against a `SyncEndpoint` (Spec §2.3,
/// §2.7, §5.4).
///
/// DEFERRED — CRUD table materialization: looking up a peer's Journal/
/// Medications/Settings row content from a received `_sync_log` entry is
/// deferred to a follow-up phase. Today's SyncCoordinator handles the
/// sample/tombstone bulk path — where the row data itself flows on the wire —
/// and the delta cursor for CRUD tables, without materializing peer row
/// content. Plan §7.2's dual-write pattern keeps UI-visible CRUD tables
/// (SwiftData) authoritative through the initial rollout; the coordinator
/// plumbs the delta cursor now so the schema is ready for CRUD-content
/// plumbing in a later minor version. Pulled `_sync_log` entries whose
/// table_name is not in the registry are warned about and ignored.
///
/// Invariants:
/// - Pulled peer rows are persisted with the INCOMING remote HLC unchanged.
///   `hlc.observe()` is called per row (advancing the local clock, bounded
///   merge), but its return value — the clamped LOCAL view — is never stored
///   on the peer row. Storing it would corrupt peer causal history.
/// - Pulled-batch inserts run in ONE writer transaction; the pull cursor file
///   is written only after that transaction commits.
/// - The push cursor advances ONLY on a server ACK (`SyncPushResponse.ackCursor`).
/// - While `ClockSuspectGate.isSuspect`, uploads are paused; pulls continue
///   (Spec §2.2).
/// - Rows whose HLC exceeds 24 h drift are quarantined to `_sync_quarantine`
///   and the pull cursor never advances past them for their node.
public actor SyncCoordinator {
    public struct Dependencies: Sendable {
        public let database: DatabaseManager
        public let samples: SamplesStore
        public let tombstones: SampleTombstonesStore
        public let syncLog: SyncLogStore
        public let quarantine: QuarantineStore
        public let hlc: HLC
        public let clockSuspect: ClockSuspectGate
        public let endpoint: SyncEndpoint
        /// Location of `sync_cursor.json`. Should live in the same directory
        /// as the DB file (Spec: <AppGroupSupport>/sync_cursor.json).
        public let cursorFileURL: URL

        public init(
            database: DatabaseManager,
            samples: SamplesStore,
            tombstones: SampleTombstonesStore,
            syncLog: SyncLogStore,
            quarantine: QuarantineStore,
            hlc: HLC,
            clockSuspect: ClockSuspectGate,
            endpoint: SyncEndpoint,
            cursorFileURL: URL
        ) {
            self.database = database
            self.samples = samples
            self.tombstones = tombstones
            self.syncLog = syncLog
            self.quarantine = quarantine
            self.hlc = hlc
            self.clockSuspect = clockSuspect
            self.endpoint = endpoint
            self.cursorFileURL = cursorFileURL
        }
    }

    public enum SyncCoordinatorError: Error, Sendable, Equatable {
        /// fullRestore() exceeded its iteration safety cap without the server
        /// draining — e.g. every page re-quarantines and the cursor stalls.
        case restoreDidNotTerminate
    }

    public struct SyncOnceResult: Sendable, Equatable {
        public let pulledSamples: Int
        public let pulledTombstones: Int
        public let pulledSyncLog: Int
        public let pushedSamples: Int
        public let pushedTombstones: Int
        public let pushedSyncLog: Int
    }

    /// MANUAL SYNCABLE REGISTRATION LIST — read this before adding a table.
    ///
    /// Every `@Syncable` type in the app MUST be appended here (at app startup,
    /// before `bootstrap()`). There is NO automatic discovery: a type that is
    /// annotated `@Syncable` but missing from this list silently never has its
    /// triggers applied or its rows pushed — the exact silent-omission data
    /// loss the T16 macro exists to prevent, reintroduced one level up.
    ///
    /// ⚠️ THIS LIST IS THE MANUAL SEAM. `bootstrap()` registers exactly this
    /// list into the SyncRegistry and nothing verifies it at compile time. The
    /// ONLY tripwire is the completeness test
    /// (`testBootstrapCompletenessCatchesForgottenType` in
    /// SyncCoordinatorTests), which hardcodes the expected table-name set
    /// INDEPENDENTLY of this list. When you add a @Syncable type you MUST
    /// update BOTH this list AND that test's expected set — updating only one
    /// fails the test, which is the point.
    public nonisolated(unsafe) static var registeredSyncableTypes: [any Syncable.Type] = []

    private let deps: Dependencies
    private let cursorStore: SyncCursorStore
    private let registry = SyncRegistry()

    private var pullCursors = TableCursors()
    private var pushCursors = TableCursors()

    private let pushBatchLimit = 500
    private let maxBatchBytes = 512 * 1024

    public init(dependencies: Dependencies) {
        self.deps = dependencies
        self.cursorStore = SyncCursorStore(url: dependencies.cursorFileURL)
    }

    // MARK: - Bootstrap

    /// Reads persisted cursors from disk, registers all types from
    /// `registeredSyncableTypes`, and wires the DatabaseManager
    /// PostRecoveryHook to `fullRestore()` (Spec §1.6 step 6).
    /// Periodic scheduling is a later task.
    public func bootstrap() async throws {
        if let persisted = try cursorStore.load() {
            pullCursors = persisted.pull
            pushCursors = persisted.push
        }

        for type in Self.registeredSyncableTypes {
            await type.registerForSync(registry)
        }

        await deps.database.setPostRecoveryHook { [weak self] error in
            guard error == nil, let self else { return }
            do {
                try await self.fullRestore()
            } catch {
                Log.sync.error("fullRestore after corruption recovery failed: \(error)")
            }
        }
    }

    /// Tables registered via bootstrap() — for the completeness test and
    /// SyncCoordinator's trigger application (later task).
    public func registeredSyncTables() async -> [String] {
        await registry.registered.map { $0.name }
    }

    // MARK: - Sync cycle

    /// Manually run one sync cycle: pull then push.
    public func syncOnce() async throws -> SyncOnceResult {
        let pulled = try await runPull(cursor: pullCursors)
        let pushed = try await runPush()
        return SyncOnceResult(
            pulledSamples: pulled.samples,
            pulledTombstones: pulled.tombstones,
            pulledSyncLog: pulled.syncLog,
            pushedSamples: pushed.samples,
            pushedTombstones: pushed.tombstones,
            pushedSyncLog: pushed.syncLog
        )
    }

    /// Full restore from server (called by the DatabaseManager
    /// PostRecoveryHook after corruption recovery per Spec §1.6): resets the
    /// pull cursors to "from the beginning" and DRAINS the server — looping
    /// until a page applies zero rows AND the cursor makes no progress. A
    /// single page would leave the post-recovery DB permanently partial.
    /// The iteration cap guards against infinite spins when only quarantined
    /// rows remain and every page re-quarantines without cursor progress.
    public func fullRestore() async throws {
        pullCursors = TableCursors()
        var priorCursor = pullCursors
        var totalApplied = 0
        let maxIterations = 10_000

        for _ in 0..<maxIterations {
            let counts = try await runPull(cursor: pullCursors)
            let applied = counts.samples + counts.tombstones + counts.syncLog
            totalApplied += applied

            if applied == 0 && pullCursors == priorCursor {
                Log.sync.info("fullRestore drained: \(totalApplied) row(s) applied")
                return
            }
            priorCursor = pullCursors
        }

        Log.sync.fault("fullRestore hit max iterations \(maxIterations); aborting")
        throw SyncCoordinatorError.restoreDidNotTerminate
    }

    // MARK: - Pull

    private struct PullCounts {
        let samples: Int
        let tombstones: Int
        let syncLog: Int
    }

    private func runPull(cursor: TableCursors) async throws -> PullCounts {
        let response = try await deps.endpoint.pull(cursor: cursor, maxBatchBytes: maxBatchBytes)

        // Advance the local clock from the server's HLC (bounded merge). A
        // drifted server clock is not fatal to the pull itself.
        try? await deps.hlc.observe(response.serverHLC)

        // Phase 1 — observe every incoming row's HLC and partition into
        // apply/quarantine. NOTE: rows are later persisted with the INCOMING
        // HLC, never observe()'s clamped local view.
        var quarantineRows: [QuarantineRow] = []
        // Per (table, node): smallest quarantined HLC — the cursor must never
        // advance past it or the row would be skipped forever on retry.
        var quarantineFloor: [String: [Data: HLCStamped]] = [:]

        func vet(_ stamp: HLCStamped, table: String, rowPK: String, payload: Data) async -> Bool {
            do {
                _ = try await deps.hlc.observe(stamp)
                return true
            } catch {
                let reason: String
                if case HLC.HLCError.driftExceeded(let millis) = error {
                    reason = "drift_exceeded:\(millis)"
                } else {
                    reason = "invalid_remote:\(error)"
                }
                quarantineRows.append(QuarantineRow(
                    tableName: table,
                    rowPK: rowPK,
                    hlcPhysical: stamp.physical,
                    hlcLogical: stamp.logical,
                    nodeID: stamp.nodeID,
                    reason: reason,
                    payload: payload
                ))
                let current = quarantineFloor[table]?[stamp.nodeID]
                if current == nil || stamp < current! {
                    quarantineFloor[table, default: [:]][stamp.nodeID] = stamp
                }
                return false
            }
        }

        let encoder = JSONEncoder()

        var applySamples: [SampleRow] = []
        for row in response.samples {
            let stamp = HLCStamped(physical: row.hlcPhysical, logical: row.hlcLogical, nodeID: row.nodeID)
            let payload = (try? encoder.encode(row)) ?? Data()
            if await vet(stamp, table: "samples",
                         rowPK: "\(row.source)-\(row.type)-\(row.timestamp)", payload: payload) {
                applySamples.append(row)
            }
        }

        var applyTombstones: [SampleTombstoneRow] = []
        for row in response.sampleTombstones {
            let stamp = HLCStamped(physical: row.hlcPhysical, logical: row.hlcLogical, nodeID: row.nodeID)
            let payload = (try? encoder.encode(row)) ?? Data()
            if await vet(stamp, table: "sample_tombstones",
                         rowPK: "\(row.source)-\(row.type)-\(row.tsStart)", payload: payload) {
                applyTombstones.append(row)
            }
        }

        // CRUD delta entries: only tables known to the registry are applied.
        // Unregistered tables are deliberately ignored (with a warning) — see
        // the CRUD-materialization deferral note on this actor. The cursor
        // still advances past ignored entries so the pull doesn't stall.
        let registeredTables = Set(await registry.registered.map { $0.name })
        var applySyncLog: [SyncLogEntry] = []
        var ignoredSyncLog: [SyncLogEntry] = []
        for entry in response.syncLog {
            let stamp = HLCStamped(physical: entry.hlcPhysical, logical: entry.hlcLogical, nodeID: entry.nodeID)
            let payload = (try? encoder.encode(entry)) ?? Data()
            if await vet(stamp, table: "_sync_log",
                         rowPK: "\(entry.tableName)/\(entry.rowPK)", payload: payload) {
                if registeredTables.contains(entry.tableName) {
                    applySyncLog.append(entry)
                } else {
                    Log.sync.warning("Received syncLog entry for unregistered table \(entry.tableName); ignoring")
                    ignoredSyncLog.append(entry)
                }
            }
        }

        // Phase 2 — apply ALL rows in ONE writer transaction. Rows carry the
        // incoming remote HLC values verbatim.
        let samplesToInsert = applySamples
        let tombstonesToInsert = applyTombstones
        let syncLogToInsert = applySyncLog
        try await deps.database.writer { db in
            // HLC-guarded LWW upserts (NOT INSERT OR IGNORE): the samples PK
            // has no node_id, so two nodes can write the same tuple — an
            // incoming higher-HLC row must replace, and a lower one must lose.
            try SamplesStore.upsertHLCLatest(samplesToInsert, in: db)
            try SampleTombstonesStore.upsertHLCLatest(tombstonesToInsert, in: db)
            for entry in syncLogToInsert {
                // HLC-guarded upsert, same semantic as SyncLogStore.upsert.
                try db.execute(sql: """
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
                    """, arguments: [
                        entry.tableName, entry.rowPK, entry.hlcPhysical, entry.hlcLogical,
                        entry.nodeID, entry.operation.rawValue
                    ])
            }
        }

        // Phase 3 — persist quarantined rows (outside the batch transaction;
        // quarantine is diagnostic bookkeeping, not sync state).
        for row in quarantineRows {
            try await deps.quarantine.insert(row)
        }

        // Phase 4 — advance pull cursors from APPLIED rows only, capped below
        // any quarantined HLC for the same node, then persist to disk. The
        // server's next_cursor is intentionally not trusted here: it may jump
        // past quarantined rows.
        var newCursors = cursor
        func advance(_ syncCursor: inout SyncCursor, table: String, stamp: HLCStamped) {
            if let floor = quarantineFloor[table]?[stamp.nodeID], stamp >= floor {
                return
            }
            syncCursor.advance(nodeID: stamp.nodeID, physical: stamp.physical, logical: stamp.logical)
        }
        for row in applySamples {
            advance(&newCursors.samples, table: "samples",
                    stamp: HLCStamped(physical: row.hlcPhysical, logical: row.hlcLogical, nodeID: row.nodeID))
        }
        for row in applyTombstones {
            advance(&newCursors.sampleTombstones, table: "sample_tombstones",
                    stamp: HLCStamped(physical: row.hlcPhysical, logical: row.hlcLogical, nodeID: row.nodeID))
        }
        for entry in applySyncLog {
            advance(&newCursors.syncLog, table: "_sync_log",
                    stamp: HLCStamped(physical: entry.hlcPhysical, logical: entry.hlcLogical, nodeID: entry.nodeID))
        }
        for entry in ignoredSyncLog {
            // Deliberately-ignored entries still advance the cursor so the
            // pull can't stall on an unregistered table.
            advance(&newCursors.syncLog, table: "_sync_log",
                    stamp: HLCStamped(physical: entry.hlcPhysical, logical: entry.hlcLogical, nodeID: entry.nodeID))
        }

        pullCursors = newCursors
        try cursorStore.save(.init(pull: pullCursors, push: pushCursors))

        if !quarantineRows.isEmpty {
            Log.sync.warning("Pull quarantined \(quarantineRows.count) row(s) for HLC drift")
        }
        Log.sync.info("Pull applied samples=\(samplesToInsert.count) tombstones=\(tombstonesToInsert.count) syncLog=\(syncLogToInsert.count)")

        return PullCounts(
            samples: applySamples.count,
            tombstones: applyTombstones.count,
            syncLog: applySyncLog.count
        )
    }

    // MARK: - Push

    private struct PushCounts {
        let samples: Int
        let tombstones: Int
        let syncLog: Int

        static let zero = PushCounts(samples: 0, tombstones: 0, syncLog: 0)
    }

    private func runPush() async throws -> PushCounts {
        // Uploads pause while the local clock is suspect; pulls continue (§2.2).
        if await deps.clockSuspect.isSuspect {
            Log.sync.warning("Push skipped: clockSuspect is set")
            return .zero
        }

        let ourNode = await deps.hlc.currentLocal.nodeID

        let sw = pushCursors.samples.watermark(for: ourNode)
        let tw = pushCursors.sampleTombstones.watermark(for: ourNode)
        let lw = pushCursors.syncLog.watermark(for: ourNode)

        let samples = try await deps.samples.fetchForSync(
            nodeID: ourNode, afterHLC: sw.physical, lc: sw.logical, limit: pushBatchLimit)
        let tombstones = try await deps.tombstones.fetchForSync(
            nodeID: ourNode, afterHLC: tw.physical, lc: tw.logical, limit: pushBatchLimit)
        let syncLog = try await deps.syncLog.fetchForSync(
            nodeID: ourNode, afterHLC: lw.physical, lc: lw.logical, limit: pushBatchLimit)

        if samples.isEmpty && tombstones.isEmpty && syncLog.isEmpty {
            return .zero
        }

        let payload = SyncPushPayload(
            samples: samples,
            sampleTombstones: tombstones,
            syncLog: syncLog,
            clientHLC: await deps.hlc.now()
        )

        let response = try await deps.endpoint.push(payload: payload)
        try? await deps.hlc.observe(response.serverHLC)

        // Cursor advances ONLY here — on the server's ACK — and never past
        // what we actually sent: a misbehaving server must not be able to
        // make us skip unpushed local rows.
        func maxPushed<S: Sequence>(_ rows: S, stamp: (S.Element) -> HLCStamped) -> [Data: HLCStamped] {
            var out: [Data: HLCStamped] = [:]
            for row in rows {
                let s = stamp(row)
                if let existing = out[s.nodeID], existing >= s { continue }
                out[s.nodeID] = s
            }
            return out
        }
        func clampAck(_ ack: SyncCursor, prior: SyncCursor, pushedMax: [Data: HLCStamped], table: String) -> SyncCursor {
            var result = prior
            for node in ack.knownNodes {
                let w = ack.watermark(for: node)
                let ackStamp = HLCStamped(physical: w.physical, logical: w.logical, nodeID: node)
                guard let sentMax = pushedMax[node] else {
                    Log.sync.warning("Server ackCursor for \(table) covers a node we did not push; ignoring that node")
                    continue
                }
                if ackStamp > sentMax {
                    Log.sync.warning("Server ackCursor for \(table) exceeds pushed max; capping to sent maximum")
                    result.advance(nodeID: node, physical: sentMax.physical, logical: sentMax.logical)
                } else {
                    result.advance(nodeID: node, physical: w.physical, logical: w.logical)
                }
            }
            return result
        }

        var acked = TableCursors()
        acked.samples = clampAck(
            response.ackCursor.samples, prior: pushCursors.samples,
            pushedMax: maxPushed(samples) { HLCStamped(physical: $0.hlcPhysical, logical: $0.hlcLogical, nodeID: $0.nodeID) },
            table: "samples")
        acked.sampleTombstones = clampAck(
            response.ackCursor.sampleTombstones, prior: pushCursors.sampleTombstones,
            pushedMax: maxPushed(tombstones) { HLCStamped(physical: $0.hlcPhysical, logical: $0.hlcLogical, nodeID: $0.nodeID) },
            table: "sample_tombstones")
        acked.syncLog = clampAck(
            response.ackCursor.syncLog, prior: pushCursors.syncLog,
            pushedMax: maxPushed(syncLog) { HLCStamped(physical: $0.hlcPhysical, logical: $0.hlcLogical, nodeID: $0.nodeID) },
            table: "_sync_log")

        pushCursors = acked
        try cursorStore.save(.init(pull: pullCursors, push: pushCursors))

        Log.sync.info("Push ACKed samples=\(samples.count) tombstones=\(tombstones.count) syncLog=\(syncLog.count)")

        return PushCounts(samples: samples.count, tombstones: tombstones.count, syncLog: syncLog.count)
    }
}
