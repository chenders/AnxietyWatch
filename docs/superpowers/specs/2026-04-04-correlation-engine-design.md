# Physiological Correlation Engine

**Date:** 2026-04-04
**Status:** Approved

## Problem

The app collects extensive physiological data (3.5 years of HealthKit snapshots) and is now collecting mood data via random check-ins. But there's no way to understand which physiological signals correlate with anxiety, or to use those correlations for prediction.

## Solution

A server-side correlation engine that analyzes paired physiological + mood data, syncs results to the device for display as insight cards with expandable charts, and provides an on-device predictor that scores current anxiety likelihood from the learned correlations.

This is Phase 2 of the smart prompting roadmap:
- Phase 1: Data collection (random check-ins) — shipped
- **Phase 2: Correlation analysis + insights — this spec**
- Phase 3: Real-time detection + smart prompts — future

## Server-Side Correlation Engine

### Computation

A new correlation computation function in the Flask server. When invoked:

1. Joins `health_snapshots` with `anxiety_entries` by date — for each day that has both a snapshot and at least one entry, pairs the physiological values with the average severity for that day
2. Computes Pearson correlation coefficient + p-value for each signal using SciPy
3. For each signal, splits days into "normal" vs "abnormal" (using mean ± 1 stddev as the threshold) and computes mean severity in each bucket
4. Stores results in the `correlations` table

### Signals (7 total)

| Signal | Column | Expected direction | Rationale |
|--------|--------|--------------------|-----------|
| HRV average | `hrv_avg` | Inverse (low HRV → high anxiety) | Vagal tone marker |
| Resting HR | `resting_hr` | Positive (high HR → high anxiety) | Sympathetic activation |
| Sleep duration | `sleep_duration_min` | Inverse (less sleep → more anxiety) | Sleep deprivation |
| Sleep quality | `(sleep_deep_min + sleep_rem_min) / sleep_duration_min` | Inverse (less restorative → more anxiety) | Sleep architecture |
| Steps | `steps` | Inverse (less activity → more anxiety) | Exercise effect |
| CPAP AHI | `cpap_ahi` | Positive (worse apnea → more anxiety) | Sleep disruption |
| Barometric change | `barometric_pressure_change_kpa` | Positive (large swings → more anxiety) | Pressure sensitivity |

### Minimum data requirement

At least 14 paired days (days with both a health snapshot and an anxiety entry) before computing correlations. Below that, return empty results.

### Database schema

```sql
CREATE TABLE IF NOT EXISTS correlations (
    id SERIAL PRIMARY KEY,
    signal_name TEXT NOT NULL,
    correlation DOUBLE PRECISION NOT NULL,
    p_value DOUBLE PRECISION NOT NULL,
    sample_count INTEGER NOT NULL,
    mean_severity_when_abnormal DOUBLE PRECISION,
    mean_severity_when_normal DOUBLE PRECISION,
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(signal_name)
);
```

Migration: `CREATE TABLE IF NOT EXISTS` + added to schema.sql.

### API

**`GET /api/correlations`** — returns the latest correlation results. If no correlations exist or they're stale (older than the most recent anxiety entry), recomputes first.

Response:
```json
{
  "correlations": [
    {
      "signal_name": "hrv_avg",
      "correlation": -0.58,
      "p_value": 0.003,
      "sample_count": 47,
      "mean_severity_when_abnormal": 6.2,
      "mean_severity_when_normal": 3.8,
      "computed_at": "2026-04-04T12:00:00Z"
    }
  ],
  "paired_days": 47,
  "minimum_required": 14
}
```

### Sync integration

The existing `/api/sync` response gains a `correlations` key containing the latest results. Computed lazily — if stale, recompute before responding. This means correlations update automatically on each app sync without a separate call.

## iOS Data Model

New SwiftData model for storing synced correlations:

```swift
@Model
final class PhysiologicalCorrelation {
    var signalName: String
    var correlation: Double
    var pValue: Double
    var sampleCount: Int
    var meanSeverityWhenAbnormal: Double?
    var meanSeverityWhenNormal: Double?
    var computedAt: Date
}
```

Read-only on device — server is the source of truth. Each sync overwrites previous values. Added to the shared schema in `AnxietyWatchApp.sharedModelContainer`.

