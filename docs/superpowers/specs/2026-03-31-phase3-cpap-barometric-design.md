# Phase 3: CPAP & Barometric Integration — Design Spec

**Date:** 2026-03-31
**Branch:** `phase3/cpap-barometric-integration`
**Approach:** Snapshot-first — wire CPAP and barometric data into `HealthSnapshot` so the existing baseline/deviation/correlation pipeline handles them automatically.

---

## 1. Data Model Changes

### HealthSnapshot — 4 new optional fields

```swift
// CPAP (matched from CPAPSession by date)
var cpapAHI: Double?
var cpapUsageMinutes: Int?

// Barometric (aggregated from BarometricReading by date)
var barometricPressureAvgKPa: Double?
var barometricPressureChangeKPa: Double?  // max - min for the day; captures weather fronts
```

All optional — graceful degradation for days without CPAP data or barometer readings.

### CPAPSession — no model changes

Duplicate detection is handled at the import layer (upsert by date), not via a `#Unique` constraint. This avoids crashes from pre-existing duplicate data.

---

## 2. CPAPImporter — Duplicate Detection & Backfill Support

### Import result struct

```swift
struct ImportResult {
    let inserted: Int
    let updated: Int
    let dateRange: ClosedRange<Date>?  // for snapshot backfill
}
```

Replaces the current `Int` return value.

### Upsert logic

Before inserting a parsed session, query for an existing `CPAPSession` with the same date (already start-of-day normalized). If found, update the existing record's fields. If not, insert a new one.

Track the min/max dates across all processed sessions to produce `dateRange`.

### Caller changes

`CPAPListView.handleImport` uses `dateRange` to trigger `SnapshotAggregator.aggregateDay` for each affected date (backfill). Alert message becomes: "Imported 12 sessions (3 updated)."

---

## 3. SnapshotAggregator — CPAP & Barometric Stitching

After the existing HealthKit queries complete:

### CPAP stitching

Fetch `CPAPSession` matching the snapshot's date (both are start-of-day normalized). If found:
- `snapshot.cpapAHI = session.ahi`
- `snapshot.cpapUsageMinutes = session.totalUsageMinutes`

### Barometric stitching

Fetch all `BarometricReading` records for the day (midnight to midnight). Compute:
- `barometricPressureAvgKPa` — arithmetic mean of all readings
- `barometricPressureChangeKPa` — max pressure minus min pressure

### Backfill on CPAP import

When `CPAPImporter.importCSV` finishes, the caller iterates `ImportResult.dateRange` and calls `SnapshotAggregator.aggregateDay` for each date. This handles the async nature of CPAP imports (SD card data arrives days after sessions occurred).

### Barometric aggregation timing

No special backfill needed. `BarometerService` persists readings continuously; the daily snapshot aggregation picks up whatever readings exist when it runs.

---

## 4. BaselineCalculator — New Baselines

Two new static methods following the existing pattern (same window, trimming, threshold logic):

### `cpapAHIBaseline(from:windowDays:)`

Reads `HealthSnapshot.cpapAHI`. AHI is a "higher is worse" metric (like resting HR), so the upper bound is the alert threshold.

### `barometricPressureBaseline(from:windowDays:)`

Reads `HealthSnapshot.barometricPressureAvgKPa`. Pressure drops are the concerning signal — lower bound triggers the alert.

Both require 14+ data points (existing `minimumSampleCount`). Outlier trimming via MAD handles edge cases like mask-off nights (AHI = 40+).

---

## 5. Dashboard Alerts

`DashboardViewModel` gets two new alert checks, following the existing pattern (3-day rolling average vs 30-day baseline):

- **CPAP AHI above baseline** — triggered when 3-day average AHI exceeds the upper bound. Display: "Your AHI has been elevated the last 3 nights."
- **Barometric pressure drop** — triggered when today's average pressure is below the lower bound. Display: "Barometric pressure is significantly below your average."

Same color treatment as existing alerts (yellow for approaching threshold, red for exceeding).

---

## 6. CPAP Detail View

### CPAPDetailView

Tapping a session row in `CPAPListView` or the dashboard card navigates here.

