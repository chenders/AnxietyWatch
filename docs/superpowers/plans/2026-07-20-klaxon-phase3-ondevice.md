# Klaxon Phase 3 (On-Device) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-07-20-klaxon-phase3-ondevice-design.md`
**Parent:** `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` (§14.5, §15.13)

**Goal:** Make the CNS-depression klaxon sound loudly through silent/Focus while locked
(Critical Alerts, watch-haptic-first) and survive iOS suspension (CoreBluetooth state
restoration driving the CNS pipeline).

**Architecture:** Two independent on-device mechanisms — (1) a pure `CNSAlarmChannelPolicy`
deciding which alert channels fire for a given tier + permission state, driven by
`CNSAlarmPresenter`; (2) a `CBCentralManager` with a restore identifier that relaunches the app
into the background on BLE sample delivery, routing each restored sample through
`CNSDetectionPipeline`. The dead-man's-switch watchdog (already shipped) upgrades to a Critical
Alert.

**Tech Stack:** Swift 5.9+, SwiftUI, `UserNotifications` (Critical Alerts), CoreBluetooth (state
preservation/restoration), WatchConnectivity (haptics), `AVAudioSession` (foreground audio),
Swift Testing.

## Global Constraints

- **HealthKit is source of truth; app never writes to it.** (This feature reads BLE + notifies;
  no HealthKit writes.)
- **All new/changed code must include tests** (Swift Testing `@Test`/`#expect`; in-memory
  `ModelContainer`; fixed reference dates, never `Date.now` in assertions). Zero compiler
  warnings (CI `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`), zero SwiftLint violations (150 warn / 200
  error line length).
- **Every tunable constant lives in `CNSThresholds`/`CNSMonitoringConstants`** — never re-type a
  literal.
- **CNS core invariants (parent §5, CLAUDE.md):** asymmetry (indeterminate ≠ safe ≠ dangerous);
  escalation past watch AND clearing require primary-informed (SpO₂/resp) evidence; invalid/
  missing data holds the tier; **never a silent stop.** `medical-data-accuracy-reviewer` is
  REQUIRED on every PR touching `Services/CNSRisk/`, plus `swift-pre-pr-reviewer`.
- **Fail-safe bias:** any permission/entitlement/Bluetooth-unavailable path degrades to a
  *louder-fallback* (watch haptics + Time-Sensitive + in-app), never to no alarm.
- Use single-clause `@Query`/`#Predicate`; `Calendar`-based date math; `nonisolated` for
  Sendable statics accessed off the main actor.

---

## File Structure

- Create `AnxietyWatch/Services/CNSRisk/CNSAlarmChannelPolicy.swift` — pure channel-decision.
- Create `AnxietyWatch/Services/CNSRisk/CNSAlarmPresenter.swift` — side-effecting presenter.
- Create `AnxietyWatch/Services/CNSRisk/CNSCriticalAlertPermission.swift` — permission request/observe.
- Modify `AnxietyWatch/Services/CNSMonitoringCoordinator.swift` — call the presenter on klaxon;
  wire CB-restored samples; upgrade watchdog notification.
- Modify `AnxietyWatch/Services/CNSRisk/CNSThresholds.swift` / `CNSMonitoringConstants.swift` —
  alone-mode fast-escalation sustains, Critical sound name.
- Modify `AnxietyWatch/Services/EMAYRealtimeService.swift` / `PolarHRMService.swift` — expose the
  restored-session sample stream to the coordinator.
- Modify `AnxietyWatch/Views/Settings/CNSMonitoringView.swift` — Phase-3 redesign.
- Modify the app entitlements + `Info.plist` — Critical Alerts capability.
- Tests: `AnxietyWatchTests/CNSAlarmChannelPolicyTests.swift`,
  `CNSCriticalAlertPermissionTests.swift`, extend `CNSAlertTierMachineTests.swift`.

---

