# Battery Drain Remediation — Background CPU, HealthKit Wakes, BLE, Barometer

**Status:** Shipped (all 6 tasks merged)
**Date:** 2026-07-30
**Author:** Claude (with the maintainer)
**Context:** iOS killed this app three times in July 2026 for sustained background CPU
exhaustion (`cpu_resource_fatal`). Investigation of 2.6 years of on-device battery telemetry
separated two distinct causes; this plan addresses the one that is ours.

---

## TL;DR

Two things were conflated and must stay separated:

1. **A one-day 5.8% capacity drop on 2026-03-16 was not caused by this app.** iOS permanently
   cut the battery's charge termination voltage by ~50 mV as an age-protection measure. The
   repo's initial commit is 2026-03-19 — the app did not exist. **No task in this plan
   addresses that.** It is recoverable only by replacing the battery.

2. **This app independently burns excessive background CPU.** Three OS kills at 91–96% CPU
   sustained for ~50 s, all overnight. That is what this plan fixes.

Do not treat (1) as absolution for (2). The measured burn stands on its own.

**Core insight:** the kills are *not* from HealthKit, BLE, or CoreMotion — all three
microstackshots are pure `AttributeGraph → SwiftUICore → _SwiftData_SwiftUI → SwiftData` on
the main thread, with **zero** frames from those frameworks. The dominant cost is SwiftUI
re-evaluating `@Query` under a wake storm. So **T1 (stop the wakes) and T3 (bound the queries)
attack the same loop from both ends** and together should resolve the kills; T4/T5 are
efficiency work, not kill-drivers.

---

## Evidence

### The three kills

```
AnxietyWatch.cpu_resource_fatal-2026-07-14-030911.ips   48s CPU / 50s wall  (96%)
AnxietyWatch.cpu_resource_fatal-2026-07-17-214805.ips   48s CPU / 52s wall  (92%)
AnxietyWatch.cpu_resource_fatal-2026-07-18-022923.ips   48s CPU / 53s wall  (91%)

Limit: 80% CPU over 60s -> process killed.  All three overnight (03:09, 21:48, 02:29).
```

Identical microstack in all three:

```
CoreFoundation (main run loop) -> libdispatch -> UIKitCore
  -> SwiftUICore -> AttributeGraph -> SwiftUICore
    -> AnxietyWatch -> _SwiftData_SwiftUI -> SwiftData     (53-97 frames)
```

### Where things stand

| Piece | State | Where |
|---|---|---|
| HealthKit `.immediate` background delivery on all 13 anchored types | ❌ wakes on every sample | `HealthKitManager.swift:707` |
| Refresh handler does full mirror + 2-day re-aggregate + clinical import per delivery | ❌ 5 s debounce only coalesces bursts | `HealthDataCoordinator.swift:399` |
| Trends whole-table `@Query` (AnxietyEntry, CPAPSession, BarometricReading) | ✅ bounded in PR #42 | `TrendsFetchWindow.swift` |
| Trends whole-table `@Query` (HRVReading, SensorSession, QuantityHealthSample) | ❌ still unbounded | `Views/Trends/TrendsView.swift` |
| Background BLE scanning, 3 services, `bluetooth-central` declared | ❌ active scan keeps radio hot | `PolarHRMService:233`, `EMAYRealtimeService:623`, `OuraBLEDelegate:160` |
| Barometer callback on `.main` at sensor rate | ❌ throttle governs saves, not callbacks | `BarometerService.swift:36` |
| Any measurement of energy/background CPU | ❌ none — this went unnoticed for months | — |

---

## Tasks

Dependency graph: **T1, T4, T5, T6 are independent and parallel-safe.**
**T2 depends on T1** (frequency tiers determine the debounce budget).
**T3 is independent** but touches a file PR #42 just changed — rebase first.

### Fan-out guidance (for the driving agent)

Farm work out to other herdr tabs / models wherever it is independent and useful. Do not do
all six serially in one context.

| Wave | Tasks | Notes |
|---|---|---|
| 1 | **T1**, **T4**, **T5**, **T6** | Ran concurrently to address urgent crashes without waiting 7 days for a baseline |
| 2 | **T2**, **T3** | T2 chained off T1; T3 isolated to avoid PR #42 merge conflicts |

**Model selection.** Match reasoning depth to the task:

