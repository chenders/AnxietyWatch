# AnxietyWatch Redesign — Implementation Specification

**Source:** `/Users/chris/redesign_the_app.md` (v3, negotiated across four rounds).
**Audience:** engineers implementing the redesign.
**Scope:** module boundaries, data schemas, interfaces, sequence flows, invariants, and acceptance tests. This spec is prescriptive; when it disagrees with the plan, the plan wins.

---

## 0. Module Map

```
Targets
├── AnxietyWatch (iOS)
├── AnxietyWatch Watch App (watchOS)
├── AnxietyWatch Complication Extension (watchOS)
└── AnxietyWatchKit (shared framework, iOS + watchOS)
    ├── Storage/              §1
    │   ├── DatabaseManager       (open/close, corruption circuit breaker)
    │   ├── SamplesStore          (samples + sample_tombstones)
    │   ├── SyncLogStore          (_sync_log for CRUD tables)
    │   ├── BackfillProgressStore (_backfill_progress)
    │   ├── QuarantineStore       (_sync_quarantine)
    │   └── Compaction/           (retention, downsample, wal_checkpoint)
    ├── Sync/                 §2
    │   ├── HLC                   (clock, node_id, drift guard)
    │   ├── ClockSuspectGate      (upload pause + fusion suppression)
    │   ├── SyncCursor            (per-table {node_id: (pt, lc)} map)
    │   ├── SyncCoordinator       (pull, push, ACK, retry)
    │   ├── PanicProtocol         (225/250 MB + unacked_overflow)
    │   └── SyncableMacro/        (compile-time @Syncable + SyncRegistry)
    ├── BLE/                  §3
    │   ├── PolarActor            (per-device background actor)
    │   ├── EMAYActor
    │   ├── HealthKitAdapterActor (HKAnchoredObjectQuery → AsyncStream)
    │   └── SensorRouter          (fan-in, backpressure policy)
    ├── Pipeline/             §4
    │   ├── CNSDetectionPipeline  (pure (State, Sample) → (State, [Cmd]))
    │   ├── CNSFusionEngine
    │   ├── CNSAlertTierMachine
    │   └── CNSMonitoringCoordinator (side-effect boundary)
    ├── Transport/            §5
    │   ├── WCSessionCoordinator
    │   ├── BinaryCodec           (packed rows, Apple Compression)
    │   └── RESTClient            (legacy + delta-sync)
    ├── ViewModels/           (@MainActor @Observable)
    └── Diagnostics/          (OSLog, MetricKit, signposts)

Extension:
    ComplicationCacheReader        (App Group plist reader; NO DB access)
```

---

## 1. Storage Layer

### 1.1 Files and DB open sequence

- **DB path:** App Group container `group.<team>.com.anxietywatch/tsdb.sqlite`
- **File attributes:** `NSFileProtectionCompleteUntilFirstUserAuthentication`, `NSURLIsExcludedFromBackupKey = true`
- **Engine:** system SQLite via GRDB. Single writer via `DatabaseQueue`.
- **PRAGMAs** (applied every open, in order):
  ```
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA wal_autocheckpoint = 1000;
  PRAGMA foreign_keys = ON;
  ```
- **Open flow:**
  1. `sqlite3_open_v2(path, ..., SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)`.
  2. If open returns `SQLITE_CORRUPT` or subsequent `PRAGMA integrity_check` fails → invoke `DatabaseManager.recoverFromCorruption()` (§1.6).
  3. If last shutdown had an aborted checkpoint marker set (see §1.5), run `PRAGMA wal_checkpoint(RESTART)` and re-verify `integrity_check` before accepting writes.
- **Close flow:** on `WKExtensionDelegate.applicationWillResignActive` (watchOS) or `UIApplicationDelegate.applicationDidEnterBackground` (iOS):
  1. `PRAGMA wal_checkpoint(PASSIVE)`.
  2. `sqlite3_close_v2()` (accepts unfinalized statements gracefully).
  3. Set `LastCleanShutdown` UserDefaults flag.

### 1.2 Schema DDL (samples + tombstones)