### Task 1: `CNSAlarmChannelPolicy` — pure channel decision (A1)

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSAlarmChannelPolicy.swift`
- Test: `AnxietyWatchTests/CNSAlarmChannelPolicyTests.swift`

**Interfaces:**
- Produces: `enum CNSAlarmChannel { case watchHaptic, criticalNotification, timeSensitiveNotification, foregroundAudio, inAppBanner }`
  and `struct CNSAlarmChannelPolicy { static func channels(tier: CNSAlertTier, criticalGranted: Bool, timeSensitiveGranted: Bool, appActive: Bool) -> Set<CNSAlarmChannel> }`

- [ ] **Step 1: Write the failing test** — a klaxon tier with Critical granted fires the critical
  notification + watch haptic; with Critical denied but Time-Sensitive granted, it falls back to
  Time-Sensitive + watch haptic (never empty); a non-klaxon tier (clear/watch) fires nothing.

```swift
import Testing
@testable import AnxietyWatch

struct CNSAlarmChannelPolicyTests {
    @Test("Klaxon with Critical granted uses the critical channel + haptics")
    func klaxonCritical() {
        let ch = CNSAlarmChannelPolicy.channels(tier: .klaxon, criticalGranted: true,
                                                timeSensitiveGranted: true, appActive: false)
        #expect(ch.contains(.criticalNotification))
        #expect(ch.contains(.watchHaptic))
        #expect(!ch.contains(.timeSensitiveNotification)) // don't double-fire
    }

    @Test("Klaxon with Critical denied falls back to Time-Sensitive, never silent")
    func klaxonFallback() {
        let ch = CNSAlarmChannelPolicy.channels(tier: .klaxon, criticalGranted: false,
                                                timeSensitiveGranted: true, appActive: false)
        #expect(ch.contains(.timeSensitiveNotification))
        #expect(ch.contains(.watchHaptic))
        #expect(!ch.isEmpty)
    }

    @Test("Below-klaxon tiers fire no alarm channel")
    func belowKlaxonSilent() {
        for t in [CNSAlertTier.clear, .watch, .confirm] {
            #expect(CNSAlarmChannelPolicy.channels(tier: t, criticalGranted: true,
                                                   timeSensitiveGranted: true, appActive: false).isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run it — expect FAIL** (`CNSAlarmChannelPolicy` undefined).
  `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSAlarmChannelPolicyTests`
- [ ] **Step 3: Implement the minimal pure type.** Klaxon → prefer `.criticalNotification` when
  granted else `.timeSensitiveNotification`; always add `.watchHaptic`; add `.foregroundAudio`
  when `appActive`; add `.inAppBanner` when `appActive`. Below `.klaxon` → empty set. Confirm
  tier may fire watch haptic only if the design later opts in (default: empty).
- [ ] **Step 4: Run tests — expect PASS.**
- [ ] **Step 5: Commit.** `git add … && git commit -m "feat(cns): pure alarm-channel policy"`

### Task 2: `CNSCriticalAlertPermission` — request/observe (A1)

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSCriticalAlertPermission.swift`
- Test: `AnxietyWatchTests/CNSCriticalAlertPermissionTests.swift`

**Interfaces:**
- Produces: `enum CNSNotifyPermission { case criticalGranted, timeSensitiveOnly, standardOnly, denied }`
  and a pure `static func map(_ settings: UNNotificationSettings) -> CNSNotifyPermission` plus an
  `actor`/`@MainActor` wrapper `requestIfNeeded()` calling
  `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound, .criticalAlert])`.

- [ ] **Step 1: Failing test** — the pure `map` returns `.criticalGranted` when
  `criticalAlertSetting == .enabled`, `.timeSensitiveOnly` when only time-sensitive is enabled,
  `.denied` when authorizationStatus is `.denied`. (Construct settings via a small injectable
  struct mirroring the fields, since `UNNotificationSettings` isn't directly constructable —
  define `protocol NotificationSettingsShape { var authorizationStatus … }` and map that.)
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** the shape protocol + pure `map`; the request wrapper is thin I/O.
- [ ] **Step 4: PASS.**
- [ ] **Step 5: Commit.**

### Task 3: Critical Alerts entitlement + Info.plist + request wiring (A1)

**Files:**
- Modify: app `.entitlements` (add `com.apple.developer.usernotifications.critical-alerts`),
  request at the existing auth point.

- [ ] **Step 1:** Add the entitlement key (value `true`) to the app target's entitlements.
- [ ] **Step 2:** Call `CNSCriticalAlertPermission.requestIfNeeded()` from the CNS-arm flow (not
  app launch — request only when the user arms monitoring, so the OS prompt has context).
- [ ] **Step 3:** Build clean (entitlement present; if the provisioning profile lacks Apple's
  grant yet, the request simply returns without `.criticalAlert` — handle gracefully). Commit.
  *(No test — this is capability config; Task 1/2 cover the behaviour under each permission state.)*
- **Note:** Submit the Critical Alerts entitlement request to Apple in parallel (health/safety
  justification). The build ships watch-first without it (Task 4/5).

### Task 4: `CNSAlarmPresenter` — fire the decided channels (A1)

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSAlarmPresenter.swift`
- Test: `AnxietyWatchTests/CNSAlarmPresenterTests.swift`