- **T2, T3** — heaviest. Subtle, load-bearing invariants (late-landing HealthKit data,
  LF/HF coalesce-before-window ordering, empty-state gate semantics, F-030 predicate shape).
  Use the strongest available model and do not parallelize *within* these.
- **T1, T4** — moderate. Mechanical changes but with real correctness constraints (klaxon
  primary-signal latency; BLE teardown across in-flight states).
- **T5, T6** — light. Largely mechanical; a cheaper/faster model is fine.

**Isolation.** T1/T4/T5/T6 touch disjoint files and can share a working tree. **T3 should run
in its own git worktree** — it edits `TrendsView.swift`, which PR #42 also changed, and a
concurrent rebase there will conflict.

**Do not fan out the reviews.** Run the required review agents (below) once per task, in the
tab that owns that task, against that task's diff — not as one bulk review at the end.

---

### T1 — Tier HealthKit background-delivery frequency  ·  *parallel-safe*

- [x] **Files:** `AnxietyWatch/Utilities/SampleTypeConfig.swift`, `AnxietyWatch/Services/HealthKitManager.swift:707`

**Problem.** `.immediate` is applied uniformly to all 13 types in
`SampleTypeConfig.anchoredTypes`. Every delivery is a process wake. Several types are
high-rate and none but two need immediacy.

**Change.** Make frequency a property of the config, not a constant:

```swift
struct SampleTypeConfig {
    let identifier: HKQuantityTypeIdentifier
    /// Only signals the CNS klaxon can act on in real time justify `.immediate` —
    /// every `.immediate` delivery is a process wake.
    let backgroundFrequency: HKUpdateFrequency
    // ...existing members...
}
```

Assignment:

| Frequency | Types | Rationale |
|---|---|---|
| `.immediate` | `oxygenSaturation`, `respiratoryRate` | Klaxon primary signals — escalation requires observed primary evidence (see CNS engine invariants) |
| `.hourly` | `heartRate`, `heartRateVariabilitySDNN`, `restingHeartRate` | Corroborating only; cannot raise a tier past watch |
| `.daily` | `vo2Max`, `walkingHeartRateAverage`, `appleWalkingSteadiness`, `bloodGlucose`, `bloodPressureSystolic`, `bloodPressureDiastolic`, `environmentalAudioExposure`, `headphoneAudioExposure` | Trend/report data; no real-time consumer |

**Acceptance.**
- Unit test asserting exactly `{oxygenSaturation, respiratoryRate}` map to `.immediate` —
  a shape test, so adding a type without choosing a tier fails CI.
- Unit test asserting every entry in `anchoredTypes` has an explicit `backgroundFrequency`.

**Guardrail.** Do **not** downgrade `oxygenSaturation`/`respiratoryRate`. The klaxon's
asymmetry invariant means a missing primary signal must never be launderable into "all clear";
delaying them by an hour would do exactly that.

---

### T2 — Make the refresh handler cheap and idempotent  ·  *depends on T1*

- [x] **Files:** `AnxietyWatch/Services/HealthDataCoordinator.swift:399`

**Problem.** `scheduleRefresh()` runs on every delivery: 5 s debounce, then
`mirrorHealthKitSamples()`, a fresh `ModelContext`, `aggregateRecentDays()` over 2 days, and
`importClinicalRecordsIfNeeded()`. The debounce coalesces *bursts* but not *trickles* —
deliveries spaced >5 s apart each trigger a full pass.

**Change.**
1. Raise debounce to 60 s **and add a maximum coalescing window** so a steady trickle yields
   one pass per minute rather than one pass per sample.
2. **Dirty-check before aggregating.** `bufferSamples` already knows what arrived — skip
   `aggregateRecentDays` when no buffered sample falls inside the lookback window.
3. Move `importClinicalRecordsIfNeeded()` onto the existing daily `BGAppRefreshTask`
   (`HealthDataCoordinator.swift:315`). It has no reason to run per-delivery.

**Acceptance.**
- Test: N deliveries spaced 10 s apart over 5 minutes trigger **one** aggregation, not N.
- Test: a delivery whose samples all fall outside the lookback triggers **zero** aggregations.
- Existing `aggregateRecentDays` late-landing-data behaviour must not regress — the
  trailing-days re-aggregation exists because a day's HealthKit data keeps arriving after the
  day ends (CLAUDE.md). Keep a test asserting yesterday's late values still land.

