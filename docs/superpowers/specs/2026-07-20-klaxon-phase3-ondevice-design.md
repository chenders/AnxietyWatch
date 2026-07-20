# CNS Klaxon Phase 3 (On-Device) — Robust Background Monitoring & Loud Alerting

**Status:** Design (approved architecture, 2026-07-20). Sub-project **A** of the CNS-klaxon
program (A = this doc, B = AS11 context feed, C = server redundant alert channel).

**Parent design:** `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md`
(authoritative; §14.5 alarm mechanism, §15.13 Phase-3 scope).

**Research grounding:** `Keeping a Real-Time Health Feed Alive on a Backgrounded iOS App-
What Actually Works.md` (repo root) — the practitioner-converged architecture: for a **local
BLE sensor** the primary near-real-time path is **direct BLE + CoreBluetooth state restoration
computing alerts on-device** (the Dexcom model), with server push as a *redundant* channel
(sub-project C). A live socket/tick loop cannot survive iOS suspension; do not rely on one.

---

## 1. Problem

Phase 2 shipped the detection pipeline (`CNSDetectionPipeline` → `CNSAlertTierMachine`) and a
1 Hz `Task.sleep` tick loop in `CNSMonitoringCoordinator`, plus a **dead-man's-switch
watchdog** (`CNSMonitoringConstants.deadMansSwitchInterval`, 90 s) that reschedules a local
notification each persist tick. But (parent §15.13):

- The tick loop has **no background-execution guarantee.** iOS suspends the app seconds after
  the screen locks. When it does, the loop stops: no sensor polling, no device-loss detection,
  no tier updates, and none of the "never a silent stop" notifications fire — because all of
  that logic only runs *inside a tick*. The watchdog bounds the **detection-latency** of that
  silent stop to ~90 s; it does **not** keep monitoring alive.
- The alarm today is a **standard** local notification. It respects the mute switch and Focus,
  so it cannot be a klaxon-through-silent while the phone is locked.

This is the exact scenario the feature exists to catch (the "EMAY battery dies at 3 a.m." /
overnight-desaturation case), and today it fails the way the feature is meant to prevent —
silently, once the phone suspends.

## 2. Goal

Make the klaxon **survive suspension** and **sound loudly through silent/Focus while locked**,
on-device, with no dependency on a cloud round-trip for the alert decision (parent §1
hard-non-goal: local alarm only; C is redundancy, never the primary decision path).

## 3. Architecture (research-validated)

Two independent mechanisms, both on-device:

1. **Survive suspension → BLE-event-driven monitoring via CoreBluetooth state restoration.**
   The CNS pipeline stops being driven by a wall-clock tick and becomes driven by **BLE sample
   arrival**. iOS relaunches a force-quit-or-suspended app *into the background* to deliver
   Core Bluetooth events for a central manager that opted into state preservation/restoration
   (`CBCentralManagerOptionRestoreIdentifierKey`). Each restored SpO₂/HR sample runs
   `CNSDetectionPipeline.process(...)` + tier evaluation + the alarm decision — so monitoring
   continues across suspension for as long as a sensor is connected and delivering.
   `EMAYRealtimeService` and `PolarHRMService` already use CB restoration for **reconnect**;
   Phase 3 makes the **CNS pipeline itself** a consumer of those restored-session sample
   events (parent §15.13 names this as the Phase-3 mechanism).

2. **Sound through silent/locked → Critical Alerts.** The klaxon / device-loss / watchdog
   notifications upgrade from standard to **Critical Alert** (`UNNotificationInterruptionLevel
   .critical` + a `critical` sound payload at a system-controlled volume), the *only* iOS
   mechanism that bypasses the ringer/mute switch **and** Focus/DND while locked/suspended
   (parent §14.5). This needs the `com.apple.developer.usernotifications.critical-alerts`
   entitlement (manual Apple approval, feasible for a personal/dev-profile health app) **plus**
   the runtime `UNAuthorizationOptions.criticalAlert` grant.

**Not blocked on Apple's approval** (parent §14.5 decision): the feature ships
**watch-haptic-first** — on-wrist haptics need no entitlement and are always felt — plus
foreground `AVAudioSession.playback` audio; the **phone-klaxon-through-silent/locked upgrade
activates once the entitlement + runtime permission are granted.** The alarm layer must handle
"critical permission off" gracefully, falling back to **Time-Sensitive** (breaks Focus, respects
mute, no entitlement) + watch haptics + in-app banner.

**Documented limitation (as Dexcom does):** state restoration relaunches the app after *system*
termination, but **a user force-quit from the app switcher blocks it**, and a device reboot
suspends it until first unlock. The CNS Monitoring screen must state this plainly; it is a
disclosure, not a bug.

## 4. Components