**Interfaces:**
- Consumes: `CNSAlarmChannelPolicy`, `CNSNotifyPermission`.
- Produces: `struct CNSAlarmPresenter { init(notify: NotificationPosting, haptic: WatchHapticSending, audio: AlarmAudioPlaying); func present(tier:permission:appActive:) }`
  — inject the three side-effect sinks as protocols so the presenter is testable.

- [ ] **Step 1: Failing test** — with a spy `NotificationPosting`/`WatchHapticSending`/
  `AlarmAudioPlaying`, `present(tier: .klaxon, permission: .criticalGranted, appActive: false)`
  posts exactly one critical notification (assert interruption level `.critical` + sound dict)
  and one watch haptic; `.timeSensitiveOnly` posts a time-sensitive notification instead.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — map policy channels to sink calls; build the `UNNotificationContent`
  with `interruptionLevel = .critical` and `sound = .defaultCriticalSound(withAudioVolume:)`.
- [ ] **Step 4: PASS.**
- [ ] **Step 5: Commit.**

### Task 5: Watch haptics via WatchConnectivity (A1)

**Files:**
- Modify: `PhoneConnectivityManager` (phone) + `WatchConnectivityManager` (watch) to send/receive
  a klaxon-haptic message; play `WKInterfaceDevice.current().play(.failure)` (repeated) on watch.
- Test: the phone-side message-construction is a pure function → test the payload; the watch
  playback is hardware (documented manual test).

- [ ] Steps: failing test on the phone-side klaxon-message payload → implement → PASS → commit.
  Note the watch-hardware playback as a manual device test in the commit body.

### Task 6: CoreBluetooth state restoration → CNS pipeline (A2)

**Files:**
- Modify: `EMAYRealtimeService.swift` / `PolarHRMService.swift` (they already set a
  `CBCentralManagerOptionRestoreIdentifierKey`; expose a restored-sample callback) and
  `CNSMonitoringcoordinator.swift` (subscribe, run `CNSDetectionPipeline.process` per restored
  sample even while backgrounded).

- [ ] **Step 1: Failing test** — a unit test asserting the *wiring*: given a restored sample
  delivered to the coordinator's `handleRestoredSample(_:)`, it calls
  `CNSDetectionPipeline.process` and updates the tier (inject a spy pipeline). Per the parent's
  "assert on the inputs" discipline (CB restoration itself is un-simulatable).
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** `handleRestoredSample`; implement `centralManager(_:willRestoreState:)`
  in the sensor service to re-attach the peripheral and forward samples to the coordinator.
