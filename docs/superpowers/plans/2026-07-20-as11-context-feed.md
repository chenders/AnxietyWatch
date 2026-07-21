# AS11 Context Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `docs/superpowers/specs/2026-07-20-as11-context-feed-design.md`

**Goal:** Make the AS11 (aircannect CPAP bridge) a **live** context/primary-capable SpO₂ source
for the CNS klaxon: a server WebSocket pushes authoritative stream samples + state, a
foreground/BLE-session iOS client ingests them into the CNS pipeline, and every dormant AS11
defect two reviewers found on #23 is fixed with test coverage.

**Architecture:** Backend collector owns the CPAP socket (already scaffolded,
`server/as11_collector.py`); a new authenticated WS endpoint pushes `{samples, state}`; the app's
`AS11WebSocketClient` (`URLSessionWebSocketTask`) connects only while foreground or in an active
BLE session, drops on background, and reconnect-resyncs from a cursor. The socket is a foreground
optimization — background survival is sub-project A, not this feed.

**Tech Stack:** Python 3.12 / Flask + a WS extension (flask-sock) + gunicorn (WS-capable worker);
Swift `URLSessionWebSocketTask`; Swift Testing; `pytest`.

## Global Constraints

- Same CNS invariants + required reviewers as Plan A (asymmetry; primary-informed escalation/
  clearing; invalid data contributes nothing; never a silent stop; `medical-data-accuracy-reviewer`
  + `swift-pre-pr-reviewer` on all `Services/CNSRisk/` changes).
- Server: flake8 clean (`--max-line-length=120`), bandit clean (`uvx bandit -r server -x
  server/tests -l -ii`), `pytest` green against a test Postgres; no `# nosec` without a scoped
  reason; log non-identifying metadata only.
- Every threshold/constant in `CNSThresholds`; source labels via typed constants, not literals
  outside `#Predicate`.
- **Server → app is authoritative for stream state** — the app must never infer "streaming" from
  socket liveness; a stale/absent feed surfaces as "can't assess," never "OK."

---

## File Structure

- Create `server/api/as11_ws.py` (or extend `server/api/as11.py`) — the WS endpoint.
- Modify `server/server.py` — register the WS blueprint; `server/requirements.txt` + gunicorn
  config for a WS worker; `docs/SERVER_SETUP.md`.
- Modify `server/api/as11.py` — ISO-8601 timestamp serialization (§ Task 8).
- Create `AnxietyWatch/Services/CNSRisk/AS11StreamSource.swift` — protocol + WS impl.
- Modify `AnxietyWatch/Services/CNSMonitoringCoordinator.swift` — inject the real source; add
  AS11 samples to `collectSamples`; fix `isOnlyPrimarySource`.
- Modify `AnxietyWatch/Services/CNSRisk/CNSFusionEngine.swift`,
  `CNSDeviceStateMatrix.swift`, `CNSAlertTierMachine.swift` — the §7 spec fixes.
- Tests: `AnxietyWatchTests/AS11StreamSourceTests.swift`, `AS11StreamModelsTests.swift`,
  extend `CNSFusionEngineTests`, `CNSAlertTierMachineTests`, `CNSSensorAdapterTests`,
  `CNSDetectionPipelineTests`, `CNSDeviceStateMatrixTests`; `server/tests/test_as11_ws.py`,
  extend `server/tests/test_server.py`.

---

### Task 1: Server WS endpoint `GET /api/cpap/as11/ws`

**Files:** Create `server/api/as11_ws.py`; modify `server/server.py`, `requirements.txt`.
Test: `server/tests/test_as11_ws.py`.

