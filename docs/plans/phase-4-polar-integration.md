# Phase 4 — Polar H10 surface-area integration

## Why

PRs #131 / #132 (Phase 3a-c) shipped real Polar H10 data plumbing — sensor sessions, HRV readings, frequency-domain math, sync — but introduced the new physiological capability behind **parallel surfaces** instead of extending the existing app. Three concrete instances of the same architectural drift:

1. **New trend data → new card.** `LFHFChartView` ("HRV Frequency Power") sits next to the existing trend charts as a separate section instead of feeding into them.
2. **New recording capability → modal takeover.** Starting an HRV recording presents `HRVSessionLiveView` as a foreground modal, locking out the rest of the app. The journal — the *anchor* of the app per `CLAUDE.md`'s design principles — is unreachable while recording.
3. **New session-level data → standalone list.** `LFHFSessionsListView` exists only as a destination from the HRV Frequency Power card. The session detail (`LFHFSessionDetailView`) is otherwise unreachable from the Trends tab's existing visual vocabulary.

The unifying intent of this phase:

> **New physiological capability should extend existing surfaces, not stand up parallel ones.**

This plan also captures the implications surfaced by the ten-persona UX review in `lfhf-ux-persona-review.md`, in particular: most lay users bounced off the standalone LF/HF surface, two clinicians independently asked for RMSSD as a time-domain companion, and the recording UX limits the journal-during-capture workflow the app was built around.

## Scope

Three restructurings, each independently shippable.

### 4a — Trend chart integration

Pull the Polar HRV data **into** existing trend charts rather than presenting it next to them.

| Existing chart | Change |
|---|---|
| Heart rate trend | Add an overnight-average source from Polar `SensorSession` (when present), alongside the existing HealthKit data. Different marker / line styling to distinguish source. |
| HRV (SDNN) trend | Add a per-session SDNN value from Polar's RR-interval stream. Same metric definition as `HKQuantityTypeIdentifier.heartRateVariabilitySDNN`, just from a chest strap. Trivially comparable; brief on-chart note explains window difference (HealthKit: ~60s sliding; Polar: per-session aggregate). |
| *(new)* HRV (RMSSD) trend | New trend chart in the same style as the rest of Trends. Polar-only — HealthKit doesn't store RMSSD. Computed from the RR stream already in `HRVReading.rmssd`. |
| *(new)* HRV (HF Power) trend | New trend chart in the same style. Polar-only. Sourced from `HRVReading.hfPower` aggregated per session. Replaces what `LFHFChartView` currently does, but in the existing trend-chart vocabulary. |

**Demotions / removals:**
- `LFHFChartView` ("HRV Frequency Power" card) — removed. Its data is now in the new HF Power trend chart in the standard style.
- `LF/HF Ratio` — removed from the headline / Trends surface entirely. Kept only in `LFHFSessionDetailView` as one panel of the per-session drilldown. Interpretively contested per Billman 2013 — three of the literate persona-reviewers (Dr. Patel, Dr. Rivera, Lena) independently flagged it as the worst headline metric in the app.
- `LFHFExplainerSheet` — kept, reachable from the new HF Power trend chart's info button instead.

