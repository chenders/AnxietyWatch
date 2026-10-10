# Server Redundant Alert Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Spec:** `docs/superpowers/specs/2026-07-20-server-redundant-alert-channel-design.md`

**Goal:** A **redundant, secondary** alert channel — the server runs a simple conservative
backstop over live-uploaded SpO₂/HR and detects a stopped feed, pushing a high-priority APNs
alert (Time-Sensitive now, Critical once sub-project A's entitlement lands) and surfacing
channel health — so a silent failure of the on-device path or the phone itself is still caught.

**Architecture:** During an armed BLE-active session the phone uploads the samples its on-device
pipeline consumes; the server buffers per session and runs (a) a conservative fixed-floor
backstop and (b) a no-data heartbeat monitor; either raises → one APNs push. C never suppresses
or replaces the on-device decision (sub-project A); it only ever adds an alert.

**Tech Stack:** Python 3.12 / Flask + APNs (`.p8` token auth, e.g. `aioapns`/`httpx`+JWT);
Swift `URLSession` upload; `pytest`; Swift Testing.

## Global Constraints

- **C is redundancy, never primary** (parent klaxon §1). It cannot cancel/downgrade an on-device
  alarm. No full `CNSFusionEngine`/`CNSAlertTierMachine` port to Python — the backstop is a
  simple fixed-floor check only.
- Server: flake8 + bandit + pytest green (as Plan B). APNs keys via env (`.p8`, key id, team id);
  **never log tokens/keys/PII** — presence/length only.
- **Own failure must be visible** (2019 Dexcom lesson): a dead server / stopped feed must never
  read as "all clear"; channel health is surfaced in-app.
- Fixed floors come from the parent design §3 thresholds (named constants), not the personalized
  baseline logic (which stays on-device).

---

## File Structure

- Create `server/api/alert_channel.py` — upload append + backstop + heartbeat + push trigger.
- Create `server/backstop.py` — pure conservative evaluator.
- Create `server/apns.py` — APNs client wrapper (payload builder + send).
- Modify `server/schema.sql` + a new Alembic migration — `session_sample_buffer`,
  `device_push_token`, `alert_event` tables.
- Modify `server/server.py` — register blueprint; env docs in `docs/SERVER_SETUP.md`.
- Create `AnxietyWatch/Services/AlertChannelUploader.swift` — upload during armed sessions +
  push-token registration + channel-health.
- Tests: `server/tests/test_backstop.py`, `server/tests/test_alert_channel.py`,
  `server/tests/test_apns.py`; `AnxietyWatchTests/AlertChannelUploaderTests.swift`.

---

### Task 1: Schema — sample buffer, push tokens, alert events

**Files:** `server/schema.sql` + new `server/alembic/versions/*_alert_channel.py`.
Test: `server/tests/test_schema.py` / migration parity (schema.sql and the migration must be
identical — the #23 index-DESC-drift lesson).

- [ ] Failing test: the migration upgrades cleanly and the tables match `schema.sql` (same
  columns + index ordering). → add tables (`session_sample_buffer(session_id, ts_utc, channel,
  value)`, `device_push_token(token, env, created_at)`, `alert_event(session_id, kind, ts_utc)`)
  to BOTH schema.sql and the migration identically → PASS → commit.

### Task 2: Pure backstop evaluator

**Files:** Create `server/backstop.py`. Test: `server/tests/test_backstop.py`.

**Interface:** `evaluate(samples: list[Sample], now: datetime) -> BackstopVerdict` where a verdict
is `raise` iff SpO₂ stays below `SPO2_FLOOR` (parent §3) for ≥ `SUSTAIN_SECONDS` within the
window, with no gap > `MAX_GAP_SECONDS` (so two samples bracketing a blackout can't trigger it —
mirrors the on-device gap guard).

- [ ] **Step 1: Failing tests** (table-driven): sustained-low → raise; brief-dip → no raise;
  low-samples bracketing a > `MAX_GAP_SECONDS` gap → no raise; empty/short window → no raise.
- [ ] **Step 2: FAIL → Step 3: Implement** the pure evaluator (clock injected as `now`). →
  **Step 4: PASS → Step 5: Commit.**

### Task 3: APNs client wrapper

**Files:** Create `server/apns.py`. Test: `server/tests/test_apns.py` (mock the HTTP send).

- [ ] Failing test: `build_payload(kind, critical: bool)` produces a Time-Sensitive payload
  (interruption level `time-sensitive`, priority 10) when `critical=False`, and a Critical
  payload (sound dict `{"critical":1,"name":…,"volume":…}`) when `critical=True`; `send` posts to
  the correct APNs host with a JWT from the `.p8`. → implement → PASS → commit. *(No real APNs in
  CI; assert payload shape + request construction against a mock.)*

### Task 4: Upload append + backstop + heartbeat wiring

**Files:** Create `server/api/alert_channel.py`; modify `server/server.py`.
Test: `server/tests/test_alert_channel.py`.

- [ ] **Step 1: Failing tests** — POST samples to the append endpoint (Bearer auth) → buffered;
  a run of low samples triggers exactly one push (idempotent per event via `alert_event`); a
  session whose last upload is older than `HEARTBEAT_TIMEOUT` triggers a "monitoring stopped"
  push; resumed uploads clear it. Clock injected.
- [ ] **Step 2: FAIL → Step 3: Implement** append + evaluate-on-append + a heartbeat sweep
  (invoked by a test-callable function; scheduled in prod via the existing job mechanism). →
  **Step 4: PASS → Step 5: Commit.**

### Task 5: iOS `AlertChannelUploader` — upload only while armed + token registration

**Files:** Create `AnxietyWatch/Services/AlertChannelUploader.swift`; register for remote
notifications; modify the CNS arm/disarm flow. Test: `AlertChannelUploaderTests.swift`.

- [ ] **Step 1: Failing test** — the uploader emits samples ONLY while an armed BLE-active session
  is running (not general background); on disarm it stops. The push-token payload is built
  correctly. (Test the gating + payload logic; `URLSession` I/O is thin.)
- [ ] **Step 2: FAIL → Step 3: Implement** (reuse `SyncService` auth; a lightweight append call,
  NOT the bulk sync path). → **Step 4: PASS → Step 5: Commit.**

### Task 6: Channel-health surface (the failure-is-visible requirement)

**Files:** Modify the CNS Monitoring screen (or a Sync/Server settings row) to show last
heartbeat ack + push-permission state. Test: extract the health-status derivation to a helper +
unit-test it.

- [ ] Failing test on the pure health-status derivation (last-ack age + permission → a
  user-facing status string that never reads "OK" when the channel is stale/denied) → implement →
  PASS → commit.

---

## Self-Review checklist

- Spec §3 components → T1 (schema) + T4 (append/backstop/heartbeat) + T2 (backstop) + T3 (APNs) +
  T5 (uploader/token) + T6 (channel health). ✔
- Non-goals honoured: no fusion port (T2 is a fixed-floor check); C only adds alerts (T4 writes
  `alert_event`, never touches on-device state); own-failure visible (T6).
- Gap guard: T2 proves samples bracketing a blackout don't false-trigger (the on-device
  invariant, mirrored server-side).

## Execution handoff

Subagent-driven recommended. Build order is **A → B → C** — C is the last, redundant layer and
depends on A only for the shared Critical Alerts entitlement (it ships Time-Sensitive first). No
`CNSRisk/` changes here, so the CNS reviewers aren't mandatory, but a `silent-failure-hunter`
pass on the server error paths is worthwhile.
