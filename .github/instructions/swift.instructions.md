---
applyTo: "**/*.swift"
---

# Swift / iOS Code Review Instructions

These instructions apply when reviewing Swift files (iOS app, watchOS app, widgets, Swift tests). Cross-cutting project standards live in `.github/copilot-instructions.md`.

## Swift Coding Conventions

- **SwiftData models:** Use `@Model` macro. One model per file in `Models/`.
- **HealthKit:** ALL HealthKit interaction goes through `HealthKitManager` actor. Never query HealthKit directly from views.
- **Concurrency:** Use async/await and structured concurrency throughout. When system APIs only provide callbacks (e.g., CoreMotion, some HealthKit APIs), wrap them using continuations rather than exposing completion handlers in app code.
- **Error handling:** Use typed errors where practical. Never force-unwrap optionals from external data (HealthKit, CPAP files, network responses).
- **Views:** Keep views small and composable. Extract subviews when a view exceeds ~100 lines. Use `@Observable` view models for complex screens.
- **Naming:** Follow Swift API Design Guidelines. Descriptive names, no abbreviations except well-known ones: HR, HRV, AHI, BP, SpO2.
- **No storyboards or XIBs** — pure SwiftUI.
- **Comments:** Comment the "why", not the "what". HealthKit type identifiers should have inline comments explaining what they measure.

## HealthKit Specifics

- HealthKit does NOT tell you whether the user denied a specific read type. `authorizationStatus` returns `.notDetermined` even if denied (Apple privacy protection). Always handle missing data gracefully.
- Use `HKStatisticsQuery` for aggregations, `HKSampleQuery` for individual samples, `HKStatisticsCollectionQuery` for time-series.
- Sleep stages: `.asleepREM`, `.asleepDeep`, `.asleepCore`, `.awake`, `.inBed`.
- Units: HRV in ms, HR in bpm, BP in mmHg, SpO2 in %, temperature in celsius, blood glucose in mg/dL.

## Patterns to actively look for in Swift reviews

Check every Swift diff for these specific patterns, even when not obviously broken. Each has been responsible for multiple review rounds on recent PRs (see `docs/plans/claude-code-setup-improvements.md` for the empirical basis):