```sql
CREATE TABLE samples (
  source        INTEGER NOT NULL,        -- 0=EMAY, 1=Polar, 2=AppleWatch, 3=Derived, ...
  type          INTEGER NOT NULL,        -- HR=1, SpO2=2, Accel=3, HRV=4, ...
  timestamp     REAL    NOT NULL,        -- CFAbsoluteTime seconds
  value         REAL    NOT NULL,
  extra         BLOB,                    -- optional per-type payload (FFT bins, spectrogram, etc.)
  hlc_physical  INTEGER NOT NULL,        -- ms since Unix epoch
  hlc_logical   INTEGER NOT NULL,        -- monotonically increasing per node
  node_id       BLOB    NOT NULL,        -- 16-byte UUID
  PRIMARY KEY (source, type, timestamp)
) WITHOUT ROWID, STRICT;

CREATE INDEX idx_samples_hlc
  ON samples(node_id, hlc_physical, hlc_logical);

CREATE TABLE sample_tombstones (
  source            INTEGER NOT NULL,
  type              INTEGER NOT NULL,
  ts_start          REAL    NOT NULL,
  ts_end            REAL    NOT NULL,
  hlc_physical      INTEGER NOT NULL,
  hlc_logical       INTEGER NOT NULL,
  node_id           BLOB    NOT NULL,
  dropped_row_count INTEGER NOT NULL,
  reason            TEXT    NOT NULL     -- 'memory_panic'|'corruption'|'manual'|'retention'|'unacked_overflow'
    CHECK (reason IN ('memory_panic','corruption','manual','retention','unacked_overflow')),
  PRIMARY KEY (source, type, ts_start, hlc_physical, hlc_logical, node_id)
) WITHOUT ROWID, STRICT;

CREATE INDEX idx_sample_tombstones_hlc
  ON sample_tombstones(node_id, hlc_physical, hlc_logical);
```

**Downsampled rollups:** stored in a sibling table `samples_1min` with identical shape but `timestamp` snapped to the enclosing minute, and `value` = window mean (or type-specific aggregator).

```sql
CREATE TABLE samples_1min (
  source INTEGER NOT NULL, type INTEGER NOT NULL, minute_bucket INTEGER NOT NULL,
  value REAL NOT NULL, sample_count INTEGER NOT NULL,
  hlc_physical INTEGER NOT NULL, hlc_logical INTEGER NOT NULL, node_id BLOB NOT NULL,
  PRIMARY KEY (source, type, minute_bucket)
) WITHOUT ROWID, STRICT;
CREATE INDEX idx_samples_1min_hlc ON samples_1min(node_id, hlc_physical, hlc_logical);
```

### 1.3 Sync log (low-frequency CRUD only)

```sql
CREATE TABLE _sync_log (
  table_name    TEXT    NOT NULL,
  row_pk        TEXT    NOT NULL,
  hlc_physical  INTEGER NOT NULL,
  hlc_logical   INTEGER NOT NULL,
  node_id       BLOB    NOT NULL,
  operation     TEXT    NOT NULL CHECK (operation IN ('upsert','delete')),
  PRIMARY KEY (table_name, row_pk)
) WITHOUT ROWID, STRICT;
```

**Coalescing invariant (developer docs):** PK is `(table_name, row_pk)` — only the latest op per row is retained. Intermediate updates between ACKs are silently coalesced. Do not rely on the log to reconstruct history; it is a delta cursor, not an audit trail.

**Trigger generation:** `@Syncable` macro emits three triggers per table:

```sql
CREATE TRIGGER trg_<table>_ins AFTER INSERT ON <table> BEGIN
  INSERT INTO _sync_log(table_name, row_pk, hlc_physical, hlc_logical, node_id, operation)
    VALUES ('<table>', NEW.<pk>, hlc_now_pt(), hlc_now_lc(), hlc_now_node(), 'upsert')
    ON CONFLICT(table_name, row_pk) DO UPDATE SET
      hlc_physical = excluded.hlc_physical,
      hlc_logical  = excluded.hlc_logical,
      node_id      = excluded.node_id,
      operation    = 'upsert';
END;
-- analogous AFTER UPDATE and AFTER DELETE
```

`hlc_now_pt()`, `hlc_now_lc()`, `hlc_now_node()` are SQLite user-defined functions registered by `DatabaseManager` at open. They read from the process-wide `HLC` service (§2.1).

### 1.4 Backfill progress

```sql
CREATE TABLE _backfill_progress (
  source  INTEGER NOT NULL,
  type    INTEGER NOT NULL,
  last_ts REAL    NOT NULL,
  PRIMARY KEY (source, type)
) WITHOUT ROWID, STRICT;
```

Written in the same transaction as each backfill batch. On resume, backfill reads `last_ts` per (source, type) and continues.

### 1.5 Compaction and downsampling

Compaction runs in two contexts:

