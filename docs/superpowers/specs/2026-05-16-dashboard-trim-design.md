# Dashboard trim & redesign

**Status:** Approved (mockup signed off 2026-05-16)
**Branch:** `dashboard-trim-redesign`
**Driver:** Chris

## Goal

The Dashboard tab currently renders up to ~30 stacked full-width cards. It's the home screen of the app — opening it should answer "how am I doing right now / today" in one to two screen-heights of scroll. Today it doesn't.

In priority order:

1. **Much shorter** — visible content fits in ~1.5 phone screens (target: ~14–16 zones max, several of them compact 1-line rows).
2. **More intuitive** — clear hierarchy with the spine signals (anxiety, last-night, autonomic state) above the fold; every visible card answers "good / bad / typical for me" not just "show a number".
3. **Right chart for the data** — fix viz/data mismatches (sparkline-with-one-point, intraday sparkline on a nightly metric, progress bar against an arbitrary goal).

Non-goal: rewriting the underlying data layer. The redesign is composition + a few new visualization cases + a couple of safety retrofits.

## Final zone order (top → bottom)

```
1. Alerts strip            (rolled-up; zero alerts = zero pixels)
2. "What changed today"    (smart summary; NEW)
3. Polar HRV session       (always-at-top when paired, per user)
4. Last Anxiety            (spine signal, red tint)
5. Last Night              (MERGED hero: sleep efficiency + AHI + nadir + WASO)
6. Heart Rate              (full-width, sparkline)
7. HRV                     (full-width, recent-bars + baseline chip)
8. Vitals 2-col grid       (default expanded, 6–9 tiles, section header)
9. Activity row            (MERGED: Steps + Cal + Exercise)
10. Environment & background (default collapsed disclosure)
11. Last Medication        (compact row)
12. Care section           (compact row → existing LabResultsView)
```

Roughly ~3,000pt of scroll today, ~1,200–1,400pt after.

## Decisions captured

- **Q1 (Smart Summary):** include in this PR.
- **Q2 (Sleep Efficiency + WASO):** include in this PR; replaces raw duration as the Last Night headline.
- **Q3 (REM/deep clonazepam gate):** deferred — no REM/deep alerts exist today. This spec documents the constraint so any future REM/deep baseline alert must be gated on `medicationTakenToday == false` (clonazepam suppresses both REM and deep sleep; an alert against an unsuppressed baseline would be a false positive).
- **Q4 (Polar visibility):** keep current behavior — always at top when paired.

## In scope

### A. New components

**`MetricSalience` helper** (new file, alongside `BaselineCalculator`)
- Pure functions returning whether a given metric is "notable enough to surface" given current value + baseline + freshness.
- Per-metric rules (initial set; expand later):
  - VO₂ Max: notable if drop > 10% from 90-day baseline, OR no baseline yet.
  - Walking HR: notable if last 7-day avg > baseline + 1σ.
  - Walking Steadiness: notable on any state transition (OK → Low / Very Low).
  - AFib Burden: notable if > 0% OR week-over-week increase.
  - Env Sound / Headphone Audio: notable if 7-day TWA > 80 dBA or any single reading > 85 dBA.
  - Blood Pressure: notable if reading > 7 days old OR last 3 readings out of normal range.
  - Blood Glucose: notable if fasting > 100 OR any reading > 180.
  - Barometric: notable if 24h Δ > 0.5 kPa.
- Each returns `MetricSalience.Verdict = .surface | .demote` plus an optional `reason` for the demoted-section header.
- Lives in `AnxietyWatch/Services/MetricSalience.swift`. Pure; trivially testable.

**`CollapsibleSection<Content>`** (new view)
- Header row with title, chevron, optional count badge, optional severity dot.
- Tap to expand/collapse inline. Expansion state persisted via `@AppStorage("dashboard.section.<id>.expanded")`.
- Replaces ad-hoc disclosure pattern.

