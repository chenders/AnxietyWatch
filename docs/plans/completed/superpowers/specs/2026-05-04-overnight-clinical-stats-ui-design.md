# Overnight Clinical Stats — UI Surfacing Design

## Context

PR #120 added 7 derived clinical stats to `HealthSnapshot` (SpO₂ nadir/T90/desats overnight; glucose SD/CV/min/max daily) but kept them confined to the data layer + CSV/JSON export. This spec covers the UI surfacing decisions made during brainstorming for the same PR: where these fields appear in the iOS app and how they're presented.

The data is sourced from devices like the EMAY SleepO2 (overnight SpO₂) and Dexcom Stelo (continuous glucose) writing to HealthKit, then aggregated into `HealthSnapshot` by the existing `SnapshotAggregator`. Without UI, the user has to open Xcode or a CSV to see the values — defeating the point of bringing them into the anxiety-correlation app.

**Goal:** surface the seven new fields in the iOS app's user-facing views — Dashboard, Trends, CPAP Detail, and the PDF Report — using clinical-default severity thresholds for color coding. Server-side schema changes are deferred to a follow-up PR.

## Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Dashboard density | All 7 fields visible: dedicated "Last Night" section + augmented Glucose tile with mini-grid |
| Trends layout | Expand existing CPAP chart into a "Sleep Respiratory" panel; add new standalone Glucose chart |
| Other surfaces | PDF Report (ReportGenerator) + CPAP Detail view; sync server work split into follow-up PR |
| Color coding | Clinical defaults (not personal baselines) |
| First-day behavior | Conditional rendering — sections hidden when no overnight data exists, matching existing CPAP card pattern |

## Severity thresholds (clinical defaults)

```swift
enum Severity { case normal, mild, moderate, severe }
// Color mapping: normal=green, mild=yellow, moderate=orange, severe=red
```

All bands are inclusive at the lower-severity end: e.g., for T90, `5` is mild and `6` is moderate; for desats, `15` is mild and `16` is moderate.

| Metric | normal | mild | moderate | severe |
|---|---|---|---|---|
| SpO₂ nadir (%) | ≥ 95 | [90, 95) | [85, 90) | < 85 |
| T90 (min) | 0 | 1–5 | 6–30 | > 30 |
| Desats (count/night) | < 5 | 5–15 | 16–30 | > 30 |
| Glucose CV (%) | < 36 | [36, 50] | — | > 50 |
| Glucose value (mg/dL) | [70, 180] | < 70 or (180, 250] | — | > 250 |

## Architecture

### New files

- **`AnxietyWatch/Utilities/ClinicalSeverity.swift`** — pure-function classifier
  - `enum Severity { normal, mild, moderate, severe }` with `var color: Color`
  - Static functions per metric: `spo2NadirSeverity`, `t90Severity`, `desatCountSeverity`, `glucoseCVSeverity`, `glucoseValueSeverity`
  - No HealthKit / SwiftData dependency, fully unit-tested
- **`AnxietyWatch/Views/Dashboard/LastNightCard.swift`** — single full-width tile with internal 3-column grid (SpO₂ nadir / T90 / desats). Footer shows freshness ("Last night" / "3 nights ago"). Color comes from `ClinicalSeverity`.
- **`AnxietyWatch/Views/Trends/GlucoseTrendChart.swift`** — `ChartCard`-wrapped chart: AreaMark range band (min→max), LineMark for daily avg, plus a secondary chart row of CV% bars colored via `ClinicalSeverity.glucoseCVSeverity`. Anxiety-entries overlay matches other Trends charts.
- **`AnxietyWatchTests/ClinicalSeverityTests.swift`** — boundary-value tests for each severity function.

### Renamed files

- **`AnxietyWatch/Views/Trends/CPAPTrendChart.swift`** → **`SleepRespiratoryTrendChart.swift`**
  - Type renamed `CPAPTrendChart` → `SleepRespiratoryTrendChart`
  - Now takes `snapshots: [HealthSnapshot]` in addition to existing parameters
  - Four vertically stacked Charts inside one `ChartCard("Sleep Respiratory")`:
    1. AHI bars (existing, unchanged styling)
    2. SpO₂ nadir LineMark on its own chart (separate from AHI to avoid the disjoint-y-axis distortion that would compress the AHI bars into the bottom 30% of a shared scale; explicit 75–100% domain so day-to-day variation is legible)
    3. T90 bars (new) — color from `ClinicalSeverity.t90Severity`
    4. CPAP usage hours (existing, unchanged)
  - Subtitle aggregates desats across the visible window ("avg 5.2 desats/night across 30 nights") so 30/90-day views don't expand the ChartCard header into a paragraph
  - Existing baseline overlay + anxiety-entries overlay preserved

