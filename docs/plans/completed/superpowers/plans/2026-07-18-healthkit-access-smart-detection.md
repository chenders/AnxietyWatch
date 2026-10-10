# HealthKit Access Smart-Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the HealthKit-access `.likelyRevoked` verdict confident enough to drive a proactive (soft-copy) Dashboard banner, by corroborating "reads are empty" with an external signal (Apple Watch paired) and a timing guard (grace period), fixing the self-referential weakness of `hadRecentHistory`.

**Architecture:** Extend the existing pure `evaluateHealthKitAccess` classifier with two inputs (`watchPaired`, `graceElapsed`) gated all-of for `.likelyRevoked`; widen/strengthen the presence probe; add a `HealthKitGraceGate` (persisted first-authorized timestamp) and a `HealthKitAccessProbe` coordinator that assembles all inputs; wire the banner and Settings panel through the coordinator with state-specific copy.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, HealthKit, WatchConnectivity, Swift Testing.

## Global Constraints

- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`) — never XCTest. Copied verbatim from CLAUDE.md.
- **Never `#expect(x == y)` on `Double`** — use an epsilon (`abs(a - b) < 0.001`). (No doubles are asserted here, but the rule stands.)
- **Zero warnings** — CI builds with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`; the module uses MainActor-by-default isolation, so background/Sendable types need explicit `nonisolated`.
- **All HealthKit interaction goes through `HealthKitManager`** (an actor conforming to `HealthKitDataSource`). Never query `HKHealthStore` from views.
- **SwiftLint:** 150 warn / 200 error line length; split long `Text("…")` with `+`.
- **Date math** uses `Calendar` (DST-safe), never `Date() - N*86400` (Semgrep rule `anxietywatch-date-arithmetic-no-calendar`).
- **`#Predicate`** on `HealthSnapshot` stays single-clause (compound-predicate SwiftData pitfall).
- Banner copy: `.notRequested` firm ("Apple Health isn't connected"); `.likelyRevoked` soft/hypothesis-framed ("We're not seeing your health data — check permissions"). Never phrase as an accusation.
- Run on a fresh branch `feat/healthkit-access-smart-detection` off `#21`'s head (`feat/healthkit-access-diagnostic`). Set aside the uncommitted DEBUG research probes + `docs/research/…` first.

---

## Task 0: Branch setup

**Files:** none (git only).

- [ ] **Step 1: Preserve the uncommitted DEBUG research to its own branch**

The working tree currently carries DEBUG-only probe files + a research doc (uncommitted). Move them off so this feature branch starts clean:

```bash
cd <repo-root>
git stash push -u -m "healthkit-read-perm-research" -- \
  AnxietyWatch/Services/HealthKitManager.swift \
  AnxietyWatch/Views/Settings/SettingsView.swift \
  AnxietyWatch/Views/Settings/HealthKitRawProbeView.swift \
  AnxietyWatch/Views/Settings/HealthKitPrivateAuthProbe.swift \
  "docs/research/healthkit-read-permission-detection.md"
git status --short   # expect a clean tree (openspec/ untracked is fine)
```

