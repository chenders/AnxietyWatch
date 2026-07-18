# HealthKit Access Diagnostic — Design

**Date:** 2026-07-18
**Status:** Approved (pending spec review)
**Branch:** `feat/healthkit-access-diagnostic`

## Problem

When HealthKit read authorization is not in the `.unnecessary` request state (a
fresh install, a bundle-ID rename, an entitlement change forcing re-provision, or
grants toggled off), every data-ingestion path silently reads nothing:

- `SnapshotAggregator.aggregateDay` gates on `authorizationNeedsRequest()` and, when
  it returns `true`, takes the **reduced pass** — skipping every HealthKit read.
- `backfillIfNeeded` and `mirrorHealthKitSamples` gate the same way.
- **Rebuild All History** is just `aggregateDay` in a loop, so it inherits the gate
  and "rebuilds" every day without reading HealthKit — fast, and useless.

The failure is invisible. iOS Settings shows *"Health Data — On"* (which only means
the app appears in Health's list, not that reads succeed), the Trends charts say
*"No data for this period,"* and Rebuild appears to run. This silent freeze has hit
production twice (2026-07-13, 2026-07-18), each time triggered by bundle-ID /
entitlement churn resetting grants. The tell was that Rebuild ran at ~100 days/5s
(reduced pass, no I/O) instead of ~5s/day (full pass hitting HealthKit).

The app already holds every piece of state needed to detect this. It just never
surfaces it.

## Goal

Make the invisible auth/read failure **visible** and **one-tap recoverable**,
without crying wolf on a store that is legitimately empty.

## Non-goals (YAGNI)

- No automatic re-granting — iOS forbids forcing read grants.
- No per-type grant introspection — iOS deliberately hides read denials
  (`authorizationStatus` returns `.notDetermined` even when denied). We use a
  presence *probe*, not an authorization query, to infer whether reads work.
- No new persistence. The diagnostic is computed on demand.

## Core: pure evaluator

The heart of the feature is a pure, HealthKit-free, SwiftData-free function —
trivially and exhaustively unit-testable.

```swift
enum HealthKitAccessState: Sendable, Equatable {
    case receiving      // reads are returning data — all good
    case notRequested   // auth gate says "pending" — reads will fail (THE incident)
    case likelyRevoked  // reads empty across the board, but we HAD recent data → grants dropped
    case noDataYet      // reads empty and we never had data → new/empty store, do NOT alarm
}

func evaluateHealthKitAccess(
    needsRequest: Bool,
    probeReturnedValue: Bool,
    hadRecentHistory: Bool
) -> HealthKitAccessState {
    if needsRequest       { return .notRequested }
    if probeReturnedValue { return .receiving }
    if hadRecentHistory   { return .likelyRevoked }
    return .noDataYet
}
```

`hadRecentHistory` is what separates a revoke-mid-use freeze from a brand-new empty
store — it kills the false positive.

## Probe (async runner)

`HealthKitAccessDiagnostic.run(...)` composes the evaluator over live inputs, using
the injectable `HealthKitDataSource` protocol (so it is fully mockable):

- `needsRequest = await source.authorizationNeedsRequest()`
- `probeReturnedValue` — true if **any** of these over a **rolling ~72h window**
  (not just today, to avoid early-morning "data hasn't landed yet" flakiness):
  - cumulative `stepCount` > 0  (steps come from the iPhone pedometer too, so this
    is present for anyone carrying their phone — the strongest single signal)
  - average `restingHeartRate` non-nil
  - `querySleepAnalysis` total asleep > 0
- `hadRecentHistory` — computed by a small `HealthKitHistoryProbe` helper that counts
  `HealthSnapshot` rows in the last 30 days with **any non-nil HealthKit-derived
  field** (e.g. `restingHeartRate`, `steps`, `sleepDurationMin`). Passed into the
  evaluator so the pure core stays dependency-free.

The banner-critical `.notRequested` verdict depends **only** on the auth gate, not
the probe, so it is robust regardless of probe-window nuances.

## Surfaces

1. **Settings → Apple Health** (`AppleHealthSettingsView`) — upgrade the blind
   "Request Access" button into a status panel:
   - Access state row (e.g. "Receiving data" / "Access not granted" / "Not receiving
     data — access may have been revoked").
   - Per-probe readout: `Steps ✓ · Resting HR — · Sleep ✓` (factual, developer-facing,
     no judgment → no false-positive risk).
   - The existing in-app re-request button (calls `requestAuthorization()`).
   - A deep link to iOS Settings (`UIApplication.openSettingsURLString`) for the
     revoked case, where re-toggling in Health is the real fix.

2. **Dashboard banner** (`HealthKitAccessBanner`, new) — a dedicated, dismissible
   banner **separate from the physiological `AlertsStrip`** (whose categories are
   autonomic/sleep/environment — a plumbing failure is not a physiological signal).
   - Fires **only** for `.notRequested` (per approved decision — zero false-positive
     risk; would have caught both prior incidents).
   - Tap → navigates to the Apple Health panel.
   - Computed inside a child view with its own `@State` + `.task`, so observation is
     scoped and does not register at WindowGroup scope (the documented
     `@Observable`-at-App-scope render-loop pitfall).

## Testing

Swift Testing (`@Test`), reusing `MockHealthKitDataSource` and an in-memory
`ModelContainer`:

- **Evaluator truth table** — all four states plus precedence ordering
  (`needsRequest` wins over a positive probe; `probeReturnedValue` wins over history).
- **Runner** — `.notRequested` when the gate is true (even if probe data is present);
  `.receiving` when steps present; `.likelyRevoked` when all probes empty + history
  present; `.noDataYet` when all probes empty + no history.
- **History helper** — with seeded `HealthSnapshot` rows: non-nil recent field →
  `true`; all-nil / older-than-30-days → `false`.

## Files

- **New** `AnxietyWatch/Services/HealthKitAccessDiagnostic.swift` — enum, pure
  `evaluateHealthKitAccess`, async runner, `HealthKitHistoryProbe` helper.
- **Modify** `AnxietyWatch/Views/Settings/AppleHealthSettingsView.swift` — status panel.
- **New** `AnxietyWatch/Views/Dashboard/HealthKitAccessBanner.swift` — banner view.
- **Modify** `AnxietyWatch/Views/Dashboard/DashboardView.swift` — insert banner.
- **New** `AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift` — coverage above.

## Review gates

- `swift-pre-pr-reviewer` before push (mandatory per CLAUDE.md).
- `swiftui-render-pitfall-detector` (touches Dashboard view + a `.task`-driven child).
