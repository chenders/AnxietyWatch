# AS11 Context Feed — Server WebSocket Push + On-Device Ingest

**Status:** Design (approved architecture, 2026-07-20). Sub-project **B** of the CNS-klaxon
program (A = on-device Phase 3, B = this doc, C = server redundant alert channel).

**Parent designs:** `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` (klaxon,
§5 detection engine, §4 sensor inventory) and `Integration Plan- aircannect - AnxietyWatch.md`
(repo root; §5: AS11 is **context/gating** for SpO₂ detection, the backend collector owns the
socket, capture-first/hardware-gated).

**Research grounding:** `Keeping a Real-Time Health Feed Alive on a Backgrounded iOS App-…md` —
the socket is a **foreground optimization with queue-and-replay/cursor resync**, not a
background lifeline. Let it die on background; reconnect + resync from a server cursor on wake.

**What #23 already merged (the mocked scaffold this plan makes live):** `AS11StreamPayload` +
`AS11StreamState(from:)` (`AnxietyWatch/Services/CNSRisk/AS11StreamModels.swift`),
`CNSSensorAdapters.samples(from: AS11StreamPayload)`, the `.as11Bridge` source with fidelity
0.9 in `CNSThresholds`, `CNSFusionEngine` AS11 fault-handling, `latestAS11State` plumbing into
`CNSMonitoringCoordinator`/`CNSDetectionPipeline`, and the server `/api/cpap/as11/live` +
`/sessions` REST endpoints, `as11_collector.py`, `mock_aircannect.py`, schema + migration.
**All of it is dormant**: `latestAS11State` is a constant `.streamingOK` with no call site, and
`CNSSensorAdapters.samples(from:)` is never called from `collectSamples`. This plan wires it up
**and fixes every latent defect two reviewers found in that dormant code (§7 below).**

---

## 1. Problem & role

The AirSense 11 (via the aircannect bridge) is a **context/gating** signal for the klaxon
(Integration Plan §5): a continuous SpO₂/pressure/flow/leak stream that (a) can act as a
primary-capable SpO₂ source alongside the EMAY oximeter, and (b) tells the detection engine when
physiological assessment is mechanically invalid (mask off / large leak → suppress) or the
bridge is down. #23 modelled the wire types and the fusion logic but never connected a real
data source, so the whole path is inert. This sub-project connects it.

## 2. Architecture

Backend collector owns the CPAP socket (Integration Plan): `as11_collector.py` speaks the
bridge's JSON-RPC-over-TCP, parses the stream, and persists samples/sessions. The **app** does
not talk to the bridge; it consumes the server. Two transport questions:

- **Server → app, live:** a **WebSocket** endpoint `GET /api/cpap/as11/ws` that pushes
  authoritative `{samples:[…], state:"STREAMING_OK|STREAM_STALLED|BRIDGE_DOWN|MASK_OFF_LEAK"}`
  frames. The server owns the **authoritative stream state** (it holds the socket and knows
  liveness), which is why #23's client-side "derive state from sample recency" approach was
  removed — the server tells the app the state directly.
- **App side, foreground/BLE-session only:** a `URLSessionWebSocketTask` client that runs while
  the app is foreground **or** while an active BLE monitoring session keeps the app alive
  (`bluetooth-central`). On background/suspension it **drops**; on wake it **reconnects and
  resyncs** from a server cursor (last-seen sample id / ts) and dedupes. The live socket is an
  optimization; **the klaxon's background survival comes from sub-project A (on-device BLE), not
  from this socket** (research: no socket survives suspension).

The REST endpoints (`/live`, `/sessions`) remain as capture-first query/debug endpoints; the WS
is the live channel.

## 3. Components

