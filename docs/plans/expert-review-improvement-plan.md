# AnxietyWatch Expert Review Improvement Plan

**Date:** 2026-03-28
**Reviewers:** 9 domain experts (iOS UI/UX, Health App UX, HealthKit, Refactoring, Anxiety/Panic Medical, Lived Experience, Developer Experience, Retail Pharmacy, Xcode/Claude Code Tooling)
**Scope:** Full codebase and feature review across all dimensions

---

## Table of Contents

1. [Critical Fixes](#1-critical-fixes)
2. [High-Impact UX Improvements](#2-high-impact-ux-improvements)
3. [HealthKit & Data Collection](#3-healthkit--data-collection)
4. [Architecture & Code Quality](#4-architecture--code-quality)
5. [Developer Experience](#5-developer-experience)
6. [Clinical / Medical Value](#6-clinical--medical-value)
7. [Nice-to-Haves](#7-nice-to-haves)
8. [Rejected Suggestions](#8-rejected-suggestions)

---

## 1. Critical Fixes

These are bugs, broken behavior, or silent-failure conditions that undermine existing functionality.

---

### 1.1 iOS CI Is Non-Blocking (`continue-on-error: true`)

**Source experts:** Developer Experience, Xcode/Claude Code Tooling
**Description:** The `ios-ci.yml` workflow has `continue-on-error: true`, which means test failures are silently ignored. All 21 test files and their assertions are effectively decorative -- broken code can be merged to `main` without any gate.
**What to do:** Remove `continue-on-error: true` from the iOS CI workflow. If the issue is Xcode version availability on runners, pin to an available Xcode version (e.g., Xcode 16) for now, or use a matrix that tries multiple versions. Once the CI is enforcing, add it as a required status check in the repo's branch protection rules.
**File:** `.github/workflows/ios-ci.yml`
**Pros:** Tests actually prevent regressions; CI becomes trustworthy.
**Cons:** May require fixing currently-broken tests before the change.
**Risks:** If tests are currently failing, this blocks all PRs until fixed.
**Mitigations:** Run the full test suite locally first. Fix any failures before removing the flag. Roll out in a single PR.
**Effort:** Small
**Impact:** High
**Expert consensus:** Unanimous. Both experts who discussed CI flagged this as the top CI issue.

---

### 1.2 Anchored Query Predicate Drops Samples After Extended Device Downtime

**Source experts:** HealthKit
**Description:** In `HealthKitManager.startAnchoredQueries()`, the 7-day retention predicate is applied even when the anchor is non-nil. If the device was off for more than 7 days, samples between the anchor and the 7-day cutoff are silently dropped. The predicate should only apply when the anchor is nil (first run).
**What to do:** Wrap the predicate in a nil-anchor check:
```swift
let predicate: NSPredicate? = (anchor == nil) ? retentionStart.map {
    HKQuery.predicateForSamples(withStart: $0, end: nil)
} : nil
```
**File:** `AnxietyWatch/Services/HealthKitManager.swift`, around line 298
**Pros:** Prevents silent data loss after extended periods without the app running.
**Cons:** None meaningful.
**Risks:** Low -- the fix is a simple conditional.
**Mitigations:** Test with both nil and non-nil anchors.
**Effort:** Small
**Impact:** High
**Expert consensus:** Single expert identified this, but the bug is clear and unambiguous.

---

### 1.3 BaselineCalculator Uses Population Variance (N) Instead of Sample Variance (N-1)

**Source experts:** HealthKit, Medical
**Description:** `BaselineCalculator` divides by `N` (population variance) instead of `N-1` (Bessel's correction). With small sample sizes early in app usage, this underestimates the standard deviation, making baseline bounds too tight and triggering false-positive alerts.
**What to do:** Change the variance calculation to divide by `values.count - 1`:
```swift
let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
```
**File:** `AnxietyWatch/Services/BaselineCalculator.swift`, around line 73
**Pros:** Correct statistics; fewer false-positive baseline alerts.
**Cons:** Slightly wider bounds, meaning marginally fewer true-positive alerts.
**Risks:** Very low.
**Mitigations:** Update existing baseline tests to expect the corrected values.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both HealthKit and Medical experts independently identified this exact issue.

---

### 1.4 BaselineCalculator Minimum Sample Count Is Too Low (3)

**Source experts:** HealthKit, Medical
**Description:** The baseline requires only 3 values to compute a standard deviation. With 3 data points, the standard deviation is statistically meaningless and will produce erratic baseline bands during the user's first week.
**What to do:** Increase the minimum to 14 (two weeks of data). Add a UI indicator showing "Collecting baseline data (X/14 days)" until sufficient data exists.
**File:** `AnxietyWatch/Services/BaselineCalculator.swift`, around line 69
**Pros:** Baseline alerts become meaningful; reduces noise in the first weeks.
**Cons:** Users must wait 14 days before seeing baseline comparisons.
**Risks:** Users might perceive the app as having less functionality initially.
**Mitigations:** Show a progress indicator ("Collecting baseline: 8 of 14 days"). Consider allowing a lower threshold (7) with a "preliminary" label.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts recommended 14 days. Medical expert went further, suggesting a 90-day window for the baseline itself.

---

### 1.5 Prescription Staleness Filter Breaks for 90-Day Mail Order Fills

**Source experts:** Pharmacy, Refactoring
**Description:** `alertStalenessLimitDays = 60` is a fixed constant. A 90-day mail order fill will age past 60 days while the patient still has supply, causing the supply alert to disappear prematurely.
**What to do:** Make the staleness limit relative to the prescription's own days supply (or estimated days supply). Use `max(daysSupply + 30, 60)` as the staleness threshold so that a 90-day fill stays visible for at least 120 days.
**File:** `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`
**Pros:** Supply alerts remain visible for the actual duration of the prescription.
**Cons:** Requires knowing `daysSupply`, which needs to be stored on the model (see item 3.6).
**Risks:** If `daysSupply` is missing, the fallback to a fixed value is still needed.
**Mitigations:** Keep the 60-day default as a fallback when `daysSupply` is nil.
**Effort:** Small
**Impact:** High (for anyone on 90-day fills)
**Expert consensus:** Pharmacy expert identified as a functional bug. Refactoring expert noted the triple-duplicated supply alert logic as the place to fix.

---

### 1.6 `refillsRemaining` Shows 0 for CapRx-Sourced Prescriptions (Misleading)

**Source experts:** Pharmacy
**Description:** CapRx claims data does not include refills remaining. The field defaults to 0, which is displayed to the user as "0 refills" -- implying the prescription cannot be refilled when in reality the data is simply unavailable.
**What to do:** Show "Unknown" for refills on claims-sourced records (`importSource == "caprx"`) rather than "0". Change the UI to differentiate between "0 refills authorized" and "refill data not available."
**Files:** `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift`, `AnxietyWatch/Models/Prescription.swift`
**Pros:** Prevents user confusion and incorrect decisions about contacting prescriber.
**Cons:** None.
**Risks:** Minimal.
**Mitigations:** Add a computed property `refillsDisplay: String?` that returns nil for claims-sourced records.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert, but the issue is factually clear.

---

### 1.7 `navigationDestination(for:)` Scoped Inside Conditional View

**Source experts:** iOS UI/UX
**Description:** In `MedicationsHubView.swift` (line 113), `.navigationDestination(for: UUID.self)` is registered inside the `supplyAlertSection` `@ViewBuilder`. If there are no supply alerts, the navigation destination is never registered, and tapping a supply alert link from elsewhere would fail. Similarly, `PharmacyDetailView` has a `NavigationLink(value: rx)` with no corresponding `.navigationDestination` for `Prescription.self`.
**What to do:** Move `.navigationDestination` registrations to the `NavigationStack` level or `List` level, not inside conditional sections.
**Files:** `AnxietyWatch/Views/Medications/MedicationsHubView.swift`, `AnxietyWatch/Views/Pharmacy/PharmacyDetailView.swift`
**Pros:** Navigation works reliably regardless of view state.
**Cons:** None.
**Risks:** Low.
**Mitigations:** Test navigation paths with empty and populated data.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert, but this is a known SwiftUI pitfall.

---

### 1.8 `.alert` Binding Anti-Pattern in ExportView and CPAPListView

**Source experts:** iOS UI/UX
**Description:** Both `ExportView.swift` and `CPAPListView.swift` use `.alert("...", isPresented: .constant(errorMessage != nil))`, creating a binding to a constant. The alert cannot be dismissed by SwiftUI's built-in mechanism; it relies on manually nilling the error message inside the "OK" action. This pattern can cause issues with sheet/alert lifecycle management.
**What to do:** Replace with a proper `Binding<Bool>` computed from the optional, or use `.alert(item:)`.
**Files:** `AnxietyWatch/Views/Reports/ExportView.swift`, `AnxietyWatch/Views/CPAP/CPAPListView.swift`
**Pros:** Standard SwiftUI patterns; avoids subtle dismissal bugs.
**Cons:** None.
**Risks:** Low.
**Mitigations:** Verify alert dismissal works correctly after the change.
**Effort:** Small
**Impact:** Low
**Expert consensus:** Single expert.

---

## 2. High-Impact UX Improvements

Changes that meaningfully improve the user experience, especially for someone actively managing anxiety.

---

### 2.1 Add "Log Anxiety" Quick Action on the Dashboard

**Source experts:** iOS UI/UX, Health App UX, Lived Experience
**Description:** The Dashboard (first tab, most-visited screen) shows the last anxiety entry but has no button to create a new one. The user must switch to the Journal tab and tap "+". During acute anxiety, every extra tap matters. Add a prominent "Log Now" button directly on the Dashboard, near the anxiety section at the top. One tap should open a minimal severity picker (not the full form).
**What to do:** Add a tappable "Log Anxiety" button at the top of `DashboardView`, near the anxiety metric card. It should present a streamlined severity picker sheet (numbered circles, not a slider), with notes and tags as optional collapsible sections. Save on tap of a severity number; dismiss immediately.
**Files:** `AnxietyWatch/Views/Dashboard/DashboardView.swift` (add button), new file `AnxietyWatch/Views/Journal/QuickAnxietyLogView.swift` (minimal picker)
**Pros:** Eliminates the most common extra-tap friction for the app's core action.
**Cons:** Another sheet to maintain; need to keep quick log and full form in sync.
**Risks:** Users might stop using the full journal form, reducing data richness.
**Mitigations:** After quick-logging, offer a "Add notes?" expandable prompt. Show the entry in journal list for retroactive annotation.
**Effort:** Medium
**Impact:** High
**Expert consensus:** All three UX-focused experts independently recommended this as a top-priority item.

---

### 2.2 Group Dashboard Cards into Labeled Sections

**Source experts:** iOS UI/UX, Health App UX, Lived Experience
**Description:** The Dashboard renders 18+ metric cards in a single flat `VStack` with no grouping. Every metric gets equal visual weight. This is overwhelming, especially during anxiety when cognitive load should be minimized. Group cards into titled sections: "Anxiety & Mood" (pinned at top), "Sleep" (sleep + CPAP), "Heart & Autonomic" (HR, HRV, RHR, BP), "Activity" (steps, exercise, calories), "Other" (sound, barometric, glucose).
**What to do:** Wrap dashboard cards in `Section`-like headers within the `ScrollView`. Elevate the anxiety entry card to a prominent position at the top with the colored severity badge and time-since-last-entry.
**File:** `AnxietyWatch/Views/Dashboard/DashboardView.swift`
**Pros:** Scannable at a glance; most important data is visible first without scrolling.
**Cons:** Increases view nesting; may need collapsible sections (more code).
**Risks:** Could break existing layout expectations.
**Mitigations:** Keep the same cards; just wrap them in groups. Test with various data availability scenarios (no CPAP, no BP, etc.).
**Effort:** Medium
**Impact:** High
**Expert consensus:** Unanimous among all UX experts. The Lived Experience expert was especially emphatic that the current wall of data is counterproductive during high anxiety.

---

### 2.3 Replace Severity Slider with Tappable Numbered Circles

**Source experts:** Health App UX, Lived Experience
**Description:** The iOS `Slider` control is difficult to use with trembling hands during anxiety. Replace with a grid of 10 large, tappable, color-coded circles (at least 44x44pt each for accessibility compliance). Add descriptive anchors at key points: 1-2 "Calm", 3-4 "Mild", 5-6 "Moderate", 7-8 "High / physical symptoms", 9-10 "Panic / crisis".
**What to do:** Replace the `Slider` in `AddJournalEntryView` and `QuickAnxietyLogView` with a horizontal row of 10 numbered circles. Each circle is color-coded using the existing `severityColor`. Tap to select. Add text anchors below the row.
**File:** `AnxietyWatch/Views/Journal/AddJournalEntryView.swift`
**Pros:** Usable during panic; provides scale calibration that reduces rating drift over time.
**Cons:** Takes more vertical space than a slider.
**Risks:** Users accustomed to the slider may find it jarring.
**Mitigations:** The numbered circles are objectively better for discrete integer selection on a 1-10 scale. The Watch continues to use Digital Crown.
**Effort:** Small
**Impact:** High
**Expert consensus:** Both experts recommended this. Lived Experience expert noted most people collapse a 1-10 slider to ~4 values anyway.

---

### 2.4 Add Severity Scale Descriptive Anchors

**Source experts:** Lived Experience, Medical
**Description:** The 1-10 severity scale currently has only "Calm" and "Severe" as endpoints. Users self-calibrate inconsistently, reducing data quality. Add anchors: 1-2 "Baseline / calm", 3-4 "Mild, manageable", 5-6 "Moderate, affecting concentration", 7-8 "High, physical symptoms", 9-10 "Panic / crisis".
**What to do:** Add descriptive text below the severity selector in both the iPhone journal form and Watch Quick Log. Consider also showing the anchor in the severity badge throughout the app.
**Files:** `AnxietyWatch/Views/Journal/AddJournalEntryView.swift`, `AnxietyWatch Watch App/QuickLogView.swift`, `DoseAnxietyPromptView.swift`
**Pros:** More consistent self-reporting improves trend data quality and clinical report reliability.
**Cons:** Slightly more visual clutter on the entry form.
**Risks:** Low.
**Mitigations:** Keep anchors subtle (small text, muted color) so they guide without dominating.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts independently identified this need.

---

### 2.5 Show "Last Taken" Time Next to Quick Log Medication Buttons

**Source experts:** Health App UX, Lived Experience
**Description:** The Quick Log section in `MedicationsHubView` shows a "Log Dose" button per medication but not when the last dose was taken. For medications where double-dosing is dangerous (stimulants, benzos), seeing "Last taken: 8:15 AM" next to the button prevents errors. During panic, users genuinely forget whether they already took something.
**What to do:** Below each medication name in the Quick Log section, show the timestamp of the most recent dose today (or "Not taken today" if none). Highlight in a warning color if the last dose was within a short window of the medication's expected frequency.
**File:** `AnxietyWatch/Views/Medications/MedicationsHubView.swift`
**Pros:** Prevents accidental double-dosing; provides useful context.
**Cons:** Requires a query per medication (minor performance consideration).
**Risks:** Low.
**Mitigations:** Batch-fetch recent doses for all active medications in a single query.
**Effort:** Small
**Impact:** High
**Expert consensus:** Both experts recommended this. Lived Experience expert specifically flagged double-dosing risk during panic.

---

### 2.6 Add Breathing Exercise / Grounding Tool

**Source experts:** Health App UX, Lived Experience
**Description:** Every clinical anxiety app includes a breathing pacer or grounding prompt because it is the most immediately helpful intervention during a panic attack. AnxietyWatch has nothing for the acute moment. Add a simple timed breathing animation (breathe in 4s, hold 4s, out 6s) accessible from the Dashboard and the Watch Quick Log.
**What to do:** Create a `BreathingExerciseView` with a simple expanding/contracting circle animation, timed breathing prompts, and haptic feedback on transitions. Add access from: (1) a "Need help?" button near the Dashboard quick-log, (2) the Watch Quick Log screen, (3) an optional home-screen widget shortcut.
**Files:** New `AnxietyWatch/Views/Journal/BreathingExerciseView.swift`, update `DashboardView.swift` and Watch `QuickLogView.swift`
**Pros:** Provides immediate practical help during the moment the app should be most useful. Writes a mindful session to HealthKit.
**Cons:** Scope creep beyond data tracking into intervention.
**Risks:** Could feel half-baked compared to dedicated breathing apps (Calm, Headspace).
**Mitigations:** Keep it minimal: one breathing pattern, simple animation, no audio. Link to Apple Watch's built-in Breathe app as an alternative.
**Effort:** Medium
**Impact:** High
**Expert consensus:** Both experts rated this as essential. HealthKit expert also noted this enables writing `HKCategoryTypeIdentifier.mindfulSession` to HealthKit.

---

### 2.7 Add Quick Tags (Tappable Chips) to Journal Entry Form

**Source experts:** iOS UI/UX, Health App UX, Lived Experience
**Description:** Free-text tag entry requires typing during crisis, which is unrealistic. Show the user's most-used tags as tappable chips above the text input. One tap to toggle a tag on/off. Keep the free-text "Add tag" input below for new tags.
**What to do:** Query the most frequently used tags (top 8-10). Display as horizontally scrolling chips in the tags section. Tapping a chip toggles it in the entry's tag list.
**File:** `AnxietyWatch/Views/Journal/AddJournalEntryView.swift`
**Pros:** Dramatically faster tag entry; encourages consistent tagging which improves pattern analysis.
**Cons:** Need to maintain a tag frequency counter.
**Risks:** Low.
**Mitigations:** Use a simple `@Query` over existing `AnxietyEntry.tags` to compute frequencies. No new model needed.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Three experts recommended this independently.

---

### 2.8 Dose-Triggered Follow-Up: Show Before/After Delta

**Source experts:** Health App UX, Lived Experience
**Description:** After completing a medication follow-up, the user gets no feedback about the change. Showing "Before: 7/10 -> After: 4/10. Improvement of 3 points" creates a meaningful reward loop and reinforces medication efficacy awareness.
**What to do:** After saving a follow-up anxiety entry, display a brief summary card showing the pre-dose severity, post-dose severity, and the delta. Auto-dismiss after 5 seconds or on tap.
**File:** `AnxietyWatch/Views/Medications/DoseAnxietyPromptView.swift`
**Pros:** Motivational; creates data awareness; reinforces the tracking habit.
**Cons:** Adds a transient UI element.
**Risks:** Could feel patronizing if the delta is 0 or negative (medication did not help).
**Mitigations:** Show the delta neutrally without judgment. "Before: 7, After: 8" is still valid data.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts recommended this.

---

### 2.9 Fix Trend Arrow Colors for Context-Dependent Metrics

**Source experts:** iOS UI/UX
**Description:** In `LiveMetricCard`, trend arrows use fixed colors: rising=orange, stable=green, dropping=blue. For HR, rising=orange is correct (caution). But for HRV, rising should be green (positive), not orange. The color should be context-dependent, like `baselineColor` already is for the main value.
**What to do:** Add a `risingIsGood: Bool` parameter to `LiveMetricCard` (defaulting to `false`). When true, swap the rising/dropping colors.
**File:** `AnxietyWatch/Views/Dashboard/LiveMetricCard.swift`
**Pros:** Correct color communication; avoids misleading the user.
**Cons:** One more parameter.
**Risks:** Low.
**Mitigations:** Default to current behavior so only explicitly flagged metrics change.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert, but the bug is clear.

---

### 2.10 Watch Quick Log: Remove Modal Alert, Show Last Entry Context

**Source experts:** Lived Experience
**Description:** The Watch Quick Log shows a modal `alert("Logged")` that requires tapping "OK" to dismiss. The haptic feedback is sufficient confirmation. Additionally, the log defaults to severity 5 every time, but defaulting to the last-logged severity would require less adjustment. Show "Last: 6, 2 hours ago" at the top for context.
**What to do:** (1) Replace the modal alert with a brief checkmark animation that auto-dismisses. (2) Default the severity to the user's last-logged value. (3) Show last entry severity and time-since at the top of the Quick Log screen.
**File:** `AnxietyWatch Watch App/QuickLogView.swift`
**Pros:** Faster interaction; better context for choosing a severity number.
**Cons:** Defaulting to last value could bias toward repeating the same number.
**Risks:** Low.
**Mitigations:** Keep Digital Crown easily adjustable so the default is just a starting point.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert (lived experience), but the suggestions are specific and well-reasoned.

---

### 2.11 Move Export/Reports to a More Discoverable Location

**Source experts:** iOS UI/UX, Health App UX
**Description:** Export and clinical reports are buried in the Settings tab. For an "export-first" app where clinical reports are a key value proposition, this is too hidden. Make reports accessible from the Trends tab via a toolbar button, or add a "Reports" section to the Medications hub.
**What to do:** Add a toolbar button (document icon) to `TrendsView` that navigates to `ExportView`. Optionally, also add a quick link from `MedicationsHubView` to generate a medication-specific report.
**Files:** `AnxietyWatch/Views/Trends/TrendsView.swift`, `AnxietyWatch/App/ContentView.swift`
**Pros:** Core feature becomes discoverable; encourages report sharing with clinicians.
**Cons:** Toolbar may get crowded.
**Risks:** Low.
**Mitigations:** Use a simple icon, not a full button.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts agreed.

---

## 3. HealthKit & Data Collection

Improvements to physiological data collection, processing, and interpretation.

---

### 3.1 Add `HKWorkoutType` Reading

**Source experts:** HealthKit, Medical
**Description:** The app does not read workout sessions at all. This is the single biggest HealthKit gap. Workouts provide critical context: a 45-minute run explains why HR was 160 at 3pm and why HRV is suppressed at 5pm. Without workout data, exercise HR contaminates baseline calculations and could trigger false anxiety-correlation flags.
**What to do:** Add `HKWorkoutType` to `HealthKitManager.allReadTypes`. Create a basic workout query method. Use workout windows to exclude exercise-period HR samples from baseline calculations. Display workout sessions on trend charts as shaded regions. Derive heart rate recovery (HRR) from HR samples immediately post-workout.
**Files:** `AnxietyWatch/Services/HealthKitManager.swift`, `AnxietyWatch/Services/SnapshotAggregator.swift`, `AnxietyWatch/Services/BaselineCalculator.swift`
**Pros:** Eliminates exercise-induced false positives in anxiety detection; enables HRR calculation.
**Cons:** Additional HealthKit authorization prompt; more data processing.
**Risks:** Low -- additive change.
**Mitigations:** Gracefully handle case where workout data is unavailable.
**Effort:** Medium
**Impact:** High
**Expert consensus:** Both experts rated this as the highest-priority HealthKit addition.

---

### 3.2 Add `timeInDaylight` Reading (iOS 17+)

**Source experts:** HealthKit, Medical
**Description:** Light exposure regulates circadian rhythm and directly modulates cortisol and anxiety. Available on any Apple Watch running watchOS 10+, trivially easy to add. Low daylight exposure is associated with worsened anxiety and depression.
**What to do:** Add `HKQuantityTypeIdentifier.timeInDaylight` to `allReadTypes`. Add a `timeInDaylightMin: Int?` field to `HealthSnapshot`. Query and aggregate in `SnapshotAggregator`. Display on Dashboard and in trend charts.
**Files:** `AnxietyWatch/Services/HealthKitManager.swift`, `AnxietyWatch/Models/HealthSnapshot.swift`, `AnxietyWatch/Services/SnapshotAggregator.swift`
**Pros:** High clinical value for anxiety; trivial implementation; no other anxiety app does this well.
**Cons:** Only available on watchOS 10+ devices.
**Risks:** Very low.
**Mitigations:** Already guarded by platform availability checks.
**Effort:** Small
**Impact:** High
**Expert consensus:** Both experts independently identified this as the top single-metric addition.

---

### 3.3 Add `physicalEffort` Reading (iOS 17+)

**Source experts:** HealthKit, Medical
**Description:** `HKQuantityTypeIdentifier.physicalEffort` rates physical effort as low/moderate/vigorous in real time. Better than exercise minutes alone for distinguishing "elevated HR from exercise" versus "elevated HR from anxiety." This is a key disambiguator for the app's core use case.
**What to do:** Add to `allReadTypes`. Use as a filter when evaluating whether an elevated HR reading is exercise-related or anxiety-related.
**File:** `AnxietyWatch/Services/HealthKitManager.swift`
**Pros:** Directly improves accuracy of anxiety detection algorithms.
**Cons:** Adds another metric to manage.
**Risks:** Low.
**Mitigations:** Use as a filter/context signal, not as a displayed metric.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts recommended this.

---

### 3.4 Implement `HKStateOfMind` Writing (iOS 18+)

**Source experts:** HealthKit
**Description:** Apple's new mental health API for iOS 18. Supports logging valence, emotions, and associations. The app's anxiety severity scale maps directly. Writing `HKStateOfMind` samples makes anxiety data visible in Apple Health's Mental Wellbeing section and enables bidirectional data flow with other mental health apps.
**What to do:** When saving an `AnxietyEntry`, also write an `HKStateOfMind` sample to HealthKit. Map severity 1-10 to valence -1.0 to +1.0. Map journal tags to associations (e.g., "work" -> `.work`). Add `HKStateOfMind` to the `toShare` set and request write authorization.
**Files:** `AnxietyWatch/Services/HealthKitManager.swift`, `AnxietyWatch/Views/Journal/AddJournalEntryView.swift` (or wherever entries are saved)
**Pros:** Integrates with Apple's mental health ecosystem; makes data available to other apps.
**Cons:** iOS 18+ only; requires write authorization.
**Risks:** Users may be surprised to see anxiety data in Apple Health.
**Mitigations:** Make it a user-facing toggle in Settings ("Share anxiety data with Apple Health"). Default on, easily discoverable.
**Effort:** Medium
**Impact:** High
**Expert consensus:** Single expert identified this as "the single most strategically important addition."

---

### 3.5 Derive Overnight HRV as a Separate Snapshot Field

**Source experts:** Medical
**Description:** HRV during sleep is a cleaner measure of autonomic state because it removes confounds from daytime activity, caffeine, posture changes, etc. The app already uses a noon-to-noon window for respiratory rate and SpO2. Apply the same window to HRV and store as `hrvOvernightAvg`.
**What to do:** Add `hrvOvernightAvg: Double?` to `HealthSnapshot`. In `SnapshotAggregator`, query HRV samples within the overnight window (same as respiratory rate) and compute the average.
**Files:** `AnxietyWatch/Models/HealthSnapshot.swift`, `AnxietyWatch/Services/SnapshotAggregator.swift`
**Pros:** More clinically valid metric; better baseline comparison.
**Cons:** Another field to maintain.
**Risks:** Low.
**Mitigations:** Add alongside existing `hrvAvg`, not replacing it.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert (medical), but the clinical reasoning is strong.

---

### 3.6 Store `daysSupply` on the Prescription Model

**Source experts:** Pharmacy
**Description:** The CapRx API returns `days_supply` and the server uses it to compute `estimatedRunOutDate`, but the actual integer is not stored on the Swift `Prescription` model. Days supply is a first-class pharmacy concept -- it drives insurance refill eligibility calculations and is more reliable than computing from quantity and daily dose count. The PBM already calculated it.
**What to do:** Add `daysSupply: Int?` to the `Prescription` model. Pass through from the server's `normalize_claim` output. Use `dateFilled + daysSupply` as the primary run-out date calculation when available, falling back to the current `quantity / dailyDoseCount` method.
**Files:** `AnxietyWatch/Models/Prescription.swift`, `AnxietyWatch/Services/SyncService.swift`, `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`, `server/app.py` or `server/schema.sql`
**Pros:** More accurate supply calculations; fixes the staleness filter issue (1.5).
**Cons:** Requires schema migration on both server and client.
**Risks:** Medium -- migration required.
**Mitigations:** Make the field optional. Existing prescriptions remain valid with nil `daysSupply`.
**Effort:** Medium
**Impact:** High
**Expert consensus:** Single expert, but the pharmacy operations rationale is compelling.

---

### 3.7 Add Baselines for Sleep Duration and Respiratory Rate

**Source experts:** HealthKit, Medical
**Description:** Currently only HRV and resting HR have baseline calculations. Sleep duration baseline deviation is one of the strongest predictors of next-day anxiety episodes. Respiratory rate deviation is also clinically relevant.
**What to do:** Extend `BaselineCalculator` to compute baselines for `sleepDurationMin` and `respiratoryRate`. Display baseline bands on the corresponding trend charts. Fire baseline alerts when these metrics deviate significantly.
**Files:** `AnxietyWatch/Services/BaselineCalculator.swift`, `AnxietyWatch/Views/Dashboard/DashboardView.swift`
**Pros:** More comprehensive baseline alerting; sleep deviation is highly predictive.
**Cons:** More alerts could increase noise.
**Risks:** Alert fatigue.
**Mitigations:** Make baseline alerts per-metric toggleable in Settings.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts recommended this.

---

### 3.8 Use `HKCorrelationType(.bloodPressure)` for Paired BP Readings

**Source experts:** HealthKit
**Description:** BP readings in HealthKit are stored as `HKCorrelation` objects containing paired systolic and diastolic samples. The current implementation queries them as independent quantity types, which could theoretically mismatch AM systolic with PM diastolic when averaging.
**What to do:** Query `HKCorrelationType(.bloodPressure)` and extract paired values from each correlation.
**File:** `AnxietyWatch/Services/HealthKitManager.swift`
**Pros:** Correctly paired BP readings; more accurate daily averages.
**Cons:** More complex query code.
**Risks:** Low.
**Mitigations:** Keep the existing query as a fallback if correlations aren't available.
**Effort:** Small
**Impact:** Low (unless multiple daily BP readings are common)
**Expert consensus:** Single expert.

---

## 4. Architecture & Code Quality

Structural improvements that reduce maintenance burden and improve testability.

---

### 4.1 Extract `DashboardViewModel` from `DashboardView`

**Source experts:** iOS UI/UX, Refactoring
**Description:** `DashboardView.swift` is 703 lines and contains extensive business logic: sample loading, baseline computation, supply alert filtering, trend calculation, color mapping, sync orchestration. All of this is in private methods on the view, making it untestable. Extract into a `DashboardViewModel` using `@Observable`.
**What to do:** Create `DashboardViewModel` holding all `@State` properties, the sample grouping, baseline computation, supply alert filtering, and refresh/sync orchestration. The view subscribes to the view model's published properties and just renders.
**Files:** New `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift`, refactor `AnxietyWatch/Views/Dashboard/DashboardView.swift`
**Pros:** Makes 700 lines of logic testable; view becomes a thin rendering layer; follows project's own CLAUDE.md convention.
**Cons:** Larger refactor; risk of introducing regressions.
**Risks:** Medium -- many moving parts.
**Mitigations:** Extract incrementally (e.g., move supply alerts first, then baselines, then samples). Add tests for each extracted method.
**Effort:** Medium
**Impact:** High
**Expert consensus:** Both experts identified this as the highest-value refactoring.

---

### 4.2 Extract Shared `SupplyAlertFilter` Utility

**Source experts:** Refactoring
**Description:** The supply alert filtering logic (staleness cutoff + inactive medication check + status filter) is duplicated in three places: `DashboardView`, `MedicationsHubView`, and `PrescriptionListView`. Extract into a single shared function.
**What to do:** Create a `SupplyAlertFilter` (or extension on `PrescriptionSupplyCalculator`) with a static method that takes prescriptions and medication definitions and returns filtered/categorized results.
**Files:** `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift` (add method), update three view files
**Pros:** Eliminates triple duplication; single place to fix the staleness logic (item 1.5).
**Cons:** None.
**Risks:** Low.
**Mitigations:** Add tests for the extracted filter.
**Effort:** Small
**Impact:** High
**Expert consensus:** Single expert, but the duplication is factual and verified.

---

### 4.3 Extract `severityColor` to a Shared Utility

**Source experts:** iOS UI/UX, Refactoring
**Description:** `severityColor` (mapping severity 1-10 to a color) is duplicated in 6+ files: `DashboardView`, `AddJournalEntryView`, `JournalEntryDetailView`, `DoseAnxietyPromptView`, `AnxietySeverityChart`, `HRVTrendChart`, `HeartRateTrendChart`, `BarometricTrendChart`. Any divergence means inconsistent colors across the app.
**What to do:** Create an extension `Int.severityColor: Color` or a static function in `Constants.swift` / a new `AnxietyScale.swift`. Replace all copies.
**File:** New `AnxietyWatch/Utilities/AnxietyScale.swift` (or add to `Constants.swift`), update all 6+ files
**Pros:** Single source of truth for severity colors; enables the anchored-scale work (item 2.4).
**Cons:** None.
**Risks:** Very low.
**Mitigations:** Compile-time guarantee that all call sites are updated.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts flagged this independently.

---

### 4.4 Delete `MedicationListView.swift` (Dead Code)

**Source experts:** iOS UI/UX, Health App UX, Refactoring
**Description:** `MedicationListView` is a near-exact duplicate of the Quick Log + Recent Doses sections of `MedicationsHubView`. It is never referenced in the current navigation flow -- no `NavigationLink` points to it. It is dead code and a maintenance liability.
**What to do:** Delete `AnxietyWatch/Views/Medications/MedicationListView.swift`. Verify no references remain (build should confirm).
**File:** Delete `AnxietyWatch/Views/Medications/MedicationListView.swift`
**Pros:** Less code to maintain; removes confusion about which view is canonical.
**Cons:** None.
**Risks:** Very low (verify it's truly unreferenced first).
**Mitigations:** Search for all references before deleting.
**Effort:** Small
**Impact:** Low (maintenance quality)
**Expert consensus:** Three experts flagged this.

---

### 4.5 Replace `try?` Swallowing with `do/catch` + Logging

**Source experts:** Refactoring, Developer Experience
**Description:** Throughout the codebase, errors are silently discarded with `try?`: `HealthDataCoordinator.backfillIfNeeded()`, `fillGaps()`, `pruneOldSamples()`, `insertSamples()`, `DashboardView.refreshSnapshot()`, `PhoneConnectivityManager.handleIncoming()`. If aggregation fails systemically, all 90+ days fail with no indication.
**What to do:** Replace `try?` with `do { try ... } catch { Logger.service.error("...") }` using `os.Logger`. Add a shared `Logger` definition in utilities.
**Files:** Multiple: `HealthDataCoordinator.swift`, `DashboardView.swift`, `PhoneConnectivityManager.swift`
**Pros:** Surfaces silent failures; makes debugging feasible.
**Cons:** Slightly more verbose code.
**Risks:** Low.
**Mitigations:** Use `os.Logger` for structured, filterable logging.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts recommended structured logging.

---

### 4.6 Add `#Unique` Constraint on `CPAPSession.date` and Dedup on Import

**Source experts:** Refactoring
**Description:** No unique constraint prevents duplicate CPAP sessions for the same date from CSV re-import. The importer does not check for existing sessions.
**What to do:** Add `#Unique([\.date])` to `CPAPSession`. Add a deduplication check in `CPAPImporter` before inserting.
**Files:** `AnxietyWatch/Models/CPAPSession.swift`, `AnxietyWatch/Services/CPAPImporter.swift`
**Pros:** Prevents data corruption on re-import.
**Cons:** Requires SwiftData migration consideration.
**Risks:** Medium -- existing duplicate data could cause migration failure.
**Mitigations:** Before adding the constraint, add a migration step that deduplicates existing records.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert, but the risk is real.

---

### 4.7 Extract `PrescriptionImporter` from `SyncService`

**Source experts:** Refactoring
**Description:** `SyncService.fetchPrescriptions` (115 lines) does complex JSON parsing and upsert logic that is logically separate from sync orchestration. `findOrCreateMedication` and `backfillMedicationLinks` are static methods on `SyncService` that have nothing to do with syncing.
**What to do:** Extract prescription import logic into a new `PrescriptionImporter` service. Move `findOrCreateMedication` and `backfillMedicationLinks` there. This makes the complex upsert logic independently testable.
**Files:** New `AnxietyWatch/Services/PrescriptionImporter.swift`, refactor `AnxietyWatch/Services/SyncService.swift`
**Pros:** Separation of concerns; testable JSON-to-model mapping.
**Cons:** One more file.
**Risks:** Low.
**Mitigations:** Maintain the same public API for `SyncService`; it just delegates to the new importer.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert.

---

### 4.8 Add `HealthSample` Deduplication

**Source experts:** HealthKit
**Description:** The `insertSamples` method in `HealthDataCoordinator` inserts every sample without checking for duplicates. If anchor persistence fails (e.g., app crash), the next launch replays those samples. No unique constraint on `(type, timestamp, value)`.
**What to do:** Add a dedup check before inserting: query for existing samples with the same type and timestamp within a small window. Alternatively, add a `#Unique` constraint.
**File:** `AnxietyWatch/Services/HealthDataCoordinator.swift`
**Pros:** Prevents duplicate data points that can skew averages.
**Cons:** Slightly slower insertion.
**Risks:** Low.
**Mitigations:** For sparkline display, duplicates are cosmetic. Prioritize if average calculations are performed on cached samples.
**Effort:** Small
**Impact:** Low
**Expert consensus:** Single expert.

---

### 4.9 Add `FetchDescriptor` Date Filter to Dashboard `loadSamples()`

**Source experts:** iOS UI/UX
**Description:** The `FetchDescriptor` for `HealthSample` fetches ALL records. For 13 anchored queries producing hundreds of samples per day over months, this is an unbounded memory growth risk.
**What to do:** Add a date filter (e.g., last 7 days) to the `FetchDescriptor` in `loadSamples()`.
**File:** `AnxietyWatch/Views/Dashboard/DashboardView.swift` (or `DashboardViewModel` after item 4.1)
**Pros:** Bounded memory; faster load.
**Cons:** None.
**Risks:** Low.
**Mitigations:** Verify sparklines still have enough data points.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert.

---

## 5. Developer Experience

Changes that improve the development workflow, testing infrastructure, and tooling.

---

### 5.1 Create a Makefile with Standard Targets

**Source experts:** Developer Experience
**Description:** No `Makefile`, `Justfile`, or `Taskfile` exists. Every command must be remembered or copy-pasted from CLAUDE.md. Common operations like build, test, lint, server-up are multi-word commands that are easy to mistype.
**What to do:** Create a `Makefile` at project root with targets: `build`, `test`, `test-server`, `lint`, `server-up`, `server-down`, `generate-version`, `coverage`, `setup`.
**File:** New `/Users/chris/Source/AnxietyWatch/Makefile`
**Pros:** One-word commands for all common operations; reduces cognitive load.
**Cons:** One more file to maintain.
**Risks:** Low.
**Mitigations:** Keep targets thin (just wrapping the underlying commands).
**Effort:** Small
**Impact:** High
**Expert consensus:** Single expert, rated as their #1 recommendation.

---

### 5.2 Create Shared `TestHelpers.swift` and `ModelFactory.swift`

**Source experts:** Developer Experience
**Description:** Every test file creates its own `makeContainer()` with a different subset of models. There are no shared factory methods for test models. The schema list must stay in sync with `AnxietyWatchApp.swift` manually. `BaselineCalculatorTests` uses `Date.now` violating the project's fixed-date convention.
**What to do:** Create `TestHelpers.swift` with a `makeFullContainer()` that includes ALL models (matching `AnxietyWatchApp.swift`). Create `ModelFactory.swift` with static factory methods: `makeHealthSnapshot(daysAgo:hrvAvg:)`, `makePrescription(...)`, etc.
**Files:** New `AnxietyWatchTests/TestHelpers.swift`, new `AnxietyWatchTests/ModelFactory.swift`
**Pros:** Eliminates schema drift bugs; makes writing new tests fast; single source of truth.
**Cons:** Need to update existing tests to use the shared helpers (one-time effort).
**Risks:** Low.
**Mitigations:** Can be adopted incrementally -- new tests use shared helpers, old tests migrated over time.
**Effort:** Small
**Impact:** High
**Expert consensus:** Single expert, rated as their #4 recommendation.

---

### 5.3 Add `#Preview` Blocks and `SampleData.swift`

**Source experts:** Developer Experience
**Description:** Zero SwiftUI `#Preview` providers exist. Every UI change requires a full build-and-run cycle. No mock data generators. HealthKit provides no data in the simulator.
**What to do:** Create `SampleData.swift` that populates a `ModelContainer` with realistic test data (7 days of snapshots, journal entries, prescriptions, CPAP sessions, medications). Add `#Preview` blocks to the 5 most-used views: `DashboardView`, `JournalListView`, `MedicationsHubView`, `TrendsView`, `AddJournalEntryView`.
**Files:** New `AnxietyWatch/Utilities/SampleData.swift`, update 5 view files
**Pros:** Cuts the edit-preview cycle from minutes to seconds; reusable for screenshots and demos.
**Cons:** Sample data must be maintained as models evolve.
**Risks:** Preview code could diverge from runtime behavior.
**Mitigations:** Use the same `ModelContainer` configuration as the app.
**Effort:** Medium
**Impact:** High
**Expert consensus:** Single expert, rated as their #2 recommendation.

---

### 5.4 Add watchOS Build Step to CI

**Source experts:** Developer Experience, Xcode/Claude Code Tooling
**Description:** No CI workflow builds the watchOS target. A breaking change to the Watch app won't be caught until manual testing.
**What to do:** Add a step to `ios-ci.yml`: `xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator'`.
**File:** `.github/workflows/ios-ci.yml`
**Pros:** Catches Watch build failures automatically.
**Cons:** Adds CI time (~1-2 min).
**Risks:** Low.
**Mitigations:** Run in parallel with the iOS build step.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Both experts mentioned this.

---

### 5.5 Add SwiftLint Step to iOS CI

**Source experts:** Developer Experience
**Description:** `.swiftlint.yml` exists with good configuration but never runs in CI. Lint issues are only caught if developers remember to run it locally.
**What to do:** Add a lint step to `ios-ci.yml`: `brew install swiftlint && swiftlint lint --reporter github-actions-logging`.
**File:** `.github/workflows/ios-ci.yml`
**Pros:** Enforces code style consistently.
**Cons:** Adds ~30s to CI.
**Risks:** May surface many existing warnings.
**Mitigations:** Run SwiftLint locally first and fix existing issues, or start with `--strict` on only new/changed files.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert.

---

### 5.6 Replace `print()` with `os.Logger`

**Source experts:** Developer Experience, Refactoring
**Description:** Error logging uses `print()` throughout. No structured logging. No way to filter by subsystem/category in Console.app.
**What to do:** Create a shared `Logger` definition: `extension Logger { static let sync = Logger(subsystem: "com.anxietywatch", category: "sync") }` etc. Replace `print()` calls with appropriate `Logger` calls.
**Files:** New `AnxietyWatch/Utilities/Logging.swift`, multiple service files
**Pros:** Structured, filterable logging; survives release builds (unlike print).
**Cons:** Migration effort across multiple files.
**Risks:** Low.
**Mitigations:** Adopt incrementally, starting with services.
**Effort:** Medium
**Impact:** Medium
**Expert consensus:** Both experts recommended this.

---

### 5.7 Fix CLAUDE.md Documentation Inconsistencies

**Source experts:** Developer Experience, Xcode/Claude Code Tooling
**Description:** Multiple inconsistencies: (1) Two different `xcodebuild test` destinations in Commands vs Testing sections. (2) CI table says 3 workflows but there are 4. (3) No mention of `scripts/generate-version.sh`. (4) No first-time setup section.
**What to do:** Reconcile `xcodebuild test` to use `generic/platform=iOS Simulator` consistently. Update CI table to include `ios-ci.yml`. Add a "First-time Setup" section. Document `generate-version.sh`.
**File:** `CLAUDE.md`
**Pros:** Reduces confusion for agent-assisted development.
**Cons:** None.
**Risks:** Low.
**Mitigations:** None needed.
**Effort:** Small
**Impact:** Low
**Expert consensus:** Both experts identified documentation gaps.

---

## 6. Clinical / Medical Value

Features that increase the app's value for clinical insights and psychiatric care.

---

### 6.1 Add Medication Dose Markers to Trend Charts

**Source experts:** Health App UX, Medical
**Description:** No trend chart shows when medications were taken. For an anxiety tracking app, knowing when benzos were taken relative to HRV changes or anxiety entries is critical. Dose markers should appear as vertical rule marks or small pill icons on the HRV and Anxiety charts at minimum.
**What to do:** Query `MedicationDose` records for the displayed time window. Add `RuleMark` or `PointMark` annotations at each dose timestamp on the Anxiety Severity and HRV trend charts.
**Files:** `AnxietyWatch/Views/Trends/AnxietySeverityChart.swift`, `AnxietyWatch/Views/Trends/HRVTrendChart.swift`
**Pros:** Unlocks the core correlation insight -- visual connection between medication timing and physiological changes.
**Cons:** Chart visual complexity increases.
**Risks:** Cluttered charts if many doses per day.
**Mitigations:** Use subtle markers (small dots or thin rule marks); filter to show only medications in categories that matter (benzos, stimulants).
**Effort:** Medium
**Impact:** High
**Expert consensus:** Both experts independently recommended this as high-priority.

---

### 6.2 Add Dose-Anxiety Efficacy Section to Clinical Report

**Source experts:** Health App UX, Lived Experience
**Description:** The medication section of the PDF report shows dose counts per day but does not report before/after anxiety deltas from the dose prompt system. This is uniquely valuable clinical data: "Patient self-reported anxiety decreased an average of 2.3 points within 30 minutes of lorazepam across N=12 administrations this month."
**What to do:** In `ReportGenerator`, query `AnxietyEntry` pairs where `isFollowUp == true` and their corresponding pre-dose entries (linked by `followUpDoseId`). Compute: average pre-dose severity, average post-dose severity, average delta, number of observations. Add as a "Medication Efficacy" section in the PDF.
**File:** `AnxietyWatch/Services/ReportGenerator.swift`
**Pros:** Genuinely novel clinical data that psychiatrists rarely get; directly informs prescribing decisions.
**Cons:** Requires sufficient follow-up data to be meaningful.
**Risks:** Small sample sizes could be misleading.
**Mitigations:** Show N alongside all averages. Require minimum N=5 before including the section.
**Effort:** Medium
**Impact:** High
**Expert consensus:** Both experts rated this very highly. Lived Experience expert called medication response data "the headliner."

---

### 6.3 Embed Trend Charts in PDF Clinical Report

**Source experts:** Health App UX
**Description:** The PDF report includes computed statistics but no visual charts. A psychiatrist would benefit from seeing an HRV trend line, an anxiety severity scatter plot, and a sleep duration chart. Clinicians consistently say visuals are more useful than numbers.
**What to do:** Render Swift Charts views to `UIImage` using `ImageRenderer`. Draw the images into the PDF context. Include at minimum: anxiety severity trend, HRV with baseline bands, sleep duration, and medication timeline.
**File:** `AnxietyWatch/Services/ReportGenerator.swift`
**Pros:** Dramatically more useful clinical reports.
**Cons:** PDF generation becomes more complex; layout/sizing challenges.
**Risks:** Charts may not render well in all PDF viewers.
**Mitigations:** Test PDF output on macOS Preview, iOS Files, and at least one clinical PDF viewer. Use fixed-size rendering for consistent output.
**Effort:** Large
**Impact:** High
**Expert consensus:** Single expert, but the suggestion aligns with clinical best practices.

---

### 6.4 Implement Benzo Tolerance Detection

**Source experts:** Medical
**Description:** Track rolling 30-day average of PRN benzodiazepine dose frequency and total mg consumed. Flag if weekly doses are trending upward. Also track efficacy decay: compare before/after anxiety deltas from the first week of use vs the most recent week. Tolerance develops within 2-4 weeks of regular use and increasing dose frequency is the earliest warning sign.
**What to do:** Create a `MedicationPatternAnalyzer` service that, for benzo-category medications, computes: weekly dose count trend, total mg trend, efficacy trend (using follow-up data). Surface findings in the Medications hub and in clinical reports.
**Files:** New `AnxietyWatch/Services/MedicationPatternAnalyzer.swift`, update `MedicationsHubView.swift`, `ReportGenerator.swift`
**Pros:** Extremely valuable clinical insight; early warning for dependence; data psychiatrists almost never see.
**Cons:** Significant new feature; requires careful messaging to avoid alarming users.
**Risks:** Users might stop taking needed medication if the app implies they are becoming dependent.
**Mitigations:** Frame as informational ("usage trend"), not diagnostic. Include educational context. Show only in the context of clinical reports or a dedicated "Medication Insights" section.
**Effort:** Large
**Impact:** High
**Expert consensus:** Single expert (medical), but the clinical reasoning is robust.

---

### 6.5 Add Refill Eligibility Date Alongside Run-Out Date

**Source experts:** Pharmacy
**Description:** "When supply runs out" and "when insurance allows a refill" are different dates. Typically, refills are eligible at 75-80% through the days supply. For anxiety medications, a gap in therapy can trigger withdrawal (SSRIs) or rebound anxiety (benzos).
**What to do:** Add a computed `earliestRefillDate` to `PrescriptionSupplyCalculator`: `dateFilled + (daysSupply * 0.75)`. Display both dates in `PrescriptionDetailView` and in supply alert badges.
**File:** `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`, `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift`
**Pros:** Proactive refill management prevents therapy gaps; pharmacy-professional-level feature.
**Cons:** The 75% threshold is approximate; varies by PBM.
**Risks:** User might try to refill too early and get rejected.
**Mitigations:** Label as "Estimated eligible" with a note that actual eligibility depends on insurance plan.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert, but the domain expertise is authoritative.

---

### 6.6 Add DEA Schedule Awareness to Medications

**Source experts:** Pharmacy
**Description:** The app does not reflect DEA scheduling rules. Schedule II meds (Adderall) cannot be refilled -- each fill requires a new prescription. Schedule III-IV (benzos) have a 5-refill / 6-month limit. The app should customize alerts and messaging based on schedule.
**What to do:** Add a `deaSchedule: Int?` property to `MedicationDefinition` (nil for non-controlled, 2-5 for controlled). Use it to: show "New prescription required" instead of "Refills: 0" for Schedule II; display "X refills or Y months remaining" for Schedule III-IV; customize alert timing (earlier for Schedule II since getting a new Rx takes time).
**Files:** `AnxietyWatch/Models/MedicationDefinition.swift`, `AnxietyWatch/Views/Medications/AddMedicationView.swift`, `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`
**Pros:** Pharmacy-accurate medication management; prevents surprises when controlled substances need new prescriptions.
**Cons:** Requires user to know/set the schedule for each medication.
**Risks:** Incorrect scheduling could give wrong advice.
**Mitigations:** Pre-populate schedule based on `category` (benzos -> IV, stimulants -> II). Allow manual override.
**Effort:** Medium
**Impact:** Medium
**Expert consensus:** Single expert.

---

### 6.7 Detect Therapy Gaps from Fill History

**Source experts:** Pharmacy
**Description:** If a patient has a 30-day supply filled on March 1 and doesn't fill again until April 15, that's a 15-day gap. For SSRIs, even a few missed days can cause discontinuation syndrome. The app should automatically detect and flag therapy gaps by comparing expected refill dates with actual fill dates.
**What to do:** For consecutive fills of the same medication, compute the gap between expected run-out and actual next fill date. Flag gaps > 3 days. Show in medication detail view and clinical reports.
**Files:** `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift`, `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift`
**Pros:** Clinically important; cross-references dose logging for a complete adherence picture.
**Cons:** Claims data may not capture all fills (cash-pay, different pharmacies).
**Risks:** False positives if patient uses multiple pharmacies.
**Mitigations:** Label as "Possible therapy gap" rather than definitive. Allow manual dismissal.
**Effort:** Medium
**Impact:** Medium
**Expert consensus:** Single expert.

---

### 6.8 Add Sleep Onset Latency Derivation

**Source experts:** Medical
**Description:** Time between first "inBed" sample and first "asleep" sample. Prolonged sleep onset (>30 min) is a hallmark of anxiety and predicts next-day symptoms. Derivable from existing sleep stage data.
**What to do:** In `SnapshotAggregator`, compute sleep onset latency from the gap between the first `.inBed` and first `.asleep*` samples. Add `sleepOnsetLatencyMin: Int?` to `HealthSnapshot`.
**Files:** `AnxietyWatch/Models/HealthSnapshot.swift`, `AnxietyWatch/Services/SnapshotAggregator.swift`
**Pros:** High clinical value; no new data sources needed.
**Cons:** Depends on accurate "inBed" detection (not always reliable on Apple Watch).
**Risks:** Inaccurate if user doesn't mark bedtime or if Watch detection is off.
**Mitigations:** Mark as "estimated" in the UI. Only compute when both inBed and asleep samples exist.
**Effort:** Small
**Impact:** Medium
**Expert consensus:** Single expert, strong clinical rationale.

---

## 7. Nice-to-Haves

Lower-priority improvements that would enhance the app but are not urgent.

---

### 7.1 "Today's Summary" Composite Card on Dashboard

**Source experts:** Health App UX, Lived Experience
**Description:** A top-of-dashboard card synthesizing: anxiety trend direction (better/worse/stable over last 3 days), sleep quality last night, HRV vs baseline status, and medication adherence today. Interpretive text, not raw numbers.
**Files:** `AnxietyWatch/Views/Dashboard/DashboardView.swift`
**Effort:** Large | **Impact:** High
**Note:** High value but depends on items 4.1 (DashboardViewModel) and 3.7 (more baselines) being done first.

---

### 7.2 Home-Screen and Lock Screen Widgets

**Source experts:** Health App UX
**Description:** A quick-log widget and a status widget showing HRV, last anxiety, and sleep quality. The watchOS complication from REQUIREMENTS.md is also unimplemented.
**Files:** `AnxietyWatchWidgets/`
**Effort:** Large | **Impact:** Medium

---

### 7.3 Notification Actions for Follow-Up Prompts

**Source experts:** Health App UX
**Description:** iOS supports `UNNotificationAction`. Add a "Rate Now" action directly from the notification banner so the user can rate anxiety without opening the full app.
**Files:** `AnxietyWatch/Services/DoseFollowUpManager.swift`, `AnxietyWatch/App/AnxietyWatchApp.swift`
**Effort:** Medium | **Impact:** Medium

---

### 7.4 Configurable Follow-Up Timing per Medication

**Source experts:** Health App UX, Lived Experience, Medical
**Description:** Different medications have different onset times. Allow the follow-up delay to be set per `MedicationDefinition` (default 30 min, options 15/30/45/60).
**Files:** `AnxietyWatch/Models/MedicationDefinition.swift`, `AnxietyWatch/Services/DoseFollowUpManager.swift`
**Effort:** Small | **Impact:** Medium

---

### 7.5 Medication Adherence Tracking (Expected vs. Actual Doses)

**Source experts:** Health App UX
**Description:** No concept of "expected doses per day" for scheduled medications. Add an optional `expectedDosesPerDay` field to `MedicationDefinition`. Compute and display adherence percentage.
**Files:** `AnxietyWatch/Models/MedicationDefinition.swift`, `AnxietyWatch/Views/Medications/MedicationsHubView.swift`
**Effort:** Medium | **Impact:** Medium

---

### 7.6 "This Too Shall Pass" Recovery History View

**Source experts:** Lived Experience
**Description:** Show the user's own history of panic attacks resolving. "You have logged 47 episodes rated 7+. Average duration until you felt better: 34 minutes. You have survived every single one."
**Files:** New view, accessible from Dashboard or Journal
**Effort:** Medium | **Impact:** High (for acute moments)

---

### 7.7 Group Prescription History by Medication

**Source experts:** Pharmacy
**Description:** Show medications as cards with most recent fill details and expandable fill history, rather than individual fills as separate rows.
**Files:** `AnxietyWatch/Views/Prescriptions/PrescriptionListView.swift`
**Effort:** Medium | **Impact:** Medium

---

### 7.8 Store Additional CapRx Fields

**Source experts:** Pharmacy
**Description:** `patientPay`, `planPay`, `dosageForm`, and `drugType` are extracted by `normalize_claim` but never stored. All four should be persisted for cost tracking and formulation change detection.
**Files:** `server/schema.sql`, `server/app.py`, `AnxietyWatch/Models/Prescription.swift`, `AnxietyWatch/Services/SyncService.swift`
**Effort:** Medium | **Impact:** Medium

---

### 7.9 Add Pull-to-Refresh on Dashboard and Trends

**Source experts:** iOS UI/UX
**Description:** Dashboard uses `ScrollView` which supports `.refreshable` in iOS 16+. Add pull-to-refresh to re-fetch HealthKit data and refresh snapshots.
**Files:** `AnxietyWatch/Views/Dashboard/DashboardView.swift`, `AnxietyWatch/Views/Trends/TrendsView.swift`
**Effort:** Small | **Impact:** Low

---

### 7.10 Accessibility Improvements for Metric Cards and Charts

**Source experts:** iOS UI/UX
**Description:** Multiple accessibility gaps: `LiveMetricCard` has no `accessibilityElement` grouping, `SparklineView`/`ProgressBarView`/`SleepStagesView`/`RecentBarsView` have no accessibility representation, fixed-size fonts in sparklines don't scale with Dynamic Type, and the yellow severity badge has poor contrast with white text.
**Files:** `AnxietyWatch/Views/Dashboard/LiveMetricCard.swift` and associated visualization views
**Effort:** Medium | **Impact:** Medium (required for VoiceOver usability)

---

### 7.11 Add Structured Tags for Anxiety Phenomenology

**Source experts:** Medical
**Description:** Add structured tag prefixes to capture onset speed (`onset:sudden`, `onset:gradual`), physical symptoms (`symptom:palpitations`), and duration (`duration:short`). This enables pattern analysis by anxiety type without requiring a diagnostic classification.
**Files:** `AnxietyWatch/Views/Journal/AddJournalEntryView.swift` (add structured tag chips)
**Effort:** Small | **Impact:** Medium

---

### 7.12 Add Data Completeness Metrics to Clinical Reports

**Source experts:** Health App UX
**Description:** The report doesn't indicate data completeness. "HRV data available for 25 of 30 days" helps a clinician interpret averages.
**File:** `AnxietyWatch/Services/ReportGenerator.swift`
**Effort:** Small | **Impact:** Low

---

### 7.13 Log HealthKit Background Delivery and Anchored Query Errors

**Source experts:** HealthKit
**Description:** Both `enableBackgroundDelivery` and anchored query error handlers silently discard errors. At minimum, log them.
**File:** `AnxietyWatch/Services/HealthKitManager.swift`, `AnxietyWatch/Services/HealthDataCoordinator.swift`
**Effort:** Small | **Impact:** Low

---

### 7.14 Add `HealthKitManager` Protocol for Mock Data in Simulator

**Source experts:** Developer Experience
**Description:** The app is data-driven but the simulator has no HealthKit data. A protocol + mock implementation would make development feasible without a physical device.
**Files:** `AnxietyWatch/Services/HealthKitManager.swift`, new `AnxietyWatch/Services/MockHealthKitManager.swift`
**Effort:** Medium | **Impact:** High (for development)

---

### 7.15 Consider Expanding Baseline Window to 90 Days

**Source experts:** Medical
**Description:** A fixed 30-day window means that prolonged anxiety episodes contaminate the baseline. A 90-day window with a 7-day rolling average for "current" comparison would be more robust.
**Files:** `AnxietyWatch/Services/BaselineCalculator.swift`, `AnxietyWatch/Utilities/Constants.swift`
**Effort:** Small | **Impact:** Medium

---

## 8. Rejected Suggestions

Suggestions that were considered but not included in the plan, with rationale.

---

### Location Tagging on Journal Entries
**Source:** REQUIREMENTS.md (optional feature)
**Rejected because:** Lived Experience expert explicitly recommended against it. "I know where I was when I got anxious. I do not need GPS to tell me. The privacy implications of a detailed anxiety-location map make me uncomfortable." The data model supports it optionally, but actively building the UI is not worth the effort.

### Environmental Sound and Headphone Audio on Dashboard
**Source:** Currently implemented on Dashboard
**Rejected for elevation, not removal:** Lived Experience expert flagged these as noise ("I have never once thought 'I bet my anxiety is high because the ambient noise level is 72 dBA'"). These should remain available but be moved to the "Other" section at the bottom of the grouped dashboard (item 2.2), not removed entirely. The HealthKit expert noted environmental sound has a cortisol correlation, but it's a low-priority signal.

### SwiftFormat Enforcement
**Source:** Developer Experience
**Rejected because:** Low priority for a single-developer project. SwiftLint is already configured and covers the important cases. Adding a formatter introduces friction without proportional benefit.

### Full MVVM Architecture Overhaul
**Source:** Refactoring
**Rejected as stated:** The expert explicitly said "the app does not need a formal architectural framework." The recommendation is selective ViewModel extraction for complex screens (items 4.1), not a wholesale MVVM migration.

### Screen Time API Integration
**Source:** Medical
**Rejected because:** The medical expert themselves deferred it: "high friction to implement." The API is also limited in what it can share with apps.

### Pre-Commit Git Hooks
**Source:** Developer Experience
**Rejected because:** CI enforcement (items 1.1, 5.5) provides the same quality gate without the local developer friction. For a personal project, pre-commit hooks slow down the rapid iteration cycle.

### Full Prescription/Fill Data Model Split
**Source:** Pharmacy
**Rejected because:** The pharmacy expert themselves recommended against it: "Since you do not have the original Rx number from CapRx, you cannot reliably group fills. My pragmatic recommendation: keep the current flat model but add computed grouping." The suggestion to group by `(medicationName, doseMg)` in the UI (item 7.7) achieves the same UX benefit without a schema redesign.

### VO2 Max and Walking Steadiness on Dashboard
**Source:** Currently implemented
**Considered for removal:** Lived Experience expert flagged these as irrelevant to anxiety tracking. However, they should stay in the app (in the "Other" section) because they are read from HealthKit anyway and the marginal cost of displaying them is zero.

### Composite "Anxiety Risk Score"
**Source:** Health App UX
**Deferred, not rejected:** Computing a composite score from HRV deviation, sleep quality, exercise, and CPAP compliance is the eventual killer feature. But it requires significant data science work and validated weightings. The "Today's Summary" card (item 7.1) is the practical intermediate step.

### Caffeine/Alcohol Dedicated Logging
**Source:** Medical
**Deferred, not rejected:** High clinical value, but adds UI surface area. The existing tag system (`"trigger:caffeine"`) provides a lightweight alternative until dedicated logging is justified by usage patterns.

---

## Implementation Priority Order

For maximum value with minimum risk, implement in this order:

### Phase 1: Critical Fixes (1-2 days)
1. Fix iOS CI `continue-on-error` (1.1)
2. Fix anchored query predicate (1.2)
3. Fix BaselineCalculator variance and minimum (1.3, 1.4)
4. Fix `navigationDestination` scoping (1.7)
5. Fix `.alert` binding pattern (1.8)

### Phase 2: High-Impact Quick Wins (3-5 days)
6. Extract `severityColor` to shared utility (4.3)
7. Delete `MedicationListView` dead code (4.4)
8. Extract `SupplyAlertFilter` utility (4.2)
9. Fix trend arrow colors (2.9)
10. Add `timeInDaylight` reading (3.2)
11. Add `physicalEffort` reading (3.3)
12. Add pull-to-refresh (7.9)
13. Show "Last taken" time on Quick Log (2.5)
14. Fix prescription staleness filter (1.5)
15. Fix refillsRemaining display for CapRx (1.6)

### Phase 3: Core UX Improvements (1-2 weeks)
16. Dashboard section grouping (2.2)
17. Add "Log Anxiety" quick action on Dashboard (2.1)
18. Replace severity slider with tappable circles + anchors (2.3, 2.4)
19. Add quick tags to journal form (2.7)
20. Watch Quick Log improvements (2.10)
21. Move Export/Reports to discoverable location (2.11)

### Phase 4: Architecture & Testing (1-2 weeks)
22. Create Makefile (5.1)
23. Create TestHelpers + ModelFactory (5.2)
24. Extract DashboardViewModel (4.1)
25. Extract PrescriptionImporter (4.7)
26. Replace `try?` with structured logging (4.5, 5.6)
27. Add `#Preview` blocks + SampleData (5.3)
28. Fix CLAUDE.md docs (5.7)

### Phase 5: HealthKit & Clinical (2-3 weeks)
29. Add `HKWorkoutType` reading (3.1)
30. Store `daysSupply` on Prescription (3.6)
31. Implement `HKStateOfMind` writing (3.4)
32. Add medication dose markers to trend charts (6.1)
33. Derive overnight HRV (3.5)
34. Add sleep/respiratory rate baselines (3.7)
35. Add dose-anxiety efficacy to clinical report (6.2)
36. Add breathing exercise (2.6)

### Phase 6: Advanced Clinical Features (ongoing)
37. Embed charts in PDF report (6.3)
38. Sleep onset latency derivation (6.8)
39. Refill eligibility date (6.5)
40. DEA schedule awareness (6.6)
41. Therapy gap detection (6.7)
42. Benzo tolerance detection (6.4)
43. Show before/after delta on follow-up (2.8)
44. Configurable follow-up timing (7.4)
45. Accessibility improvements (7.10)

---

## Expert Agreement Matrix

| Topic | Experts Who Agreed | Dissent |
|-------|-------------------|---------|
| Dashboard needs section grouping | iOS UI/UX, Health App UX, Lived Experience | None |
| Quick log on Dashboard | iOS UI/UX, Health App UX, Lived Experience | None |
| DashboardView is too large, needs ViewModel | iOS UI/UX, Refactoring | None |
| Delete MedicationListView (dead code) | iOS UI/UX, Health App UX, Refactoring | None |
| Add HKWorkoutType | HealthKit, Medical | None |
| Add timeInDaylight | HealthKit, Medical | None |
| BaselineCalculator needs N-1 and higher minimum | HealthKit, Medical | None |
| Severity slider should be tappable circles | Health App UX, Lived Experience | None |
| Medication dose markers on trend charts | Health App UX, Medical | None |
| Breathing exercise needed | Health App UX, Lived Experience | None |
| Quick tags for journal | iOS UI/UX, Health App UX, Lived Experience | None |
| CI continue-on-error must be removed | Developer Experience, Xcode/Claude Code | None |
| Supply alert filtering is triplicated | Refactoring, (implied by others) | None |
| Reports should have efficacy data | Health App UX, Lived Experience | None |
| Environmental sound/VO2 Max low value on dashboard | Lived Experience | Medical expert noted sound has some value |
| Location tagging not worth building | Lived Experience | REQUIREMENTS.md lists it as optional |
