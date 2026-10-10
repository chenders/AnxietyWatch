# Design

## Context

Redesign v3 was negotiated over multiple review rounds and partially implemented across the shared package, both app targets, and the server. Merge commit `720609a` brought most package components and some app integration to `main`, but the now-archived `docs/plans/converted/redesign/redesign_status.md` stopped reflecting the tree: many tasks still appear unchecked even though their files and tests exist. Conversely, file existence was sometimes treated as shipment even when the runtime flag was unused or a legacy service still owned the production path.

This document preserves the material content of the superseded redesign specification and plan, reconciles the historical task record against the merged tree, and defines how to finish the migration. The capability contracts live in `openspec/specs/`; the deltas for remaining work live beside this document. Exact old wording remains recoverable in Git history after `docs/redesign_spec.md` is removed.

### Current architecture

```text
Targets
├── AnxietyWatch (iOS)
│   ├── active package sensor pipeline: Polar + EMAY + HealthKit
│   ├── package SyncEngine started during app bootstrap
│   └── legacy PhoneConnectivityManager activated afterward
├── AnxietyWatch Watch App (watchOS)
│   ├── active HealthKit-only SensorRouter and complication feed
│   ├── active legacy WatchConnectivityManager
│   └── package SyncEngine/WCSessionCoordinator intentionally not started
├── complication surfaces
│   └── cache writer exists; a dedicated read-only cache reader is absent
└── AnxietyWatchKit
    ├── Storage: GRDB schema, stores, compaction foundations
    ├── Sync: HLC, cursors, macro, coordinator, panic foundations
    ├── BLE: Polar, EMAY, HealthKit, optional Oura actors/router
    ├── Pipeline: deterministic state/event processing and coordinator
    ├── Transport: binary codec, WCSession coordinator, REST client
    ├── ViewModels: monitoring snapshots and complication cache writer
    └── Diagnostics: logging, signposts, diagnostics view, export engine
```

The package transport is not the effective iPhone connectivity owner after startup because `PhoneConnectivityManager.activate()` reassigns `WCSession.default.delegate`. On watchOS the source explicitly states that package transport has not started. The SQLite and delta-sync flags are defined but have no production decision-point readers. These facts make the migration incomplete even though much of its code is tested.

## Goals / Non-Goals

**Goals:**

- Preserve every material requirement, invariant, rollout gate, operational target, and historical implementation result from the superseded redesign documents.
- Establish one OpenSpec source of truth that distinguishes implementation, tests, app wiring, rollout, and production authority.
- Finish or explicitly retire each dormant foundation through independently reversible phases.
- Prevent loss during backfill, restore, corruption recovery, watch transfer, or server synchronization.
- Keep HealthKit ownership and the app's sync/restore round-trip rules intact.

**Non-Goals:**

- Enabling SQLite reads, binary watch transport, or delta sync as part of this documentation conversion.
- Replacing the newer app-level `Services/CNSRisk` engine or conflating it with the package pipeline.
- Routing CPAP imports, demo data, Oura Cloud summaries, or every optional Oura BLE path through the live package router.
- Removing legacy SwiftData, REST, or WatchConnectivity paths before replacement evidence exists.
- Treating the redesign as a CRDT or using the SQLite session extension.

## Decisions

### 1. Finish the staged migration instead of deleting the package foundations

The implemented surface is too broad and too integrated to call accidental: storage, clocks, cursors, macros, panic logic, actors, deterministic processing, codecs, watch background handling, diagnostics, server schema, and delta endpoints all have focused tests. Phase 1 compute and watch complication-feed pieces are already active. The safer choice is to finish in bounded phases, beginning with ownership and recovery gaps, rather than remove a large tested subsystem that active code already uses.

**Alternative considered:** retire all redesign code and return entirely to legacy services. Rejected because it would require unwinding active sensor and watch presentation paths while leaving the original high-frequency storage, concurrency, and restore risks unresolved.

### 2. Treat four statuses as independent

Each item reports:

1. **Implemented** — source exists.
2. **Tested** — focused automated evidence exists.
3. **Wired** — an app/server production path invokes it.
4. **Authoritative** — it owns the behavior after rollout and rollback validation.

A task is marked complete below only when its original deliverable exists and has focused tests. Integration shortfalls are separately marked partial; this preserves past work without overstating the rollout.

### 3. One WatchConnectivity owner per target