1. **Ordinary (retention & PASSIVE checkpoint):**
   - Trigger: daily background schedule + `wal_autocheckpoint` safety net.
   - Steps: `DELETE FROM samples WHERE timestamp < now - 7*86400 LIMIT 5000` in a loop, yielding between batches. `wal_checkpoint(PASSIVE)` interleaved.
2. **Idle-time downsampling:**
   - Trigger: `SensorRouter.idleSince(> 60s)` observed by a background `Task`.
   - Steps: aggregate raw `samples` into `samples_1min` for buckets that have no rollup yet, one (source, type) at a time.
3. **TRUNCATE checkpoint:**
   - Trigger: inside a `WKApplicationRefreshBackgroundTask` when `SensorRouter.isIdle && !SyncCoordinator.isBusy`.
   - Steps: `PRAGMA wal_checkpoint(TRUNCATE)`. Aborted-checkpoint marker written pre-call, cleared post-call.

### 1.6 Corruption recovery

`DatabaseManager.recoverFromCorruption()`:

```
1. Post CorruptionDetected notification (UI → "Recovering…" state).
2. Close DB.
3. Delete tsdb.sqlite, tsdb.sqlite-wal, tsdb.sqlite-shm.
4. Re-open (fresh schema).
5. DO NOT touch Keychain node_id.
6. Kick SyncCoordinator.fullRestore() which pulls from server using the
   preserved node_id + reset cursor {}.
7. Once restore >0%, dismiss "Recovering…" UI.
```

Circuit breaker: 3 corruption events in 24 h → surface diagnostics red banner + block auto-recovery until user opts in (prevents corruption/restore thrash from burning battery).

### 1.7 HealthKit boundaries

The `samples` table **must not** contain rows for types HK owns on Apple Watch (HR, HRV, resting HR, VO2max, respiratory rate). Compile-time enforcement: `SamplesStore.insert(source:type:...)` traps in debug when `(source, type)` matches the HK-owned list.

---

## 2. Sync Layer

### 2.1 HLC service

```swift
public struct HLCTimestamp: Hashable, Comparable {
  public let physical: Int64   // ms since Unix epoch
  public let logical:  Int32
  public let nodeID:   Data    // 16 bytes
}

public actor HLC {
  public func now() -> HLCTimestamp
  public func observe(_ remote: HLCTimestamp) throws -> HLCTimestamp  // bounded merge
  public var clockSuspect: Bool { get }
}
```

**Node ID:**
- Loaded on first launch from Keychain under service `com.anxietywatch.hlc.node`, account `install`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false`.
- If absent, generated as **16 raw bytes** via `withUnsafeBytes(of: UUID().uuid) { Data($0) }` (NOT the 36-byte `uuidString`) and stored. This width is canonical across `SchemaV1.samples.node_id`, `HLCStamped.nodeID`, and the §5.1 binary wire format.
- iPhone and Watch each execute this independently and produce distinct node IDs by construction.

**`now()`:**
```
pt_wall = current UTC ms
pt = max(local.pt, pt_wall, boot_anchored_monotonic_ms)
if pt == local.pt: lc = local.lc + 1
else:              lc = 0
local = (pt, lc)
return (pt, lc, node_id)
```

**`observe(remote)`:**
```
if remote.pt - local_wall > 60_000:
    return bounded_merge(remote, cap: local_wall + 60_000)
if remote.pt - local_wall > 86_400_000:
    quarantine(remote); throw HLCError.driftExceeded
merge as normal
```

**Bounded merge:** the returned HLC never advances `local.pt` past `local_wall + 60_000`, but the event is causally ordered via `logical` and persisted with the *incoming* HLC values (so peer causal history isn't corrupted).

### 2.2 Clock-suspect gate

`ClockSuspectGate` observes wall-vs-monotonic divergence continuously:

- Sample every 30 s.
- If |wall − boot_anchored_monotonic| > 60 s for 5 consecutive minutes → set `clockSuspect = true`.
- If back within bounds for 15 continuous minutes → clear.
- Every set/clear emits an OSLog fault `com.anxietywatch.sync.clock_suspect` and a MetricKit custom metric.

**Effects while set:**
- `SyncCoordinator.pushEnabled = false` (uploads paused; **pulls continue**).
- `CNSFusionEngine.crossDeviceFusionEnabled = false` (single-device fusion still runs).
- ViewModel exposes a `clockSuspect` badge for the diagnostics screen.

### 2.3 Sync cursor and pagination

**Cursor type:**
```swift
public struct SyncCursor: Codable {
  // Per node_id → (physical, logical). Missing node_id means "from beginning".
  public var perNode: [Data: (physical: Int64, logical: Int32)]
}
public struct TableCursors: Codable {
  public var samples:           SyncCursor
  public var sample_tombstones: SyncCursor
  public var _sync_log:         SyncCursor   // covers all CRUD tables
}
```

**Pagination (per node, per table):**

```sql
-- samples
SELECT source, type, timestamp, value, extra, hlc_physical, hlc_logical, node_id
  FROM samples
 WHERE node_id = :node
   AND (hlc_physical, hlc_logical) > (:pt, :lc)
 ORDER BY hlc_physical, hlc_logical
 LIMIT :batch;

