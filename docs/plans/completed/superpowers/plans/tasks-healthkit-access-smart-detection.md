# tasks.md — HealthKit Access Smart-Detection

> **Conductor:** dispatch tasks from this file to worker agents in sibling panes.
> Review each worker's output against the Acceptance criteria before marking `[x]`.
> Keep checkboxes updated. Only implement a task yourself if it is trivial.
>
> **Spec:** `docs/superpowers/specs/2026-07-18-healthkit-access-smart-detection-design.md`
> **Base branch:** `feat/healthkit-access-diagnostic` (#21)
> **Feature branch:** `feat/healthkit-access-smart-detection`

## Agents

| Name      | Role                     | Started with |
|-----------|--------------------------|--------------|
| worker-1  | Primary implementer      | `herdr agent start worker-1 --split right -- pi` |
| worker-2  | Reviewer / test-runner   | `herdr agent start worker-2 --split right -- pi` |

## Global Spec (shared truth for validation)

> The conductor checks every worker deliverable against this spec.

### Evaluator logic (truth table)

```
needsRequest  probeReturned  hadHistory  watchPaired  graceElapsed → state
─────────────────────────────────────────────────────────────────────────
true           *              *           *            *            → .notRequested
false          true           *           *            *            → .receiving
false          false          true        true         true         → .likelyRevoked
false          false          *           *            *            → .noDataYet
  (any row not matching the above three)
```

`.unavailable` is resolved before the evaluator (via `isHealthDataAvailable()`).

### Key constraints

- `.likelyRevoked` requires **all-of**: `hadRecentHistory AND watchPaired AND graceElapsed`. Any one missing degrades to `.noDataYet`.
- `graceElapsed` = now − `healthKitFirstAuthorizedAt` ≥ 48h. The timestamp is stamped once on first observed authorization and never moves.
- Probe window: **14 days**, sampling steps, resting heart rate, heart rate, and sleep. Any one non-empty ⇒ `probeReturnedValue = true`.
- `showsDashboardBanner` = `true` for `.notRequested` and `.likelyRevoked` only.
- Banner copy: `.notRequested` firm ("Apple Health isn't connected"), `.likelyRevoked` soft/hypothesis-framed ("We're not seeing your health data — check permissions").
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), never XCTest.
- **Zero warnings** — CI builds with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
- All HealthKit interaction goes through `HealthKitManager` (an actor conforming to `HealthKitDataSource`). Never query `HKHealthStore` from views.
- Date math uses `Calendar`, never `Date() - N*86400`.

---

## Tasks

> **Statuses:** `[ ]` pending · `[~]` dispatched · `[x]` done · `[!]` blocked
> **Rule:** only dispatch when all **Depends on** are `[x]`.

---

### [x] T0: Branch setup (clean working tree + create feature branch)

- **Agent:** worker-1
- **Depends on:** none
- **⚠️ Destructive:** ask conductor before dispatching — this stashes uncommitted work.
- **Prompt:**
  ```
  You are working in <repo-root>.

  Step 1: Stash the uncommitted DEBUG research files to a named stash:
    git stash push -u -m "healthkit-read-perm-research" -- \
      AnxietyWatch/Services/HealthKitManager.swift \
      AnxietyWatch/Views/Settings/SettingsView.swift \
      AnxietyWatch/Views/Settings/HealthKitRawProbeView.swift \
      AnxietyWatch/Views/Settings/HealthKitPrivateAuthProbe.swift \
      "docs/research/healthkit-read-permission-detection.md"

  Step 2: Verify the tree is clean:
    git status --short

  Step 3: Create the feature branch off feat/healthkit-access-diagnostic:
    git checkout -b feat/healthkit-access-smart-detection feat/healthkit-access-diagnostic

  Step 4: Confirm:
    git branch --show-current

  Report the output of each step.
  ```
- **Acceptance:**
  - `git status --short` shows clean tree (or only `openspec/` untracked)
  - `git branch --show-current` = `feat/healthkit-access-smart-detection`
  - `git stash list` includes `healthkit-read-perm-research`

