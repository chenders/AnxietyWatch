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

### Why read grant/denial cannot be detected (verified 2026-07-18)

This was checked against ground truth before settling on a heuristic, so nobody
re-investigates:

- **The SDK API has no representation for it.** In the iOS 26.5 HealthKit
  headers, `authorizationStatusForType:` returns `HKAuthorizationStatus`, whose
  only non-`notDetermined` cases are `sharingDenied` / `sharingAuthorized` —
  both defined purely in terms of *save* (write). There is no `read`-grant case,
  so for a read type the method can only ever return `.notDetermined`. The
  absence is structural, not just a runtime redaction. The one read-relevant
  API, `getRequestStatusForAuthorization` → `HKAuthorizationRequestStatus`
  (`.shouldRequest` / `.unnecessary`), reports only *asked-vs-never-asked*;
  `.unnecessary` conflates granted and denied. That is exactly (and only) what
  `authorizationNeedsRequest()` uses.
- **The open-source ecosystem confirms it.** Every surveyed wrapper hits the
  same wall — react-native-health's own docs state "There is no way to check
  authorization status for read permission"; Flutter `health` returns `null`
  for read on iOS by design; Capacitor exposes only write ("edition") status.
  (The `read: [1,1]` in react-native-health#342 is `sharingDenied` write status
  mislabeled as read — a red herring.)
- **The only technique with real signal is one-directional.** Reading a sample
  from a *foreign source* (not written by this app) proves read is granted;
  absence is ambiguous (denied vs genuinely empty). Because this app is
  read-only (Design Principle #1), *every* sample it can read is foreign-source
  (the Apple Watch's own HR/sleep/step writes), so "any successful read ⇒
  granted" is the strongest form of that technique — and it needs no sentinel
  write. A cross-process written sentinel can't improve on this: an app
  extension shares the parent's HealthKit authorization
  (`handleAuthorizationForExtension…` authorizes "the app and its extensions"),
  and a genuinely separate app is disproportionate. Hence the probe +
  `hadRecentHistory` heuristic is the best available design.

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

2. **Dashboard banner** (`HealthKitAccessBanner`, new) — a dedicated banner
   **separate from the physiological `AlertsStrip`** (whose categories are
   autonomic/sleep/environment — a plumbing failure is not a physiological signal).
   - Fires **only** for `.notRequested` (per approved decision — zero false-positive
     risk; would have caught both prior incidents).
   - Tap → presents the HealthKit authorization sheet in place (`requestAuthorization`),
     then re-probes; a granted response flips the gate and the banner clears itself.
     (One-tap recovery, rather than navigating to the Settings panel.)
   - Self-contained child view: owns its `@State` and probes in its own `.task`
     (plus a `scenePhase`-active refresh), so observation is scoped to the banner and
     a probe result never invalidates the whole dashboard body (the documented
     `@Observable`/broad-scope render pitfall).

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

## Implementation notes (post-review)

Shipped on `feat/healthkit-access-diagnostic`. Both review agents ran; the
render-pitfall detector returned 0 findings (and empirically confirmed the hidden
banner reserves no `VStack` spacing via an `ImageRenderer` harness). The generalist
raised 0 Will-Block / 4 Should-Address / 2 Nit — all addressed:

- **Probe-row honesty:** the Settings panel now hides the per-probe Steps/RHR/Sleep
  rows while `.notRequested`, so unmeasured signals are never rendered as "—" (which
  read as "checked, empty"). Probes are only reported once auth is determined and the
  reads actually ran.
- **Testable presentation:** the four state→`(icon, title, detail, tint)` switches were
  extracted from the view into a tested `HealthKitAccessState` presentation extension
  (`HealthKitAccessState+Presentation.swift`), since those strings also feed VoiceOver.
  `.notRequested` and `.likelyRevoked` now use distinct icons.
- **Scoped state (matches original design):** an interim revision had hoisted the
  probe `@State` into `DashboardView`; reverted to the self-contained child view so a
  probe result invalidates only the banner, not the whole dashboard body.
- **Banner action:** requests authorization in place (one-tap) rather than navigating
  to Settings — see the Surfaces section, updated to match.

Coverage: 17 Swift Testing cases (evaluator truth table + precedence, runner probe
composition, history-helper boundaries, banner scope, presentation mapping). Full
suite 1454/1454 green, app builds with zero warnings.