**Files affected:**
- `AnxietyWatch/Views/Trends/TrendsView.swift` — remove `LFHFChartView` slot; add Polar overlays to `HRVTrendChart` + `HeartRateTrendChart`; add new `RMSSDTrendChart` + `HFPowerTrendChart`.
- `AnxietyWatch/Views/Trends/HRVTrendChart.swift` *(existing)*, `HeartRateTrendChart.swift` *(existing)* — accept a new `polarReadings` / `polarSessions` parameter and render the additional series.
- `AnxietyWatch/Views/Trends/LFHFChartView.swift` — removed.
- `AnxietyWatch/Views/Trends/RMSSDTrendChart.swift` *(new)*, `HFPowerTrendChart.swift` *(new)* — new chart cards modeled on existing `HRVTrendChart`.
- `AnxietyWatch/Services/LFHFAggregator.swift` — kept, used by the new HF Power trend (`nightlyMeans` already returns what's needed). Possibly extended with `nightlySDNN` / `nightlyRMSSD` helpers if the per-session aggregation isn't already there.

### 4b — Live recording ambient UX

Convert recording from "modal that owns the foreground" to "ambient activity the app navigates around."

**Layered approach:**

- **Background recording** — already done. `PolarHRMService` has `bluetooth-central` background mode and `recoverInFlightSessionIfNeeded()` state restoration. No changes.
- **In-app ambient indicator** — persistent pill at the top of every tab when recording is active: *"Recording · 12:34 · 62 BPM"*. Tap to expand the live session view as a sheet over the current tab. Dismissing returns to whatever tab the user was on, recording still running.
- **System-level Live Activity** — `ActivityKit` widget for Lock Screen + Dynamic Island. Renders the same values the in-app pill renders. Textbook Live Activity use case (ongoing, time-bounded, glanceable, definite end state).

**What this fixes:**
- Journal-during-recording workflow becomes possible. Currently the user has to choose between journaling and recording — exactly the integration the app's design principles describe.
- Quick-check pattern (look at live HR, then go back to dashboard) takes one tap and one swipe instead of a full modal lifecycle.
- Glanceability via Lock Screen / Dynamic Island, no need to open the app at all to confirm recording is alive.

**Files affected:**
- `AnxietyWatch/App/ContentView.swift` — wrap the `TabView` in a layout that reserves space for the recording pill when active.
- `AnxietyWatch/Views/Common/RecordingStatusPill.swift` *(new)* — the persistent indicator. Reads `PolarHRMService.state` already in the environment.
- `AnxietyWatch/Views/Settings/HRVSessionLiveView.swift` — change from `.fullScreenCover` / `.sheet(.large)` presentation to a `.sheet` with a smaller detent that can be dismissed without ending the session. Or convert to a navigation destination.
- `AnxietyWatchActivity/` *(new target)* — `ActivityKit` widget extension. New Xcode target, modest scope.

### 4c — Session detail entry points

Make `LFHFSessionDetailView` reachable from the trend charts themselves, not just from a separate list.

- Tap a point / mark on the HR trend, SDNN trend, RMSSD trend, or HF Power trend → opens the session detail for the night corresponding to that point.
- `LFHFSessionsListView` either:
  - **Removed** (data is fully reachable via trend interaction), or
  - **Demoted** to Settings → History, for users who specifically want a flat chronological list.

The session detail view itself stays largely as-is — it's well-received by Lena, Sam, Priya, and Diego. The persona review's suggested polish (Simple/Advanced toggle, plain-language interpretation sentence, etc.) is **out of scope for 4c**; tracked as Phase 4d below.

**Files affected:**
- `AnxietyWatch/Views/Trends/HRVTrendChart.swift`, `HeartRateTrendChart.swift`, `RMSSDTrendChart.swift`, `HFPowerTrendChart.swift` — add `.chartGesture` / tap handler to navigate to `LFHFSessionDetailView` when a session-anchored mark is tapped.
- `AnxietyWatch/Views/Trends/LFHFSessionsListView.swift` — removed (preferred) or moved.

## Shipping order

**4a → 4b → 4c.** Each is independently shippable, but the order matters:

1. **4a first** — purely UI rearrangement of data the app already has. Lowest risk. Highest persona-visible impact. Sets up the entry points that 4c will hook into.
2. **4b second** — independent from 4a / 4c. Bigger surface-area change (new Xcode target for Live Activity) but isolated to recording workflow.
3. **4c last** — depends on 4a's new trend charts existing.

## Out of scope (deferred)

The persona review surfaces additional valuable work that **does not** belong in this phase. Tracked here so it's not lost:

- **Plain-language interpretation sentence** at the top of session detail (Marcus, Janine, Diego all asked for it independently)
- **Anxiety-sensitive mode** / illness-anxiety routing (Tom + Dr. Patel — separate clinical-safety work item)
- **Medication / dose overlay** on session timeline (Diego, Priya)
- **Posture / orthostatic annotation** (Priya)
- **Weekly multi-night overlay** of HF traces (Sam)
- **Methodology disclosure sheet** behind the info button (Lena, Dr. Rivera)
- **CSV export** at session detail (Lena)
- **Accessibility fixes** for the per-minute charts in `LFHFSessionDetailView`, the "1 sessions" plural bug in `LFHFChartView.accessibilitySummary`, and the row-level hint on `LFHFSessionRow` (David — concrete code locations in `lfhf-ux-persona-review.md`)
- **Disambiguate "301/301 windows"** label

Some of these are 30-minute fixes (the David / accessibility items in particular) and could ride along with 4a/4b/4c rather than waiting for a Phase 4d.

## Risks / open questions

- **SDNN comparability.** Apple Watch SDNN is computed over a short window (~60s) opportunistically, often during a Breathe session. Polar SDNN here would be a per-overnight-session aggregate. Both are SDNN, but the temporal granularity differs. Decision needed: render as same-line different-marker (visual unification) vs separate lines (acknowledged different windows). Leaning toward different markers + brief in-chart note.
- **Live Activity scope.** First Live Activity in the app means a new Xcode target, `ActivityKit` framework, `WidgetKit` interop, push token handling for remote updates if desired. Probably one-day spike to confirm shape before committing to 4b's full scope.
- **Removal of `LFHFChartView` and `LFHFSessionsListView`** may break expectations for users running v0.x with deep links / saved screenshots. Mitigation: graceful redirects from old NavigationLinks (if any are exposed) and clear release notes.
- **The `Anxiety` framing** that Priya flagged — out of scope here, but worth tracking. Renaming the app or repositioning ("AnxietyWatch — for tracking anxiety alongside autonomic data") is a separate strategic question not solved by this phase.

## Success criteria

A user opening the app sees one coherent set of trend charts. The fact that data came from Polar vs HealthKit is a visual detail (different marker, footnoted in the chart), not a separate section of the app. Tapping a point on any HRV-related chart opens the session detail. Starting a recording shows a small pill at the top of the screen and continues to let the user journal, log medications, or browse Trends while the strap is recording. The Lock Screen shows a Live Activity for the ongoing session.

No new UX surfaces have been added. Existing surfaces have absorbed the new capability. The complexity of the app *decreases* even as functionality increases.