| Unit | Responsibility | Depends on |
|------|----------------|-----------|
| `CNSBluetoothRestoration` (or extension of the sensor services) | Own a `CBCentralManager` with a restore identifier; on `willRestoreState`, re-attach the monitored peripheral and route its delivered samples into the CNS pipeline while backgrounded. | CoreBluetooth; `CNSMonitoringCoordinator` |
| `CNSAlarmPresenter` | **Pure decision** of *which* channels fire for the current (tier, permission-state, companion-present) — then side-effects: schedule Critical/Time-Sensitive `UNNotification`, trigger watch haptics, start foreground `.playback` audio. | `CNSAlarmChannelPolicy` (pure); `UNUserNotificationCenter`; WatchConnectivity |
| `CNSAlarmChannelPolicy` (pure value type) | Given `(tier, criticalGranted, timeSensitiveGranted, companionPresent)` → the ordered set of channels to fire. Unit-tested exhaustively; no I/O. | — |
| `CNSCriticalAlertPermission` | Request/observe `.criticalAlert` + `.timeSensitive` authorization; expose status to UI; never assume granted. | `UNUserNotificationCenter` |
| CNS Monitoring screen (Phase-3 redesign) | Live tier + alarm state, **slide-to-acknowledge/dismiss**, permission status + re-request, the force-quit/reboot disclosure. | `CNSMonitoringCoordinator`; `CNSCriticalAlertPermission` |
| Confirmation tier + alone-mode fast escalation | Deferred from Phase 2 (parent §14.4, §15.11/§15.16): the `clear→watch→confirm→klaxon` machine exists; wire the **shorter alone-mode sustains** so an unaccompanied user escalates faster. | `CNSAlertTierMachine`; `CNSThresholds` |

## 5. Data flow

```
BLE sample (foreground OR state-restored background)
  → sensor service delivers to CNSMonitoringCoordinator
  → CNSDetectionPipeline.process(samples, baselines, as11State, at:)
  → CNSAlertTierMachine.ingest → tier
  → if tier rose to .klaxon (or a device-loss classification demands it):
       CNSAlarmPresenter.present(tier, permission, companion)
         → CNSAlarmChannelPolicy decides channels
         → watch haptics + Critical/Time-Sensitive notification + foreground audio
  → persist tick reschedules the dead-man's-switch watchdog (existing)
```

On tick-loop death (suspension the restoration path did not cover, e.g. no BLE sensor
connected), the **watchdog** fires — now as a **Critical Alert** — telling the user monitoring
may have stopped. The watchdog remains the backstop; state restoration removes the common case
(a connected sensor) from its scope.

## 6. Error handling / fail-safe bias (parent §11, §14.2)

- **Entitlement not granted / permission off** → watch haptics + Time-Sensitive + in-app; the
  UI surfaces the downgrade prominently. Never silently degrade to "no alarm."
- **Permission revoked mid-use** → detected by `CNSCriticalAlertPermission`; surfaced.
- **CB restoration unavailable** (Bluetooth off, no sensor) → fall back to foreground tick +
  watchdog; the watchdog's Critical Alert covers the silent-stop.
- **Force-quit / reboot** → cannot wake; documented to the user, not silently absorbed.
- **Asymmetry preserved:** missing data still holds the tier; only observed, primary-informed
  evidence escalates or clears (unchanged from Phase 2).

## 7. Testing

- `CNSAlarmChannelPolicy` — exhaustive matrix of `(tier × criticalGranted × timeSensitiveGranted
  × companionPresent)` → expected channel set. Pure, deterministic.
- Confirmation-tier + alone-mode sustain math — extend `CNSAlertTierMachineTests` with the
  shorter alone-mode sustains (currently only the threshold-delta half is wired, parent §14.4).
- `CNSCriticalAlertPermission` status mapping — pure mapping of `UNNotificationSettings` →
  the app's permission enum.
- CoreBluetooth state restoration is **integration/manual** (the simulator can't restore a real
  peripheral) — documented device test: background the app, disconnect+reconnect the sensor,
  confirm the pipeline processed the restored sample and the alarm fired. Assert on the *inputs*
  (that the coordinator's restored-sample handler is wired), per the parent's "first-run-only
  paths are untested in production" discipline.

## 8. Phasing within A (each independently shippable)

- **A1 — Loud path (no Apple dependency).** `CNSAlarmChannelPolicy` + `CNSAlarmPresenter` +
  `CNSCriticalAlertPermission` + watch haptics + foreground audio + Time-Sensitive fallback.
  Submit the Critical Alerts entitlement request in parallel; the phone-through-silent upgrade
  lights up when it lands. **Ships the loud alarm immediately, watch-first.**
- **A2 — Background survival.** CB state restoration wired to the CNS pipeline + the watchdog
  upgraded to Critical Alert. **Ships monitoring that survives suspension while a sensor is
  connected.**
- **A3 — Escalation + UI.** Confirmation-tier alone-mode fast escalation + the CNS Monitoring
  screen redesign (slide-to-acknowledge, permission status, force-quit disclosure).

## 9. Dependencies & open items

- **Critical Alerts entitlement** — Apple manual review (days–weeks). Not blocking (A1 ships
  watch-first). Requires a health/safety justification naming the event (opioid/benzo-driven
  respiratory depression), the consequence of a missed alert, and the at-risk user.
- **Parent §15 open question** — `RestoreFromServer.importMedDoses` does not feed the dose-window
  gate, so a server-restored in-window dose does not auto-arm monitoring. Decide in A3 or a
  dedicated fix whether restore should feed the dose gate.
- **Sub-project C (server redundant channel)** is the belt-and-suspenders for the *force-quit /
  no-sensor-connected / app-dead* gaps A cannot cover on-device — but C is **redundant**, never
  the primary decision path (parent §1). A ships first and stands alone.