-- sample_tombstones (same pattern)
SELECT ... FROM sample_tombstones
 WHERE node_id = :node AND (hlc_physical, hlc_logical) > (:pt, :lc)
 ORDER BY hlc_physical, hlc_logical LIMIT :batch;
```

Then the coordinator issues these queries per `node_id` in `cursor.perNode`, plus one bootstrapping query for any node observed in server responses but absent from the local cursor. Results merged in memory by HLC ascending.

**Push payload** = union of samples + sample_tombstones for the batch window (`UNION ALL` when materialized; distinct arrays when framed to the wire codec).

**N (node count) is bounded ~2–5 per user** (Watch, iPhone, possibly a household member's device). O(N) indexed seeks per sync is intentional and cheap.

### 2.4 @Syncable macro

**Attribute:**
```swift
@Syncable                          // implicit .bidirectional
@Syncable(direction: .upOnly)      // legacy, upload-only
@Syncable(direction: .downOnly)    // e.g. server-owned lookup tables
```

**Compile-time checks (macro-emitted diagnostics):**
- Bidirectional table missing `init(fromSync:)` → error.
- Bidirectional table missing `encodeForSync()` → error.
- Any stored property not tagged `@SyncableIgnore` and not conforming to `SyncCodable` → error.
- Nested `@Syncable` types → error (flatten at schema layer).

**Macro output per type:**
- `SyncRegistry.register(<Type>.self, direction: ..., encoder: ..., decoder: ...)` in a generated `SyncRegistry+<Type>.swift` file, collected at `SyncCoordinator.bootstrap()` time.
- SQLite trigger DDL emitted as a static `Self.syncTriggerDDL: String` for `DatabaseManager` to apply on migrate.

**Test:** a compile-fixture package must include a bidirectional table with no `init(fromSync:)` and assert a diagnostic — this is the EMAY-loss regression guard.

### 2.5 Panic protocol

State machine transitions triggered by post-write DB size check:

| State | Trigger | Action |
|-------|---------|--------|
| Normal | size ≥ 200 MB | Attempt ordinary LRU eviction of ACKed rows only. |
| Yellow | size ≥ 225 MB | Fire `SyncCoordinator.urgentPush(timeout: 30s)`. Continue accepting writes. |
| Red | size ≥ 250 MB *after* Yellow attempt failed | Emit `data_gap(reason: memory_panic)` per (source, type) covering the oldest ACKed range still present; evict; log `sync.memory_panic.fired`. |
| Overflow | size ≥ 250 MB *AND* all four preconditions met (§2.6) | Trigger `unacked_overflow` protocol (§2.6). |

**Un-ACKed row protection:** ordinary LRU eviction MUST NOT delete rows with `(hlc_physical, hlc_logical) > per-node ackedCursor`. Only the overflow path may.

### 2.6 unacked_overflow protocol (LAST RESORT)

All preconditions must hold:

1. `dbSize >= 250 MB` after ordinary eviction to 200 MB has already run.
2. Yellow-state urgent push failed or timed out (30 s).
3. Raw un-ACKed samples for the target (source, type) already downsampled to `samples_1min`. If not, downsample **synchronously** now.
4. No prior `unacked_overflow` for the same (source, type) in the last 60 min.

Action:
1. Select oldest un-ACKed raw samples for one (source, type) at a time, up to 6 hours of wall-clock coverage per event.
2. Compute `data_gap` row: `ts_start = min(ts)`, `ts_end = max(ts)`, `dropped_row_count = count`, `hlc_* = HLC.now()`, `reason = 'unacked_overflow'`.
3. In one transaction: insert tombstone into `sample_tombstones`, delete the raw rows, keep `samples_1min` rows untouched.
4. Post `DiagnosticsBanner.unackedOverflow(source, type, ts_start, ts_end)` (immediate, not gated on 24 h / >1 threshold).
5. Emit metric `sync.unacked_overflow.fired`. If two chunks fire within a rolling 4 h window, emit `sync.unacked_overflow.chunked_burst` (severity indicator).

If more than 6 hours of raw samples still un-ACKed after the event, wait until the next 60-minute hysteresis window and repeat with a fresh tombstone. Never fold >6 h of loss into one tombstone.

### 2.7 Server contract (Phase 2C)

```
POST /sync/pull
  Body: { cursor_format_version: int,
          table_cursors: { samples: SyncCursor, sample_tombstones: SyncCursor,
                           sync_log: SyncCursor },
          max_batch_bytes: int }
  Response: { rows: { samples: [...], sample_tombstones: [...],
                      sync_log: [...] },
              next_cursor: TableCursors,
              server_hlc: HLCTimestamp }