**Guardrail.** Do not gate the *whole* refresh on HealthKit authorization — CPAP/barometric/
sensor-derived stitching reads SwiftData and must keep running (CLAUDE.md `aggregateDay`
reduced pass).

---

### T3 — Bound the three remaining Trends queries  ·  *rebase on PR #42 first*

- [x] **Files:** `AnxietyWatch/Views/Trends/TrendsView.swift`, `AnxietyWatch/Views/Trends/TrendsFetchWindow.swift`

**Problem.** Three queries remain whole-table because a `Date` clause beside their captured
`String` would hit the F-030 SwiftData ORDER BY hang:

```
allHRVReadings          source-filtered, no date bound    (per-minute table)
allSensorSessions       source-filtered, no date bound
allLiveOximeterSamples  sourceBundleID-filtered           (~1k rows/night, unbounded growth)
```

**Change.** Use the two-step pattern already built in `TrendsFetchWindow`: a **`Date`-only**
predicate for the fetch, then filter `source` / `sourceBundleID` **in memory**. That never
places a `String` and a `Date` in the same `#Predicate`, so F-030 is structurally avoided.

**Acceptance.**
- Tests mirroring `TrendsFetchWindowTests`: bounding excludes out-of-window rows on both
  edges; window edges remain inclusive; snapped bounds stay a superset.
- Test asserting no `#Predicate` in `TrendsFetchWindow` captures a non-`Date` local.

**Guardrails.**
- **LF/HF aggregation order is load-bearing.** `LFHFAggregator.coalesce` must still run over
  the full session set *before* windowing — a night straddling the boundary contributes its
  full-night mean anchored to bedtime. Filter the resulting per-night means, never the
  per-reading rows (CLAUDE.md "filter granularity vs aggregation unit").
- `allLiveOximeterSamples.isEmpty` gates the oximeter card's existence ("has ANY live rows
  ever"). Bounding it changes that gate — preserve the semantics or the card vanishes for
  users with only older data (CLAUDE.md "empty-state gates").
- Keep `allSnapshots` whole-table: its consumers are `.now`-anchored `BaselineCalculator`
  windows, so windowing it silently changes baselines when paging back.

---

### T4 — Replace background BLE scanning with reconnection  ·  *parallel-safe*

- [x] **Files:** `AnxietyWatch/Services/PolarHRMService.swift:233`, `AnxietyWatch/Services/EMAYRealtimeService.swift:623`, `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEDelegate.swift:160`

**Problem.** Three services call `scanForPeripherals` with `bluetooth-central` declared.
Active background scanning keeps the radio hot; a pending `connect` does not.

**Change.**
- For **already-paired** peripherals, replace scanning with
  `centralManager.connect(peripheral)`. A pending connect is serviced by the BT controller,
  costs far less than an active scan, and survives suspension.
- Reserve `scanForPeripherals` for explicit user-initiated pairing.
- Every scan gets a `stopScan()` timeout. `OuraBLEDelegate` already does this at 15 s —
  apply the same to `PolarHRMService` and `EMAYRealtimeService`.

**Acceptance.**
- Test: reconnect path for a known peripheral issues `connect` and **never** `scanForPeripherals`.
- Test: a user-initiated scan always calls `stopScan` within the timeout, including on the
  no-device-found path.

**Guardrail.** Destructive/teardown actions must handle all in-flight states, not just the
terminal one (CLAUDE.md state-machine completeness) — `disconnect` during a pending connect
must cancel it.

---

### T5 — Get the barometer off the main queue  ·  *parallel-safe*

- [x] **Files:** `AnxietyWatch/Services/BarometerService.swift:36`

**Problem.**

```swift
altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
```

`shouldCapture` throttles *saves* to one per 15 min / 0.05 kPa, but the **callback still fires
at sensor rate on the main actor**.

**Change.** Deliver to a dedicated `OperationQueue`, evaluate `shouldCapture` there, and hop
to the main actor only when a row is actually persisted.

**Acceptance.**
- Existing `BarometerService.shouldCapture` tests must pass unchanged (it is already a pure
  static function — keep it that way).
- Test asserting the callback queue is not `.main`.

---

### T6 — Add MetricKit so this cannot regress silently  ·  *parallel-safe*

- [x] **Files:** new `AnxietyWatch/Services/EnergyMetricsCollector.swift`, wired in `AnxietyWatchApp`