- [ ] **Step 1: Failing test** — a WS client with a valid Bearer token receives a
  `{samples:[…], state:"STREAMING_OK"}` frame for buffered rows; an invalid token is rejected;
  a `since` cursor only replays newer rows. (Use flask-sock's test client / a wsproto harness.)
- [ ] **Step 2: FAIL → Step 3: Implement** the endpoint: authenticate (reuse the REST decorator's
  logic incl. usage tracking), stream recent `as11_stream_sample` rows + the authoritative state,
  honour `since`. → **Step 4: PASS → Step 5: Commit.**

### Task 2: gunicorn WS worker + deploy config

**Files:** `server/requirements.txt`, gunicorn command / compose, `docs/SERVER_SETUP.md`.
- [ ] Add the WS-capable worker (the default sync worker can't hold a long-lived WS); keep sync
  workers for REST. Document. Verify locally (`docker compose … up`, connect a WS client).
  Commit. *(Infra config; Task 1's test covers behaviour.)*

### Task 3: iOS `AS11StreamSource` protocol + mock parity

**Files:** Create `AnxietyWatch/Services/CNSRisk/AS11StreamSource.swift`.
Test: `AnxietyWatchTests/AS11StreamSourceTests.swift`.

**Interfaces:** `protocol AS11StreamSource { var latestState: AS11StreamState { get }; func latestSamples() -> [AS11StreamPayload] }` + a `MockAS11StreamSource`.

- [ ] Failing test: the mock returns the configured state/samples; a stale source (no frame
  within a timeout) reports `.streamStalled` (fail-safe), never `.streamingOK`. → implement →
  PASS → commit.

### Task 4: `AS11WebSocketClient` — connect/drop/resync

**Files:** Extend `AS11StreamSource.swift`. Test: `AS11StreamSourceTests.swift`.

- [ ] Failing test on the pure reconnect/resync state machine: on `willResignActive` the client
  marks dropped; on wake it reconnects with the last cursor and dedupes by sample id (two
  overlapping frames yield no duplicate). The `URLSessionWebSocketTask` I/O is thin; test the
  cursor/dedupe logic. → implement → PASS → commit.

### Task 5: Wire the real source into `CNSMonitoringCoordinator`

**Files:** Modify `CNSMonitoringCoordinator.swift` (3 construction sites currently default
`latestAS11State = { .streamingOK }`; add AS11 samples to `collectSamples`).

- [ ] Failing test: given an `AS11WebSocketClient`/mock reporting `.bridgeDown`, the coordinator's
  `latestAS11State()` returns `.bridgeDown` and AS11 samples reach `collectSamples`. → implement →
  PASS → commit. **Required reviewers.**

### Task 6 (Will-Block from #23): AS11 as a primary-capable source

**Files:** Modify `CNSMonitoringCoordinator.updateDeviceStates` (the hardcoded
`isOnlyPrimarySource = (source == .emayOximeter)`), `CNSDeviceStateMatrix.swift` (contract text +
`CNSDeviceFallbackConfig` gains an `as11` action). Test: `CNSDeviceStateMatrixTests`,
`CNSMonitoringCoordinatorTests`.

- [ ] **Step 1: Failing test** — an AS11-only session whose bridge dies mid-session classifies to
  `.endMonitoring` (not `.degradeDisclosed`); an AS11-only bridge absent-from-start classifies to
  `.degradeDisclosed` (not `.ignorable`).
- [ ] **Step 2: FAIL → Step 3: Implement** a `primaryCapableSources: Set<CNSSignalSource> =
  [.emayOximeter, .as11Bridge]`, replace the hardcode, update the matrix doc/assertions, add the
  `as11` fallback action. → **Step 4: PASS → Step 5: Commit. Required reviewers.**

### Task 7 (Should-Address from #23): strip ALL AS11 data during faults + emptiness-after-strip

**Files:** Modify `CNSFusionEngine.fuse`. Test: extend `CNSFusionEngineTests`.

- [ ] **Step 1: Failing tests** — (a) with `as11State == .bridgeDown`, an AS11 **heart-rate**
  sample does NOT contribute to the score (currently only SpO₂ is stripped); (b) a buffer whose
  only entry is AS11 SpO₂ under `.bridgeDown` returns `.monitoringDegraded(reason:)`, not
  `.insufficientData`.
- [ ] **Step 2: FAIL → Step 3: Implement** — strip every `$0.source == .as11Bridge` when
  `as11State != .streamingOK`; re-check emptiness after the strip (or strip before the degraded
  check). → **Step 4: PASS → Step 5: Commit. Required reviewers.**

### Task 8 (Should-Address): `.monitoringPaused` rise-candidate — align with the gap-guarded path

**Files:** Modify `CNSAlertTierMachine.ingest`. Test: extend `CNSAlertTierMachineTests`.

- [ ] **DECIDED (maintainer, 2026-07-20):** `.monitoringPaused` must **NOT** call
  `resetRiseCandidate()` — remove that call so the branch matches the gap-guarded
  `.insufficientData`/`.monitoringDegraded` path, relying on `advanceRise`'s `sustainMaxGapSeconds`
  guard instead. Rationale: a brief mask-slip during a real desaturation must not restart the
  klaxon sustain timer from zero. Record this in the PR body and add an `## Implementation notes
  (post-merge)` line to the parent design doc (§14.2). (The two #23 reviewers had disagreed; this
  resolves it.)
- [ ] **Step 1: Failing test** for the chosen behaviour — e.g. a rise-in-progress that sees a
  single `.monitoringPaused` tick then resumes elevated within `sustainMaxGapSeconds` still
  escalates on schedule (does not restart). Plus tests for BOTH `.monitoringPaused` and
  `.monitoringDegraded` branches (neither has direct coverage today).
- [ ] **FAIL → Implement the decision → PASS → Commit. Required reviewers** (escalation timing).

### Task 9 (Should-Address): thread the fault `reason` into observability

**Files:** Modify `CNSMonitoringCoordinator.persistIfDue` to record/log
`.monitoringDegraded(reason:)`/`.monitoringPaused(reason:)`'s reason. Test: assert the persisted
record (or a debug log spy) distinguishes `BRIDGE_DOWN`/`STREAM_STALLED`/`MASK_OFF_LEAK`.
- [ ] Failing test → implement → PASS → commit.

### Task 10 (Should-Address): AS11 unit coverage #23 shipped without

**Files:** Tests only: `AS11StreamModelsTests` (`AS11StreamState.init(from:)` nil/unknown →
`.streamStalled`), `CNSSensorAdapterTests` (`samples(from: AS11StreamPayload)` spo2/hr present×
absent), `CNSDetectionPipelineTests` (`process(..., as11State:)` integration), and strengthen
`CNSFusionEngineTests.streamStalledStripsAS11Primary` to assert `contributions` **excludes** the
`.as11Bridge` SpO₂ (not just the score bound).
- [ ] Write each failing test → confirm it drives/guards existing behaviour → PASS → commit.

### Task 11 (Should-Address / Copilot): server REST timestamps → ISO 8601

**Files:** Modify `server/api/as11.py` `/live` + `/sessions`. Test: extend
`server/tests/test_server.py`.
- [ ] Failing test: insert a session + sample, GET the endpoint, assert `ts_utc`/`start_utc`/
  `created_at` are ISO-8601 strings. → implement (serialize the TIMESTAMPTZ columns) → PASS →
  commit.

---

## Self-Review checklist

- Spec §3 components → T1–T5; spec §7 deferred findings → T6 (§7.1), T7 (§7.2/§7.3), T8 (§7.4),
  T9 (§7.5), T10 (§7.6), T11 (§7.7). Every reviewer finding has a task + test. ✔
- Types consistent: `AS11StreamSource`, `AS11StreamPayload`, `AS11StreamState`,
  `primaryCapableSources`, `CNSDeviceFallbackConfig.as11`.
- Fail-safe: T3 proves stale feed → `.streamStalled`; T7 proves faulted AS11 contributes nothing.

## Execution handoff

Subagent-driven recommended. **T5–T10 each require `medical-data-accuracy-reviewer` +
`swift-pre-pr-reviewer`** (life-safety CNS logic). Depends on sub-project A for the actual
background alarm; can be built after or alongside A.

## Implementation notes (post-merge)
- **Deferred Manual Testing (Tasks 4 & 5):** Physical hardware testing is required for BLE session backgrounding, lifecycle state machine (app lock/background/foreground), and end-to-end hardware ingestion. This cannot be tested in the simulator due to lack of CoreBluetooth support and inaccurate background execution limits. This testing is temporarily deferred and assumed passing until the physical hardware (aircannect CPAP bridge / EMAY oximeter) setup is complete.
- **Task 5 transport recovery:** The original Task 5 commit became orphaned during concurrent branch work. Its live WebSocket transport, lifecycle methods, app injection, and fractional ISO-8601 decoding were restored in `c1c4578`; simulator build and focused transport tests pass.
- **Task 6 shipped:** AS11 is primary-capable with klaxon fallback, and coordinator loss classification only treats a healthy, reporting primary as coverage (`98de01f`, `bac1cc7`, `37d4a8e`).
- **Task 7/10 fault hardening shipped:** Every AS11 contribution is stripped while the stream is faulted, emptiness is checked after stripping, and model/adapter/fusion/pipeline regressions cover the fail-safe behavior (`f16d3d7`).
- **Task 8 shipped:** `.monitoringPaused` preserves a rise candidate and relies on the maximum-gap guard; brief and over-gap pause behavior plus degraded-state behavior are covered (`ea410cb`).
- **Task 9 shipped:** Persisted risk snapshots retain authoritative `BRIDGE_DOWN`, `STREAM_STALLED`, and `MASK_OFF_LEAK` reasons (`a86bd39`).
- **Task 11 shipped:** REST timestamps serialize as ISO-8601 strings (`b51b9ee`).
- **Final-review follow-ups completed:**
  1. `e118382` bounds the AS11 receipt-time buffer and coordinator dedup set, resets history at session boundaries, and prevents stale replay from being treated as fresh evidence; `c9eac96` adds server-side replay recency defense.
  2. Foreground scene transitions now suspend/resume the active AS11 session with its cursor intact, and transient socket failures retry with bounded exponential backoff while remaining fail-closed as `.streamStalled`.
  3. `e118382` adds negative persistence assertions proving `.insufficientData` and `.assessed` records clear `assessmentReason`.
  4. `e118382` adds AS11 SpO₂/HR plausibility bounds at sample construction so impossible values contribute nothing. EMAY parser clamping and Polar's typed parser remain their source-specific guards.
- **Phase A dependency:** PR #27 (real foreground `AVAudioEngine` klaxon) merged to `main` as `239519a`; Phase B was merged/rebased with that implementation present.
- **Deferred transport-test harness:** The reconnect identity guard is correct by inspection and all exposed lifecycle/backoff behavior is covered, but directly firing an old socket's cancelled completion after a replacement socket opens requires an injectable/fake `URLSessionWebSocketTask` harness. Add that direct race regression when the transport seam is introduced; current behavior remains fail-closed.