POST /sync/push
  Body: { rows: { samples: [...], sample_tombstones: [...], sync_log: [...] },
          client_hlc: HLCTimestamp }
  Response: { ack_cursor: TableCursors, server_hlc: HLCTimestamp }
```

**Cursor format version** starts at `2` (v1 = legacy scalar). Server rejects mismatched versions with `409 CursorFormatMismatch`; client responds by falling back to legacy REST via feature flag.

**Server-side data_gap handling (hard blocker):** server MUST persist `sample_tombstones` rows and return them in `/sync/pull` responses to peer devices; server MUST NOT interpolate or hide gaps in aggregate/reporting endpoints without explicit product decision.

---

## 3. BLE Layer

### 3.1 Actor topology

```swift
public actor PolarActor {
  public let outboundHR: AsyncStream<HRSample>
  private var continuation: AsyncStream<HRSample>.Continuation!
  // CBCentralManagerDelegate on its own dispatch_queue writes via
  // `continuation.yield(sample)`.
}
```

Same pattern for `EMAYActor` and `HealthKitAdapterActor`. Each hardware source owns one AsyncStream.

**Backpressure policy:**
```swift
AsyncStream<HRSample>(bufferingPolicy: .bufferingNewest(1000)) { c in
  continuation = c
}
```

Frame ordering is preserved by construction because CBCentralManager's dispatch queue is serial and continuation writes are FIFO.

### 3.2 Sensor router

```swift
public actor SensorRouter {
  // Fan-in of all sources into a merged AsyncStream<AnySensorSample>.
  // Exposes: isIdle: Bool, idleSince: Duration
  // Exposes: throttled(rate: 10) → AsyncStream<ViewModelSnapshot>
}
```

**Idle definition:** no frame from any subscribed source for ≥ 60 s.

### 3.3 HealthKit adapter details

- `HKAnchoredObjectQuery(type: hrType, predicate: nil, anchor: lastAnchor, limit: HKObjectQueryNoLimit)`.
- Anchor persisted in App Group UserDefaults.
- Empty result batches DO NOT yield any items on the AsyncStream (they don't emit `data_gap`).
- Pipeline detects HK staleness via its ring buffer's own timestamp comparison — see ops note in the plan re: off-wrist scenarios.

### 3.4 SwiftUI observation

```swift
@MainActor @Observable
public final class MonitoringViewModel {
  public private(set) var latestHR: Int?
  public private(set) var alertTier: AlertTier
  // ...
  init(router: SensorRouter) {
    Task { @MainActor in
      for await snap in await router.throttled(rate: 10) {
        self.latestHR = snap.hr
        self.alertTier = snap.tier
      }
    }
  }
}
```

Views read `viewModel.latestHR` synchronously. No `await` in any view body.

---

## 4. CNS Pipeline

### 4.1 Types

```swift
public struct PipelineState: Equatable, Codable {
  public var thresholds: CNSThresholds
  public var hrRing:    RingBuffer<HRSample>       // 60 s
  public var accelRing: RingBuffer<AccelBin>       // 60 s
  public var hrvRing:   RingBuffer<HRVReading>     // 60 s
  public var lastGapAt: HLCTimestamp?
  // Total <10 KB.
}

public enum AlertCommand: Equatable {
  case notify(tier: AlertTier, message: String)
  case haptic(pattern: HapticPattern)
  case watchMessage(WCPayload)
}