---

### [x] T1: Grace gate (persisted first-authorized timestamp)

- **Agent:** worker-1
- **Depends on:** T0
- **Prompt:**
  ```
  You are working in <repo-root> on branch feat/healthkit-access-smart-detection.

  Create two files. Write the test FIRST, then the implementation. Do NOT run tests
  yourself — just create the files with the exact content below.

  ## File 1: AnxietyWatchTests/HealthKitGraceGateTests.swift

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
          let later = now.addingTimeInterval(100 * 60 * 60)
          let second = HealthKitGraceGate.recordFirstAuthorizedIfNeeded(now: later, defaults: defaults)
          #expect(abs(second.timeIntervalSince(now)) < 0.001)
      }
  }
  ```

  ## File 2: AnxietyWatch/Services/HealthKitGraceGate.swift

  ```swift
  import Foundation

  enum HealthKitGraceGate {
      static let minimumInterval: TimeInterval = 48 * 60 * 60
      private static let key = "healthKitFirstAuthorizedAt"

      static func hasElapsed(firstAuthorizedAt: Date?, now: Date,
                             minimum: TimeInterval = minimumInterval) -> Bool {
          guard let firstAuthorizedAt else { return false }
          return now.timeIntervalSince(firstAuthorizedAt) >= minimum
      }

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

  After creating both files, commit:
    git add AnxietyWatch/Services/HealthKitGraceGate.swift AnxietyWatchTests/HealthKitGraceGateTests.swift
    git commit -m "Add HealthKitGraceGate: persisted first-authorized timestamp + 48h grace predicate"

  Report what you created and the commit hash.
  ```