**Layout:**
- Date header + import source badge (csv / oscar / manual)
- Key metrics cards: AHI (color-coded by clinical severity), usage hours, leak rate (if available)
- Event breakdown: obstructive / central / hypopnea counts
- Pressure stats: min / mean / max in cmH2O
- **Context panel:** that day's `HealthSnapshot` data — sleep duration, HRV, and any journal entries with anxiety severity. Shows the cross-metric correlation for that specific night.

### CPAPListView improvements

- Rows become tappable `NavigationLink` to `CPAPDetailView`
- Summary header: average AHI over last 7 and 30 days, consecutive nights with data

### Dashboard card improvement

- Add baseline deviation line: "0.8 below average" or "1.2 above average"
- Make card tappable → navigates to `CPAPDetailView` for most recent session

---

## 7. Barometric Integration — Dashboard & Trends

### Dashboard card upgrade

Current card shows "101.2 kPa — Current". Enhance to show the day's pressure change: "101.2 kPa — dropped 0.8 today". Flag when change exceeds baseline deviation threshold.

### Trend chart

`BarometricTrendChart` already shows readings with anxiety overlays. Add a horizontal `RuleMark` for the 30-day baseline average pressure (dashed line), matching the HRV chart's pattern.

### CPAPTrendChart improvements

- Add horizontal `RuleMark` for AHI baseline (dashed line)
- Add anxiety entry overlays (vertical `RuleMark`) matching the other trend charts

### No changes to

- `BarometerService` or `HealthDataCoordinator` wiring (already correct)
- Live pressure display on dashboard (additive, not replacement)

---

## 8. Testing

All tests use Swift Testing (`@Test`, `#expect`), in-memory `ModelContainer`, and fixed reference dates.

### CPAPImporter tests

- Import simple CSV — verify session count and field values
- Import OSCAR CSV — verify column mapping
- Duplicate detection — import same CSV twice, verify no duplicates (updated count)
- Invalid format / empty file / malformed rows — verify errors
- `ImportResult.dateRange` correctness

### SnapshotAggregator CPAP/barometric stitching tests

- Day with matching `CPAPSession` — `cpapAHI` and `cpapUsageMinutes` populated
- Day with no CPAP data — fields remain nil
- Day with `BarometricReading` records — avg and change computed correctly
- Backfill: import CSV then aggregate affected dates — snapshot updated

### BaselineCalculator tests

- AHI baseline with 14+ days — verify mean/stddev/bounds
- AHI baseline with insufficient data — returns nil
- Barometric pressure baseline — same pattern
- Outlier trimming for AHI (mask-off night = AHI 40 shouldn't skew baseline)

### No view tests

Existing pattern doesn't test views directly. Value is in the service/model layer.

---

## Files Modified

| File | Change |
|------|--------|
| `Models/HealthSnapshot.swift` | Add 4 optional fields |
| `Models/CPAPSession.swift` | No changes |
| `Services/CPAPImporter.swift` | `ImportResult` struct, upsert logic, date range tracking |
| `Services/SnapshotAggregator.swift` | CPAP + barometric stitching after HealthKit queries |
| `Services/BaselineCalculator.swift` | `cpapAHIBaseline`, `barometricPressureBaseline` |
| `Views/Dashboard/DashboardViewModel.swift` | AHI + barometric baseline alerts |
| `Views/Dashboard/DashboardView.swift` | Tappable CPAP card, enhanced barometric card |
| `Views/Trends/CPAPTrendChart.swift` | Baseline RuleMark, anxiety overlays |
| `Views/Trends/BarometricTrendChart.swift` | Baseline RuleMark |
| `Views/CPAP/CPAPListView.swift` | NavigationLink rows, summary header, backfill trigger |

## Files Created

| File | Purpose |
|------|---------|
| `Views/CPAP/CPAPDetailView.swift` | Session detail + cross-metric context panel |
| `AnxietyWatchTests/CPAPImporterTests.swift` | Import, upsert, error handling tests |
| `AnxietyWatchTests/BaselineCalculatorCPAPTests.swift` | AHI + barometric baseline tests |