public struct PipelineStep {
  public static func step(
    _ state: PipelineState,
    _ event: SensorEvent,   // .sample(...) | .dataGap(...) | .tick(Duration)
    clock: any Clock<Duration>
  ) -> (PipelineState, [AlertCommand])
}
```

**Purity requirements:** `PipelineStep.step` MUST NOT reference `Date()`, `DispatchTime.now()`, `Task.sleep`, `UNUserNotificationCenter`, or any singleton. All time comes from `clock`. Property-based tests assert this via a build-time lint that greps the module.

### 4.2 Coordinator (impure boundary)

```swift
public actor CNSMonitoringCoordinator {
  public func run(events: AsyncStream<SensorEvent>) async {
    var state = PipelineState.initial
    let clock = ContinuousClock()
    for await event in events {
      let (newState, commands) = PipelineStep.step(state, event, clock: clock)
      state = newState
      for cmd in commands { await interpret(cmd) }
    }
  }
  private func interpret(_ cmd: AlertCommand) async { /* UN, haptic, WC */ }
}
```

### 4.3 Data-gap handling

On `.dataGap(range: ClosedRange<HLCTimestamp>)`:
- Reset `hrRing/accelRing/hrvRing` prefixes whose timestamps fall inside the range.
- `state.lastGapAt = range.upperBound`.
- Do not emit any alert command purely due to the gap (avoid alarm from data loss).
- Emit `.notify(tier: .info, message: "Monitoring gap: <range>")` only if `range.duration > 5 min`.

**Phase 1 gate:** the entire `case .dataGap` branch is compiled but early-returned when `Feature.pipelineGapEventsEnabled == false` (Phase 1 default). CI runs a synthetic-fixture test that flips the flag on and exercises the branch.

---

## 5. Transport Layer

### 5.1 Binary codec

Wire schema (protobuf syntax, for concreteness):

```proto
message SamplePayload {
  repeated SampleRow samples = 1;
  repeated TombstoneRow tombstones = 2;
  HLCTimestamp client_hlc = 3;
}
message SampleRow {
  int32  source = 1;
  int32  type = 2;
  double timestamp = 3;
  double value = 4;
  bytes  extra = 5;
  int64  hlc_physical = 6;
  int32  hlc_logical = 7;
  bytes  node_id = 8;
}
message TombstoneRow {
  int32  source = 1;  int32 type = 2;
  double ts_start = 3; double ts_end = 4;
  int64  hlc_physical = 5; int32 hlc_logical = 6; bytes node_id = 7;
  int32  dropped_row_count = 8; string reason = 9;
}
```

Framed with 4-byte big-endian length prefix; payload compressed with `Compression.Algorithm.zlib` via `NSData.compressed(using:)`.

### 5.2 WCSession routing

| Payload | Transport | Rationale |
|---------|-----------|-----------|
| Latest status, settings, `requires_urgent_sync` ping | `updateApplicationContext` | LWW semantic, one small dict |
| CNS critical alert | `sendMessage(...)` first; on failure `transferUserInfo` | <2 s wall-clock P95 needed; FIFO fallback |
| Historical time-series batch | `transferFile` | Chunked binary, disk-backed, resumable |

**sendMessage fallback:** `session.sendMessage(payload, replyHandler: ...) { error in fallback via transferUserInfo }`. `session.isReachable` is checked first; if false, skip straight to `transferUserInfo` to avoid retry latency.

### 5.3 transferFile resiliency

- Success: delete temp file.
- Failure: exponential backoff `min(2^n * 15 min, 4 h)`, ±20 % jitter.
- `NWPathMonitor` gates retries; on `.satisfied` transition, retry immediately (bypass backoff).
- Files never manually reordered; receiver dedupes by `(source, type, timestamp)` on ingest.

### 5.4 SyncCoordinator retry ladder

```
attempt = 0
loop:
    if !NWPathMonitor.currentPath.status.isSatisfied:
        reschedule(in: 30 min); continue
    result = try syncOnce()
    if result.success: attempt = 0; break
    else:
        attempt += 1
        if attempt >= 6:
            wcSession.updateApplicationContext({"requires_urgent_sync": true})
            attempt = 0
            reschedule(in: 60 min)
        else:
            reschedule(in: min(2^attempt * 15 min, 4 h) * jitter(±20%))