- **Hardcoded source-label strings** (`"polar_h10"`, `"healthkit"`) outside `#Predicate`/`@Query` macros where the typed constant (`PolarHRMService.sourceLabel`) is available.
- **`@Query` predicates filtering on a discriminator column** (`source`, `kind`, `provider`) without nil handling — legacy rows or transfer-pipeline rows may have nil and get silently excluded.
- **New `@Query` on unbounded tables** (`HRVReading`, `BarometricReading`) that don't bound by date and filter by source in the predicate.
- **Accessibility numeric formatting** — `Int(x)` (truncates) where the on-screen format uses `%.0f` (rounds). Spoken value ≠ displayed value is a real bug.
- **`Button` inside `NavigationLink` label** — the inner button becomes non-interactive.
- **`Dictionary(grouping:).map { }`** immediately before rendering — order is arbitrary; needs explicit sort.
- **`Date.now` in baseline/window math** where the displayed window's `upperBound` is the correct anchor. Also flag if `upperBound` itself is padded for chart spacing — non-visual consumers need an unpadded sibling.
- **`Date - N.days` cutoffs without `Calendar.current.startOfDay(for:)`** — the cutoff becomes time-of-day-dependent.
- **Magic numbers** like `3 * 3600` repeated as literals in 2+ files instead of a named constant (e.g., `LFHFAggregator.overnightThresholdSeconds`).
- **`#expect(x == y)` on `Double`** — float equality without epsilon tolerance.
- **Computed properties called 2+ times in the same `View.body`** without caching as a `let` — repeats sort/map/filter work per render.
- **Empty-state gates derived from a filtered subset** (e.g., `validWindowMeans` filtering out nils) used as both the empty check and the source of "latest" — they need different definitions.
- **Doc comments** describing chronology, order, or behavior that contradict the `@Query order:` parameter or sort/filter below them.
- **Anchor timing precision** — bucket sessions by `SensorSession.startTime`, not the earliest reading timestamp. Readings can lag start by up to a minute and mis-bucket near-midnight sessions.
- **`.accessibilityElement(children: .combine)` on a container with interactive children** (info `Button`, `NavigationLink`) — collapses them into one VoiceOver element so the user can't focus or activate them independently. Use `.accessibilityElement(children: .ignore)` on the container and put the summary on the interactive label (or `.accessibilityValue` on it) instead.
- **Filter granularity vs aggregation unit** — when filtering data before aggregating it, the filter granularity must match the aggregation unit. Filtering per-reading before computing per-session means produces partial means for sessions that straddle the window boundary (the in-window slice gets averaged instead of the full session). Filter the resulting per-session values instead, or carry both the unfiltered set and a window predicate.
- **Compound `#Predicate` with captured non-primitive locals** — `#Predicate<T> { $0.fk == capturedUUID && $0.col == capturedString }` can hang the main thread in SwiftData's SQL ORDER BY generation on iOS 26 (`+[_NSPredicateUtilities _predicateEnforceRestrictionsOnSelector:…]`, scene-update watchdog `0x8BADF00D`). Flag any compound `#Predicate` clause where one term references a captured local of a non-primitive type and suggest splitting into a single-clause predicate plus an in-memory filter for the secondary condition.
- **`NavigationLink` destinations that contain `@Query`** — closure-based `NavigationLink { DestView() } label: { … }` rebuilds the destination struct on every parent body re-render. SwiftUI's default memberwise comparison cannot dedupe when the struct contains `@Query` (or any property wrapper with internal observation state), so the NavigationStack push animation restarts every frame, cascading into a ~30 Hz render loop and eventually a `CA::Layer::layout_is_active` use-after-free on iOS 26. Any view used as a `NavigationLink` destination AND containing `@Query` must (a) conform to `Equatable` on its identity props only and (b) be wrapped with `.equatable()` at the call site (e.g. `LFHFSessionDetailView(sessionID: id).equatable()`). Flag any new such destination missing either piece.
- **`chartYScale(domain:)` paired with `.nan` y-values** — Swift Charts on iOS 26 has a pathologically slow layout when a `LineMark` y-value can be `.nan` (the gap-drawing pattern) AND the axis is clamped via `.chartYScale(domain: 0...upper)`. Pre-clip at the data layer instead — `point.value.map { min($0, upper) } ?? .nan` plus auto-scale — same visual result, no NaN-vs-finite-domain layout cost. Flag any new `.chartYScale(domain:)` whose data feeder can emit `.nan`.
- **`@Observable` property reads at App / WindowGroup scope** — reading any mutating property on an `@Observable` class inside the App body's `.overlay { … }`, `.background { … }`, or other top-level modifier registers observation at WindowGroup scope, and every change invalidates the entire downstream tab tree. Flag any `@Observable` property access in `App.body` or directly under `WindowGroup { … }` and suggest extracting into a child `View` struct that owns the observation.
- **Incremental-sync cursor advanced to `.now` after I/O** — any pattern of the shape `let payload = build(since: lastSyncDate); await POST(payload); lastSyncDate = .now` has a race: a record created between the build and the cursor assignment is not in the payload (created after the fetch returned) AND has a timestamp less than the new cursor (so the next sync skips it). Capture the upper-bound timestamp BEFORE building the payload, pass it as the export's `end:` cap, and assign the cursor to that captured value on success — not to `.now`/`Date()` post-I/O. Especially severe in drain loops, where each iteration opens a new race window.
- **Cursor advanced past tables that weren't exported** — corollary of the previous rule. When a drain loop conditionally skips some tables on later iterations (e.g., `bulkOnly: true` that omits small-volume tables to avoid repeated full-table scans), advancing the cursor on those iterations reintroduces the original race for the omitted tables: records were never sent but their timestamps are now less than the new cursor. The cursor advance must be conditional on the payload actually having exported the relevant tables.
- **Conditional-skip optimizations breaking invariants the unconditional version preserved** — whenever a diff adds a branch that skips work the original code did unconditionally (`bulkOnly`/`fast`/`cached`/`skipOnRetry` flags, lazy short-circuit, "if expensive" gates), audit every downstream state mutation that was paired with that work. Cursor advances, flag flips, counter increments, idempotency markers — anything whose correctness assumed the skipped work happened must become conditional too, or its invariant silently breaks. Past example: the sync drain's `bulkOnly: roundTrips > 0` added in one round of review left `lastSyncDate = cursorUpperBound` unconditional in the next, reintroducing the exact race a prior fix had closed.
- **Hardcoded chart-series colors** — chart series under `AnxietyWatch/Views/Trends/` must consume tokens from `AnxietyWatch/Utilities/ChartPalette.swift`, not raw `.red`/`.blue`/`.indigo`/etc. The palette centralizes per-source semantics (`hkHeartRate`, `polarHeartRate`, `sleepDeep`, etc.) so a refactor in one place updates every chart consistently. UI accents like SF Symbol icons (`Image(systemName:)`) and status warning text are out of scope. CI enforces this via Semgrep rule `anxietywatch-chart-color-literal`.
- **`Services/CNSRisk/` threshold/ramp/gate invariants** (CNS-depression early-warning detection engine — safety-critical, dispatch `medical-data-accuracy-reviewer` as required, not just recommended, on any touching PR): any threshold, onset, floor, fidelity, fusion weight, or sustain duration must be a `CNSThresholds` member — flag a re-typed literal. A severity ramp (SpO₂, heart rate) must scale its saturation floor down with a personalized onset (`spo2Ramp`/`heartRateRamp`) rather than clamping the onset to a fixed floor — a fixed floor degenerates the ramp to a step and can score a user's own normal baseline as maximal severity (the documented spec-erratum failure one level deeper). An `indeterminate` `CNSQualityGate` verdict must never yield a score — `CNSSeverityScorer.assess` must return `nil`, never a fabricated "safe" or "danger" value. `CNSQualityGate`'s sample-count-as-seconds coverage math assumes ~1 Hz streams (EMAY/Polar); flag any sparse-cadence source (Apple Watch spot-checks) fed through it unchanged. Escalation and clearing in `CNSAlertTierMachine` both require primary-informed (SpO₂/respiratory-rate) evidence in the contributions list — a corroborating-only (HR/HRV) reading must never clear a raised tier or reset rise progress.