(The research is recoverable via `git stash list`; a later branch can restore it. `HealthKitManager.swift`'s stash only removes the DEBUG `rawProbe` extension — verify with `git stash show -p stash@{0}`.)

- [ ] **Step 2: Create the feature branch off #21**

```bash
git checkout -b feat/healthkit-access-smart-detection feat/healthkit-access-diagnostic
git branch --show-current   # expect: feat/healthkit-access-smart-detection
```

---

## Task 1: Grace gate (persisted first-authorized timestamp)

**Files:**
- Create: `AnxietyWatch/Services/HealthKitGraceGate.swift`
- Test: `AnxietyWatchTests/HealthKitGraceGateTests.swift`

**Interfaces:**
- Produces: `enum HealthKitGraceGate` with
  - `static let minimumInterval: TimeInterval` (48h)
  - `static func hasElapsed(firstAuthorizedAt: Date?, now: Date, minimum: TimeInterval = minimumInterval) -> Bool`
  - `@discardableResult static func recordFirstAuthorizedIfNeeded(now: Date, defaults: UserDefaults) -> Date`
  - `static func firstAuthorizedAt(defaults: UserDefaults) -> Date?`

- [ ] **Step 1: Write the failing tests**

Create `AnxietyWatchTests/HealthKitGraceGateTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

struct HealthKitGraceGateTests {
    private let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
    }()

    private func isolatedDefaults(_ function: String = #function) -> UserDefaults {
        let suite = "HealthKitGraceGateTests-\(function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("nil timestamp has not elapsed")
    func nilNotElapsed() {
        #expect(!HealthKitGraceGate.hasElapsed(firstAuthorizedAt: nil, now: now))
    }

    @Test("just under 48h has not elapsed")
    func justUnderNotElapsed() {
        let first = now.addingTimeInterval(-47 * 60 * 60)
        #expect(!HealthKitGraceGate.hasElapsed(firstAuthorizedAt: first, now: now))
    }

    @Test("just over 48h has elapsed")
    func justOverElapsed() {
        let first = now.addingTimeInterval(-49 * 60 * 60)
        #expect(HealthKitGraceGate.hasElapsed(firstAuthorizedAt: first, now: now))
    }

    @Test("recordFirstAuthorizedIfNeeded stamps once and is idempotent")
    func recordIsIdempotent() {
        let defaults = isolatedDefaults()
        let first = HealthKitGraceGate.recordFirstAuthorizedIfNeeded(now: now, defaults: defaults)
        #expect(abs(first.timeIntervalSince(now)) < 0.001)
        // A later call must NOT move the timestamp.
        let later = now.addingTimeInterval(100 * 60 * 60)
        let second = HealthKitGraceGate.recordFirstAuthorizedIfNeeded(now: later, defaults: defaults)
        #expect(abs(second.timeIntervalSince(now)) < 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitGraceGateTests`
Expected: FAIL — "cannot find 'HealthKitGraceGate' in scope".

- [ ] **Step 3: Write the implementation**

Create `AnxietyWatch/Services/HealthKitGraceGate.swift`:

```swift
import Foundation

/// Timing guard for the "likely revoked" verdict. Suppresses it until enough
/// time has passed since HealthKit was first authorized, so a freshly-granted
/// install (data hasn't synced yet) or a brand-new install is never flagged.
/// The timestamp is stamped once, the first time authorization is observed
/// determined, and never moved.
enum HealthKitGraceGate {
    static let minimumInterval: TimeInterval = 48 * 60 * 60
    private static let key = "healthKitFirstAuthorizedAt"

    /// Pure predicate — unit-testable with injected dates.
    static func hasElapsed(firstAuthorizedAt: Date?, now: Date,
                           minimum: TimeInterval = minimumInterval) -> Bool {
        guard let firstAuthorizedAt else { return false }
        return now.timeIntervalSince(firstAuthorizedAt) >= minimum
    }

    /// Records `now` the first time called; returns the stored (or just-stored)
    /// timestamp. Idempotent — subsequent calls return the original.
    @discardableResult
    static func recordFirstAuthorizedIfNeeded(now: Date, defaults: UserDefaults) -> Date {
        if let existing = defaults.object(forKey: key) as? Date { return existing }
        defaults.set(now, forKey: key)
        return now
    }

    static func firstAuthorizedAt(defaults: UserDefaults) -> Date? {
        defaults.object(forKey: key) as? Date
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitGraceGateTests`
Expected: PASS (4 tests), zero warnings.

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/HealthKitGraceGate.swift AnxietyWatchTests/HealthKitGraceGateTests.swift
git commit -m "Add HealthKitGraceGate: persisted first-authorized timestamp + 48h grace predicate"
```

---

## Task 2: Extend the evaluator + banner scope

**Files:**
- Modify: `AnxietyWatch/Services/HealthKitAccessDiagnostic.swift` (`evaluateHealthKitAccess`, `showsDashboardBanner`)
- Test: `AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift`

**Interfaces:**
- Consumes: `HealthKitAccessState` (unchanged cases).
- Produces: `func evaluateHealthKitAccess(needsRequest: Bool, probeReturnedValue: Bool, hadRecentHistory: Bool, watchPaired: Bool, graceElapsed: Bool) -> HealthKitAccessState`; `HealthKitAccessState.showsDashboardBanner` now true for `.notRequested` and `.likelyRevoked`.

- [ ] **Step 1: Update the failing tests**

In `AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift`, the existing evaluator tests call `evaluateHealthKitAccess` with 3 labels. Replace the whole "Pure evaluator" MARK block with this expanded version (adds `watchPaired`/`graceElapsed` and the all-of cases):

```swift
    // MARK: - Pure evaluator (exhaustive truth table + precedence)

    @Test("notRequested wins over everything")
    func notRequestedTakesPrecedence() {
        #expect(evaluateHealthKitAccess(
            needsRequest: true, probeReturnedValue: true, hadRecentHistory: true,
            watchPaired: true, graceElapsed: true
        ) == .notRequested)
    }

    @Test("receiving when a probe returned a value and auth is determined")
    func receivingWhenProbePresent() {
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: true, hadRecentHistory: false,
            watchPaired: false, graceElapsed: false
        ) == .receiving)
    }

    @Test("likelyRevoked only when history AND paired AND grace elapsed (all-of)")
    func likelyRevokedRequiresAllOf() {
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: false, hadRecentHistory: true,
            watchPaired: true, graceElapsed: true
        ) == .likelyRevoked)
    }

    @Test("any missing corroborating signal degrades to noDataYet")
    func missingSignalIsNoDataYet() {
        // history true but not paired
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: false, hadRecentHistory: true,
            watchPaired: false, graceElapsed: true) == .noDataYet)
        // history true, paired, but grace not elapsed
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: false, hadRecentHistory: true,
            watchPaired: true, graceElapsed: false) == .noDataYet)
        // paired + grace but no history
        #expect(evaluateHealthKitAccess(
            needsRequest: false, probeReturnedValue: false, hadRecentHistory: false,
            watchPaired: true, graceElapsed: true) == .noDataYet)
    }