| Unit | Responsibility |
|------|----------------|
| Server `GET /api/cpap/as11/ws` (flask-sock or equivalent) | Authenticated (Bearer, mirroring the REST decorator incl. usage tracking) WS that streams recent samples + authoritative state; supports a `since` cursor for resync. |
| Gunicorn worker config | A WS-capable worker (the sync worker cannot hold a long-lived WS). Documented in `docs/SERVER_SETUP.md`; keep the existing sync workers for REST. |
| iOS `AS11StreamSource` (protocol) | Abstracts "where AS11 state + samples come from," with a `WebSocket` impl and the existing mock. Injected into `CNSMonitoringCoordinator` as `latestAS11State` **and** a sample provider for `collectSamples`. |
| iOS `AS11WebSocketClient` | `URLSessionWebSocketTask` lifecycle: connect on foreground/session-active, drop on background, reconnect + cursor-resync + dedupe on wake. |
| `CNSMonitoringCoordinator` wiring | Replace the 3 default `latestAS11State = { .streamingOK }` construction sites with the real source; add AS11 samples to `collectSamples`. |

## 4. Data flow

```
CPAP bridge --TCP/JSON-RPC--> as11_collector (server) --persist--> Postgres
                                     |
                          WS push {samples, state}
                                     v
iOS AS11WebSocketClient (fg / BLE-session) --> AS11StreamSource
   --> latestAS11State()  ─────────────────┐
   --> AS11 samples into collectSamples ────┴─> CNSDetectionPipeline.process(..., as11State:)
                                               --> CNSFusionEngine.fuse --> CNSAlertTierMachine
```

## 5. Making AS11 a primary-capable source (the core behavioural change)

#23 marked `.as11Bridge` fidelity 0.9 ("continuous, verified stream") but left the device-loss
logic hardcoded to EMAY. This plan makes the two consistent: AS11 becomes a **primary-capable**
SpO₂ source, so its absence/death is disclosed and can end monitoring under the "only
primary-capable source" condition — exactly like EMAY. See §7.1.

## 6. Error handling / fail-safe

- Server state is authoritative; a stale/absent WS (no frames within a timeout) surfaces to the
  app as **"can't assess"** (indeterminate), never "OK" — the app must not infer streaming from
  socket liveness alone.
- Fault states (`BRIDGE_DOWN`/`STREAM_STALLED`/`MASK_OFF_LEAK`) must **strip untrusted AS11
  data from scoring** (see §7.2) so a faulted bridge can neither escalate nor reassure.
- Reconnect uses a cursor + dedupe so a gap never double-counts or, worse, lets two samples
  bracketing a gap satisfy a sustain window (the tier machine's `sustainMaxGapSeconds` guard
  already enforces this on the assessment side).

## 7. Deferred from #23 — MUST fix as part of this sub-project

Two independent reviewers (medical-data-accuracy + swift-pre-pr) flagged these in #23's dormant
AS11 code. They cause **no current-behaviour bug** (the path is inert) but become live the moment
this plan wires AS11 sampling, so they are **required work here, each with test coverage.**

### 7.1 `isOnlyPrimarySource` / device-state-matrix consistency (Will-Block)
`CNSMonitoringCoordinator.updateDeviceStates` hardcodes `isOnlyPrimarySource = (source ==
.emayOximeter)`, and `CNSDeviceStateMatrix` doc/assertions say "only EMAY is primary-capable" —
but `.as11Bridge` now carries primary SpO₂ fidelity. Fix: treat AS11 as primary-capable
(`source == .emayOximeter || source == .as11Bridge`, or a `primaryCapableSources` set), update
`CNSDeviceStateMatrix`'s contract text, and add an `as11` action to `CNSDeviceFallbackConfig`.
**Failure if unfixed:** an AS11-only user whose bridge dies mid-session gets a passive "degraded"
notice (session continues) instead of `.endMonitoring` + the Phase-3 klaxon fallback; an
AS11-only bridge that never connects gets `.ignorable` (zero disclosure).

### 7.2 Strip **all** AS11 data during faults, not just SpO₂ (Should-Address)
`CNSFusionEngine.fuse` strips `.as11Bridge && .kind == .spo2` when `as11State != .streamingOK`,
but leaves AS11 **heart-rate** in `usable` — so a bridge-down/stalled HR reading still boosts
`corroborating`/`multiSourceBonus`. AS11 HR is bridge-derived; a mask-off/bridge-down HR value
is exactly the "invalid data contributes nothing" case (CLAUDE.md CNS invariants). Fix: strip
**every** `$0.source == .as11Bridge` sample when `as11State != .streamingOK`.