**`BaselineChip`** (new `MetricVisualization` case)
- `.baselineChip(value: Double, deltaText: String, color: Color)` — renders inline next to the value as `↑ +6 vs 30d` colored by severity.
- Applied to: Resting HR, Walking HR, Walking Steadiness, Blood Pressure, Barometric Pressure (6h trailing Δ arrow), Walking HR.
- Implementation note: extend the existing `MetricVisualization` enum in `LiveMetricCard.swift`. The case is data-only; rendering is a small `HStack` inside the existing card chrome.

**`AlertsStrip`** (new view)
- Replaces the stacked `baselineAlert` + `supplyAlertCard` cluster.
- Rule: 0 alerts → zero pixels; 1 alert → single line; 2+ → single line with count chip and severity color, tap to expand inline.
- Dedupe correlated alerts (HRV low + RHR up + Sleep short → show the highest-z-score one with "+2 related").
- Cap visible at 3 when expanded.

**`SmartSummaryComposer`** (new pure helper) + **`SmartSummaryCard`** (new view)
- Composer is a pure type (struct with static methods) in `AnxietyWatch/Services/SmartSummaryComposer.swift`. Takes snapshots, samples, baselines, last anxiety entry → returns a `SmartSummary` value (sentence text + severity color, or `.quiet`).
- Selection: rank candidates (HRV, sleep efficiency, RHR, RR, AHI, anxiety self-report z-score, baro Δ) by absolute z-score against the 30-day baseline; pick top 1–3 with |z| > 1.0; tie-break toward (a) most-recent journal correlate and (b) downward direction.
- Suppression: nothing > 1σ AND no alerts AND no journal entry ≥ 5/10 in last 24h → returns `.quiet`. View renders "Nothing unusual today." in muted text (~32pt tall — absence is information).
- **No LLM at render time.** Deterministic template composition. The view is a thin shell over the composer's output; all logic is in the composer (testable).

**`LastNightCard`** (replaces existing minimal `LastNightCard`)
- Merges Sleep, CPAP, overnight SpO₂. Single tappable card → existing `CPAPDetailView` (already wired and `@Query`-free).
- Headline composition:
  - Default: `"<verdict> · Sleep efficiency <pct>%, AHI <ahi>, SpO₂ nadir <nadir>%"`
  - Verdict words: `Solid night` (eff ≥ 85% AND AHI < 5 AND nadir ≥ 92), `OK` (one breach), `Rough night` (two+ breaches).
  - If nadir missing: drop the SpO₂ clause and keep the rest.
  - If AHI missing: drop the CPAP clause and keep the rest.
  - If sleep stages missing: degrade to `"<verdict> · <time-in-bed> · AHI <ahi>"`.
- Supporting rows: Sleep (in-bed, asleep, WASO) · Stages bar · CPAP (AHI + usage + Δ-vs-baseline) · SpO₂ (nadir + t<90 + desats, with EMAY chip).
- Lives in `AnxietyWatch/Views/Dashboard/LastNightCard.swift` (extend the existing file — currently renders only the SpO₂ stat trio; expanding it to the merged hero is in-scope).

**`SleepEfficiencyCalculator`** (new file)
- Static methods that take `[SleepStageEvent]` for a single night and produce:
  - `inBedMinutes` (sum of in-bed events)
  - `asleepMinutes` (sum of `asleep*` events)
  - `wasoMinutes` — wake-after-sleep-onset, computed as awake-time *between* the first and last asleep events
  - `efficiencyPct = asleepMinutes / inBedMinutes`
- Lives next to `BaselineCalculator` in `AnxietyWatch/Services/`. Pure. Heavily unit-tested with synthetic event streams (sleep-start, mid-night wake, multiple wake-ups, no-data, single-stage).

### B. Chart-correctness fixes