## Swift Testing Conventions

- Use **Swift Testing** (`@Test` macro, `#expect()`) for all new tests — not XCTest.
- Use in-memory `ModelContainer` for SwiftData test isolation.
- Use fixed reference dates for deterministic assertions.
- Extract pure logic into testable helpers rather than burying it in views or private methods.

## HealthKit authorization

- **Never put an `HKCorrelationType` in the read-authorization set.** HealthKit disallows read authorization for correlation types and raises `NSInvalidArgumentException` ("Authorization to read the following types is disallowed: HKCorrelationTypeIdentifierBloodPressure"). It is an ObjC exception, so Swift `try` cannot catch it — the app aborts on signal 6 with no Swift error and no recovery. Read access to a correlation comes from its **constituent quantity types**: request `.bloodPressureSystolic` + `.bloodPressureDiastolic`, never `HKCorrelationType(.bloodPressure)`. `HKCorrelationQuery` reads through those grants, so querying the correlation still works. This crashed on the *first* authorization prompt only, making it invisible to every already-authorized install for months.
- Because the exception is uncatchable, there is no error path to test. Assert on the **shape of the read set** instead (`HealthKitManagerReadTypesTests` pins "no correlation types" plus the positive "BP quantity types are still requested"). Flag any diff that adds a type to `allReadTypes` without a corresponding shape assertion.

## Swift-specific Don'ts

- Don't use Core Data — this project uses SwiftData exclusively.
- Don't query HealthKit from views — always go through `HealthKitManager`.
- Don't expose completion handlers in app code — use async/await, wrapping callback-based system APIs with continuations.
- Don't write to a table that a guard requires to be empty, without checking the gate. `SnapshotAggregator.aggregateDay` wrote a `HealthSnapshot` during the fresh-install pre-decision window; `HealthSnapshot` is one of the tables `restoreGuardTablesAreEmpty` checks, so one row permanently blocked "Restore from Server" with no way out but deleting the app. Deferring the *caller* that normally does the writing was not enough — observer and refresh paths called the aggregator anyway. Gate the **write**, not just the caller you know about.
