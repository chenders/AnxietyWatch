# AnxietyWatch Expert Review Improvement Plan

**Date:** 2026-03-28
**Source:** Synthesis of 9 expert reviews (Xcode/Claude Code tooling, iOS UI/UX, Health app UX, HealthKit, Refactoring, Anxiety/Panic medical, Lived experience, Developer experience, Retail pharmacy)

---

## Table of Contents

1. [Critical Fixes](#1-critical-fixes)
2. [High-Impact UX Improvements](#2-high-impact-ux-improvements)
3. [HealthKit & Data Collection](#3-healthkit--data-collection)
4. [Architecture & Code Quality](#4-architecture--code-quality)
5. [Developer Experience](#5-developer-experience)
6. [Clinical / Medical Value](#6-clinical--medical-value)
7. [Pharmacy & Prescription Improvements](#7-pharmacy--prescription-improvements)
8. [Nice-to-Haves](#8-nice-to-haves)
9. [Rejected Suggestions](#9-rejected-suggestions)

---

## 1. Critical Fixes

These are bugs, broken behavior, or silent-failure conditions that undermine existing functionality.

---

### 1.1 iOS CI Is Non-Blocking (`continue-on-error: true`)

- **Source experts:** Developer Experience, Xcode/Claude Code Tooling
- **Description:** The `ios-ci.yml` workflow has `continue-on-error: true`, meaning test failures are silently ignored. All 21 test files are effectively decorative. Remove it or pin to an available Xcode version so tests actually gate merges.
- **Pros:** Tests prevent regressions; CI becomes trustworthy.
- **Cons:** May require fixing currently-broken tests first.
- **Risks:** If tests are currently failing, this blocks all PRs until fixed.
- **Mitigations:** Run the full suite locally first. Fix failures before removing the flag. Add `xcodebuild -version` output to job summary.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Both experts flagged this independently. Strong agreement.

---

### 1.2 Fix `AnxietyScope` Typo in respond-to-copilot.md

- **Source experts:** Xcode/Claude Code Tooling
- **Description:** The custom command `.claude/commands/respond-to-copilot.md` hardcodes `AnxietyScope` in all GitHub API calls. The actual repo is `AnxietyWatch`. Every invocation fails with 404 errors. Replace all instances or switch to `gh` subcommands that infer the repo from the local git remote.
- **Pros:** The `/respond-to-copilot` command will actually work.
- **Cons:** None.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small (5 minutes)
- **Impact:** High
- **Expert consensus:** Unambiguous bug. Single expert found it.

---

### 1.3 Fix Anchored Query Predicate Dropping Samples After Long Offline Periods

- **Source experts:** HealthKit
- **Description:** In `HealthKitManager.startAnchoredQueries()`, the 7-day retention predicate is applied unconditionally. When the anchor is non-nil but older than 7 days (device was off for a week), samples between the anchor and the 7-day cutoff are silently dropped. The predicate should only apply when the anchor is nil.
- **Pros:** No silent data loss after extended offline periods.
- **Cons:** First-run fetch may be larger without the predicate (acceptable).
- **Risks:** Low.
- **Mitigations:** Test with a nil anchor and a stale anchor to verify both paths.
- **Effort:** Small
- **Impact:** High (data integrity)
- **Expert consensus:** Single expert. Clear-cut bug.

---

### 1.4 Fix BaselineCalculator: Population Variance and Minimum Sample Count

- **Source experts:** HealthKit, Medical
- **Description:** Two issues: (a) Divides by N instead of N-1 (Bessel's correction), underestimating standard deviation for small samples and creating too-tight bounds that trigger false alerts. (b) Minimum sample count of 3 is too low for meaningful statistics. Increase to 7 minimum (ideally 14).
- **Pros:** Fewer false-positive alerts. Statistically meaningful deviations.
- **Cons:** Users see baseline comparisons later (after 7-14 days instead of 3).
- **Risks:** Users may perceive the delay as a missing feature.
- **Mitigations:** Show a "building your baseline" progress indicator during initial data collection.
- **Effort:** Small
- **Impact:** High (accuracy of core alerting)
- **Expert consensus:** Both experts independently flagged both issues. Strong agreement.

---

### 1.5 Fix `.navigationDestination` Scoping in MedicationsHubView

- **Source experts:** iOS UI/UX
- **Description:** `.navigationDestination(for: UUID.self)` is registered inside `supplyAlertSection`, so it only exists when supply alerts are visible. No alerts = no navigation destination registered. Similarly, `PharmacyDetailView` has a `NavigationLink(value: rx)` with no corresponding `.navigationDestination(for: Prescription.self)`.
- **Pros:** Navigation works reliably regardless of data state.
- **Cons:** None.
- **Risks:** Low.
- **Mitigations:** Move navigation destinations to the `NavigationStack` or `List` level.
- **Effort:** Small
- **Impact:** High (broken navigation paths)
- **Expert consensus:** Single expert. Verifiable bugs.

---

### 1.6 Fix `.alert` Binding Anti-Pattern in ExportView and CPAPListView

- **Source experts:** iOS UI/UX
- **Description:** Both views use `.alert("...", isPresented: .constant(errorMessage != nil))`, creating a binding to a constant that SwiftUI's built-in dismissal cannot modify. Use a proper `Binding<Bool>` or `.alert(item:)`.
- **Pros:** Standard SwiftUI behavior. Alerts dismiss reliably.
- **Cons:** None.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert. Straightforward fix.

---

### 1.7 Fix Staleness Filter for 90-Day Mail Order Prescriptions

- **Source experts:** Retail Pharmacy
- **Description:** `alertStalenessLimitDays = 60` is a global constant. A 90-day mail order fill ages past 60 days while the patient still has supply, causing alerts to disappear prematurely. Make staleness relative to the prescription's own days supply.
- **Pros:** Supply alerts remain accurate for mail-order prescriptions.
- **Cons:** Slightly more complex logic.
- **Risks:** Low.
- **Mitigations:** Default to current behavior (60 days) when days supply is unknown.
- **Effort:** Small
- **Impact:** High (incorrect behavior for a common pharmacy scenario)
- **Expert consensus:** Single expert with deep domain knowledge.

---

## 2. High-Impact UX Improvements

---

### 2.1 Add "Log Anxiety" Quick Action on Dashboard

- **Source experts:** Health App UX, Lived Experience, iOS UI/UX
- **Description:** The Dashboard shows the last anxiety entry but has no button to create a new one. Add a prominent "Log Anxiety" button that opens a minimal severity picker (not the full form). Notes and tags should be optional/secondary.
- **Pros:** Eliminates the most common extra-tap friction. Usable during high anxiety.
- **Cons:** Adds a UI element to the dashboard.
- **Risks:** Could feel cluttered if not designed carefully.
- **Mitigations:** Make it the dominant element at the top, replacing or enhancing the current anxiety card.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Three experts independently recommended this. Strongest consensus of any suggestion.

---

### 2.2 Dashboard Section Grouping and Hierarchy

- **Source experts:** iOS UI/UX, Health App UX, Lived Experience
- **Description:** The dashboard renders 18+ metric cards in a single flat scroll with no grouping or hierarchy. Group into titled sections: "Anxiety & Mood" (pinned at top), "Sleep" (sleep + CPAP), "Heart & Autonomic" (HR, HRV, RHR, BP), "Activity" (steps, exercise, calories), "Other." Consider making sections collapsible.
- **Pros:** Dramatically reduces information overload. Gives visual anchor points.
- **Cons:** Requires restructuring of DashboardView.
- **Risks:** Section boundaries may feel arbitrary for some metrics.
- **Mitigations:** Allow user customization of section visibility. Start with sensible defaults.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** All three UX-focused experts flagged this. The lived experience expert said the dashboard is "designed for calm, reflective use" and is overwhelming during anxiety.

---

### 2.3 Replace Severity Slider with Tappable Numbered Circles

- **Source experts:** Health App UX, Lived Experience
- **Description:** iOS `Slider` is hard to use with trembling hands during panic. Replace with a 1-10 grid of large, tappable numbered circles (minimum 44x44pt), color-coded by severity. Add descriptive anchors: 1-2 Calm, 3-4 Mild, 5-6 Moderate, 7-8 High/physical symptoms, 9-10 Panic/crisis.
- **Pros:** Accessible during acute anxiety. Works with trembling hands. Anchors improve rating consistency over time.
- **Cons:** Takes more vertical space.
- **Risks:** May feel cluttered in the full form.
- **Mitigations:** Use a compact 2-row grid (5 per row). Color coding provides visual grouping.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Both agreed. The lived experience expert noted they only use 4 distinct values on a 10-point scale due to lack of anchors.

---

### 2.4 Quick Tags / Suggested Tags on Journal Entry

- **Source experts:** iOS UI/UX, Health App UX, Lived Experience
- **Description:** Tag entry requires typing each tag individually. Show the user's most-used tags as tappable chips. Tapping toggles on/off. Move free-text "Add tag" below.
- **Pros:** Dramatically faster tag entry. Better data quality. Usable during high anxiety.
- **Cons:** Needs to track tag frequency.
- **Risks:** Tag chip row could become long.
- **Mitigations:** Show top 6-8 most-used tags. Provide a "More..." expansion.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** All three recommended this independently.

---

### 2.5 Show "Last Taken" Timestamps Next to Quick Log Medication Buttons

- **Source experts:** Health App UX, Lived Experience
- **Description:** The Quick Log section shows "Log Dose" buttons but not when each medication was last taken today. For anxiety meds, this is a double-dosing risk. Show "Last taken: [time]" below each medication. Warning color if >24h for daily meds.
- **Pros:** Prevents accidental double-dosing. Critical safety for benzos and stimulants.
- **Cons:** Adds visual weight to each medication row.
- **Risks:** Low.
- **Mitigations:** Keep the timestamp small/subtle unless it indicates a problem.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Both experts flagged this. The lived experience expert: "during panic I will forget whether I already took something."

---

### 2.6 Add Breathing Exercise / Grounding Tool

- **Source experts:** Lived Experience, Health App UX
- **Description:** A simple timed breathing animation ("breathe in 4... hold 4... out 6"). Table stakes for an anxiety app. Make accessible from both the Watch Quick Log screen and the iPhone dashboard.
- **Pros:** Direct therapeutic value during acute episodes. Standard in clinical anxiety apps.
- **Cons:** Feature scope expansion beyond tracking.
- **Risks:** Over-engineering.
- **Mitigations:** Keep it minimal -- a single timed animation, not a meditation platform. Consider leveraging Apple Watch's Breathe app integration.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Both experts strongly recommended this. Called "the one thing that actually helps mid-panic."

---

### 2.7 Trend Arrow Color Should Be Context-Dependent

- **Source experts:** iOS UI/UX
- **Description:** `LiveMetricCard` maps `.rising` to orange, `.stable` to green, `.dropping` to blue universally. HRV rising should be green (good), not orange. The color should depend on the metric's "good direction," like `baselineColor` already does for the main value.
- **Pros:** Eliminates misleading visual signals.
- **Cons:** Requires per-metric configuration.
- **Risks:** Low.
- **Mitigations:** Add a `goodDirection` parameter to `LiveMetricCard`.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert. Clearly correct.

---

### 2.8 Pull-to-Refresh on Dashboard and Trends

- **Source experts:** iOS UI/UX
- **Description:** `DashboardView` uses a `ScrollView`, so `.refreshable` is not automatic. Add it for re-fetching HealthKit data and refreshing snapshots. Same for `TrendsView`.
- **Pros:** Standard iOS gesture users expect.
- **Cons:** None.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert. Standard iOS pattern.

---

### 2.9 Watch Quick Log Improvements

- **Source experts:** Lived Experience
- **Description:** (a) Default to last logged severity instead of always 5. (b) Replace modal confirmation alert with auto-dismissing visual flash -- the haptic is enough. (c) Show "Last: 6, 2 hours ago" at the top for context.
- **Pros:** Fewer interactions during crisis. Better context for rating.
- **Cons:** Minor complexity.
- **Risks:** Low.
- **Mitigations:** Each change is independent.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert with lived experience. Specific, actionable.

---

### 2.10 Confirmation Dialogs on Destructive Actions

- **Source experts:** iOS UI/UX
- **Description:** Swipe-to-delete on journal entries, medication doses, and CPAP sessions has no confirmation. Add `.confirmationDialog` for content-rich items like journal entries.
- **Pros:** Prevents accidental data loss.
- **Cons:** One extra tap for deletions.
- **Risks:** Could feel annoying for frequent deletions.
- **Mitigations:** Only add for journal entries (user-written content). Doses and CPAP can stay immediate.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 2.11 "Today's Summary" Composite Card on Dashboard

- **Source experts:** Health App UX, Lived Experience
- **Description:** A card at the top synthesizing: anxiety trend direction, sleep quality last night, HRV vs baseline, medication adherence today. 3-5 bullet points instead of 18 cards. Modeled after Oura's "Readiness Score."
- **Pros:** Users get the essential picture at a glance.
- **Cons:** Requires data synthesis logic.
- **Risks:** Summary could be misleading with sparse data.
- **Mitigations:** Show data completeness indicators. Don't show until enough data exists.
- **Effort:** Large
- **Impact:** High
- **Expert consensus:** Both experts recommended this. "The dashboard shows numbers; it should tell stories."

---

## 3. HealthKit & Data Collection

---

### 3.1 Add HKWorkoutType to Read Types

- **Source experts:** HealthKit, Medical
- **Description:** The app does not read workout sessions. Without this, elevated HR during exercise contaminates baseline calculations and triggers false anxiety-correlation flags. A 45-minute run explains why HR was 160 at 3pm. This is arguably the single biggest data gap.
- **Pros:** Eliminates exercise-HR false positives. Enables exercise-type correlation and heart rate recovery computation.
- **Cons:** Additional HealthKit authorization.
- **Risks:** Low.
- **Mitigations:** Add to existing authorization batch.
- **Effort:** Small (reading) to Medium (using for HR filtering)
- **Impact:** High
- **Expert consensus:** Both experts independently identified this as the biggest gap. Strong agreement.

---

### 3.2 Add Time in Daylight (iOS 17+)

- **Source experts:** HealthKit, Medical
- **Description:** `HKQuantityTypeIdentifier.timeInDaylight` is trivially available on watchOS 10+. Low daylight exposure disrupts circadian rhythm and exacerbates anxiety. Add to `allReadTypes` and `HealthSnapshot`.
- **Pros:** High anxiety-correlation value. Zero new hardware. Not self-reportable.
- **Cons:** Only available on watchOS 10+/iOS 17+ (already the minimum target).
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Both experts ranked this as the highest-value single addition. Strong agreement.

---

### 3.3 Implement HKStateOfMind Writing (iOS 18+)

- **Source experts:** HealthKit
- **Description:** Apple's mental health journaling API (iOS 18). Write anxiety severity as `HKStateOfMind` when users log journal entries. Anxiety data becomes visible in Apple Health's Mental Wellbeing section.
- **Pros:** Bidirectional data flow with Apple Health. Anxiety data visible in Health app.
- **Cons:** iOS 18+ only. Requires write authorization.
- **Risks:** Users may not want anxiety data in Health app.
- **Mitigations:** Opt-in setting. `#available(iOS 18, *)` guard.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Single expert. Identified as "the single most strategically important addition."

---

### 3.4 Add Physical Effort (iOS 17+) to Read Types

- **Source experts:** HealthKit
- **Description:** `HKQuantityTypeIdentifier.physicalEffort` rates effort levels in real time. Better than exercise minutes alone for distinguishing "elevated HR from exercise" vs "elevated HR from anxiety."
- **Pros:** Key disambiguator for this use case.
- **Cons:** None.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert. Clear rationale.

---

### 3.5 Derive Overnight HRV as Separate Snapshot Field

- **Source experts:** Medical, HealthKit
- **Description:** HRV during sleep removes confounds from daytime activity, caffeine, and posture. Add `hrvOvernightAvg` to `HealthSnapshot` using the existing noon-to-noon window.
- **Pros:** More clinically interpretable than all-day HRV. Already have the data.
- **Cons:** Adds another field.
- **Risks:** Low.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Both experts recommended this.

---

### 3.6 Add Sleep Onset Latency Derivation

- **Source experts:** Medical
- **Description:** Derive time between first "inBed" and first "asleep" from existing sleep stage data. Prolonged onset (>30 min) is a hallmark anxiety symptom. Zero new data sources needed.
- **Pros:** High clinical value. Derivable from existing data.
- **Cons:** Depends on accurate "inBed" detection.
- **Risks:** Apple Watch inBed detection can be unreliable.
- **Mitigations:** Only show when both timestamps are available.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert. Well-supported by literature.

---

### 3.7 Use HKCorrelation for Blood Pressure Pairing

- **Source experts:** HealthKit
- **Description:** BP readings are stored as `HKCorrelation` pairing systolic and diastolic. Currently queried independently, risking mismatch. Query `HKCorrelationType(.bloodPressure)` instead.
- **Pros:** Correctly paired BP readings.
- **Cons:** Slightly more complex query.
- **Risks:** Low.
- **Mitigations:** Fall back to independent queries if correlation query returns empty.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 3.8 Add Apple Sleeping Breathing Disturbances (iOS 18+)

- **Source experts:** HealthKit
- **Description:** Apple's native AHI equivalent. Provides a fallback for nights without the CPAP machine.
- **Pros:** Apple-native AHI for non-CPAP nights.
- **Cons:** iOS 18+ only.
- **Risks:** Low.
- **Mitigations:** `#available` guard.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 3.9 Add Baselines for Sleep Duration and Respiratory Rate

- **Source experts:** HealthKit, Medical
- **Description:** Only HRV and resting HR have baselines currently. Sleep duration deviation is one of the strongest predictors of next-day anxiety. Add baselines for at least sleep minutes and respiratory rate.
- **Pros:** Catches sleep-related anxiety predictors.
- **Cons:** More alerts to manage.
- **Risks:** Alert fatigue.
- **Mitigations:** Prioritize sleep baseline. Use configurable per-metric thresholds.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Both experts recommended this.

---

### 3.10 Write Mindful Session to HealthKit on Journal Entry

- **Source experts:** HealthKit
- **Description:** Write `HKCategoryTypeIdentifier.mindfulSession` when users log journal entries. Integrates with Apple's Mindfulness ecosystem.
- **Pros:** Journaling contributes to Apple Health mindfulness data.
- **Cons:** Requires write authorization.
- **Risks:** Low.
- **Mitigations:** Opt-in.
- **Effort:** Small
- **Impact:** Low
- **Expert consensus:** Single expert.

---

## 4. Architecture & Code Quality

---

### 4.1 Extract DashboardViewModel from DashboardView

- **Source experts:** Refactoring, iOS UI/UX
- **Description:** `DashboardView.swift` (703 lines) contains data loading, baseline computation, supply alert filtering, trend computation, color mapping, and sync orchestration in private methods on the view struct. None is testable. Extract into a `DashboardViewModel` using `@Observable`.
- **Pros:** 700 lines of logic become testable. View becomes purely declarative. Follows CLAUDE.md convention.
- **Cons:** Significant refactoring effort.
- **Risks:** Regressions during extraction.
- **Mitigations:** Write tests for the extracted view model that validate existing behavior before changing the view.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Both experts agreed this is the highest-value refactoring.

---

### 4.2 Extract Shared Supply Alert Filtering

- **Source experts:** Refactoring
- **Description:** Supply alert filtering (staleness + inactive medication + status filter) is duplicated in DashboardView, MedicationsHubView, and PrescriptionListView. Extract into a single `SupplyAlertFilter` utility.
- **Pros:** Eliminates triple duplication. Single source of truth.
- **Cons:** None.
- **Risks:** Low.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Single expert. Clear-cut duplication.

---

### 4.3 Extract `severityColor` to Shared Utility

- **Source experts:** iOS UI/UX, Refactoring
- **Description:** `severityColor` is duplicated in 6+ places. `anxietyColor` duplicated in 3 trend charts. Extract to a single `Int` extension or shared function.
- **Pros:** Eliminates divergence risk. One place to adjust the color scale.
- **Cons:** None.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Both flagged independently.

---

### 4.4 Delete Dead Code: MedicationListView.swift

- **Source experts:** iOS UI/UX, Health App UX, Refactoring
- **Description:** `MedicationListView` is a near-exact duplicate of the Quick Log + Recent Doses sections of `MedicationsHubView`. Never referenced in navigation. Delete or merge unique code.
- **Pros:** Removes maintenance liability and divergence risk.
- **Cons:** None.
- **Risks:** Verify it is truly unreachable.
- **Mitigations:** Search for all references before removal.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Three experts noted the duplication.

---

### 4.5 Replace `try?` Error Swallowing with Logging

- **Source experts:** Refactoring, Developer Experience
- **Description:** Pervasive `try?` throughout `HealthDataCoordinator`, `DashboardView`, `PhoneConnectivityManager` silently discards errors. Replace with `do/catch` + `os.Logger`.
- **Pros:** Surfaces silent failures. Makes debugging possible.
- **Cons:** Slightly more verbose.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Both experts flagged this.

---

### 4.6 Add `#Unique` Constraint on CPAPSession.date and HealthSample Dedup

- **Source experts:** Refactoring, HealthKit
- **Description:** Nothing prevents duplicate CPAP sessions from re-import. `HealthSample` insertion has no dedup check; anchor persistence failure replays create duplicates that skew averages. Add constraints and dedup checks.
- **Pros:** Data integrity.
- **Cons:** Migration consideration for existing data.
- **Risks:** Medium for `#Unique` on existing models (migration).
- **Mitigations:** Add dedup checks in importers first (low risk), then add constraints.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Both experts (different domains) flagged related issues.

---

### 4.7 Log HealthKit Errors Instead of Silently Discarding

- **Source experts:** HealthKit
- **Description:** Both `enableBackgroundDelivery` handlers and anchored query error handlers silently discard errors. Actionable errors like `HKError.errorAuthorizationDenied` are invisible.
- **Pros:** Enables debugging of HealthKit issues.
- **Cons:** None.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert. Overlaps with 4.5.

---

### 4.8 Convert Raw String Fields to Swift Enums

- **Source experts:** Refactoring
- **Description:** `PharmacyCallLog.direction`, `CPAPSession.importSource`, `Prescription.importSource`, and `HealthSample.type` use raw strings where enums would be safer.
- **Pros:** Compiler-enforced valid values.
- **Cons:** Requires migration-safe raw values.
- **Risks:** Low with raw string backing.
- **Mitigations:** Use `String`-backed enums.
- **Effort:** Small per item
- **Impact:** Low
- **Expert consensus:** Single expert.

---

## 5. Developer Experience

---

### 5.1 Create a Makefile for Common Commands

- **Source experts:** Developer Experience
- **Description:** No `Makefile` or equivalent. Every command must be remembered or copied from CLAUDE.md. Create one with targets: `build`, `test`, `test-server`, `lint`, `server-up`, `server-down`, `generate-version`, `coverage`.
- **Pros:** Every action becomes a one-word command.
- **Cons:** One more file to maintain.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Single expert. Identified as highest-impact DX change.

---

### 5.2 Add SwiftUI `#Preview` Blocks and SampleData

- **Source experts:** Developer Experience
- **Description:** Zero `#Preview` providers in the entire codebase. Every UI change requires full build-and-run. Add previews to the 5 most-used views. Create a `SampleData.swift` utility reusable across previews, tests, and demo mode.
- **Pros:** Cuts edit-preview cycle from minutes to seconds. Sample data reusable for tests and screenshots.
- **Cons:** Initial setup effort.
- **Risks:** Preview data diverging from real patterns.
- **Mitigations:** Use SampleData in tests too.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Single expert. Standard iOS practice.

---

### 5.3 Shared TestHelpers.swift and ModelFactory.swift

- **Source experts:** Developer Experience
- **Description:** Every test file creates its own `makeContainer()` with different model subsets. No shared factory methods. The schema list must stay in sync manually. Create a shared `makeFullContainer()` and `ModelFactory` with static factory methods.
- **Pros:** Eliminates schema drift in tests. Makes writing new tests faster.
- **Cons:** Initial migration of existing tests.
- **Risks:** Low.
- **Mitigations:** Migrate incrementally.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Single expert.

---

### 5.4 Wire generate-version.sh into Xcode Build Phases

- **Source experts:** Xcode/Claude Code Tooling
- **Description:** `generate-version.sh` runs in CI but not local builds. `BuildVersion.swift` is gitignored and becomes stale. Add a Run Script build phase before "Compile Sources."
- **Pros:** Every local build gets the correct commit hash.
- **Cons:** Adds a build phase.
- **Risks:** Low.
- **Mitigations:** Mark output file so Xcode knows it is generated.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 5.5 Add HealthKitManager Protocol for Mock Data

- **Source experts:** Developer Experience
- **Description:** The app is data-driven but the simulator has no HealthKit data. Create a protocol abstraction and `MockHealthKitManager` with static data, used in simulator builds.
- **Pros:** Development feasible without a physical device. Previews show realistic data.
- **Cons:** Maintaining mock alongside real implementation.
- **Risks:** Mock diverging from real behavior.
- **Mitigations:** Use `#if targetEnvironment(simulator)` conditional compilation.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Single expert.

---

### 5.6 Add watchOS Build Step to CI

- **Source experts:** Developer Experience
- **Description:** No CI workflow builds the watchOS target. Breaking changes are uncaught. Add a watchOS build step to ios-ci.yml.
- **Pros:** Catches watch compile errors.
- **Cons:** Adds CI time.
- **Risks:** Low.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 5.7 Expand AGENTS.md with Tool Guidance

- **Source experts:** Xcode/Claude Code Tooling
- **Description:** Current AGENTS.md is 7 lines. Should document XcodeBuildMCP vs raw xcodebuild usage, coverage workflow, and available tools.
- **Pros:** Better agent behavior in multi-agent workflows.
- **Cons:** Documentation maintenance.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 5.8 Add SwiftLint Step to CI

- **Source experts:** Developer Experience
- **Description:** SwiftLint is configured (`.swiftlint.yml`) but never runs in CI. Add a lint step to `ios-ci.yml`.
- **Pros:** Catches lint issues automatically.
- **Cons:** Minor CI time addition.
- **Risks:** Low.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

## 6. Clinical / Medical Value

---

### 6.1 Add Medication Dose Markers on Trend Charts

- **Source experts:** Health App UX, Medical
- **Description:** No trend chart shows when medications were taken. For anxiety tracking, knowing when benzos were taken relative to HRV changes is critical. Add dose markers (pill icons or rule marks) on Anxiety and HRV trend charts.
- **Pros:** Unlocks the core correlation insight. Makes medication effects visually obvious.
- **Cons:** Chart complexity.
- **Risks:** Visual clutter with many doses.
- **Mitigations:** Filter to relevant categories (benzos, stimulants). Make overlay toggleable.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Both recommended this. Strong agreement.

---

### 6.2 Build Medication Pattern Engine

- **Source experts:** Medical
- **Description:** Category-specific pattern analysis: (a) Benzo: rolling PRN frequency + efficacy decay (before/after severity delta over time) + rebound anxiety detection. (b) SSRI: onset lag tracking with expected timeline + activation syndrome detection. (c) Stimulant: peak-effect vs wearing-off anxiety correlation. All infrastructure exists; this is computation on existing data.
- **Pros:** Uniquely valuable clinical data. Benzo tolerance detection is "extremely valuable" for psychiatrists. SSRI onset tracking reduces premature discontinuation.
- **Cons:** Complex logic requiring clinical validation.
- **Risks:** False positives causing alarm. Over-interpreting patterns.
- **Mitigations:** Frame as observations, not diagnoses ("usage frequency has increased" not "you are developing tolerance"). Require minimum sample sizes.
- **Effort:** Large
- **Impact:** High
- **Expert consensus:** Single expert. Well-documented evidence base per medication class.

---

### 6.3 Embed Charts in PDF Clinical Report

- **Source experts:** Health App UX, Lived Experience
- **Description:** The PDF report has statistics but no visual charts. Render Swift Charts to UIImage and draw into the PDF. Include HRV trend, anxiety scatter plot, sleep chart, and medication timeline.
- **Pros:** Dramatically more useful for clinicians. Visual patterns are immediately apparent.
- **Cons:** Non-trivial PDF rendering.
- **Risks:** Chart quality may not match interactive charts.
- **Mitigations:** Start with 2-3 essential charts. Iterate.
- **Effort:** Large
- **Impact:** High
- **Expert consensus:** Both recommended this.

---

### 6.4 Add Dose-Anxiety Efficacy Section to Clinical Report

- **Source experts:** Health App UX, Lived Experience
- **Description:** Report shows dose counts but not before/after anxiety deltas. Add: "Patient self-reported anxiety decreased an average of X points within 30 minutes of [medication] across N administrations." Data psychiatrists almost never get.
- **Pros:** Directly informs prescribing decisions.
- **Cons:** Requires sufficient follow-ups.
- **Risks:** Small sample sizes misleading.
- **Mitigations:** Only show when N >= 5. Show sample size.
- **Effort:** Medium
- **Impact:** High
- **Expert consensus:** Both independently recommended this. Called "the headliner" for reports.

---

### 6.5 Show Before/After Delta After Dose Follow-Up

- **Source experts:** Health App UX
- **Description:** After completing a follow-up, show: "Before: 7/10 -> After: 4/10. Improvement of 3 points." No feedback currently exists. Creates a reward loop.
- **Pros:** Motivating. Validates medication. Reinforces tracking.
- **Cons:** Could be discouraging if no improvement.
- **Risks:** Negative deltas could amplify anxiety.
- **Mitigations:** Frame neutrally. "7 -> 7" is still useful data.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 6.6 Configurable Follow-Up Interval Per Medication

- **Source experts:** Health App UX, Medical, Lived Experience
- **Description:** Fixed 30-minute interval does not match pharmacokinetics. Sublingual lorazepam ~15 min, oral clonazepam ~30-60 min, beta-blockers ~45-60 min. Make configurable per `MedicationDefinition`.
- **Pros:** More accurate efficacy measurement.
- **Cons:** Configuration UI complexity.
- **Risks:** Low.
- **Mitigations:** Smart defaults per category. Allow override.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Three experts recommended this independently.

---

### 6.7 Expand Structured Tags for Anxiety Phenomenology

- **Source experts:** Medical
- **Description:** Add structured tag prefixes for onset speed (`onset:sudden` vs `onset:gradual`), physical symptoms (`symptom:palpitations`), and duration. Enables panic vs GAD pattern differentiation. No model changes -- existing tags array supports this.
- **Pros:** Richer clinical data. Pattern differentiation.
- **Cons:** More options could increase cognitive load.
- **Mitigations:** Quick-tap chips, not free text. Only show when expanding beyond basic entry.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert with clinical rationale.

---

### 6.8 Compute Heart Rate Recovery from Existing Data

- **Source experts:** Medical, HealthKit
- **Description:** HR drop in first 60s after exercise is one of the strongest vagal tone markers. Requires workout reading (3.1) + raw HR (already collected).
- **Pros:** Strong autonomic health marker. Free from existing data.
- **Cons:** Depends on workout reading implementation.
- **Risks:** HR granularity may be insufficient for 60-second windows.
- **Mitigations:** Use best-available HR sample within 2 minutes of workout end.
- **Effort:** Medium (after 3.1)
- **Impact:** Medium
- **Expert consensus:** Both recommended this.

---

### 6.9 Increase Baseline Window to 90 Days (Configurable)

- **Source experts:** Medical
- **Description:** A 30-day window shifts to include prolonged anxious periods, masking the deviation. Use 90-day for baseline with 7-day rolling for "current." Also consider per-metric thresholds (1.5 SD for noisy HRV, 1 SD for stable RHR).
- **Pros:** Prevents baseline contamination during prolonged episodes.
- **Cons:** Requires 90 days for full accuracy.
- **Risks:** Seasonal variation in longer window.
- **Mitigations:** Make configurable. Start at 30, allow extension.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert with strong clinical rationale.

---

### 6.10 Nocturnal HR Spike and HRV Circadian Rhythm Detection

- **Source experts:** Medical
- **Description:** Two derived patterns: (a) Overnight max HR exceeding resting HR by >40% predicts next-day anxiety and detects nocturnal panic. (b) Flattening of the daytime-vs-overnight HRV ratio indicates chronic anxiety/PTSD.
- **Pros:** High clinical value from existing data.
- **Cons:** Complex pattern computation.
- **Risks:** False positives from movement/nocturia.
- **Mitigations:** Require multiple nights. Annotate with sleep quality context.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Single expert. Published evidence base (Uhde et al., Brindle et al.).

---

## 7. Pharmacy & Prescription Improvements

---

### 7.1 Store `daysSupply` on Prescription Model

- **Source experts:** Retail Pharmacy
- **Description:** CapRx API returns `days_supply` and the server uses it for `estimatedRunOutDate`, but the integer is not stored on the model. Days supply from the PBM is more authoritative than quantity-based computation. Store it and use as primary input.
- **Pros:** More accurate supply tracking.
- **Cons:** Model + migration.
- **Risks:** Low.
- **Mitigations:** Default to quantity-based calculation when nil.
- **Effort:** Small
- **Impact:** High
- **Expert consensus:** Single expert. Clear data modeling improvement.

---

### 7.2 Store CapRx Cost Fields (patientPay, planPay, dosageForm, drugType)

- **Source experts:** Retail Pharmacy
- **Description:** `normalize_claim` extracts these but they are never stored or passed to iOS. Cost trends help patients understand formulary changes. Dosage form distinguishes tablet vs ODT vs solution.
- **Pros:** Cost tracking. Formulary change visibility. Formulation tracking.
- **Cons:** Schema and model additions.
- **Risks:** Low.
- **Mitigations:** Implement incrementally.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 7.3 Add Refill Eligibility Date

- **Source experts:** Retail Pharmacy
- **Description:** Show "Eligible to refill" (~75% through days supply) alongside "Supply runs out." Insurance typically allows refills at 75-80%. For anxiety meds, therapy gaps trigger withdrawal or rebound.
- **Pros:** Patients refill proactively. Reduces therapy gaps.
- **Cons:** 75% threshold varies by plan.
- **Risks:** Insurance rejection if threshold is wrong.
- **Mitigations:** 75% default with a note. Allow override.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 7.4 Add DEA Schedule Awareness

- **Source experts:** Retail Pharmacy
- **Description:** Add `deaSchedule` to `MedicationDefinition`. Show "New Rx required" for Schedule II instead of "0 refills." Show refill/expiry countdown for III-IV. Earlier alerts for Schedule II (requires prescriber appointment).
- **Pros:** Accurate refill messaging. Proactive alerts.
- **Cons:** Users must set schedule (or auto-populate from category).
- **Risks:** Incorrect schedule = wrong guidance.
- **Mitigations:** Pre-populate for known categories (benzo=IV, stimulant=II).
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 7.5 Show "Unknown" for Refills on Claims-Sourced Records

- **Source experts:** Retail Pharmacy
- **Description:** `refillsRemaining` is set to 0 for CapRx imports because PBM data does not include this. "0 refills" is misleading. Show "Unknown" instead.
- **Pros:** No user confusion.
- **Cons:** None.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 7.6 Group Prescription History by Medication

- **Source experts:** Retail Pharmacy
- **Description:** Each CapRx claim is a separate row. Show medications as groups: most-recent fill details, expandable history, cost trends. Patients think "I take 4 medications" not "I have 12 prescriptions."
- **Pros:** Matches mental model. Cleaner UI. Enables cost tracking.
- **Cons:** Grouping logic needed.
- **Risks:** Incorrect grouping of different formulations.
- **Mitigations:** Include doseMg and dosageForm in grouping key.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 7.7 Detect Therapy Gaps Between Fills

- **Source experts:** Retail Pharmacy
- **Description:** Compare expected refill dates with actual fill dates. Flag gaps. SSRI gaps cause discontinuation syndrome. Benzo gaps cause rebound.
- **Pros:** Clinical safety. Adherence insight for reports.
- **Cons:** Depends on reliable fill data.
- **Risks:** Partial fills or manual sources create false positives.
- **Mitigations:** Only flag gaps > 3 days. Allow override.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 7.8 Filter Out Reversed/Rejected Claims from CapRx

- **Source experts:** Retail Pharmacy
- **Description:** The server does not check claim status. Reversed claims (medication returned, claim reprocessed) are imported as valid fills. Filter on the server side.
- **Pros:** Prevents phantom fills.
- **Cons:** Depends on CapRx exposing claim status.
- **Risks:** Low.
- **Mitigations:** Check if CapRx API provides status field. If not, defer.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

## 8. Nice-to-Haves

---

### 8.1 Home Screen Widget (WidgetKit)

- **Source experts:** Health App UX
- **Description:** Quick-log widget opening to severity picker. Status widget with HRV, anxiety, sleep. Lock Screen widget for HRV vs baseline.
- **Pros:** Fastest path to logging. Glanceable metrics.
- **Cons:** WidgetKit limitations on interactivity and freshness.
- **Risks:** Stale data.
- **Mitigations:** Appropriate refresh intervals.
- **Effort:** Large
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 8.2 Implement watchOS Complication

- **Source experts:** Health App UX, Lived Experience
- **Description:** REQUIREMENTS.md lists a complication but none is implemented. Show HRV or last anxiety, or "time since last log."
- **Pros:** Glanceable from watch face.
- **Cons:** Severe data refresh limitations.
- **Risks:** Stale data.
- **Mitigations:** Timeline-based updates.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Two experts mentioned this.

---

### 8.3 "This Too Shall Pass" View

- **Source experts:** Lived Experience
- **Description:** Show personal history of panic attacks resolving: "You have logged 47 episodes rated 7+. Average duration until improvement: 34 minutes. You have survived every one." Personal evidence of recovery is uniquely grounding during panic.
- **Pros:** Direct therapeutic value from the user's own data.
- **Cons:** Requires sufficient history.
- **Risks:** Could feel patronizing.
- **Mitigations:** Only show after 5+ high-severity episodes with subsequent lower entries. Frame factually.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Single expert. Compelling rationale.

---

### 8.4 Proactive Pattern Detection and Insight Surfacing

- **Source experts:** Lived Experience, Health App UX
- **Description:** Surface simple insights proactively: "Anxiety is higher on days with <6h sleep." "Exercise 30+ min correlates with 3.2 avg anxiety vs 5.8 sedentary." Currently deferred to V2/Claude exports.
- **Pros:** Transforms app from data collection to insight delivery.
- **Cons:** Complex computation. Risk of misleading insights.
- **Risks:** Statistical noise presented as patterns. Acting on spurious correlations.
- **Mitigations:** 30+ day minimums. Confidence qualifiers. Start with simplest correlations (sleep, exercise).
- **Effort:** Large
- **Impact:** High
- **Expert consensus:** Two experts identified this as the biggest opportunity gap. Called "the missing layer."

---

### 8.5 Medication Adherence Tracking (Expected vs. Actual)

- **Source experts:** Health App UX, Retail Pharmacy
- **Description:** Optional "doses per day" on `MedicationDefinition`. Show adherence percentage in meds section and reports. Not applicable to PRN.
- **Pros:** Critical clinical data. Most common question at psychiatric visits.
- **Cons:** Users must set expected frequency.
- **Risks:** Guilt about missed doses could worsen anxiety.
- **Mitigations:** Frame positively ("18 of 21 days"). Never "missed" or "failed." Optional.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Two experts recommended this.

---

### 8.6 Cross-Metric Correlation View in Trends

- **Source experts:** Health App UX, Lived Experience
- **Description:** Explicit correlation visualizations: "Sleep vs Next-Day Anxiety" scatter plot, "Exercise vs Anxiety," medication-aware overlays.
- **Pros:** Surfaces the patterns the system is designed to find.
- **Cons:** Complex chart design.
- **Risks:** Misleading with small datasets.
- **Mitigations:** Minimum data requirements. Show correlation strength.
- **Effort:** Large
- **Impact:** Medium
- **Expert consensus:** Two experts recommended this.

---

### 8.7 Accessibility Improvements (VoiceOver, Dynamic Type)

- **Source experts:** iOS UI/UX
- **Description:** Multiple gaps: LiveMetricCard has no accessibilityElement grouping. SparklineView, ProgressBarView, SleepStagesView are invisible to VoiceOver. SeverityBadge has poor contrast (white on yellow). Several views use fixed-size fonts that don't scale.
- **Pros:** VoiceOver usability. Accessibility compliance.
- **Cons:** Effort across many views.
- **Risks:** Low.
- **Mitigations:** Address incrementally starting with most-used views.
- **Effort:** Medium (cumulative)
- **Impact:** Medium (critical for accessibility users)
- **Expert consensus:** Single expert with detailed findings.

---

### 8.8 Dashboard Loading State and HealthKit Error Guidance

- **Source experts:** iOS UI/UX
- **Description:** No loading state during data fetch. No guidance when HealthKit isn't authorized. Add ProgressView and permission banner.
- **Pros:** Better first-launch experience.
- **Cons:** Minor effort.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 8.9 FetchDescriptor Limit on Dashboard loadSamples()

- **Source experts:** iOS UI/UX
- **Description:** Fetches ALL HealthSample records with no date filter or limit. With months of data this is a memory/performance problem. Add a 7-day date filter.
- **Pros:** Prevents unbounded memory growth.
- **Cons:** Historical data needs separate query if needed.
- **Risks:** Low.
- **Mitigations:** 7-day window is sufficient for sparklines.
- **Effort:** Small
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 8.10 Add Notification Actions to Follow-Up Notifications

- **Source experts:** Health App UX
- **Description:** `UNNotificationAction` for "Rate Anxiety" directly from notification banner.
- **Pros:** Lower friction. Higher completion rate.
- **Cons:** iOS action UI is limited.
- **Risks:** Low.
- **Mitigations:** N/A.
- **Effort:** Medium
- **Impact:** Medium
- **Expert consensus:** Single expert.

---

### 8.11 Weekday/Weekend Baseline Stratification

- **Source experts:** HealthKit, Medical
- **Description:** Many people have different HRV/sleep on weekdays vs weekends. A blended average causes every Monday to flag. Consider separate baselines.
- **Pros:** Fewer false-positive Monday alerts.
- **Cons:** Doubles computation. Only ~9 weekend days per 30-day window.
- **Risks:** Insufficient per-bucket data.
- **Mitigations:** Fall back to combined when sample count is low.
- **Effort:** Medium
- **Impact:** Low
- **Expert consensus:** Both mentioned this.

---

### 8.12 Reduce Background Delivery Frequency for Low-Change Metrics

- **Source experts:** HealthKit
- **Description:** `.immediate` for all types is aggressive. Use `.hourly`/`.daily` for VO2 max, walking steadiness, AFib burden. Keep `.immediate` for HR, HRV, SpO2.
- **Pros:** Better battery life.
- **Cons:** Slightly delayed updates for infrequent metrics.
- **Risks:** None.
- **Mitigations:** N/A.
- **Effort:** Small
- **Impact:** Low
- **Expert consensus:** Single expert.

---

## 9. Rejected Suggestions

### Location Tagging on Journal Entries
- **Source:** REQUIREMENTS.md mentions optional location
- **Why rejected:** The lived experience expert: "I know where I was when I got anxious. I do not need GPS to tell me it was at work. And the privacy implications of a detailed anxiety-location map make me uncomfortable." Tags capture location context more safely.

### Environmental Sound and Headphone Audio as Dashboard Cards
- **Source:** Currently displayed on dashboard
- **Why rejected:** Lived experience expert: "I have never once thought 'I bet my anxiety is high because the ambient noise level is 72 dBA.'" Not actionable daily. Keep collecting the data but demote or hide from the dashboard.

### Walking Steadiness and VO2 Max on Dashboard
- **Source:** Currently displayed on dashboard
- **Why rejected:** Lived experience expert: "Walking steadiness is a fall risk metric. VO2 Max is a fitness metric that changes over weeks." Neither is anxiety-relevant daily. Move to a secondary section or remove.

### Full MVVM Architecture for All Views
- **Source:** Refactoring expert
- **Why rejected:** The expert themselves concluded: "The app does not need a formal architectural framework." Simple CRUD views (AddMedicationView, AddPharmacyView) are fine as-is. Only extract view models where complexity warrants it (Dashboard, MedicationsHub).

### SwiftFormat Enforcement
- **Source:** Developer Experience expert
- **Why rejected:** Rated "Low" priority by the expert for a solo project. SwiftLint already covers meaningful issues. The cost of setup and maintenance outweighs the benefit.

### Serena Plugin Configuration
- **Source:** Xcode/Claude Code expert
- **Why rejected:** `swift-lsp` already provides symbol navigation for Swift, making Serena redundant. Remove to reduce tool noise rather than investing in configuration.

### Playwright MCP Cleanup
- **Source:** Xcode/Claude Code expert
- **Why rejected:** Pure housekeeping with no functional impact. Not worth including in a prioritized plan.

### Blood Glucose / CGM Integration
- **Source:** REQUIREMENTS.md Tier 3
- **Why rejected:** Lived experience expert: "For most anxiety patients, the CGM integration is a solution looking for a problem." Remains Tier 3 / deferred until there is a confirmed personal need.

### Separate Prescription/PrescriptionFill Data Model
- **Source:** Retail Pharmacy expert
- **Why rejected:** The expert themselves concluded: "Since you do not have the original Rx number from CapRx, you cannot reliably group fills. Keep the current flat model but add computed grouping." The cleaner model is not feasible with available data.

### Screen Time Integration
- **Source:** Medical expert
- **Why rejected:** The expert rated it "high friction to implement" and recommended deferring. The Screen Time API is restricted and the signal-to-effort ratio is poor.

---

## Implementation Sequence

### Phase 1: Critical Fixes (1-2 days)
Items 1.1-1.7. Bugs, broken behavior, and silent-failure conditions.

### Phase 2: Foundation for Quality (1 week)
- Architecture: 4.1 (DashboardViewModel), 4.2 (supply alert filter), 4.3 (severity color)
- DX: 5.1 (Makefile), 5.3 (TestHelpers), 5.4 (build phase)
- Cleanup: 4.4 (delete dead code), 4.5 (error logging)

### Phase 3: Core UX (1-2 weeks)
Items 2.1-2.5, 2.7-2.9 -- quick log on dashboard, section grouping, severity circles, quick tags, last-taken timestamps, trend colors, pull-to-refresh, Watch improvements.

### Phase 4: HealthKit Expansion (1 week)
Items 3.1-3.2, 3.4-3.9 -- workout type, time in daylight, physical effort, overnight HRV, sleep onset latency, BP correlation, breathing disturbances, sleep/respiratory baselines.

### Phase 5: Clinical Value (2 weeks)
Items 6.1, 6.4-6.7, 7.1, 7.5 -- medication markers on charts, efficacy in reports, before/after delta, configurable follow-ups, structured tags, days supply, refill display fix.

### Phase 6: Advanced Features (ongoing)
Breathing exercise (2.6), composite summary (2.11), HKStateOfMind (3.3), medication pattern engine (6.2), charts in PDF (6.3), proactive insights (8.4), widgets/complications (8.1-8.2), and remaining items.

---

## Expert Agreement Matrix

| Topic | Experts in Agreement | Dissent |
|-------|---------------------|---------|
| Quick log on Dashboard | iOS UI/UX, Health App UX, Lived Experience | None |
| Dashboard needs section grouping | iOS UI/UX, Health App UX, Lived Experience | None |
| Quick tags for journal | iOS UI/UX, Health App UX, Lived Experience | None |
| CI must actually enforce tests | Developer Experience, Xcode/Claude Code | None |
| Delete MedicationListView (dead code) | iOS UI/UX, Health App UX, Refactoring | None |
| Configurable follow-up timing | Health App UX, Medical, Lived Experience | None |
| Add HKWorkoutType | HealthKit, Medical | None |
| Add timeInDaylight | HealthKit, Medical | None |
| BaselineCalculator needs N-1 and higher minimum | HealthKit, Medical | None |
| Severity slider -> tappable circles | Health App UX, Lived Experience | None |
| Medication dose markers on trend charts | Health App UX, Medical | None |
| Breathing exercise needed | Health App UX, Lived Experience | None |
| DashboardView needs ViewModel extraction | iOS UI/UX, Refactoring | None |
| Overnight HRV as separate field | HealthKit, Medical | None |
| Reports should include efficacy data | Health App UX, Lived Experience | None |
| Supply alert filtering is triplicated | Refactoring (confirmed by others) | None |
| Environmental sound/VO2 Max low dashboard value | Lived Experience | Medical notes some aggregate value for sound |
| Location tagging not useful to build | Lived Experience | REQUIREMENTS.md lists as optional |