The replacement migration begins by inventorying every legacy delegate callback and moving them behind one coordinator/dispatcher. Starting two actors that both assign `WCSession.default.delegate` is not coexistence. The watch target cuts over only after legacy message coverage, activation, background delivery, reply handlers, user-info/file callbacks, and test doubles are represented.

**Alternative considered:** keep two coordinators and rely on activation order. Rejected because the last assignment wins and silently starves the other subsystem.

### 4. Storage cutover requires a recovery-complete backfill

High-frequency samples are not dual-written. A one-time idempotent backfill migrates batches of at most 5,000 rows and updates `_backfill_progress` in the same transaction. New high-frequency writes may switch only after parity. A rollback build must be able to recover SQLite-only rows back into the legacy store until the rollback window closes. Low-frequency data may dual-write for one minor version while SwiftData remains the read source.

**Alternative considered:** enable `storage.sqliteReadsEnabled` because the stores already pass tests. Rejected because no `SwiftDataBackfiller`, app read branch, or rollback exporter currently exists.

### 5. Delta sync remains dark until CRUD and restore are symmetrical

Time-series samples and tombstones bypass `_sync_log` and use per-table, per-node HLC cursors. Low-frequency tables use coalescing LWW change records. The existing coordinator explicitly defers CRUD materialization, so Phase 2C cannot be considered complete. Every uploaded table must have server persistence and a downloader/restore path; no cursor advances without an ACK.

**Alternative considered:** enable sample-only delta sync. Rejected because it would split backup authority, complicate recovery, and recreate the upload-without-restore defect class.

### 6. OpenSpec replaces the old redesign documents as authority

Canonical current behavior lives in `openspec/specs`. Remaining behavior changes live in `openspec/changes/complete-redesign-v3-migration`. The old monolithic spec was deleted after strict validation and coverage checks. `docs/plans/converted/redesign/redesign_plan.md` and `docs/plans/converted/redesign/redesign_status.md` are preserved as historical inputs only and are not authoritative.

## Preserved Technical Design

### Storage

- App-group database: `tsdb.sqlite`; file protection is complete until first user authentication and backup is excluded.
- System SQLite through GRDB with one `DatabaseQueue` writer.
- Open applies WAL, `synchronous=NORMAL`, `wal_autocheckpoint=1000`, foreign keys, busy handling, migrations, and integrity checks. An aborted checkpoint requires `RESTART` plus integrity verification.
- Background close runs a passive checkpoint and closes the handle; clean-shutdown state is recorded.
- Raw sample identity is `(source, type, timestamp)` in a strict `WITHOUT ROWID` table. Sample rows carry value, optional extra payload, physical/logical HLC, and 16-byte node identity. The HLC covering index is `(node_id, hlc_physical, hlc_logical)`.
- Gap tombstones carry source/type, start/end, HLC, node, dropped count, and one of `memory_panic`, `corruption`, `manual`, `retention`, or `unacked_overflow`. Tombstones have their own HLC covering index.
- One-minute rollups store a source/type/minute bucket, aggregate value, count, and HLC. Aggregation may be type specific.
- `_sync_log` is only for low-frequency CRUD. Its `(table_name,row_pk)` primary key deliberately coalesces intermediate operations; it is a delta cursor, not an audit log.
- Trigger HLC values must be minted once per row through the subquery-materialized UDF pattern. Storage/wire keeps flat HLC tuples; `HLCStamped` is for comparison.
- `_backfill_progress(source,type,last_ts)` advances in the same transaction as each backfill batch.
- Ordinary compaction deletes old rows in bounded batches and uses passive checkpoints. Idle downsampling begins after 60 seconds without subscribed-source frames. Truncating checkpoints require idle sensors, idle sync, a watch refresh task, and an aborted-checkpoint marker.
- Corruption recovery broadcasts recovery state, closes and replaces DB/WAL/SHM, preserves the Keychain node ID, recreates schema, and requests a full restore. Three corruption events in 24 hours stop automatic recovery until user opt-in.
- HealthKit-owned Apple Watch types do not become TSDB-only data. Debug-time insertion guards protect the boundary.

### HLC and synchronization

