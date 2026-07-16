# AnxietyWatch: Redesign Proposal

Revision history: v3 — negotiated with W1 (Claude) and shell (Qwen3-Coder) reviewers over four rounds. Original single-model draft archived by git.

Based on the deep dive into the `AnxietyWatch` codebase, the app does an impressive job wrangling disparate hardware (EMAY, Polar, Apple Watch) and complex physiological logic (CNS depression detection). However, the current architecture carries several systemic risks—primarily around data persistence, concurrency, and synchronization. 

If I were to redesign this application from the ground up, here are the core architectural changes I would make and why.

## 1. Separate Time-Series Data from SwiftData (STORAGE)
**What:** Move all high-frequency sensor data (`QuantityHealthSample`, `AccelSpectrogram`, `DerivedBreathingRate`, `HRVReading`) out of SwiftData.
**Why:** SwiftData (and Core Data beneath it) is an Object-Relational Mapper designed for graph data. It is notoriously inefficient for massive, flat time-series datasets. 

**Implementation Details:**
* **Engine:** GRDB-wrapped SQLite (system SQLite, WAL mode, `synchronous=NORMAL`).
* **Concurrency:** Single writer using a GRDB `DatabaseQueue` (not `DatabasePool`). On WKExtension background transitions, we execute an explicit `sqlite3_close_v2`.
* **Schema:** The `samples` table will use `PRIMARY KEY(source, type, timestamp) WITHOUT ROWID`. There is no `TEXT id` column. This provides natural deduplication, temporal clustering, and avoids expensive UUID string comparisons.
* **HLC Columns:** Three separate columns: `hlc_physical INTEGER`, `hlc_logical INTEGER`, and `node_id BLOB`. (W1 correctly vetoed a packed INTEGER to avoid bit-63 sign flip foot-guns). 
* **Indexing:** A covering index accelerates sync reads: `CREATE INDEX idx_samples_hlc ON samples(node_id, hlc_physical, hlc_logical)`.
* **Tombstones:** A sibling table `sample_tombstones` tracks evictions and deletions: `(source, type, ts_start, ts_end, hlc_physical, hlc_logical, node_id, dropped_row_count, reason ENUM('memory_panic','corruption','manual','retention','unacked_overflow')) PRIMARY KEY(source, type, ts_start, hlc_physical, hlc_logical, node_id) WITHOUT ROWID`. A separate index is used here: `CREATE INDEX idx_sample_tombstones_hlc ON sample_tombstones(node_id, hlc_physical, hlc_logical)`. The `data_gap` rows are written exclusively to this table.
* **HealthKit Boundaries:** HealthKit remains the canonical source of truth for Apple Watch HR/HRV. The TSDB is exclusively for BLE-native streams and app-internal derived data.
* **Retention & Compaction:** 7-day watchOS window. Background compaction runs daily (`DELETE ... LIMIT 5000`) with a `PASSIVE` checkpoint during active ingest. We only execute `wal_checkpoint(TRUNCATE)` when BLE is idle inside a `WKApplicationRefreshBackgroundTask`. A `wal_autocheckpoint=1000` serves as a safety net. If a checkpoint aborts, the next launch runs `PRAGMA wal_checkpoint(RESTART)` and an `integrity_check`.
* **Security & iCloud:** DB files use `NSFileProtectionCompleteUntilFirstUserAuthentication` and are excluded from backups (`NSURLIsExcludedFromBackupKey = true`).
* **Corruption Recovery:** A `DatabaseManager` acts as a circuit breaker. If `sqlite3_open_v2` or any query returns `SQLITE_CORRUPT`, we immediately delete `.sqlite`, `.sqlite-wal`, and `.sqlite-shm`, surface a "Recovering…" UI, and initiate a full server backfill. The `node_id` is NEVER regenerated here; it survives in the Keychain.

## 2. Event-Sourced or Delta-Based Sync Engine (SYNC)
**What:** Replace the manual `syncedToServer` toggles and custom restore logic with a Log-based delta sync.
**Why:** Manual flag-flipping leads to catastrophic data loss if an importer is forgotten. We need a mathematically sound replication pipe. (Note: NOT a CRDT, NOT the SQLite session extension).