### 7.3 Re-check emptiness **after** the strip (Should-Address / Copilot)
The `.bridgeDown`/`.streamStalled` degraded check runs **before** the SpO₂ strip, so a buffer
whose only entry is AS11 SpO₂ passes the non-empty check, is then stripped to empty, and returns
generic `.insufficientData` instead of `.monitoringDegraded(reason:)`. Fix: re-check emptiness
after stripping, or strip before the degraded check. (Inert today because the tier machine
treats both identically — but it defeats the fault classification this feature adds.)

### 7.4 `.monitoringPaused` rise-candidate reset — DECIDED (maintainer, 2026-07-20)
The two #23 reviewers disagreed; the maintainer resolved it. `CNSAlertTierMachine.ingest`'s
`.monitoringPaused` branch currently calls `resetRiseCandidate()` (unlike
`.monitoringDegraded`/`.insufficientData`, which rely on the `sustainMaxGapSeconds` gap guard).
Medical-accuracy reviewer: correct deliberate asymmetry (mask-off is a genuine mechanical
suppression). Swift reviewer: discards escalation progress on a brief mask-slip *during a real
desaturation*, restarting the klaxon sustain timer from zero — against the fail-safe bias.

**Decision: do NOT reset.** Align `.monitoringPaused` with the gap-guarded `.insufficientData`
path (remove the `resetRiseCandidate()` call; rely on `advanceRise`'s `sustainMaxGapSeconds`
guard). The *existing* rise progress reflects a real pre-slip desaturation, and a brief mask slip
must not delay the alarm — the fail-safe bias wins. Implement in plan B Task 8; document the
rationale in-code and add an `## Implementation notes (post-merge)` line to the parent design doc
(§14.2/§11); add a test covering both `.monitoringPaused` and `.monitoringDegraded`.

### 7.5 Thread the fault `reason` into observability (Should-Address)
`.monitoringDegraded(reason:)` / `.monitoringPaused(reason:)` carry `"BRIDGE_DOWN"` /
`"STREAM_STALLED"` / `"MASK_OFF_LEAK"`, but `CNSMonitoringCoordinator.persistIfDue` collapses all
no-data cases to `riskScore=nil, contributions=[]` — the reason is write-only. Thread it into the
persisted record or at least a debug log so an overnight `canAssess=false` gap is diagnosable.

### 7.6 AS11 test coverage (Should-Address, both reviewers)
Add the tests #23 shipped without: `AS11StreamState.init(from:)` (nil/unknown → `.streamStalled`
fail-safe); `CNSSensorAdapters.samples(from: AS11StreamPayload)` (spo2/hr present×absent);
`CNSDetectionPipeline.process(..., as11State:)` integration; `CNSAlertTierMachine`
`.monitoringPaused`/`.monitoringDegraded` branches; and strengthen `streamStalledStripsAS11Primary`
to assert `contributions` **excludes** the `.as11Bridge` SpO₂ (not just the score bound).

### 7.7 Server REST timestamps → ISO 8601 (Should-Address / Copilot)
`/live` and `/sessions` return `RealDictCursor` rows with TIMESTAMPTZ columns that Flask
`jsonify` emits in non-ISO (HTTP-date) format. Define the response contract as ISO 8601 (serialize
`ts_utc`/`ingest_ts_utc`/`start_utc`/`end_utc`/`created_at`) so the app decoder is
unambiguous; add tests that populate rows and assert the format.

## 8. Testing

Server: WS auth + cursor-resync + dedupe; the ISO-8601 REST contract (§7.7). iOS: the
`AS11StreamSource` protocol with the mock (deterministic), the WS client's reconnect/resync
state machine as pure-ish logic, and every §7.6 unit. Integration: full pipeline with a scripted
AS11 fault sequence (streaming → stalled → bridge-down → mask-off) asserting tier + device-state
outcomes.

## 9. Dependencies

- Depends on **A** for the actual background alarm (this feed is a foreground/session context
  signal; it does not itself make the klaxon survive suspension).
- WS server work needs a WS-capable gunicorn worker; coordinate with sub-project **C** (both add
  server surface) but they are independent deployables.