`SyncService` updated to read `correlations` from sync response and upsert into SwiftData.

## Insights UI

### CorrelationInsightsView

Accessible from the Trends tab. Shows one card per signal, sorted by absolute correlation strength (strongest first).

**Each card shows:**
- Signal name (e.g., "Heart Rate Variability")
- Direction + strength label: "Strong inverse" / "Moderate positive" / "Weak" based on |r|: >0.5 strong, 0.3-0.5 moderate, <0.3 weak
- Plain-English insight: "Your anxiety averages 6.2 on days with low HRV vs 3.8 on normal days"
- Confidence: p < 0.05 shown solid; p >= 0.05 faded with "Insufficient data" note
- Sample count: "Based on 47 paired days"

**Tap to expand:** Scatter plot — physiological value on X axis, severity on Y axis, with a trend line. Uses Swift Charts.

**Empty state:** When fewer than 14 paired days exist: "Keep logging check-ins — insights will appear after ~2 weeks of data" with progress indicator (X/14 paired days).

### Placement

A new "Insights" section at the bottom of TrendsView, or a NavigationLink card that opens CorrelationInsightsView. Not a separate tab — it's part of the Trends flow.

## On-Device Predictor

A `AnxietyPredictor` enum in Utilities/ that produces a real-time risk score from current data + server-computed correlations.

### How it works

1. Reads `PhysiologicalCorrelation` records from SwiftData
2. Filters to significant correlations only (p < 0.05)
3. For each significant signal, compares today's value (from the latest HealthSnapshot or real-time HealthSample) to the 30-day baseline
4. Computes a z-score (how many stddevs from baseline) for each signal
5. Multiplies z-score by correlation coefficient to get a directional contribution
6. Normalizes the weighted sum to 0.0-1.0 range

### Output

```swift
struct PredictionResult {
    let score: Double // 0.0 = calm, 1.0 = high anxiety likelihood
    let contributingSignals: [(name: String, direction: String, weight: Double)]
}
```

### Not wired to UI yet

Phase 3 will use this score to trigger smart prompts and optionally display a "current risk" indicator on the dashboard. For now it's a testable computation engine with unit tests.

### Minimum requirement

At least one significant correlation (p < 0.05) must exist. Otherwise returns nil.

## Docker Port Change

In `server/docker-compose.yml`, expose Postgres to the network:

```yaml
# Before
- "127.0.0.1:5439:5432"

# After
- "5439:5432"
```

## Files

### New
- `server/correlations.py` — correlation computation logic (SciPy)
- `AnxietyWatch/Models/PhysiologicalCorrelation.swift` — SwiftData model
- `AnxietyWatch/Views/Trends/CorrelationInsightsView.swift` — insight cards + charts
- `AnxietyWatch/Views/Trends/CorrelationCardView.swift` — individual card component
- `AnxietyWatch/Views/Trends/CorrelationChartView.swift` — scatter plot detail
- `AnxietyWatch/Utilities/AnxietyPredictor.swift` — on-device risk scorer
- `AnxietyWatchTests/AnxietyPredictorTests.swift` — unit tests for predictor
- `server/tests/test_correlations.py` — server correlation tests

### Modified
- `server/schema.sql` — add correlations table
- `server/server.py` — add /api/correlations endpoint, add correlations to sync response, add migration
- `server/docker-compose.yml` — expose Postgres port
- `server/requirements.txt` — add scipy
- `AnxietyWatch/App/AnxietyWatchApp.swift` — add PhysiologicalCorrelation to schema
- `AnxietyWatch/Services/SyncService.swift` — read correlations from sync response
- `AnxietyWatch/Views/Trends/TrendsView.swift` — add Insights navigation link
- `AnxietyWatchTests/Helpers/TestHelpers.swift` — add PhysiologicalCorrelation to test schema

## Out of Scope

- Phase 3 smart prompt triggering (uses predictor score to schedule notifications)
- Web dashboard for correlations
- Multi-variable regression (single-variable Pearson is sufficient for V1)
- Time-lagged correlations (e.g., "poor sleep predicts next-day anxiety") — future enhancement
- Causal inference — correlations are associational only