- **Acceptance:**
  - Both files exist with exact content as specified
  - Tests pass: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitGraceGateTests` → 4 tests PASS, zero warnings
  - Commit exists with message "Add HealthKitGraceGate: persisted first-authorized timestamp + 48h grace predicate"

---

### [x] T2: Extend evaluator + banner scope

- **Agent:** worker-1
- **Depends on:** T1
- **Prompt:**
  ```
  You are working in <repo-root> on branch feat/healthkit-access-smart-detection.

  Modify two files: the evaluator function and its tests. The evaluator currently takes
  3 parameters (needsRequest, probeReturnedValue, hadRecentHistory). Extend it to 5
  parameters by adding watchPaired (Bool) and graceElapsed (Bool). The new logic:
  .likelyRevoked only when hadRecentHistory AND watchPaired AND graceElapsed are all true.
  Any missing signal degrades to .noDataYet.

  Also: showsDashboardBanner must now be true for .likelyRevoked in addition to .notRequested.

  ## File 1: AnxietyWatch/Services/HealthKitAccessDiagnostic.swift

  Changes needed:
  1. Replace showsDashboardBanner body with:
     var showsDashboardBanner: Bool {
         self == .notRequested || self == .likelyRevoked
     }

  2. Replace the evaluateHealthKitAccess function with:
     func evaluateHealthKitAccess(
         needsRequest: Bool,
         probeReturnedValue: Bool,
         hadRecentHistory: Bool,
         watchPaired: Bool,
         graceElapsed: Bool
     ) -> HealthKitAccessState {
         if needsRequest { return .notRequested }
         if probeReturnedValue { return .receiving }
         if hadRecentHistory && watchPaired && graceElapsed { return .likelyRevoked }
         return .noDataYet
     }

  ## File 2: AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift

  Find the "Pure evaluator" MARK block. Replace all evaluator tests with the
  expanded truth-table tests below. Also update the banner-scope test.

  Replace the evaluator tests (everything between "// MARK: - Pure evaluator"
  and the next "// MARK:" or end of struct) with:

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
          #expect(evaluateHealthKitAccess(
              needsRequest: false, probeReturnedValue: false, hadRecentHistory: true,
              watchPaired: false, graceElapsed: true) == .noDataYet)
          #expect(evaluateHealthKitAccess(
              needsRequest: false, probeReturnedValue: false, hadRecentHistory: true,
              watchPaired: true, graceElapsed: false) == .noDataYet)
          #expect(evaluateHealthKitAccess(
              needsRequest: false, probeReturnedValue: false, hadRecentHistory: false,
              watchPaired: true, graceElapsed: true) == .noDataYet)
      }

  Find the banner-scope test (likely named bannerScopeIsNotRequestedOnly or similar)
  and replace with:

      @Test("Dashboard banner fires for notRequested and likelyRevoked, nothing else")
      func bannerScopeIsNotRequestedOrRevoked() {
          #expect(HealthKitAccessState.notRequested.showsDashboardBanner)
          #expect(HealthKitAccessState.likelyRevoked.showsDashboardBanner)
          #expect(!HealthKitAccessState.receiving.showsDashboardBanner)
          #expect(!HealthKitAccessState.noDataYet.showsDashboardBanner)
          #expect(!HealthKitAccessState.unavailable.showsDashboardBanner)
      }

  After editing both files, commit:
    git add AnxietyWatch/Services/HealthKitAccessDiagnostic.swift AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift
    git commit -m "Evaluator: all-of likelyRevoked (history+paired+grace); banner scope adds likelyRevoked"

  Report the files you edited and the commit hash.
  ```
- **Acceptance:**
  - `evaluateHealthKitAccess` takes 5 parameters (Bool × 5) → `HealthKitAccessState`
  - `showsDashboardBanner` is true for `.likelyRevoked`
  - Tests compile and the evaluator + banner-scope subset pass (the runner tests may still have compile errors from old 3-arg calls — that's T3's job):
    `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitAccessDiagnosticTests`
    → evaluator truth-table tests + banner-scope test PASS
  - Commit exists with correct message

---

### [x] T3: Strengthen runner probe (14d window, heart rate) + thread new inputs

- **Agent:** worker-1
- **Depends on:** T2
- **Prompt:**
  ```
  You are working in <repo-root> on branch feat/healthkit-access-smart-detection.

  Modify HealthKitAccessDiagnostic.swift and its tests. Three changes:
  1. Add heartRatePresent to Result
  2. Widen probe window from 72h to 14 days
  3. Thread watchPaired + graceElapsed through run(), add heart rate to the probe,
     and pass all new inputs to the evaluator

  ## File 1: AnxietyWatch/Services/HealthKitAccessDiagnostic.swift

  a) In the Result struct, add after sleepPresent:
         let heartRatePresent: Bool

  b) Change the probe window constant:
     Change any existing probeWindowDays value to 14. Find the constant (may be named
     probeWindowDays or similar — search for "72" or the existing window value) and replace with:
         private static let probeWindowDays = 14

  c) Replace the entire run() method signature and body. Find the existing run()
     method. Its signature currently is something like:
       func run(now: Date, hadRecentHistory: Bool) async -> Result
     Replace the entire method with:

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

  ## File 2: AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift

  Update every runner test that calls diag.run(now:hadRecentHistory:) to include the two
  new arguments. Search for all calls matching `diag.run(now:` and append
  `, watchPaired: true, graceElapsed: true` to each. For the runnerLikelyRevoked test,
  also change hadRecentHistory to true (it must now satisfy all-of).

  Add one new runner test after the existing runner tests:

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

  After editing, commit:
    git add AnxietyWatch/Services/HealthKitAccessDiagnostic.swift AnxietyWatchTests/HealthKitAccessDiagnosticTests.swift
    git commit -m "Runner: 14-day probe window + heart-rate presence signal; thread paired/grace"

  Report what you changed and the commit hash.
  ```
- **Acceptance:**
  - Full test suite passes with zero warnings:
    `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthKitAccessDiagnosticTests` → ALL tests PASS
  - `Result` has `heartRatePresent: Bool` field
  - `run()` signature includes `watchPaired: Bool, graceElapsed: Bool`
  - Commit exists with correct message

---

### [x] T4: HealthKitAccessProbe coordinator

- **Agent:** worker-1
- **Depends on:** T3
- **Prompt:**
  ```
  You are working in <repo-root> on branch feat/healthkit-access-smart-detection.

  Create one new file: AnxietyWatch/Services/HealthKitAccessProbe.swift

  This is a thin coordinator that gathers all inputs for the access diagnostic —
  recent history (SwiftData fetch), Watch pairing (WCSession), grace timer, and the
  live presence probe — and returns a HealthKitAccessDiagnostic.Result.

  Content:

  ```swift
  import Foundation
  import SwiftData
  import WatchConnectivity

  /// Assembles every input the HealthKit-access diagnostic needs — recent history
  /// (SwiftData), Watch pairing (WatchConnectivity), the grace timer, and the
  /// live presence probe — in one place, so the Dashboard banner and the Apple
  /// Health settings panel stay in sync. WCSession is activated at launch by
  /// PhoneConnectivityManager, so isPaired is valid by the time any view runs.
  enum HealthKitAccessProbe {
      static func currentResult(
          modelContext: ModelContext,
          now: Date = Date(),
          watchPaired: Bool? = nil,
          source: HealthKitDataSource = HealthKitManager.shared,
          defaults: UserDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
      ) async -> HealthKitAccessDiagnostic.Result {
          // Recent history — single-clause, date-bounded fetch.
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

  After creating, commit:
    git add AnxietyWatch/Services/HealthKitAccessProbe.swift
    git commit -m "Add HealthKitAccessProbe coordinator: gathers history, Watch pairing, grace, probe"

  Report the commit hash.
  ```