```

Sync cursor is written to disk **only after** the server ACK is persisted, in the same transaction as the pushed rows' bookkeeping. A killed/expired background task is always a no-op.

---

## 6. Watch background execution

### 6.1 WKApplicationRefreshBackgroundTask budget

| Slice | Budget | Purpose |
|-------|--------|---------|
| SQLite commit | ≤ 500 ms | Flush pending writes; PASSIVE checkpoint if idle |
| Schedule next refresh + enqueue upload | ≤ 500 ms | `WKExtension.scheduleBackgroundRefresh(...)`, hand payload to `URLSessionConfiguration.background` |
| Slack | ~3 s | Leaves headroom below the 4 s wall / 15 s CPU envelope |

**Do NOT** `await` `URLSession` uploads or `transferFile` inside the task. Background sessions complete out-of-process via `nsurlsessiond`; delegate callbacks fire in a subsequent wake.

### 6.2 Complication cache writer

```swift
public actor ComplicationCacheWriter {
  private var pending: ComplicationState?
  private var timerTask: Task<Void, Never>?

  public func submit(_ state: ComplicationState) {
    pending = state
    if timerTask == nil {
      timerTask = Task {
        try? await ContinuousClock().sleep(for: .milliseconds(500))
        await self.flush()
      }
    }
  }

  private func flush() async {
    guard let state = pending else { timerTask = nil; return }
    pending = nil
    let tmp = appGroupURL.appendingPathComponent("complication.plist.tmp")
    let dst = appGroupURL.appendingPathComponent("complication.plist")
    try? PropertyListEncoder().encode(state).write(to: tmp, options: .atomic)
    try? FileManager.default.replaceItem(at: dst, withItemAt: tmp, ...)
    timerTask = nil
  }
}
```

Trailing-edge, coalesces bursts, no writes when idle. Complication Extension reads the plist read-only; never opens SQLite.

**Build config:** requires App Group entitlement `group.<team>.com.anxietywatch` on iOS app, Watch app, and Complication extension.

---

## 7. Migration and Rollout

### 7.1 Phase gates

| Phase | Ships | Rollback | Flags |
|-------|-------|----------|-------|
| 1 | §3 actors + §4 pipeline (with gap branch dark) | Revert to prior binary | `pipeline.gapEventsEnabled=false` |
| 2A | §1 SQLite storage + backfill | Read routes back to SwiftData | `storage.sqliteReadsEnabled` |
| 2B | §5 binary WCSession codec | Flip to legacy JSON DTOs | `wc.binaryFormatEnabled` |
| 2C | §2 delta sync + backend endpoints | Legacy REST stays; delta dark | `sync.deltaEnabled` |

### 7.2 Phase 2A cutover script (client)

```
1. On first launch under 2A build:
   a. If tsdb.sqlite absent → create schema (§1.2, §1.3, §1.4).
   b. If _backfill_progress empty → begin backfill.
2. Backfill loop, per (source, type):
   BEGIN;
     INSERT OR IGNORE INTO samples SELECT ... FROM swiftdata WHERE ts > last_ts LIMIT 5000;
     UPDATE _backfill_progress SET last_ts = max_ts WHERE source=? AND type=?;
   COMMIT;
   yield;
3. When all rows migrated → set Feature.storage.sqliteReadsEnabled = true.
4. Continue dual-write of LOW-FREQUENCY tables (Journal, Medications, Settings)
   for 1 minor version. UI reads from SwiftData; SQLite is shadow.
