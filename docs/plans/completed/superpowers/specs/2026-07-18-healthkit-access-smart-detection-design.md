# HealthKit Access Smart-Detection — Design

**Date:** 2026-07-18
**Status:** Approved (pending spec review)
**Builds on:** `feat/healthkit-access-diagnostic` (#21) — the base `HealthKitAccessDiagnostic`.

## Problem

The base diagnostic infers "not receiving HealthKit data" from three signals:
never-requested auth (`.notRequested`, firm), a presence probe (`.receiving`), and
`hadRecentHistory` for the ambiguous empty case (`.likelyRevoked`). Two gaps:

1. **`hadRecentHistory` is self-referential** — it reads the app's own stored snapshots.
   It cannot, on its own, distinguish "grants revoked" from "the user simply has no
   recent data," so `.likelyRevoked` is confined to the Settings panel and never drives
   the banner. The revoked case — access granted, then lost — is therefore not surfaced
   proactively.
2. **No external corroboration or timing guard** — nothing checks whether data *should*
   exist (a paired Watch), and nothing suppresses a premature verdict right after a grant
   or on a brand-new install.

Verified separately (`docs/research/healthkit-read-permission-detection.md`): there is no
API — public or private-without-entitlement — to read the grant deterministically, so a
*stronger heuristic* is the ceiling.

## Goal

Make `.likelyRevoked` confident enough to drive a proactive (soft-copy) banner, by adding
an external corroborating signal and a timing guard — without raising false alarms.

## Design

### Evaluator (pure, tested core)

Extend the pure classifier with two inputs:

```swift
func evaluateHealthKitAccess(
    needsRequest: Bool,
    probeReturnedValue: Bool,
    hadRecentHistory: Bool,
    watchPaired: Bool,     // NEW — external: a paired Watch means data should exist
    graceElapsed: Bool     // NEW — timing guard: enough time since first authorized
) -> HealthKitAccessState {
    if needsRequest { return .notRequested }
    if probeReturnedValue { return .receiving }
    // Strong, all-of gate — any missing condition falls through to the safe .noDataYet.
    if hadRecentHistory && watchPaired && graceElapsed { return .likelyRevoked }
    return .noDataYet
}
```

(`.unavailable` continues to be resolved before this, in the runner, via
`isHealthDataAvailable()`.)

The all-of gate is deliberate: a `.likelyRevoked` verdict now requires an anomalous
conjunction — a paired Watch, prior real data, ≥48h since first authorization, and zero
reads across a 14-day window — which is very unlikely to occur unless access was actually
lost. Any weaker state degrades to `.noDataYet` (no alarm).

### New signals

- **`watchPaired`** — `WCSession.default.isPaired` (iOS side), read through the existing
  `PhoneConnectivityManager`. On a watch-less iPhone this is `false`, so `.likelyRevoked`
  can never fire there — the banner won't cry wolf on users who have no Watch to produce
  data. (watchOS/iPad have no bearing; the banner lives on the iOS Dashboard.)
- **`graceElapsed`** — a persisted `healthKitFirstAuthorizedAt` timestamp, stamped the
  first time `authorizationNeedsRequest()` is observed `false`, in the app-group
  `UserDefaults`. `graceElapsed = now − firstAuthorized ≥ 48h`. This suppresses the
  post-grant "data hasn't synced yet" window. Conservative side effect: for an
  already-authorized install, the timestamp is set on first run after this ships, so the
  smart banner stays dormant for its first 48h — acceptable. The grace logic is a pure
  helper (`HealthKitGraceGate`) so it is unit-testable with injected dates.

### Probe

Widen the presence probe window 72h → **14 days**, and add `.heartRate` (continuous on a
worn Watch — the strongest "data should exist" signal) to the existing
steps/restingHeartRate/sleep set. Any one non-empty ⇒ `probeReturnedValue`.

### Coordinator + surfacing

The banner now needs the *full* state (to react to `.likelyRevoked`), not just the cheap
auth-gate check. Introduce a small `HealthKitAccessProbe` coordinator that gathers all
inputs — `hadRecentHistory` (SwiftData fetch), `watchPaired` (WCSession), `graceElapsed`
(timestamp), and the HK presence probe — and returns the `HealthKitAccessDiagnostic.Result`.
Both surfaces consume it:

- **`HealthKitAccessState.showsDashboardBanner`** → `self == .notRequested || self == .likelyRevoked`.
- **`HealthKitAccessBanner`** — copy varies by state: `.notRequested` keeps the firm
  "Apple Health isn't connected"; `.likelyRevoked` uses soft, hypothesis-framed copy
  ("We're not seeing your health data — check permissions"). Tap → for `.notRequested`,
  request auth in place (existing); for `.likelyRevoked`, requesting is a no-op (already
  answered), so route to the Settings/Health recovery path instead. Still runs in its own
  `.task` (+ scenePhase), scoped as before. It runs the coordinator (which probes on the
  authorized path); this adds a bounded set of HK reads on Dashboard appear — acceptable
  (appear + foreground, not per-render).
- **`AppleHealthSettingsView`** — unchanged behavior, now sourced from the coordinator;
  `.likelyRevoked` already renders its hedged detail.

### Testing

- Extend the evaluator truth table for `watchPaired` × `graceElapsed` combinations:
  `.likelyRevoked` only when all-of holds; each missing condition → `.noDataYet`.
- `showsDashboardBanner` true for `.notRequested` and `.likelyRevoked`, false otherwise.
- `HealthKitGraceGate` boundary tests (just-under vs just-over 48h) with injected dates.
- Runner test: `watchPaired`/`graceElapsed` threaded through `run()` produce the expected
  state given probe/history fixtures (via `MockHealthKitDataSource` + injected inputs).

## Non-goals

- No `x-apple-health://` deep-link change (separate, optional follow-up).
- No caching of a "revoked" verdict — re-evaluated on appear / foreground, never persisted.
- No attempt to read the grant deterministically (proven impossible for a normal app).

## Git / sequencing

- New branch `feat/healthkit-access-smart-detection` off `#21`.
- The uncommitted DEBUG research probes + `docs/research/…` are moved to their own
  `research/…` branch (or committed) first, so this branch starts clean.
- `swift-pre-pr-reviewer` + `swiftui-render-pitfall-detector` before push (touches the
  Dashboard banner + a `.task`).