| Card | From | To |
|---|---|---|
| HRV | sparkline | recent-bars (last ~14) + baseline-deviation chip |
| Respiratory Rate | sparkline | recent-bars (last 14 nights) |
| Active Calories | progress bar vs 500 | "vs 7-day avg" framing inside Activity row |
| Headphone Audio | sparkline | number-only (no viz) |
| Walking Steadiness | recent-bars | number-only (no viz) |
| Resting HR | recent-bars | baseline-deviation chip |
| Walking HR | recent-bars | baseline-deviation chip |
| Blood Pressure | none | baseline-deviation chip |
| Last CPAP AHI | none | baseline-deviation chip in subtitle |
| Barometric Pressure | none | 6h trailing Δ arrow |

VO₂ Max keeps `recentBars` but the existing "last 7 readings" subtitle changes to "last 7 weeks" (cadence reality).

### C. Layout regrouping

- **Vitals 2-col tile grid** under a `Vitals` section header. Contents: Resting HR, SpO₂, Respiratory Rate, VO₂ Max, Walking HR, Walking Steadiness, AFib Burden, Blood Pressure, Blood Glucose. Heart Rate and HRV stay as full-width cards above the grid (hero vitals). Tile contents = title chip · value · delta chip OR mini-viz. **Tiles are non-interactive in v1** — they display only. The full charts already live in the Trends tab; users discover them there. (Deep-linking tiles into `TrendsView` as a `NavigationLink` destination would require `Equatable + .equatable()` retrofit on `TrendsView` per CLAUDE.md, which is out of scope here.) The section-header chevron is decorative for now.
- **Activity row** — single card containing three thin horizontal mini-bars for Steps · Active Cal · Exercise, with "vs 7-day avg" subtitles. Replaces 3 stacked progress-bar cards.
- **Environment & background** — collapsible disclosure (default collapsed). Contains: Env Sound, Headphone Audio, VO₂ Max-when-stale, Walking Steadiness, AFib Burden, Barometric Pressure. The disclosure's header line shows up to one salient item (per `MetricSalience`) as a preview — e.g. `"Environment & background · Baro ↓0.4 kPa / 6h · 5 metrics ›"`. If multiple are salient, pick the one with the largest |z-score|. If none are salient, show only the metric count.
- **Last Medication** → single-line `Label` row, not a full card.
- **Care section** → single-line row `"Care · N recent labs ›"` that pushes the existing `LabResultsView`. Prescription supply state is already handled by the Alerts strip; don't restate it here.

### D. Source / device chips

- Add `DeviceChip` view (small SF Symbol + 1-word source label).
- Wire to existing `DeviceProvenance` partitioning.
- Apply on cards where the metric can come from multiple devices: HRV, SpO₂, Heart Rate, Resting HR, Respiratory Rate, Last Night SpO₂ block.
- Single card per metric — do not duplicate by source. The existing precedence chain (EMAY > Polar > Watch for SpO₂; Polar > Watch for HRV) chooses the visible reading.

### E. iOS 26 safety retrofits (load-bearing)

1. **`GlucoseDetailView` Equatable + `.equatable()`** — currently holds two `@Query`s and is pushed as a `NavigationLink` destination without the iOS 26 guard. Conform to `Equatable` on identity props only; wrap the `NavigationLink` label call site in `.equatable()`. (Latent bug per CLAUDE.md; the redesign is the moment to fix it.)
2. **Section child views** — each section's body becomes its own `View` struct (`AlertsSectionView`, `LastNightSectionView`, `VitalsHeroSectionView`, `VitalsGridSectionView`, `ActivitySectionView`, `EnvironmentSectionView`, `CareSectionView`, `SmartSummarySectionView`). Each takes the slices of `vm` and `@Query` results it needs. This scopes `@Observable` reads so a `samplesByType` mutation doesn't invalidate the whole `ScrollView` root (CLAUDE.md "`@Observable` reads at App / WindowGroup scope" — same principle applies to any large body that reads `@Observable`).
3. **Bounded `@Query`s** — add date-bounded predicates to `recentEntries`, `recentDoses`, `recentCPAP`, `recentLabResults` in `DashboardView`. The dashboard only reads `.first` from each; anything older than 30 days is dead weight. Match the existing `recentSleepEvents` pattern.
4. **No compound `#Predicate` with captured non-primitive locals** in any new query. Stay single-clause; apply secondary filters in-memory.
5. **`Dictionary(grouping:)` order** — anywhere we iterate a metric-keyed dictionary to render tiles, sort by a fixed canonical order array, not by dictionary keys.