- Each install stores a distinct 16-byte raw UUID at Keychain service `com.anxietywatch.hlc.node`, account `install`, accessible after first unlock on this device only, non-synchronizable.
- HLC `now` uses the maximum of prior physical time, wall UTC milliseconds, and boot-anchored monotonic time; logical time increments when physical time does not.
- Observed remote time more than 60 seconds ahead is bounded locally while the incoming remote stamp is preserved on the row. More than 24 hours ahead is quarantined.
- Wall/monotonic divergence is sampled every 30 seconds. Five minutes beyond 60 seconds sets clock-suspect; 15 stable minutes clears it. Pulls continue, uploads pause, and cross-device fusion is suppressed while set.
- Cursors are maps from node to `(physical,logical)` for samples, tombstones, and sync-log rows. Pagination performs indexed seeks per bounded node set and merges results by HLC.
- `@Syncable` defaults to bidirectional, supports explicit up-only/down-only directions, rejects missing codecs and unsupported nested fields, and emits registry plus trigger data. A negative compile fixture protects the missing-downloader regression.
- Panic states: ordinary acknowledged-row eviction starts at 200 MB; 225 MB triggers a 30-second urgent push; 250 MB after failure permits acknowledged eviction with tombstones; unacknowledged eviction uses the last-resort protocol.
- Last-resort overflow requires prior ordinary eviction, failed urgent push, synchronous one-minute downsampling, and a 60-minute per-source/type quiet period. Each event covers at most six hours, inserts its tombstone and deletes rows atomically, retains rollups, shows an immediate banner, and emits both event and repeated-chunk metrics.
- `/sync/pull` and `/sync/push` exchange versioned per-table cursors, rows, acknowledgments, and server HLC. Cursor format v2 mismatch returns 409 and falls back. Server tombstone persistence and peer propagation remain a hard gate.

### Sensors and CNS processing

- Each hardware source owns a FIFO `AsyncStream` with newest-1,000 buffering, fed from its serial delegate queue and consumed by an actor.
- `SensorRouter` fans in supported sources, defines idle as no subscribed-source frame for at least 60 seconds, and exposes approximately 10 Hz presentation snapshots.
- HealthKit uses anchored queries with persisted anchors; empty batches emit nothing. Pipeline ring timestamps detect staleness, including off-wrist behavior.
- SwiftUI reads synchronous `@MainActor @Observable` state and never performs awaited hardware reads in `body`.
- The package pipeline is state-plus-event to state-plus-commands with all time injected. Its state contains bounded 60-second rings and remains small. No `Date()`, `DispatchTime.now()`, sleeping, notification centers, or singletons belong in the pure step.
- The coordinator is the only package side-effect interpreter for notifications, haptics, and watch messages.
- Data gaps reset affected ring coverage and set the last-gap marker. A gap alone does not raise a clinical alarm; an informational notice is allowed only for gaps over five minutes. The branch remains behind `pipeline.gapEventsEnabled` until authoritative storage emits gaps.

### Phone-watch transport

- Binary sample frames are versioned and length-prefixed. They preserve source, type, timestamp, value, extra data, HLC, node identity, and tombstone fields. Compression uses Apple platform facilities with zlib-compatible framing.
- Application context carries latest status/settings and urgent-sync hints. Critical alerts try reachable `sendMessage` and fall back to FIFO `transferUserInfo`. Historical data uses disk-backed `transferFile` and receiver-side natural-key deduplication.
- Successful transfer deletes temporary files. Failure backs off from 15 minutes to four hours with ±20% jitter; a satisfied path may retry immediately. No file or cursor is discarded before acknowledgment.
- After six consecutive sync failures the watch sends a lightweight `requires_urgent_sync` hint so the phone can pull.

### Watch runtime and complications

- A watch application refresh budgets at most 500 ms for SQLite and at most 500 ms for scheduling plus enqueueing, leaving slack under the operating-system limit.
- Long uploads use `URLSessionConfiguration.background` and are never awaited inside the refresh task. Later delegate callbacks finalize acknowledgment.
- The complication extension never opens the TSDB. The watch app writes denormalized state into the app-group container.
- The cache writer holds the newest pending state, uses a single 500 ms trailing-edge timer, writes a temporary property list, and atomically replaces the destination. All relevant targets need the app-group entitlement.

### Observability and release gates