**Problem.** None of the above is verifiable today. The regression ran for months and was
found only by pulling `cpu_resource_fatal` reports off the device.

**Change.**

```swift
MXMetricManager.shared.add(self)   // MXMetricPayload -> cpuMetrics, applicationLaunchMetrics,
                                   // cellularConditionMetrics, diskIOMetrics
```

Persist each daily payload to SwiftData and surface `cumulativeCPUTime` plus background-wake
counts in a Settings debug screen.

**Acceptance.**
- Test: a synthetic `MXMetricPayload` is parsed and persisted with correct units.
- Debug screen renders the last 7 daily payloads.

**Guardrail.** `@Observable` reads at App/WindowGroup scope invalidate the whole tab tree —
wrap any live metric read in a child `View` (CLAUDE.md render pitfall #4).

---

## Verification plan

1. **Baseline (before any task):** 7 days of `MXMetricPayload.cpuMetrics.cumulativeCPUTime`
   and Settings → Battery per-app background time. *(Requires T6 first — consider landing T6
   ahead of the others purely to establish the baseline.)*
2. **Land T1 + T2 + T5** (cheapest, highest impact, no F-030 exposure). Re-measure 7 days.
3. **Land T3**, then **T4**. Re-measure 7 days.
4. **Acceptance:** zero `cpu_resource_fatal` reports over 30 days **and** background CPU time
   reduced ≥70% vs baseline.
5. **Standing check:**
   ```
   pymobiledevice3 crash ls | grep AnxietyWatch
   ```
   Any new `AnxietyWatch.cpu_resource_fatal-*.ips` is a regression.

---

## Review requirements

Per CLAUDE.md, before pushing any of these:

- `swift-pre-pr-reviewer` on every task (all are non-trivial Swift).
- `swiftui-render-pitfall-detector` on **T3** and **T6** (SwiftUI / `@Query` / `@Observable`).
- `medical-data-accuracy-reviewer` on **T1** and **T2** — both touch physiological ingest and
  aggregation, and T1 changes the latency of klaxon primary signals.

---

## Appendix — degradation trajectory (context only, not a work item)

```
MONTH     Cap%    Ra   Qmax    NCC  Cycles  +Cyc
2023-12   90.4   189   3158   2933     266     6
2024-12   84.0   281   3032   2717     549    24
2025-12   79.0   384   2909   2558     818    17
2026-02   78.9   361   2878   2555     847    14
2026-03   77.1   389   2871   2440     865    17   <- 50 mV charge-voltage cut on 03-16
2026-04   73.7   391   2848   2363     885    19
2026-07   71.7   386   2830   2323     946    23
```

Cycle rate **fell** during the acceleration (14–19/month in 2026 vs 20–28/month in 2024), so
the capacity drop was not driven by heavier use. Current state: ~948 cycles against a
500-cycle rating, ~71.5% of design capacity, `WeightedRa` ~386 (roughly double its 2023 value).

Safety counters are clean — `PTATFaultCounter` 0, `BatteryCellDisconnectCount` 0,
`SystemDisconnectCount` 0, max cell temp 115.3 °F, max pack voltage 4469 mV (in spec). The
cell is **worn, not dangerous**. Hardware replacement is the fix for the capacity; this plan
is the fix for the app's contribution.

## Implementation notes (post-merge)

- **Execution Order:** We abandoned the "Wave 0" baseline delay because iOS kills were actively occurring overnight. T1, T4, T5, and T6 were dispatched concurrently as Wave 1, followed immediately by T2 (chained off T1) and T3 (isolated worktree) as Wave 2.
- **T6 `#expect` Crash:** T6 encountered an `EXC_BREAKPOINT` test failure because Swift Testing's `#expect` macro crashed when attempting to serialize `MockMetricPayload` (due to `MXMetricPayload`'s internal C-struct bridged dependencies). The agent successfully applied a workaround to extract primitive variables *before* the `#expect` boundary.
- **T2 Coalescing:** The refresh handler debounce was successfully replaced with a robust, actor-based `CoalescingThrottle` that strictly enforces the 60s maximum delay.
- **T3 Empty-State semantics:** The empty-state check for `allLiveOximeterSamples` was preserved using an unbounded `fetchCount` check to ensure the presence gate wasn't broken by the newly bound data fetch.