- **Acceptance:**
  - File exists at `AnxietyWatch/Services/HealthKitAccessProbe.swift` with exact content
  - Build succeeds: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'` → BUILD SUCCEEDED, zero warnings
  - Commit exists with correct message

---

### [x] T5: Dashboard banner — full state + state-specific copy

- **Agent:** worker-1
- **Depends on:** T4
- **Prompt:**
  ```
  You are working in <repo-root> on branch feat/healthkit-access-smart-detection.

  Rewrite the Dashboard banner to react to the full HealthKitAccessState (not just
  the cheap auth-gate) and show state-specific copy. The banner now uses
  HealthKitAccessProbe.currentResult() to get the full state including .likelyRevoked.

  Modify: AnxietyWatch/Views/Dashboard/HealthKitAccessBanner.swift

  First, add `import UIKit` under the existing imports at the top of the file (for
  UIApplication.openSettingsURLString).

  Then, find the existing HealthKitAccessBanner struct (the entire struct body) and
  replace it with:

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
              requesting = true
              try? await HealthKitManager.shared.requestAuthorization()
              await refresh()
              requesting = false
          } else {
              // .likelyRevoked — re-requesting is a no-op, route to iOS Settings.
              if let url = URL(string: UIApplication.openSettingsURLString) {
                  openURL(url)
              }
          }
      }
  }
  ```

  Keep any existing file-level doc comment / header unchanged. Only replace the struct.

  After editing, commit:
    git add AnxietyWatch/Views/Dashboard/HealthKitAccessBanner.swift
    git commit -m "Banner: react to full access state; soft copy + Settings route for likelyRevoked"

  Report the commit hash.
  ```
- **Acceptance:**
  - `HealthKitAccessBanner` body uses `HealthKitAccessProbe.currentResult` (not a raw diagnostic call)
  - `showsDashboardBanner` gates visibility (shows for both `.notRequested` and `.likelyRevoked`)
  - `.notRequested` → firm copy, tap requests auth in place
  - `.likelyRevoked` → soft copy ("We're not seeing your health data"), tap routes to iOS Settings
  - `import UIKit` present at top of file
  - Build succeeds: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'` → BUILD SUCCEEDED, zero warnings
  - Commit exists with correct message