- One `com.anxietywatch.kit` subsystem uses stable categories for storage, sync, HLC, BLE/HealthKit, pipeline, transport/WC, panic, migration, diagnostics, and complications.
- Signposts cover BLE parsing, sync pull/push, refresh tasks, transfer files, and SQLite write batches.
- Diagnostics should show DB/WAL size, rollup coverage, clock state, recent gaps, quarantine ordered by trusted capture time, last/next sync, flags, overflow state, and recent fault counts.
- Required suites include pipeline properties, HLC axioms/drift, panic gating, macro negative fixtures, interrupted migration, WC routing, and sustained memory.
- Pre-merge gates include all suites, less than 15 MB over baseline under ten simulated minutes at 200 Hz, corruption recovery, and ±90-second clock manipulation without causal poisoning.
- TestFlight gates include P95 watch memory below 50 MB across Series 6–9 and Ultra 1–2, battery drain below 5% per hour, and overflow below 0.1% of daily active users.
- Delta enablement requires two weeks of shadow service, 30 days with zero cursor divergence, tombstone round trips, P95 pull latency below two seconds, and legacy REST retained until 99% flag-on adoption for 30 days.

## Historical Implementation Ledger

Status is reconciled to the current tree. “Done” means the original component and focused tests exist; “partial” identifies a missing part of the original deliverable or its required integration.

| ID | Reconciled status | Evidence and remaining boundary |
|---|---|---|
| T01 | Done | `AnxietyWatchKit/Package.swift` and package sources exist; Xcode integration later landed in `720609a`. |
| T02 | Done | `Diagnostics/Logger.swift`, `Signpost.swift`, and diagnostics tests. Single-subsystem convention retained. |
| T03 | Done | `Storage/DatabaseManager.swift` and tests. |
| T04 | Done | `Storage/Schema/SchemaV1.swift` and schema tests. |
| T05 | Done | `Storage/SamplesStore.swift` and tests. |
| T06 | Done | `Storage/SyncLogStore.swift` and tests; backwards HLC writes intentionally no-op. |
| T06a | Done | `Sync/HLCStamped.swift`; node identity is exactly 16 bytes. |
| T06b | Done | Database HLC UDF registration; generated triggers use one stamp per row. |
| T06c | Done | `Storage/SampleTombstonesStore.swift`; tombstone GC remains part of lifecycle work. |
| T06d | Done | `Diagnostics/CorruptionBroadcaster.swift`; end-to-end recovery remains T12 partial. |
| T07 | Done | `Storage/BackfillProgressStore.swift` and interruption-oriented store tests. |
| T08 | Done | `Storage/QuarantineStore.swift` and tests; trusted local capture time is retained. |
| T09 | Done | `Storage/Compaction/RetentionCompactor.swift` and tests. |
| T10 | Done | `Storage/Compaction/IdleDownsampler.swift` and tests; multi-node rollup collision was corrected. |
| T11 | Done | `Storage/Compaction/CheckpointManager.swift` and tests; restart uses non-transactional checkpoint calls. |
| T12 | Partial | Corruption classification and broadcast exist; replacement, user-visible recovery, circuit breaker, and full restore are not an end-to-end app flow. |
| T13 | Done | `Sync/HLC.swift` and HLC tests include frozen-clock and drift branches. |
| T14 | Done | `Sync/ClockSuspectGate.swift` and tests. Production upload/fusion call-site enforcement still belongs to rollout. |
| T15 | Done | `Sync/SyncCursor.swift` and snake-case wire-key regression tests. |
| T16 | Done | `Syncable` macro, registry, generated trigger support, integration tests, and negative macro fixtures. |
| T17 | Partial | `Sync/SyncCoordinator.swift` handles time-series/tombstone flows; comments defer low-frequency CRUD materialization and periodic scheduling. |
| T18 | Done | `Sync/PanicProtocol.swift` and tests. Production storage orchestration remains gated. |
| T19 | Done | `Sync/UnackedOverflow.swift` and tests. Fleet diagnostics/metrics remain incomplete. |
| T20 | Done | `BLE/PolarActor.swift` and tests; iPhone router wiring exists. |
| T21 | Done | `BLE/EMAYActor.swift` and tests; iPhone router wiring exists. |
| T22 | Done | `BLE/HealthKitAdapterActor.swift` and tests; iPhone and watch integrations exist. |
| T23 | Done | `BLE/SensorRouter.swift`, throttle tests, and app integrations. Optional Oura paths remain separately gated. |
| T24 | Done | `Pipeline/PipelineState.swift`, `PipelineStep.swift`, ring buffer, and deterministic tests. |
| T25 | Done | Package `Pipeline/CNSFusionEngine.swift` and tests. It is distinct from app-level `Services/CNSRisk/CNSFusionEngine.swift`. |
| T26 | Done | Package `Pipeline/CNSAlertTierMachine.swift` and tests. |
| T27 | Done | `Pipeline/CNSMonitoringCoordinator.swift` and tests; package side-effect scope must remain distinct from app CNSRisk. |
| T28 | Done | `Transport/BinaryCodec.swift`, message codec, and tests. |
| T29 | Partial | `Transport/WCSessionCoordinator.swift` and tests exist, but legacy delegates remain authoritative and watch cutover is incomplete. |
| T30 | Done | `Sync/RESTClient.swift` and endpoint types/tests through coordinator coverage. |
| T31 | Done | `ViewModels/ComplicationCacheWriter.swift`, tests, and active watch complication-feed submissions. |
| T32 | Partial | Watch `AnxietyWatchApp.swift` handles refresh tasks, but explicitly does not start package sync/transport; background URL-session completion remains incomplete. |
| T33 | Not implemented | No dedicated complication-extension `ComplicationCacheReader` or focused reader tests were found. |
| T34 | Partial | `Feature.swift` defines four flags; gap and binary branches are consumed, while SQLite-read and delta flags are definitions only. Remote config, flip logging, and diagnostics display are incomplete. |
| T35 | Not implemented | No `SwiftDataBackfiller.swift`, app cutover loop, parity gate, or rollback exporter was found. |
| T36 | Partial | `Diagnostics/DiagnosticsView.swift` and tests exist; confirmed Settings navigation and all live data providers are incomplete. |
| T37 | Partial | `Diagnostics/ExportLogs.swift` and tests exist, but the planned `MetricKitReporter` and confirmed production export call site are absent. |
| T38 | Partial | iOS `KitPipelineService` and watch HealthKit-only router are active; rollout is not behind a full Phase-1 control and package watch transport remains incomplete. |
| T39 | Partial | Package suites are broad, but no current 85% coverage report, real-device memory suite, or complete cross-target migration suite proves the original gate. |
| T40 | Partial | Architecture/review documentation exists and this OpenSpec conversion improves it; subsystem ADRs and final post-implementation notes remain unfinished. |