5. Next minor version: flip UI reads to SQLite; deprecate SwiftData paths.
```

**High-frequency streams are NOT dual-written.** New 200 Hz samples go directly to SQLite from cutover. If 2A is rolled back, high-frequency data written to SQLite during the window is not lost — a manual recovery script (shipped in the rollback build) copies it back to SwiftData.

### 7.3 Feature flags

Backed by a remote-config service with 5-minute polling; default values in `Info.plist` for offline safety.

```swift
enum Feature {
  static var pipelineGapEventsEnabled: Bool { get }
  static var sqliteReadsEnabled:       Bool { get }
  static var wcBinaryFormatEnabled:    Bool { get }
  static var deltaEnabled:             Bool { get }
}
```

Every flag flip logs an OSLog event and appears on the diagnostics screen.

### 7.4 Phase 2C shadow-mode + sunset criteria

- 2 weeks server dual-serve, offline compare against legacy REST responses.
- SLO gates before flag can flip: P95 `/sync/pull` < 2 s, zero cursor divergence over 30 days, `409 CursorFormatMismatch` rate < 0.1 %.
- Sunset of legacy REST is proposed **only** after 2C at 99 % client adoption for 30 days on the flag-on path.
- Miss conditions (any) → revert client flag off, delta path stays dark: P95 > 2 s sustained 1 h, cursor divergence detected, backend team slip > 4 weeks.

---

## 8. Testing, Observability, Ops

### 8.1 Test suites

| Suite | Where | What |
|-------|-------|------|
| `PipelinePropertyTests` | `AnxietyWatchKitTests` | Property-based on `PipelineStep.step` with `TestClock`. Fixture: BLE loss/staleness, HLC drift, dataGap injection. |
| `HLCConformanceTests` | ↑ | Kulkarni HLC axioms; drift-clamp branch coverage. |
| `PanicProtocolTests` | ↑ | Fake `SamplesStore`; assert eviction order, protection of un-ACKed rows, and unacked_overflow preconditions gating. |
| `SyncableMacroFixtureTests` | separate compile-fixture package | Assert diagnostic emitted when bidirectional table omits `init(fromSync:)`. EMAY-loss regression guard. |
| `MigrationTests` | ↑ | Simulate mid-backfill crash; assert `_backfill_progress` resumes exactly. |
| `WCSessionRouteTests` | ↑ | Mock `WCSession`; assert critical alerts try `sendMessage` first. |
| `MemoryBudgetTests` | UI test on real device | `XCTMemoryMetric` + mocked 200 Hz stream, 10 sim min. Fail if peak > baseline + 15 MB. |

### 8.2 Metrics (MetricKit + custom)

| Metric | Source | Alert threshold |
|--------|--------|-----------------|
| `MXAppRunTimeMetric.peakMemoryUsage` | MetricKit | Release blocked if P95 > 50 MB on any Watch generation |
| `sync.push.p95_latency_s` | Custom | > 2 s sustained 1 h |
| `sync.cursor_divergence.count` | Server-derived | > 0 |
| `sync.unacked_overflow.fired` | Custom | Any occurrence → diagnostics banner |
| `sync.unacked_overflow.chunked_burst` | Custom | Any → severity P1 |
| `sync.clock_suspect.set` | Custom | Sustained fleet-wide > 1 % of DAUs |
| `db.corruption.recovered` | Custom | > 3 in 24 h per user |
| `ble.parse_latency_us` | os_signpost | P99 > 5 ms |

### 8.3 Signposts

Every BLE frame parse, sync pull/push, refresh-task lifecycle, and SQLite write batch is wrapped in an `os_signpost` interval. **Convention (locked in T02):** a single framework-wide subsystem `com.anxietywatch.kit` with per-module categories (`storage`, `sync`, `hlc`, `ble`, `pipeline`, `transport`, `wc`, `panic`, `migration`, `diag`, `complication`; `healthkit` is an alias for `ble`). Filter by category in Instruments. Instruments profile is checked in to `Docs/InstrumentsTemplates/`.

### 8.4 Diagnostics screen

User-visible screen accessible from Settings, showing:
- Current DB size, WAL size, rollup coverage %.
- `clockSuspect` state.
- Last 10 `data_gap` events by reason.
- Sync last-success / next-attempt.
- Feature flag values.
- OSLog fault count over last 24 h.

---

## 9. Acceptance criteria (release gates)

Before merging to main:
- [ ] All test suites in §8.1 green.
- [ ] `XCTMemoryMetric` peak < baseline + 15 MB across all fixtures.
- [ ] `SyncableMacroFixtureTests` prove the EMAY-loss regression is caught.
- [ ] Corruption injection test (`kill -9` mid-write on Watch) reproducibly recovers.
- [ ] HLC drift fixture (device with clock manipulated ±90 s) does not poison peer causal history.

Before TestFlight ramp:
- [ ] MetricKit P95 memory under 50 MB on Series 6, 7, 8, 9, Ultra 1, Ultra 2.
- [ ] Battery drain P95 < 5 %/h continuous BLE monitoring.
- [ ] `sync.unacked_overflow.fired` rate < 0.1 % of DAUs.

Before enabling `sync.deltaEnabled` in production:
- [ ] Backend `/sync/pull` and `/sync/push` live in shadow-mode 2 weeks.
- [ ] Zero cursor divergence over 30 days of shadow compare.
- [ ] Server-side `data_gap` propagation implemented and tested end-to-end.
- [ ] Legacy REST retained until 30-day 99 % adoption threshold met.

---

## 10. Open Items (from plan appendix, unchanged)

- Specific SLO thresholds for `/sync/pull` — proposed defaults in §7.4.
- Backend team ownership and timeline for delta endpoints.
- **Server-side `data_gap` schema and propagation — hard blocker on Phase 2C.**
- iOS 26 `#Predicate` radar — link when filed, not motivating.

---

*End of specification. Update alongside `redesign_the_app.md`; both files travel together.*