### Modified files

- **`AnxietyWatch/Views/Dashboard/DashboardView.swift`**
  - Add `lastNightSection` `@ViewBuilder` between `vitalsCards` and `activityCards` in `healthSection`
  - Conditionally renders `LastNightCard(snapshot:)` only when at least one of the three SpO₂ overnight fields is non-nil on the most recent snapshot
  - Modify the existing Glucose `LiveMetricCard` call site to pass `.miniGrid(items:)` visualization when current day has ≥3 glucose readings AND the most-recent snapshot has variability stats
- **`AnxietyWatch/Views/Dashboard/LiveMetricCard.swift`**
  - Add new case to `MetricVisualization`: `case miniGrid(items: [(label: String, value: String, color: Color)])`
  - Render path: 2×2 grid of `(label, value)` pairs (with per-item color via `ClinicalSeverity` for min/max/CV; SD uses default text color) replacing the right-side visualization area
- **`AnxietyWatch/Views/Dashboard/DashboardViewModel.swift`**
  - Add `var mostRecentSnapshotWithOvernightStats: HealthSnapshot?` — `FetchDescriptor<HealthSnapshot>` sorted desc by date, fetchLimit 1, predicate `spo2NadirOvernight != nil || spo2TimeBelow90Min != nil || spo2DesatsCount != nil`
  - Add `var mostRecentSnapshotWithGlucoseStats: HealthSnapshot?` — analogous predicate for glucose stats
- **`AnxietyWatch/Views/Trends/TrendsView.swift`**
  - Replace `CPAPTrendChart(...)` call with `SleepRespiratoryTrendChart(...)`
  - Add `GlucoseTrendChart(...)` after Sleep Respiratory, before Barometric
- **`AnxietyWatch/Views/CPAP/CPAPDetailView.swift`**
  - Add an "Overnight SpO₂" card beneath the existing CPAP session detail
  - Pulls the matching `HealthSnapshot` by `session.date == snapshot.date` (already available in scope from the parent passing `recentSnapshots`)
  - 3-column row of nadir/T90/desats with severity colors + a "vs. avg this month" footer line
  - Hidden if no matching snapshot
- **`AnxietyWatch/Services/BaselineCalculator.swift`**
  - Add `spo2NadirBaseline(from snapshots:)` and `t90Baseline(from snapshots:)` mirroring the existing `cpapAHIBaseline` pattern (rolling mean + σ over 30 days)
- **`AnxietyWatch/Services/ReportGenerator.swift`**
  - Add `renderOvernightSection(snapshots:into:)` method
  - Slot a new "Overnight Respiratory & Glucose" subsection between the existing CPAP/sleep summary and the activity summary
  - Per-day output renders one or two body lines per snapshot — a SpO₂ line and a Glucose line — split rather than joined to avoid `drawBody`'s 18-pt text rect clipping long combined fragments. Example:
    ```
    Mar 14: SpO₂ nadir 87% (moderate) · T90 12 min (moderate) · 4 desats (normal)
            Glucose 80–165 mg/dL · CV 19% (normal)
    ```
  - Severity is rendered as inline textual annotations (e.g., `(moderate)`, `(severe)`) rather than colored text spans. The existing PDF helpers (`drawSectionHeader`, `drawBody`) don't support per-character color, and textual annotations also survive black-and-white printing better than color.
  - Summary header above the per-day list: "X nights with desats ≥ moderate" and "Y days with elevated glucose CV" (driven through `ClinicalSeverity.glucoseCVSeverity` so the summary threshold matches the per-day labels exactly — `≥ 36%` is mild)
  - Days with no overnight data are omitted (no placeholder rows)

### Reused unchanged