---

### [x] T6: Settings panel sources from coordinator + Heart Rate row

- **Agent:** worker-1
- **Depends on:** T5
- **Prompt:**
  ```
  You are working in <repo-root> on branch feat/healthkit-access-smart-detection.

  Modify: AnxietyWatch/Views/Settings/AppleHealthSettingsView.swift

  Two changes:

  1. Route refresh() through the HealthKitAccessProbe coordinator instead of
     manually building a FetchDescriptor and calling HealthKitAccessDiagnostic.run().
     Find the existing refresh() method's body (which does a SwiftData fetch and
     calls the diagnostic) and replace it with:

         private func refresh() async {
             checking = true
             defer { checking = false }
             result = await HealthKitAccessProbe.currentResult(modelContext: modelContext)
         }

  2. Add a Heart Rate probe row. Find the block that shows probe rows (they use
     probeRow("Resting Heart Rate", ...) or similar). After the resting heart rate
     row, add:

         probeRow("Heart Rate", present: result.heartRatePresent)

  3. Check if SwiftData imports are still needed. If the file imported SwiftData
     only for the FetchDescriptor/#Predicate that has now moved to the coordinator,
     remove `import SwiftData`. But if SwiftData is used elsewhere in the file
     (e.g., @Environment(\.modelContext) or @Query), keep it.

  After editing, commit:
    git add AnxietyWatch/Views/Settings/AppleHealthSettingsView.swift
    git commit -m "Settings: source access diagnostic from coordinator; add Heart Rate probe row"

  Report the commit hash.
  ```
- **Acceptance:**
  - `refresh()` calls `HealthKitAccessProbe.currentResult(modelContext:)` (not a raw diagnostic)
  - Heart Rate probe row visible in the settings panel probe list
  - Build succeeds: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'` → BUILD SUCCEEDED, zero warnings
  - Full test suite passes: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests` → PASS, zero failures, zero warnings
  - Commit exists with correct message

---

### [~] T7: Pre-PR review + push

- **Agent:** worker-2 (reviewer)
- **Depends on:** T6
- **Prompt:**
  ```
  You are working in <repo-root> on branch feat/healthkit-access-smart-detection.

  This is a final review pass before pushing. Do NOT make code changes. Run checks and
  report findings.

  Step 1: Show the full diff of this branch against its base:
    git diff feat/healthkit-access-diagnostic...HEAD

  Step 2: Run the full test suite and report:
    xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests

  Step 3: Check for warnings:
    xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | grep -i "warning"

  Step 4: Verify every commit message is present and well-formed:
    git log feat/healthkit-access-diagnostic..HEAD --oneline

  Step 5: Read the design spec at docs/superpowers/specs/2026-07-18-healthkit-access-smart-detection-design.md
  and compare the implementation to the spec. Flag any deviations.

  Step 6: Check specifically:
    - The evaluator truth table (5-input all-of gate) matches the spec
    - showsDashboardBanner is true for both .notRequested and .likelyRevoked
    - Banner copy is firm for .notRequested and soft/hypothesis-framed for .likelyRevoked
    - Heart rate is included in the probe
    - Probe window is 14 days
    - Grace gate is 48h, idempotent stamp

  Report: PASS/FAIL for each step, with details on any failures.
  ```
- **Acceptance:**
  - All tests pass, zero warnings
  - Commit history is clean (7 commits: T0 through T6)
  - No deviations from the design spec
  - Diff looks reasonable (no stray files, no unrelated changes)

---

### [ ] T8: Push and open PR

- **Agent:** conductor (do this yourself)
- **Depends on:** T7
- **⚠️ Destructive:** pushes to remote. Ask before executing.
- **Steps:**
  ```bash
  git push -u origin feat/healthkit-access-smart-detection
  ```
  Then open a PR targeting `feat/healthkit-access-diagnostic` (stacked on #21) or `main` if #21 has merged.
- **Acceptance:** branch is pushed, PR is open
