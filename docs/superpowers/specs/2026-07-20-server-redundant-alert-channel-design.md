# Server Redundant Alert Channel — Backstop Push, Heartbeat, Status

**Status:** Design (approved architecture, 2026-07-20). Sub-project **C** of the CNS-klaxon
program (A = on-device Phase 3, B = AS11 context feed, C = this doc). **Build A and B first —
C is redundancy, not a prerequisite.**

**Parent design:** `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md`
(§1 hard non-goal: **local alarm only, never external notification** as the *primary* decision
path).

**Research grounding:** `Keeping a Real-Time Health Feed Alive on a Backgrounded iOS App-…md`
(§6 converged architecture: server-side threshold evaluation + high-priority/Critical push as
the **reliability backbone**, **plus a redundant "no-data/heartbeat-lost" alert and a status
signal** so a silent backend failure is itself detectable — the 2019 Dexcom Follow outage
lesson). §3 Owlet model: a dedicated always-on device owns the safety-critical alarm; the phone
push is the *secondary* channel.

---

## 1. Framing (read first — this is the safety boundary)

The klaxon's **primary** alarm is on-device (sub-project A: BLE + CoreBluetooth restoration +
Critical Alerts). The parent design forbids making a cloud round-trip the primary decision path
for this life-safety alarm — and the research's 2019-Dexcom-outage lesson shows exactly why: a
silent server/cloud failure stopped overnight glucose alerts to thousands, with no channel to
announce that the alerting itself was down.

So **C is a redundant, secondary channel**, deliberately scoped as belt-and-suspenders:

1. It only ever *adds* an alert; it can never *suppress* or *replace* the on-device decision.
2. It carries a **simple, conservative backstop** evaluation (not a re-derivation of the full
   on-device fusion engine — porting a life-safety Swift detection engine to Python is a
   correctness hazard we explicitly avoid).
3. Its most important product is the **failure signal**: a server that stops receiving data, or
   whose backstop notices sustained danger, pushes an alert *and* the app/UI exposes channel
   health — so the redundancy's own failure is visible.

This is the Owlet pattern (dedicated device = authoritative alarm; phone push = convenience
mirror) mapped onto our stack: **A/B on-device = authoritative; C server push = mirror + failure
detector.**

## 2. Why a server channel helps at all (given no socket survives suspension)

The phone cannot hold a live feed while suspended (research §1). But **during an active BLE
monitoring session the app is kept alive by `bluetooth-central`**, and in that window it can
**upload** live SpO₂/HR to the server. The server then has data to (a) run a conservative
backstop and (b) detect *no-data* (the feed stopped → the phone may have died / lost the sensor
/ suspended). When the phone is fully dead (force-quit, no sensor, dead battery), the on-device
path (A) cannot fire at all — and this is precisely the gap where a **server-side no-data alert
to a companion or back to the device via push** is the only remaining signal.

## 3. Components

| Unit | Responsibility |
|------|----------------|
| Phone → server **live upload** (during BLE-active sessions) | Stream the same SpO₂/HR the on-device pipeline consumes to the server, tagged with session id + cursor. Reuses `SyncService` auth; a lightweight streaming/append endpoint, not the bulk sync path. |
| Server **backstop evaluator** (simple, conservative) | Sustained SpO₂ below a fixed floor (or respiratory-rate below floor) over a fixed window → raise. Deliberately *simpler and more conservative* than on-device fusion; it is a backstop, not a second opinion that can argue the primary down. |
| Server **APNs push** | High-priority (`priority 10`) alert. Ships **Time-Sensitive** interruption level immediately (breaks Focus, respects mute, **no Apple approval**); upgrades to **Critical Alert** once sub-project A's entitlement is granted (shared entitlement). |
| Server **heartbeat / no-data monitor** | If an armed session's upload stops for longer than a threshold, push a "monitoring may have stopped" alert (mirrors the on-device dead-man's-switch, but survives the phone being dead). |
| **Channel-health / status** surface | The app shows server-channel health (last heartbeat ack, push-permission state); optionally a minimal server status page. So the redundancy's failure is detectable (the 2019 lesson). |
| APNs plumbing | Auth key (`.p8`) config in the server env; per-device token registration from the app. |

## 4. Data flow

```
(BLE-active session)
  phone pipeline sample --upload--> server append endpoint --> session buffer
                                          |
                          ┌───────────────┴────────────────┐
             backstop evaluator                    heartbeat monitor
             (sustained low → raise)               (no upload for N → raise "stopped")
                          │                                 │
                          └─────────── APNs push ───────────┘
              (Time-Sensitive now; Critical once entitlement granted)
                          │
                          v
             phone (backgrounded/locked) OR companion device
```

## 5. Error handling / fail-safe & safety invariants

- **Never suppress.** C cannot cancel or downgrade an on-device alarm; it can only add one. If C
  and A disagree, both fire.
- **Conservative backstop only.** No full fusion port. The backstop uses fixed, defensible floors
  (parent §3 thresholds), not the personalized baseline logic (which stays on-device).
- **Own failure is visible.** No-data heartbeat + channel-health surface = the 2019-Dexcom
  redundancy lesson. A dead server must not read as "all clear."
- **APNs realism (research §6):** high-priority push best-case is sub-second on Wi-Fi, a few
  seconds on cellular, with a multi-minute long tail; silent push is unreliable (~1–2/hr, dropped
  in Low Power Mode / after force-quit) and is **not** used for the alert itself — only, at most,
  as an opportunistic "fetch when you can" nudge. Design to the long tail; C is redundancy, so
  its latency floor is acceptable *because A carries the fast path*.

## 6. Testing

- Backstop evaluator — pure function over an uploaded sample window: sustained-low → raise,
  brief-dip → no raise, gap-in-window → no false raise. Deterministic, table-driven (`pytest`).
- Heartbeat/no-data monitor — clock-injected: upload stops → raise after threshold; resumes →
  clears. No wall-clock in assertions.
- APNs push — mock the APNs client; assert payload shape (interruption level, priority, sound
  dict when Critical) and that a raise produces exactly one push per event (idempotent).
- App: channel-health surfacing; token registration; that the live-upload runs **only** during
  an armed BLE-active session (not general background).

## 7. Explicit non-goals

- **Not** moving the klaxon decision server-side (parent §1; "Option B" was considered and
  rejected — it makes a cloud round-trip the primary path for a life-safety alarm, the exact
  2019-Dexcom failure mode).
- **Not** re-implementing `CNSFusionEngine`/`CNSAlertTierMachine` in Python.
- **Not** a general background real-time feed (impossible on iOS; research §1).

## 8. Dependencies

- **A** (Critical Alerts entitlement is shared; C ships Time-Sensitive first, upgrades when A's
  entitlement lands).
- **B** is independent (B feeds AS11 context to the *on-device* pipeline; C uploads the
  pipeline's SpO₂/HR to the server). C works with EMAY/Polar alone; AS11 is not required.
- Build order: **A → B → C.** C is the last, redundant layer.
