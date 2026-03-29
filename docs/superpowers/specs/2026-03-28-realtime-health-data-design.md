# Real-Time Health Data & Intraday Dashboard — Design Spec

**Date:** 2026-03-28
**Status:** Draft
**Branch:** TBD (will be created during implementation)

## Problem

The current architecture is daily-batch: `HealthSnapshot` stores one row per calendar day with averaged/summed values. When opening the dashboard, the user sees today's daily average — not the latest individual reading. Several valuable HealthKit types available from Apple Watch Series 8 are not requested or stored at all. There is no intraday trend visualization.

## Goals

1. **Show the freshest available reading** for each metric with a freshness timestamp ("78 bpm · 3 min ago")
2. **Show intraday trends** as sparklines on dashboard metric cards
3. **Add missing HealthKit types** that Apple Watch Series 8 provides (VO₂ Max, walking HR average, walking steadiness, AFib burden, headphone audio exposure, gait metrics)
4. **Preserve existing infrastructure** — daily snapshots, trends, reports, baselines, sync all continue unchanged

## Non-Goals

- Forcing SpO2/ECG readings programmatically (not possible via HealthKit API)
- Workout session-based elevated sampling
- watchOS-side HealthKit queries (future enhancement)
- Changing the sync server schema (daily snapshots remain the sync unit)

## Architecture

### Two-Layer Data Model

| Layer | Model | Purpose | Retention |
|-------|-------|---------|-----------|
| Individual readings | `HealthSample` (new) | Latest value display, intraday sparklines | 7 days |
| Daily aggregates | `HealthSnapshot` (existing) | Long-term trends, reports, baselines | Forever |

### New Model: `HealthSample`

```swift
@Model
final class HealthSample {
    var id: UUID
    var type: String          // HKQuantityTypeIdentifier.rawValue
    var value: Double         // Canonical unit for that type
    var timestamp: Date
    var source: String?       // "Apple Watch", "Omron BP", etc.
}
```

**Design decisions:**
- `type` is a `String` (not enum) — maps directly to `HKQuantityTypeIdentifier.rawValue`, adding new types requires no migration
- Single table for all metric types, indexed on `(type, timestamp)`
- `source` is optional metadata for distinguishing devices (Watch HR vs BP cuff)
- 7-day retention: cleanup pass on each app launch deletes older rows

### Data Pipeline: HKAnchoredObjectQuery

Replace `HKObserverQuery` with `HKAnchoredObjectQuery` for quantity types that benefit from individual sample storage. Anchored queries return the delta of new samples since the last query, using a persistent anchor stored in `UserDefaults` per type.

**Anchored query types** (individual readings stored in `HealthSample`):

| Type | Canonical Unit | Notes |
|------|---------------|-------|
| `heartRate` | bpm | Currently authorized but never stored |
| `heartRateVariabilitySDNN` | ms | Individual readings, not just daily avg |
| `oxygenSaturation` | % (0–1) | Periodic sleep + sparse daytime |
| `respiratoryRate` | breaths/min | Sleep only |
| `restingHeartRate` | bpm | Usually 1/day |
| `vo2Max` | mL/kg/min | New — after outdoor walks/runs |
| `walkingHeartRateAverage` | bpm | New — per walking bout |
| `appleWalkingSteadiness` | % (0–1) | New — during walking |
| `bloodPressureSystolic` | mmHg | From BP cuff |
| `bloodPressureDiastolic` | mmHg | From BP cuff |
| `bloodGlucose` | mg/dL | If CGM connected |
| `environmentalAudioExposure` | dBA | Existing |
| `headphoneAudioExposure` | dBA | New |

**Not anchored** (remain in observer/snapshot only):
- `sleepAnalysis` — category type, handled separately by existing sleep query
- `appleSleepingWristTemperature` — one reading per night, daily snapshot sufficient
- `stepCount`, `activeEnergyBurned`, `appleExerciseTime` — cumulative types, daily sums are the meaningful metric
- `atrialFibrillationBurden` — single daily value, stored in snapshot only
- Gait metrics (`walkingSpeed`, `walkingStepLength`, `walkingDoubleSupportPercentage`, `walkingAsymmetryPercentage`) — sparse, daily snapshot sufficient