- `LiveMetricCard` — receives the new `.miniGrid` viz case but the rest of the structure is unchanged
- `ChartCard` — wraps both new/modified charts as before
- `BaselineCalculator` — extended additively, existing methods unchanged
- `freshnessLabel` style — reused for the Last Night footer

## Component contracts

### `ClinicalSeverity`
```swift
enum Severity: Sendable, Equatable {
    case normal, mild, moderate, severe
    var color: Color { ... }
}

enum ClinicalSeverity {
    static func spo2NadirSeverity(_ percent: Double) -> Severity
    static func t90Severity(_ minutes: Int) -> Severity
    static func desatCountSeverity(_ count: Int) -> Severity
    static func glucoseCVSeverity(_ percent: Double) -> Severity
    static func glucoseValueSeverity(_ mgdL: Double) -> Severity
}
```

### `LastNightCard`
```swift
struct LastNightCard: View {
    let snapshot: HealthSnapshot   // assumed to have at least one overnight stat
    var body: some View { ... }
}
```
Renders as a full-width tile with title "Last Night", a 3-column grid (SpO₂ Nadir / T90 / Desats), and a footer with relative freshness.

### `SleepRespiratoryTrendChart` (new signature replacing `CPAPTrendChart`)
```swift
struct SleepRespiratoryTrendChart: View {
    let sessions: [CPAPSession]
    let snapshots: [HealthSnapshot]
    let allSnapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>
}
```

### `GlucoseTrendChart`
```swift
struct GlucoseTrendChart: View {
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>
}
```

### `LiveMetricCard.MetricVisualization` (additive)
```swift
case miniGrid(items: [(label: String, value: String, color: Color)])
```

## Testing

- **`ClinicalSeverityTests.swift`** *(new)* — boundary tests for every threshold edge in the table above (~20 assertions). Pure-function tests, instant.
- **`DashboardViewModelTests.swift`** *(extended)* — tests for `mostRecentSnapshotWithOvernightStats` and `mostRecentSnapshotWithGlucoseStats` covering empty store, all-nil snapshots, ordering.
- **`BaselineCalculatorTests.swift`** *(extended)* — `spo2NadirBaseline` and `t90Baseline` tests mirroring the existing `cpapAHIBaseline` test pattern; insufficient-data returns nil.
- **`ReportGeneratorTests.swift`** *(extended)* — `reportIncludesOvernightSection` asserting rendered output contains the new section header and per-day lines.
- **No SwiftUI view-level tests** — matches existing project pattern (visual correctness is verified by build + manual review).

## Out of scope (deferred)

- **Sync server schema additions** — Alembic migration, `health_snapshots` column additions, server-side upsert logic, admin UI columns. Will be a separate PR that consumes the existing JSON export already populated in PR #120.
- **Personal-baseline color coding** — clinical thresholds are sufficient for v1. Personal baselines could be added later as an opt-in, but the desat case (where 0 is healthy) means a naive baseline would always color red on first non-zero reading.
- **Trends "no data" empty-state copy** — `ChartCard isEmpty:` already handles this; no per-chart customization.

## Verification

End-to-end manual smoke test (after implementation):
1. Build the iOS app, install on a device or simulator.
2. Open the app: Dashboard renders without the "Last Night" section (no overnight data yet) and Glucose tile is unchanged.
3. Seed `HealthSnapshot` data with overnight stats (via Xcode debug or a test fixture).
4. Reopen: "Last Night" section appears with severity-colored values; Glucose tile shows mini-grid.
5. Open Trends: Sleep Respiratory panel shows AHI + nadir line + T90 bars; Glucose chart shows range band + avg + CV.
6. Open CPAP Detail for a session: Overnight SpO₂ card appears below the existing detail.
7. Generate a PDF report covering the seeded date range: "Overnight Respiratory & Glucose" subsection renders with per-day SpO₂ and Glucose lines plus inline severity word annotations (e.g., "nadir 87% (moderate)"). Severity is text, not color (PDFCursor has no color helpers; textual labels survive B&W printing).

Automated:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AnxietyWatchTests/ClinicalSeverityTests \
  -only-testing:AnxietyWatchTests/DashboardViewModelTests \
  -only-testing:AnxietyWatchTests/BaselineCalculatorTests \
  -only-testing:AnxietyWatchTests/ReportGeneratorTests
```
All new and extended tests must pass.