**Implementation Details:**
* **High-Frequency Time-Series:** Bypasses `_sync_log` entirely. The cursor is a per-table map `{node_id: (hlc_physical, hlc_logical)}`. Pagination executes one indexed query per `node_id` present in the map: `SELECT ... FROM samples WHERE node_id = ? AND (hlc_physical, hlc_logical) > (?, ?) ORDER BY hlc_physical, hlc_logical LIMIT ?`. Results from all node queries are merged in-memory in HLC order before being handed to the transport. The sync push routine executes a `UNION ALL` between `samples` and `sample_tombstones` (both filtered by the per-node cursor map) so gaps are inherently transmitted alongside the standard payload.
* **Low-Frequency CRUD (Settings, Journal):** Uses standard SQLite triggers + `_sync_log` + Last-Write-Wins (LWW). The `_sync_log` schema is `(table_name TEXT, row_pk TEXT, hlc_physical INTEGER, hlc_logical INTEGER, node_id BLOB, operation ENUM('upsert', 'delete')), PRIMARY KEY(table_name, row_pk) WITHOUT ROWID`. This PK deliberately retains only the latest op per row — intermediate updates between server ACKs are coalesced by design (correct under LWW; document in developer docs so it isn't mistaken for a bug). The `@Syncable` macro automatically generates the SQLite `AFTER INSERT/UPDATE/DELETE` triggers to populate this log. HLC resolution for LWW uses the standard vector-clock logic in memory prior to application. GC is performed via `DELETE FROM _sync_log WHERE hlc <= ackedCursor` batched with the next transaction.
* **Hybrid Logical Clocks (HLC):** Used everywhere. `node_id` is an install UUID pinned in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The paired iPhone and Apple Watch each generate their own `node_id` and never share them.
* **HLC Drift Guard:** If `incoming.pt - local.pt > 60 s`, we accept but bound the merge (local physical time is not advanced past `local.pt + 60 s`). If drift is `> 24 h`, the row is quarantined to `_sync_quarantine` and triggers an OSLog fault. Wall vs. boot-anchored monotonic divergence `> 60 s` for `> 5 minutes` triggers a `clock_suspect` behavior gate (not just telemetry). While set: sync pulls continue, uploads pause, and CNS cross-device fusion is suppressed. It clears after 15 minutes back in bounds, with OSLog faults on set/clear.
* **Sync Completeness:** A `@Syncable` Swift macro enforces protocol conformance at compile time. It defaults to bidirectional, requiring `encodeForSync()` and `init(fromSync:)`. A bidirectional table missing a downloader will FAIL TO COMPILE. Unidirectional tables must explicitly declare `@Syncable(direction: .upOnly)`. The macro generates a `SyncRegistry` and flattens nested graphs at the schema layer (does not recurse); transient fields can use `@SyncableIgnore`.
* **Server Contract:** The cursor is a per-table map of `(hlc_physical, hlc_logical, node_id)`, NOT a monolithic scalar. Schema-version negotiation on `/sync/pull` is a load-bearing requirement (must include cursor-format version).
* **225 MB / 250 MB Panic Protocol:** If the DB hits 225 MB, we force an out-of-schedule high-priority sync (30s timeout). If it hits 250 MB, we evict the oldest un-ACKed rows down to 200 MB and emit a `data_gap` tombstone per `(source, type)` with `reason='memory_panic'`. The gap HLC is the fresh local HLC at eviction time (so late deltas from other devices aren't suppressed). If >1 `data_gap` occurs in 24h, it surfaces in diagnostics. The server MUST persist and propagate these tombstones.
* **Un-ACKed Overflow Override:** Un-ACKed rows are protected from ordinary LRU eviction. The `unacked_overflow` override applies only when ALL of the following hold: (1) DB size ≥ 250 MB after ordinary eviction of ACKed rows to 200 MB has already run; (2) the 225 MB out-of-schedule high-priority sync attempt has failed or timed out; (3) raw un-ACKed samples have been synchronously downsampled to 1-minute rollups; and (4) no `unacked_overflow` event for the same `(source, type)` has fired in the preceding 60 minutes. When triggered, the override evicts oldest un-ACKed raw samples for the chosen `(source, type)` down to 200 MB total DB size, emits a `sample_tombstones` row with `reason='unacked_overflow'` covering the evicted range, and preserves the 1-minute rollups so the resulting server-visible gap is coarse-grained rather than total. Per-event loss is capped at 6 hours of raw samples; successive evictions mint fresh tombstones. When two or more chunked evictions fire back-to-back within a rolling 4-hour window we emit a distinct `sync.unacked_overflow.chunked_burst` OSLog fault and metric — a signal that the cap is doing real work and the underlying outage is severe. Any `unacked_overflow` event surfaces immediately in the diagnostics screen ("backend unreachable — coarse data retained") and fires a `sync.unacked_overflow.fired` metric (sustained firing across the fleet is a P1 incident).

## 3. Move Hardware & BLE Logic Off the `@MainActor` (BLE / ACTORS)
**What:** Decouple `EMAYRealtimeService`, `PolarHRMService`, and `PhoneConnectivityManager` from `@MainActor`. 
**Why:** Nonisolated BLE delegate callbacks jumping to the Main Thread cause UI stutter.

**Implementation Details:**
* **Bridging:** The `CBCentralManagerDelegate` stays on its designated `DispatchQueue` and immediately feeds frames into an `AsyncStream.Continuation`. A dedicated background actor consumes this stream per hardware source. HealthKit data enters via a dedicated actor running an `HKAnchoredObjectQuery`; empty windows do not emit `data_gap` events, as the pipeline natively handles HK staleness via its internal ring-buffer timestamps. (Ops note: a Watch off-wrist for hours will look identical to steady-state to the HK adapter — ring-buffer staleness is the sole mechanism that catches it, so alert thresholds on staleness must be tuned accordingly.)
* **Backpressure:** The AsyncStream uses a drop-oldest policy with a ~1000-frame cap per stream.
* **SwiftUI Observation:** Views read from an `@Observable @MainActor ViewModel` which consumes a throttled, downsampled (~10 Hz) view-state stream from the background actor. There are no `await` calls in SwiftUI view reads.
* **Cross-Platform:** Applies to both iOS and watchOS targets with standard per-platform background execution rules.

## 4. Pure Functional CNS Detection Pipeline (CNS PIPELINE)
**What:** Isolate the detection engine (`CNSDetectionPipeline`, `CNSFusionEngine`) from hardware adapters and side effects.
**Why:** Tying business logic to run loops makes testing non-deterministic.

**Implementation Details:**
* **Pure Function:** The pipeline operates strictly as `(State, Sample) -> (State, [AlertCommand])`. The `State` is ~10 KB of thresholds and ~60s ring buffers.
* **Time Injection:** Uses the Swift 5.7+ `Clock` protocol. We inject `ContinuousClock` in production and `TestClock` in tests.
* **Side-Effect Boundary:** The `CNSMonitoringCoordinator` is the only impure boundary responsible for reading commands and firing side-effects (UNUserNotificationCenter, haptics, WCSession messages).
* **Data Gap Handling:** The pipeline receives `data_gap` events (from the Panic Protocol) and treats them as hard stream interruptions. It explicitly does not fabricate staleness checks across gaps.

## 5. Optimize Watch-to-Phone Data Transfer (WCSESSION / TRANSPORT)
**What:** Replace JSON DTO encoding over `WCSession` with lightweight binary payloads.
**Why:** Mapping huge arrays of JSON strings drains watch battery and memory.

**Implementation Details:**
* **Format:** Packed binary row format (protobuf or custom Swift binary) matching the TSDB `(source, type, timestamp)` PK for O(1) deduplication on the receiving end. 
* **Compression:** Exclusively relies on Apple `Compression.framework` / Apple Archive. No custom compression algorithms to avoid App Review risk.
* **Transport Mapping:**
    * `updateApplicationContext`: Shared metadata, latest settings, and status (LWW).
    * `transferUserInfo`: Critical CNS alerts attempt immediate delivery via `sendMessage` (for < 2s latency). If reachable fails, they fall back to `transferUserInfo` for guaranteed eventual FIFO delivery.
    * `transferFile`: Batch syncing of historical time-series data chunked into binary files. Disk-backed, resumable, out-of-order delivery accepted.
* **Resiliency:** `transferFile` uses exponential backoff with jitter and `NWPathMonitor` gating for connectivity gaps.

## Migration & Rollout
This redesign uses a phased, unbundled rollout so individual layers can be rolled back safely.

* **Phase 1 (Compute):** Ship §3 + §4 (Actors and Pure Pipeline). No disk changes. Ships first. Phase 1 dark-ships data gap handling behind a runtime flag `pipeline.gapEventsEnabled` (default `false`). The pipeline gap logic is fully implemented and tested (synthetic TestClock fixtures in CI), but the events are not emitted by the storage layer until Phase 2A.
* **Phase 2A (Local Storage):** Ship SQLite for local storage only. WCSession continues to emit legacy JSON DTOs, but they are now sourced from SQLite reads instead of SwiftData. Flips `pipeline.gapEventsEnabled` to `true` (rollback reverts to `false`).
* **Phase 2B (Wire Format):** Ship the Binary WCSession format behind a feature flag. If toggled off, it reverts to JSON payloads.
* **Phase 2C (Delta Sync):** Delta-sync backend endpoints ship alongside the legacy REST API. Feature flag OFF by default. The server runs in shadow-mode for 2 weeks before client flag flips. 
    * **Sunset Criteria:** Legacy REST is sunset ONLY after server meets SLOs (P95 latency, cursor correctness under fuzz, 30 days stable) — NOT calendar-driven.
    * **Rollback:** If endpoint P95 > 2s, cursor divergence occurs in shadow-compare, or the backend slips > 4 weeks, Phase 2C reverts. Delta stays dark behind a flag, while 2A and 2B remain shipped.
* **Data Migration:** High-frequency (200 Hz) streams are NOT dual-written. A one-time idempotent backfill moves SwiftData into SQLite. The backfill state is transactionally persisted in a dedicated `_backfill_progress` SQLite table `(source, type, last_ts PRIMARY KEY)` to ensure memory-pressure evictions do not corrupt the resume point. Low-frequency tables dual-write for 1 minor version with count-parity telemetry. During this dual-write window, the UI strictly reads from SwiftData (the proven path) while shadow-writing to SQLite. High-frequency reads route exclusively to SQLite.
* **Complications:** Complications NEVER touch the TSDB. The main app writes denormalized state to an App Group plist (requires App Group entitlement build-config change). The `ComplicationCacheWriter` actor holds the latest pending state and a single trailing-edge 500ms timer (`ContinuousClock.sleep`). `writer.submit(state)` overwrites pending and arms the timer. On fire, it serializes to a temp file in the App Group container and performs an atomic swap via `FileManager.replaceItem(...)`. Bursts collapse to one write with the last value.
* **Background Budget Constraints:** The `WKApplicationRefreshBackgroundTask` enqueues onto `URLSessionConfiguration.background` (runs out-of-process via `nsurlsessiond`, survives task expiration, does NOT block the refresh window). Budget execution: ≤500 ms SQLite commit, ≤500 ms `scheduleBackgroundRefresh` + enqueue overhead, remainder slack. We do NOT await `transferFile` or delta-pull inside the refresh task; completion is handled via the background-session delegate in a subsequent wake. Sync backoff is `min(2^n * 15 min, 4 h)` with ±20% jitter applied to the *next* refresh scheduling. 6 consecutive failures falls back to a lightweight wakeup ping (`{"requires_urgent_sync": true}`) via `updateApplicationContext`, telling the paired iPhone to immediately initiate a direct REST pull from the backend. We never advance a sync cursor without a server ACK.

## Testing, Observability & Ops
* **Memory Limits:** The app enforces a strict peak memory budget on watchOS. Pre-commit tests use `XCTMemoryMetric` with mocked 200 Hz streams for 10 simulated minutes, asserting < 15 MB above baseline. In TestFlight, MetricKit `MXAppRunTimeMetric.peakMemoryUsage` tracks real-world limits. If P95 > 50 MB, the release is blocked.
* **Pipeline Fixtures:** Deterministic testing uses BLE loss/staleness fixtures and a `TestClock` HLC rig.
* **Telemetry:** We use `OSLog` + `os_signpost` to trace BLE parse latency, background-refresh budget consumption, and transfer file attempts. 
* **Sync Health:** HLC drift metrics, quarantine events, and `DatabaseManager` circuit breaker trips are piped to ops dashboards.

## Target Metrics 
*(Note: Must be captured as baselines prior to Phase 1)*
* **Peak Memory:** < 50 MB on watchOS.
* **Battery Drain:** < 5% per hour of continuous BLE monitoring.
* **Sync Latency:** P95 < 2 seconds for critical alerts via `transferUserInfo`.

## Conclusion
The current app's complexity stems from forcing high-velocity data through systems designed for low-velocity data. By right-sizing the tools—using WAL-mode SQLite for flat time-series, isolating hardware processing into actors, transitioning to a mathematically sound HLC delta-sync, and bypassing JSON bloat—the app will achieve the necessary resilience, battery efficiency, and memory safety for medical-grade continuous monitoring.

---

### Open Items Appendix
* Specific SLO thresholds for server `/sync/pull` (P95 latency ceiling, cursor divergence tolerance in shadow-compare). Proposed default: P95 <2 s, zero cursor divergence over 30 days.
* Backend team ownership and timeline for `/sync/pull?after_cursor=` endpoint.
* **Server-side handling of `data_gap` tombstones — the single documented hard blocker on Phase 2C shipping.** The client-side schema is fixed (see §1 `sample_tombstones`); the backend must (a) persist tombstones in the same table space as samples, (b) return them in `/sync/pull` responses to peer devices, (c) NOT interpolate or hide gaps in aggregate endpoints, and (d) negotiate cursor-format version. This item must be closed with the backend team before Phase 2C leaves shadow-mode.
* iOS 26 `#Predicate` radar — worth linking, but not motivating: SwiftData's per-row overhead and lack of bulk `INSERT OR IGNORE` remain disqualifying regardless of a fix.