**What stays on HKObserverQuery:**
- `sleepAnalysis` (category type, doesn't fit anchored sample pattern)

### HealthKitManager Changes

- Add to `allReadTypes`: `vo2Max`, `walkingHeartRateAverage`, `headphoneAudioExposure`, `appleWalkingSteadiness`, `atrialFibrillationBurden`, `walkingSpeed`, `walkingStepLength`, `walkingDoubleSupportPercentage`, `walkingAsymmetryPercentage`
- New method: `startAnchoredQueries(onNewSamples:)` — one `HKAnchoredObjectQuery` per anchored type, persistent anchor in `UserDefaults`
- Existing `startObserving(onUpdate:)` reduced to sleep analysis only

### HealthDataCoordinator Changes

- `startObserving()` launches anchored queries for quantity types, observer query for sleep
- `onNewSamples` callback inserts `HealthSample` rows and debounces `SnapshotAggregator` re-aggregation
- New `pruneOldSamples()` runs at launch, deletes `HealthSample` rows older than 7 days

### HealthSnapshot New Fields

```swift
// New fields for newly-tracked types
var vo2Max: Double?                        // mL/kg/min
var walkingHeartRateAvg: Double?           // bpm
var walkingSteadiness: Double?             // 0–1
var atrialFibrillationBurden: Double?      // 0–1
var headphoneAudioExposure: Double?        // dBA
var walkingSpeed: Double?                  // m/s
var walkingStepLength: Double?             // meters
var walkingDoubleSupportPct: Double?       // 0–1
var walkingAsymmetryPct: Double?           // 0–1
```

### SnapshotAggregator Changes

Add aggregation calls for each new `HealthSnapshot` field, using the same `averageQuantity()` / `mostRecentQuantity()` pattern as existing fields.

## Dashboard Design

### Metric Card Layout: Side-by-Side

Each card uses a side-by-side layout:
- **Left:** metric name, latest value with unit, trend direction (↗ rising / → stable / ↘ dropping), freshness timestamp
- **Right:** visualization appropriate to the metric's sampling pattern

### Trend Direction Calculation

Compare the most recent reading to the 1-hour rolling average of prior readings:
- **↗ rising:** latest > 1h avg + threshold
- **→ stable:** within threshold
- **↘ dropping:** latest < 1h avg - threshold

Thresholds are per-metric (e.g., ±3 bpm for HR, ±5 ms for HRV).

### Per-Metric Visualization Strategy

| Metric | Right-side visualization | Rationale |
|--------|--------------------------|-----------|
| Heart Rate | Intraday sparkline with gradient fill | Dense samples throughout the day |
| HRV | Intraday sparkline with gap indicators | Clustered overnight, sparse daytime — show "no readings" gaps honestly |
| Blood Oxygen (SpO2) | Intraday sparkline, sleep cluster only | "Sleep only" label when no daytime readings |
| Respiratory Rate | Intraday sparkline, sleep cluster | Same as SpO2 — overnight only |
| VO₂ Max | Last 7 readings as bar chart | Too sparse for intraday sparkline (updates after walks/runs) |
| Walking HR Average | Last 7 readings as bar chart | One reading per walking bout, sparse |
| Walking Steadiness | Last 7 readings as bar chart | Sparse |
| Sleep | Stage breakdown bar (deep/REM/core/awake) | Stage composition is more useful than a time-series |
| Steps | Progress bar toward 8,000 goal | Cumulative metric, goal-oriented |
| Active Calories | Progress bar toward daily goal | Cumulative metric |
| Exercise Minutes | Progress bar toward 30-min goal | Cumulative metric |
| Blood Pressure | Latest value only (no sparkline) | Manual readings from cuff, too sparse |
| Blood Glucose | Intraday sparkline if CGM, single value if manual | Depends on data source density |
| Barometric Pressure | Intraday sparkline | Continuous from CMAltimeter |
| Environmental Sound | Intraday sparkline | Frequent background readings |
| Headphone Audio | Intraday sparkline | During headphone use periods |
| AFib Burden | Latest value with multi-day trend | Single daily value |

### Baseline-Relative Coloring

Unchanged from current implementation. Green/yellow/red based on personal 30-day rolling baseline deviation via `BaselineCalculator`. Applied to the latest individual reading rather than the daily average.

### Sparkline Specifications

- SVG-based, rendered in SwiftUI via a custom `SparklineView`
- X-axis: midnight to now (current day)
- Y-axis: auto-scaled to min/max of today's readings with padding
- Gradient fill from line color (25% opacity) to transparent
- Current value dot at the rightmost point
- Gap handling: if no readings for >2 hours, break the line and show gap
- Time labels: "12a · 6a · 12p · Now" (4 labels, evenly spaced)

## What Does Not Change

- `HealthSnapshot` daily aggregation model and cadence
- `SnapshotAggregator` noon-to-noon sleep window logic
- `BaselineCalculator` rolling 30-day baselines on daily snapshots
- `TrendsView` and all chart views (read from `HealthSnapshot`)
- `ReportGenerator` and `DataExporter`
- Background refresh via `BGAppRefreshTask`
- Watch ↔ Phone `WatchConnectivity` flow
- Sync server schema and `SyncService`

## Apple Watch Series 8 Sensor Reality

For reference — passive sampling rates that constrain what "real-time" means:

| Sensor | Passive Behavior |
|--------|-----------------|
| Optical HR | Every ~5–10 min; more often if irregular/elevated detected |
| SpO2 | Periodic during sleep; occasional daytime if wrist still |
| Wrist temperature | Sleep only — overnight deviation from baseline |
| Respiratory rate | Sleep only — derived from accelerometer |
| ECG | On-demand only — user must open ECG app |
| Accelerometer/Gyro | Continuous — drives step count, gait metrics, steadiness |
| Microphone | Background environmental sound exposure |

## Testing Strategy

- `HealthSample` CRUD and retention pruning: unit tests with in-memory `ModelContainer`
- Anchored query anchor persistence: unit test for encode/decode round-trip
- Trend direction calculation: unit tests with fixed sample sets
- Sparkline data preparation: unit tests (data → point array conversion)
- `SnapshotAggregator` new fields: extend existing aggregator tests
- Dashboard: manual testing on device with real Watch data