- [ ] **Step 4: PASS** (the wiring unit). Add a documented manual device test (background app,
  reconnect sensor, confirm alarm) to the PR body.
- [ ] **Step 5: Commit.**

### Task 7: Watchdog → Critical Alert (A2)

**Files:** Modify the dead-man's-switch scheduling in `CNSMonitoringCoordinator` to post the
watchdog notification via `CNSAlarmPresenter`'s critical path (respecting permission fallback).

- [ ] Failing test: watchdog fire → presenter invoked with the "monitoring stopped" content at
  the highest available interruption level. Implement → PASS → commit.

### Task 8: Confirmation tier + alone-mode fast escalation (A3)

**Files:** Modify `CNSAlertTierMachine.swift` + `CNSThresholds.swift` (add
`aloneModeRiseSustainSeconds` shorter than `riseSustainSeconds`); extend
`CNSAlertTierMachineTests.swift`.

- [ ] **Step 1: Failing test** — with `companionPresent == false`, the rise-sustain to reach the
  confirm/klaxon tier uses the shorter alone-mode sustain (escalates sooner) than with a
  companion present. (Currently only the threshold-delta half of alone-mode is wired, parent
  §14.4.)
- [ ] **Step 2: FAIL → Step 3: Implement** `sustainSeconds(toEnter:)` to consult
  `companionPresent`. → **Step 4: PASS → Step 5: Commit.**
- **REQUIRED reviewers on this task:** `medical-data-accuracy-reviewer` + `swift-pre-pr-reviewer`
  (it changes escalation timing).

### [x] Task 9: CNS Monitoring screen redesign (A3)

**Files:** Modify `AnxietyWatch/Views/Settings/CNSMonitoringView.swift`.

- [x] Extract any pure derivation (permission-status label, alarm-state subtitle) to a helper +
  test it (parent: >5 lines of body derivation → extract + cover). Add: live tier + alarm state,
  slide-to-acknowledge, permission status + re-request button, the force-quit/reboot disclosure
  copy. Commit. (View layout is manual/snapshot; the extracted helpers are unit-tested.)

---

## Self-Review checklist (run before handing off)

- Every spec §4 component maps to a task (policy→T1, permission→T2/T3, presenter→T4, haptics→T5,
  CB restoration→T6, watchdog→T7, confirmation/alone-mode→T8, UI→T9). ✔
- No placeholders; pure-logic tasks show real test code; integration tasks specify the wiring
  assertion + a documented manual device test.
- Types consistent: `CNSAlarmChannel`, `CNSNotifyPermission`, `CNSAlarmChannelPolicy.channels(...)`,
  `CNSAlarmPresenter.present(...)` used identically across tasks.
- Fail-safe: T1/T4 prove the denied-permission path is never empty.

## Execution handoff

Subagent-driven recommended (fresh subagent per task + two-stage review). Dispatch
`medical-data-accuracy-reviewer` + `swift-pre-pr-reviewer` after any task touching
`Services/CNSRisk/` (all of T1–T8).

## Implementation notes (post-merge)

- **Alone-Mode Timings (Task 8)**: Implemented `aloneModeRiseSustainSeconds` (45s) and `aloneModeKlaxonRiseSustainSeconds` (15s) in `CNSThresholds.swift` and wired to `CNSAlertTierMachine.swift`. Defaulted `companionPresent` to `true` in `CNSAlertTierMachineTests.machine()` factory to keep existing tests green.
- **Background Wake (Tasks 6-7)**: Handled CoreBluetooth state restoration via `@UIApplicationDelegateAdaptor(AppDelegate.self)` instead of attempting pure SwiftUI lifecycle background tasks.
- **UI Redesign (Task 9)**: Extracted pure view logic to `CNSMonitoringViewHelpers.swift` and added tests. Implemented `SlideToAcknowledgeView` with a drag gesture.