```

Then update the banner-scope test (find `bannerScopeIsNotRequestedOnly` and `unavailableHidesBanner`) — replace `bannerScopeIsNotRequestedOnly` with:

```swift
    @Test("Dashboard banner fires for notRequested and likelyRevoked, nothing else")
    func bannerScopeIsNotRequestedOrRevoked() {
        #expect(HealthKitAccessState.notRequested.showsDashboardBanner)
        #expect(HealthKitAccessState.likelyRevoked.showsDashboardBanner)
        #expect(!HealthKitAccessState.receiving.showsDashboardBanner)
        #expect(!HealthKitAccessState.noDataYet.showsDashboardBanner)
        #expect(!HealthKitAccessState.unavailable.showsDashboardBanner)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitAccessDiagnosticTests`
Expected: FAIL — extra-argument/compile errors (evaluator still takes 3 params; `.likelyRevoked.showsDashboardBanner` is false).

- [ ] **Step 3: Update the evaluator + showsDashboardBanner**

In `AnxietyWatch/Services/HealthKitAccessDiagnostic.swift`, replace the `showsDashboardBanner` body:

```swift
    var showsDashboardBanner: Bool {
        self == .notRequested || self == .likelyRevoked
    }
```

and replace the whole `evaluateHealthKitAccess` function:

```swift
func evaluateHealthKitAccess(
    needsRequest: Bool,
    probeReturnedValue: Bool,
    hadRecentHistory: Bool,
    watchPaired: Bool,
    graceElapsed: Bool
) -> HealthKitAccessState {
    if needsRequest { return .notRequested }
    if probeReturnedValue { return .receiving }
    // Strong, all-of gate: a revoked verdict needs an anomalous conjunction —
    // prior real data, a paired Watch (data should exist), and enough elapsed
    // time — else it degrades to the safe .noDataYet (no alarm).
    if hadRecentHistory && watchPaired && graceElapsed { return .likelyRevoked }
    return .noDataYet
}
```

- [ ] **Step 4: Run the tests to verify they pass (evaluator subset)**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitAccessDiagnosticTests`
Expected: the evaluator + banner-scope tests PASS. The runner tests will still FAIL to compile (they call `run(now:hadRecentHistory:)` and the evaluator inside `run` now needs the new args) — that is Task 3. If the whole suite won't compile yet, that's expected; proceed to Task 3 and re-run at its Step 4.

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/HealthKitAccessDiagnostic.swift AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift
git commit -m "Evaluator: all-of likelyRevoked (history+paired+grace); banner scope adds likelyRevoked"
```

---

## Task 3: Strengthen the runner probe (14d window, heart rate) + thread new inputs

**Files:**
- Modify: `AnxietyWatch/Services/HealthKitAccessDiagnostic.swift` (`Result`, `probeWindowDays`, `run`)
- Test: `AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift` (runner tests)

**Interfaces:**
- Produces: `HealthKitAccessDiagnostic.Result` gains `let heartRatePresent: Bool`. `func run(now: Date, hadRecentHistory: Bool, watchPaired: Bool, graceElapsed: Bool) async -> Result`.

- [ ] **Step 1: Update the runner tests**

In `HealthKitAccessDiagnosticTests.swift`, every `diag.run(now: now, hadRecentHistory: X)` call needs the two new args. Update them:
- In `runnerNotRequestedDominatesProbe`, `runnerReceivingFromSteps`, `runnerReceivingFromRestingHR`, `runnerReceivingFromSleep`, `runnerZeroStepsIsAbsence`, `runnerUnavailable`: append `, watchPaired: true, graceElapsed: true`.
- In `runnerLikelyRevoked`: it must now pass all-of, so use `hadRecentHistory: true, watchPaired: true, graceElapsed: true` and keep expecting `.likelyRevoked`.
- In `runnerNoDataYet`: use `hadRecentHistory: false, watchPaired: true, graceElapsed: true`.

Add one new runner test asserting heart rate alone counts as presence:

```swift
    @Test("Runner reports receiving from heart rate alone")
    func runnerReceivingFromHeartRate() async {
        let mock = MockHealthKitDataSource()
        await mock.setAuthorizationNeedsRequest(false)
        await mock.setAverage(.heartRate, value: 64)
        let diag = HealthKitAccessDiagnostic(source: mock)
        let result = await diag.run(now: now, hadRecentHistory: false,
                                    watchPaired: true, graceElapsed: true)
        #expect(result.state == .receiving)
        #expect(result.heartRatePresent)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitAccessDiagnosticTests`
Expected: FAIL — `run` still has the old signature; `Result` has no `heartRatePresent`.

- [ ] **Step 3: Update `Result`, the window, and `run`**

In `HealthKitAccessDiagnostic.swift`:

Add the field to `Result` (after `sleepPresent`):

```swift
        let heartRatePresent: Bool
```

Change the window constant:

```swift
    /// 14-day window: wide enough that a worn Watch (continuous heart rate) is
    /// present, and to avoid early-morning "today's data hasn't landed" gaps.
    private static let probeWindowDays = 14
```

Replace the `run` method with:

```swift
    func run(now: Date, hadRecentHistory: Bool,
             watchPaired: Bool, graceElapsed: Bool) async -> Result {
        if await !source.isHealthDataAvailable() {
            return Result(state: .unavailable, stepsPresent: false, restingHRPresent: false,
                          sleepPresent: false, heartRatePresent: false)
        }
        if await source.authorizationNeedsRequest() {
            return Result(state: .notRequested, stepsPresent: false, restingHRPresent: false,
                          sleepPresent: false, heartRatePresent: false)
        }

        let windowStart = Calendar.current.date(
            byAdding: .day, value: -Self.probeWindowDays, to: now) ?? now

        let steps = (try? await source.cumulativeQuantity(
            .stepCount, unit: .count(), start: windowStart, end: now)) ?? nil
        let restingHR = (try? await source.averageQuantity(
            .restingHeartRate, unit: .count().unitDivided(by: .minute()),
            start: windowStart, end: now)) ?? nil
        let heartRate = (try? await source.averageQuantity(
            .heartRate, unit: .count().unitDivided(by: .minute()),
            start: windowStart, end: now)) ?? nil
        let sleep = (try? await source.querySleepAnalysis(
            start: windowStart, end: now)) ?? SleepData()

        let stepsPresent = (steps ?? 0) > 0
        let restingHRPresent = restingHR != nil
        let heartRatePresent = heartRate != nil
        let sleepPresent = sleep.totalMinutes > 0

        let state = evaluateHealthKitAccess(
            needsRequest: false,
            probeReturnedValue: stepsPresent || restingHRPresent || heartRatePresent || sleepPresent,
            hadRecentHistory: hadRecentHistory,
            watchPaired: watchPaired,
            graceElapsed: graceElapsed
        )
        return Result(state: state, stepsPresent: stepsPresent, restingHRPresent: restingHRPresent,
                      sleepPresent: sleepPresent, heartRatePresent: heartRatePresent)
    }
```

- [ ] **Step 4: Run the full diagnostic test file**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitAccessDiagnosticTests`
Expected: PASS (all evaluator + runner + presentation + history tests), zero warnings.

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/HealthKitAccessDiagnostic.swift AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift
git commit -m "Runner: 14-day probe window + heart-rate presence signal; thread paired/grace"
```

---

## Task 4: `HealthKitAccessProbe` coordinator

**Files:**
- Create: `AnxietyWatch/Services/HealthKitAccessProbe.swift`

**Interfaces:**
- Consumes: `HealthKitAccessDiagnostic`, `HealthKitHistoryProbe`, `HealthKitGraceGate`, `WCSession`, `HealthKitManager.shared`, `AppGroup.identifier`.
- Produces: `enum HealthKitAccessProbe { static func currentResult(modelContext: ModelContext, now: Date, watchPaired: Bool?, source: HealthKitDataSource, defaults: UserDefaults) async -> HealthKitAccessDiagnostic.Result }` with defaulted params for production callers.

**Note:** the coordinator is thin glue over already-tested pieces; there is no new pure logic to unit-test, so it has no dedicated test task. `watchPaired` is injectable (default `nil` → read `WCSession`) so a caller/test can override.

- [ ] **Step 1: Write the coordinator**

Create `AnxietyWatch/Services/HealthKitAccessProbe.swift`:

```swift
import Foundation
import SwiftData
import WatchConnectivity

/// Assembles every input the HealthKit-access diagnostic needs — recent history
/// (SwiftData), Watch pairing (WatchConnectivity), the grace timer, and the
/// live presence probe — in one place, so the Dashboard banner and the Apple
/// Health settings panel stay in sync. `WCSession` is activated at launch by
/// `PhoneConnectivityManager`, so `isPaired` is valid by the time any view runs.
enum HealthKitAccessProbe {
    static func currentResult(
        modelContext: ModelContext,
        now: Date = Date(),
        watchPaired: Bool? = nil,
        source: HealthKitDataSource = HealthKitManager.shared,
        defaults: UserDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    ) async -> HealthKitAccessDiagnostic.Result {
        // Recent history — single-clause, date-bounded fetch (avoids the
        // unbounded-@Query and compound-#Predicate pitfalls).
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -HealthKitHistoryProbe.defaultWindowDays, to: now) ?? now
        let descriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { $0.date >= cutoff })
        let snapshots = (try? modelContext.fetch(descriptor)) ?? []
        let hadHistory = HealthKitHistoryProbe.hadRecentHealthKitData(in: snapshots, now: now)

        // External corroboration: a paired Watch means data should exist.
        let paired = watchPaired ?? (WCSession.isSupported() && WCSession.default.isPaired)

        // Grace: stamp first-authorized once auth is determined, then check age.
        var graceElapsed = false
        if await !source.authorizationNeedsRequest() {
            let firstAuth = HealthKitGraceGate.recordFirstAuthorizedIfNeeded(now: now, defaults: defaults)
            graceElapsed = HealthKitGraceGate.hasElapsed(firstAuthorizedAt: firstAuth, now: now)
        }

        return await HealthKitAccessDiagnostic(source: source).run(
            now: now, hadRecentHistory: hadHistory,
            watchPaired: paired, graceElapsed: graceElapsed)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED, zero warnings.

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Services/HealthKitAccessProbe.swift
git commit -m "Add HealthKitAccessProbe coordinator: gathers history, Watch pairing, grace, probe"
```

---

## Task 5: Dashboard banner — full state + state-specific copy

**Files:**
- Modify: `AnxietyWatch/Views/Dashboard/HealthKitAccessBanner.swift`

**Interfaces:**
- Consumes: `HealthKitAccessProbe.currentResult`, `HealthKitAccessState`, `HealthKitManager.shared`, `@Environment(\.modelContext)`, `@Environment(\.openURL)`.

- [ ] **Step 1: Rewrite the banner to react to the full state**

Replace the entire body of `AnxietyWatch/Views/Dashboard/HealthKitAccessBanner.swift` (keep the file's doc-comment header; replace the `struct`):

```swift
struct HealthKitAccessBanner: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var state: HealthKitAccessState = .receiving
    @State private var requesting = false

    var body: some View {
        Group {
            if state.showsDashboardBanner {
                bannerButton
            }
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var bannerButton: some View {
        Button {
            Task { await handleTap() }
        } label: {
            bannerLabel
        }
        .buttonStyle(.plain)
        .disabled(requesting)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private var title: String {
        state == .notRequested ? "Apple Health isn't connected" : "We're not seeing your health data"
    }

    private var detail: String {
        state == .notRequested
            ? "Anxiety Watch hasn't been granted access to your health data, so Trends and Dashboard stay empty. Tap to grant access."
            : "Trends and Dashboard look empty. Health access may have been turned off. Tap to check your permissions."
    }

    private var bannerLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.slash.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            if requesting { ProgressView() } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }

    private func refresh() async {
        state = await HealthKitAccessProbe.currentResult(modelContext: modelContext).state
    }

    private func handleTap() async {
        if state == .notRequested {
            // Present the system sheet in place; a granted response clears it.
            requesting = true
            try? await HealthKitManager.shared.requestAuthorization()
            await refresh()
            requesting = false
        } else {
            // .likelyRevoked — re-requesting is a no-op (already answered), so
            // route the user to iOS Settings to re-enable access.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }
}
```

Add `import UIKit` under the existing imports at the top of the file (for `UIApplication.openSettingsURLString`).

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED, zero warnings.

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/Dashboard/HealthKitAccessBanner.swift
git commit -m "Banner: react to full access state; soft copy + Settings route for likelyRevoked"
```

---

## Task 6: Settings panel sources from the coordinator + shows Heart Rate row

**Files:**
- Modify: `AnxietyWatch/Views/Settings/AppleHealthSettingsView.swift`

**Interfaces:**
- Consumes: `HealthKitAccessProbe.currentResult`, `HealthKitAccessDiagnostic.Result.heartRatePresent`.

- [ ] **Step 1: Route `refresh()` through the coordinator**

In `AppleHealthSettingsView.swift`, replace the body of `refresh()` (the method that currently builds a `FetchDescriptor`, computes `hadHistory`, and calls `HealthKitAccessDiagnostic(...).run(...)`) with:

```swift
    private func refresh() async {
        checking = true
        defer { checking = false }
        result = await HealthKitAccessProbe.currentResult(modelContext: modelContext)
    }
```

Remove the now-unused `import SwiftData` only if nothing else in the file uses it (the `FetchDescriptor`/`#Predicate` moved into the coordinator). Verify with a build; keep the import if the compiler flags a use.

- [ ] **Step 2: Add the Heart Rate probe row**

In the `body`, inside the `if let result, result.state != .notRequested, result.state != .unavailable {` block, add a Heart Rate row after "Resting Heart Rate":

```swift
                    probeRow("Heart Rate", present: result.heartRatePresent)
```

- [ ] **Step 3: Build + run the full test suite**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED, zero warnings.

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests`
Expected: PASS, zero failures, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Views/Settings/AppleHealthSettingsView.swift
git commit -m "Settings: source access diagnostic from coordinator; add Heart Rate probe row"
```

---

## Task 7: Pre-PR review + push

**Files:** none (review + git).

- [ ] **Step 1: Run the required review agents on the branch diff**

Dispatch `swift-pre-pr-reviewer` and `swiftui-render-pitfall-detector` (the change touches the Dashboard banner + a `.task` + `@Query`-adjacent fetch) on `git diff feat/healthkit-access-diagnostic...HEAD`. Address Will-Block findings; address Should-Address or record a deferral reason.

- [ ] **Step 2: Push**

```bash
git push -u origin feat/healthkit-access-smart-detection
```

- [ ] **Step 3: Open a PR** targeting `feat/healthkit-access-diagnostic` (so it stacks on #21) or `main` if #21 has merged. Body: summarize the all-of `.likelyRevoked` gate, the new signals, and the banner-scope change; link `docs/superpowers/specs/2026-07-18-healthkit-access-smart-detection-design.md`.

---

## Post-merge

Update the design spec with an `## Implementation notes (post-merge)` section recording any scope deltas, and note in `CLAUDE.md`'s HealthKit section that `.likelyRevoked` can now drive the banner (so the "banner fires on .notRequested only" statement, if present, is corrected).