### Preserved historical commits and reviews

- T01 `74a24cb`; T02 `69293aa`; T03/T04 `43569c5`; T05/T06 `7cd5026`; T06a/b/d `582d612`; T06c `0a6aa85`; T14 `d11b98b`; T15 follow-up `f68dbbd`; combined integration `720609a`.
- The original workflow used author, primary reviewer, and quick-check passes, with a build/test after each task and combined reviews every five tasks.
- The T05 checkpoint identified missing HLC support, UDF registration, tombstone storage, and corruption fan-out; T06a–T06d closed those foundations.
- The T10 checkpoint passed 77 tests and assigned compaction ordering to later orchestration: retention, downsample, then truncating checkpoint; panic ordering is downsample, evict, then tombstone in one transaction.
- The T15 checkpoint passed 108 tests and ratified flat HLC tuples at storage/wire with `HLCStamped` only for comparison. It also required preserving incoming remote HLC values and the subquery-materialized HLC trigger pattern.
- Historical task-state checkboxes after T06d were not updated consistently and are superseded by the reconciled ledger above.

## Migration Plan

### Documentation conversion — current change stage

1. Bootstrap canonical current specs and configure project rules.
2. Record the reconciled implementation ledger and target deltas.
3. Strictly validate all OpenSpec artifacts and run a terminology/coverage comparison against the old specification.
4. Delete `docs/redesign_spec.md` only after steps 1–3 pass.
5. Pause for user review before generating `tasks.md`; the task plan must reflect any corrections to this conversion.

### Implementation order after approval

1. **Ownership and recovery prerequisites:** one WCSession owner design, corruption recovery completion, restore table inventory, and exact active-path tests.
2. **Phase 2A storage:** implement backfill/rollback exporter, parity telemetry, app write/read decision points, compaction lifecycle, fresh-install and device-loss tests. Enable only through a real consumed flag.
3. **Phase 2B transport:** migrate every delegate callback on iPhone and watch, add version/fallback/ACK tests, then canary binary transport independently.
4. **Phase 2C sync:** materialize low-frequency CRUD, prove every upload has a restore path, add scheduling and background continuation, then shadow-compare server behavior.
5. **Diagnostics and release evidence:** wire Settings/export, MetricKit, signposts, memory/battery/latency baselines, and operational dashboards before broad rollout.
6. **Legacy retirement:** remove each legacy path only after the corresponding phase meets its stated adoption and stability criteria.

### Rollback