### F. Tests

All new logic must have tests; failing tests block. New test files:

- `MetricSalienceTests.swift` — verdict per metric across surface/demote thresholds; missing-baseline path.
- `SleepEfficiencyCalculatorTests.swift` — synthetic stage streams covering: clean night, mid-night wake, multiple wakes, no-data, single-stage, in-bed-only.
- `SmartSummaryComposerTests.swift` — selection ranking (top-N by |z|), tie-breaking, suppression rule (returns "Nothing unusual today."), missing-data degradation.
- `LastNightHeadlineTests.swift` — headline composition across {clean / one breach / two breaches} × {AHI present/missing} × {nadir present/missing}.
- `AlertsStripDedupeTests.swift` — dedupe HRV-low + RHR-up + Sleep-short → highest-z-score wins, "+N related" suffix.
- Extend `DashboardViewModelTests.swift` for any new view-model entry points.

Coverage target carries over from `CLAUDE.md`: Services ≥ 80%.

### G. Plan-doc updates (separate task in plan)

- This spec gets a `## Implementation notes (post-merge)` section appended at merge time per CLAUDE.md's plan-doc policy.

## Out of scope (explicitly deferred)

These came up in agent review but are not part of this PR:

- **Smart-suppression of physiological alerts based on medication state** (Q3) — defer. No REM/deep alerts exist today. If/when one is added, gate on `medicationTakenToday == false`.
- **Auto-detect "Polar session due" and promote to top** — defer. Always-at-top when paired (Q4 = current behavior).
- **Polar session card replaces Heart Rate during live recording** — defer; the existing live pill above the tab bar already handles in-session UX.
- **Pinning specific lab tests to the Today zone** — defer. Cares-section row is the right place for now.
- **Apple-style three-ring Activity visualization** — defer. The single-card with three mini-bars is enough for v1.
- **Per-section lazy loading of `samplesByType`** — codebase agent confirmed the single `FetchDescriptor` is one query regardless of how many types we slice. Don't fragment.

## Implementation phasing (sketch — full plan in next doc)

Roughly five mergeable groups:

1. **Safety retrofits + query bounds** — `GlucoseDetailView` Equatable; date-bound the four unbounded `@Query`s. Land first so the surface is safe before we expand it.
2. **Pure helpers + tests** — `SleepEfficiencyCalculator`, `MetricSalience`, `SmartSummaryComposer` (the deterministic template). All unit-testable without UI.
3. **New view primitives** — `CollapsibleSection`, `BaselineChip` viz case, `DeviceChip`, `AlertsStrip`, `SmartSummaryCard`, `SectionHeader`.
4. **Section extraction** — split `DashboardView` body into child View structs (no behavior change yet).
5. **Wiring + layout switch** — replace the section list with the new zone order; merge Last Night; build the Vitals tile grid; collapse Activity; demote to disclosures.

Each group lands together but should be self-reviewable. The reviewer agent (`.claude/agents/swift-pre-pr-reviewer.md`) runs before push per CLAUDE.md policy.

## Risks

- **Visual diff surface is large.** Reviewers will need fresh screenshots. Capture before/after in the PR description.
- **Smart Summary template needs to read well on a tired morning.** Headlines like "Sleep efficiency was 76%" can sound clinical. Iterate phrasing during execution; tests cover *what* gets surfaced, not *how* it reads.
- **Sleep efficiency depends on having both in-bed and asleep events.** Apple Watch users without manual time-in-bed will see degraded headlines. Calculator must gracefully degrade.
- **`MetricSalience` rules are heuristics.** Each threshold deserves a test, and the values may need tuning after a week of dogfooding. Don't bake them into the view layer.