- Phase 1 can return to legacy compute without touching persisted storage.
- Phase 2A routes reads back to SwiftData and copies any SQLite-only high-frequency rows back during the rollback window.
- Phase 2B returns to legacy JSON without changing storage.
- Phase 2C returns to legacy REST while retaining unacknowledged local changes and already-validated storage/transport.
- No rollback deletes HealthKit-authoritative data or advances a cursor without acknowledgment.

## Risks / Trade-offs

- **Two CNS implementations can be mistaken for one** → keep package and app-level CNSRisk diagrams, tests, and ownership separate.
- **Dormant flags create false confidence** → require an exact production reader and two-value test before calling any flag a rollback control.
- **WCSession activation order silently changes ownership** → assert one delegate owner and migrate callbacks before replacement startup.
- **Backfill runs once and can rot** → test from a genuinely fresh install, at mid-batch termination, and after a bundle/store reset.
- **Upload-only backup illusion** → audit every payload table against server persistence and restore importer before enablement.
- **Server endpoint existence can be mistaken for readiness** → retain shadow, divergence, tombstone, latency, and adoption gates.
- **Historical implementation notes could be lost when old docs are removed** → keep this ledger plus Git history and do not delete the remaining plan/status inputs until review.
- **OpenSpec project initialization left stale global prompts** → project-local generated skills and prompts are valid; global cleanup is optional and outside repository scope.

## Resolved Planning Decisions

- The operator of the self-hosted server owns Phase 2C SLO and shadow-compare evidence. The repository supplies privacy-safe aggregate logs, tests, and diagnostics; it does not assume an external fleet dashboard.
- No third-party remote-config dependency will be added. An injectable feature provider supplies bundled safe defaults and local/test overrides; TestFlight or build cohorts control rollout until a separate self-hosted control is justified.
- The app-level `Services/CNSRisk` engine remains authoritative for clinical alert decisions. The package pipeline supplies monitoring and presentation state and must not duplicate notifications, haptics, or watch messages.
- `AnxietyWatchWidgets` owns the read-only complication cache reader because it is the existing extension target. The reader never opens the time-series database.
- An iOS 26 `#Predicate` radar may be linked as background but is not a design dependency or justification for the TSDB.

## Legacy Specification Traceability

| Superseded section | Canonical destination |
|---|---|
| 0 Module Map | Current architecture and Historical Implementation Ledger in this design |
| 1.1 Files and DB open sequence | `time-series-storage` current spec; Preserved Technical Design / Storage |
| 1.2 Samples, tombstones, and rollup DDL | `time-series-storage`; Preserved Technical Design / Storage |
| 1.3 Low-frequency sync log and triggers | `causal-sync`; Preserved Technical Design / Storage and HLC and synchronization |
| 1.4 Backfill progress | `time-series-storage`; storage delta / Idempotent legacy backfill |
| 1.5 Compaction and downsampling | `time-series-storage`; storage delta / Production compaction orchestration |
| 1.6 Corruption recovery | `time-series-storage`; storage delta / Complete corruption restoration |
| 1.7 HealthKit boundaries | `sensor-processing` and `time-series-storage` current specs |
| 2.1 HLC service | `causal-sync`; Preserved Technical Design / HLC and synchronization |
| 2.2 Clock-suspect gate | `causal-sync` current spec |
| 2.3 Cursor and pagination | `causal-sync` current spec and technical design |
| 2.4 Syncable macro | `causal-sync` current spec and T16 ledger entry |
| 2.5 Panic protocol | `causal-sync` current spec and technical design |
| 2.6 Unacknowledged overflow | `causal-sync` current spec and technical design |
| 2.7 Server contract | `causal-sync` current and delta specs |
| 3 BLE actors, router, HealthKit, UI observation | `sensor-processing` current spec and technical design |
| 4 CNS pipeline, coordinator, data gaps | `sensor-processing` current and delta specs |
| 5 Binary codec, WC routing, transfer resilience, retry | `watch-connectivity`, `watch-runtime`, and their deltas |
| 6 Watch background budget and complication cache | `watch-runtime` current and delta specs |
| 7 Migration phases, cutover, flags, shadow mode | `migration-rollout` current and delta specs; Migration Plan |
| 8 Tests, metrics, signposts, diagnostics | `diagnostics-operations` current and delta specs |
| 9 Acceptance and release gates | `diagnostics-operations`, `migration-rollout`, and technical design |
| 10 Open items | Open Questions and Phase 2C causal-sync delta |
