# High-Fidelity Health Sample Capture, Provenance, and Reliability — Design

## Context

Until now, AnxietyWatch has captured most HealthKit signal as **daily aggregates only**. `SnapshotAggregator` reads each day's samples once, computes mean/min/max/SD into `HealthSnapshot`, and discards the raw values. PR #120 added 7 derived clinical fields (SpO₂ overnight nadir/T90/desats; glucose SD/CV/min/max). PR #122 wired those through to the sync server. Both worked exclusively in aggregate space.

Two new devices recently entered the user's setup:
- **Dexcom Stelo:** continuous glucose, ≈ 288 samples/day at 5-minute resolution
- **EMAY SleepO2:** continuous overnight pulse oximeter, ≈ 480 samples/night at 1-minute resolution

These devices are clinically meaningful and dense. Collapsing them into 4–7 daily numbers throws away most of what they're worth. The same is true, to varying degrees, of every other HealthKit metric AnxietyWatch already reads — heart rate, HRV, respiratory rate, body temperature, blood pressure, weight, sleep stages — all of which arrive as time-stamped samples and get aggregated immediately.

This has three consequences:

1. **No intraday view of anything.** The user cannot see "what was my HR at 3 AM" or "what was my glucose at 4 PM" — even though HealthKit knows the answer.
2. **No provenance or reliability awareness.** When `spo2NadirOvernight = 88%`, the daily aggregate gives no indication whether that came from one Apple Watch reading at 3 AM (probably a sensor glitch) or 8 hours of EMAY ring data (a real desaturation event). Server-side Claude analysis has been making weighted clinical judgments without this context.
3. **No path to richer server analysis.** The synced data is daily summaries; even if Claude wanted to reason about glucose excursions in relation to HR spikes, sleep stages, or anxiety entries, the resolution isn't there.

This spec describes a comprehensive shift to **capture every sample at the highest resolution HealthKit offers**, persist it locally, sync it raw to the server for analysis and exploration, tag every sample with its writing source/device, classify daily aggregates by reliability tier, and surface the new data both visually (a Stelo-style Glucose Detail view) and via Claude-prompt augmentation.

## Goal

Capture every clinically-meaningful HealthKit sample at maximum available resolution; tag each with its writing source bundle ID and device; persist locally; sync raw to the server; classify aggregates by reliability tier driven by source identity and sample density; expose source + reliability + sample data to Claude analysis; replace the awkward Trends glucose chart with an HRV/RHR-style daily-avg line; add a new Stelo-style Glucose Detail view. App UI for other metrics is unchanged in this PR — capture and storage proceed regardless.

## Non-goals

- **Direct device APIs.** Dexcom Share, ResMed cloud, Bluetooth scraping. HealthKit is the bottleneck and the source of truth.
- **Per-sample UI for every metric.** The Glucose Detail view is the only intraday surface in this PR. Heart-rate detail / HRV detail / respiratory-rate detail views are deferred — the data being captured here makes them trivial later if needed.
- **Time-in-range / time-below-70 metrics.** Helper is small once samples exist; defer to follow-up.
- **Per-sample editing or manual annotations** in the iOS app.
- **Notifications/alerts on excursions or desaturation events.**
- **Per-event sample windowing in the default Claude prompt.** The default prompt gets aggregates + reliability + source; the server retains full sample resolution for ad-hoc/tool-driven drill-down.
- **Active-energy / step-level / audio-exposure raw mirroring.** These are continuous, very high-volume, and low signal for anxiety correlation. Daily aggregates remain in `HealthSnapshot` (already captured); raw samples stay in HealthKit and are queried on demand if ever needed.

## Decisions made during brainstorming

| Decision | Choice |
|---|---|
| PR scope | Single PR covering data layer + sync + Claude prompt + glucose UI |
| Capture breadth | All clinically-meaningful HKQuantityType + sleep stages, not just glucose/SpO₂ |
| Sample-model shape | Single generic `QuantityHealthSample` discriminated by `metricType` enum (HR, HRV, RR, SpO2, glucose, body temp, BP systolic, BP diastolic, weight, wrist temperature, …). New metric = list-entry edit. |
| Sleep stages | Separate `SleepStageEvent` model (HKCategorySample with start/end is structurally different from quantities) |
| Daily-aggregate path | `HealthSnapshot` continues to receive computed aggregates. Aggregates are now derived from the new locally-mirrored samples (so Trends/Dashboard render exactly the data Claude analyzes) rather than re-querying HealthKit |
| Trends glucose chart | Single daily-avg line, HRV/RHR style — no min/max range bars |
| Daily-max-glucose for psychiatrist PDF | Out of scope here; `HealthSnapshot.glucoseMax` is already populated, so the PDF change is a one-line follow-up |
| Glucose Detail source | Reads from `QuantityHealthSample` SwiftData (filtered to glucose) so what the user sees is exactly what the server analyzes |
| Detail view layout | Stelo-style: window picker (1/3/6/12/24h), 14-day picker, line chart with target band 70–140, sleep band overlay, tap-to-inspect via Charts ChartProxy, source/reliability footer |
| Sleep band overlay on Detail | Included — `HealthKitManager.sleepIntervals` already exists; overnight glucose context is the primary clinical use case |
| Other context overlays (journal/doses/BP) | Deferred |
| Reliability tiering | Per-aggregate enum: `high` / `medium` / `low` / `insufficient`; rules below |
| Claude default prompt | Augmented with reliability tier and source breakdown per metric per day; explicit guidance on how to qualify low-reliability conclusions |
| Claude high-resolution access | Server-side tool/query exposes raw samples in arbitrary windows for drill-down — keeps default prompt size bounded while giving Claude full fidelity when it actually matters |
| Absence ≠ zero | Prompt explicitly instructs Claude that missing data signals capture/sync gaps, not physiological zeros. SpO₂ silent ≠ apnea, HR silent ≠ asystole, glucose silent ≠ hypoglycemia |
| Storage cost | ≈ 80–100 MB/year on device for the full sample set; trivial vs. CPAP/journal data |

## Data resolution policy

Each row covers an HKQuantityType currently read by `HealthKitManager`. "Capture at sample level" means a `QuantityHealthSample` row per HealthKit sample.

| Metric | HK identifier | Sample level? | Daily aggregate? | Notes |
|---|---|---|---|---|
| Heart rate | `heartRate` | Yes | Yes (avg) | Apple Watch ~1/min ambient, ~1/sec workout |
| Heart rate variability | `heartRateVariabilitySDNN` | Yes | Yes (avg) | Sleep-only; ~1–5/night |
| Resting heart rate | `restingHeartRate` | Yes | Yes (val) | One per day from Apple Watch |
| Respiratory rate | `respiratoryRate` | Yes | Yes (avg) | Sleep + occasional daytime |
| Oxygen saturation | `oxygenSaturation` | Yes | Yes (nadir/T90/desats overnight) | EMAY SleepO2 + Apple Watch |
| Blood glucose | `bloodGlucose` | Yes | Yes (avg/SD/CV/min/max) | Stelo + manual fingerstick |
| Body temperature | `bodyTemperature` | Yes | No (event-rare) | Manual entries |
| Wrist temperature | `appleSleepingWristTemperature` | Yes | Yes (delta) | Apple Watch overnight |
| Blood pressure systolic | `bloodPressureSystolic` | Yes | Yes (latest) | BP cuff events |
| Blood pressure diastolic | `bloodPressureDiastolic` | Yes | Yes (latest) | Two `QuantityHealthSample` rows linked by `groupID` |
| Body mass | `bodyMass` | Yes | Yes (latest) | Scale/manual events |
| Steps | `stepCount` | **No** | Yes (sum) | Very high volume; aggregate only |
| Active energy | `activeEnergyBurned` | **No** | Yes (sum) | Very high volume; aggregate only |
| Basal energy | `basalEnergyBurned` | **No** | Yes (sum) | Very high volume; aggregate only |
| Distance walking/running | `distanceWalkingRunning` | **No** | Yes (sum) | Very high volume; aggregate only |
| Stand minutes | `appleStandTime` | **No** | Yes (sum) | Aggregate only |
| Exercise minutes | `appleExerciseTime` | **No** | Yes (sum) | Aggregate only |
| Audio exposure (env/headphone) | `environmentalAudioExposure` etc. | **No** | No | Out of scope; low signal for anxiety |
| Sleep stages | `sleepAnalysis` (category) | Yes (`SleepStageEvent`) | Yes (durations) | Per-stage start/end events |

**Rule of thumb:** capture at sample level when the metric is (a) physiologically meaningful at the moment, and (b) sampled at a rate where storage stays bounded (≤ ~3000 samples/day). Steps and energy fail (b) and provide nothing meaningful per-sample.

## Reliability tiers

Computed in `SnapshotAggregator` during the daily aggregation pass. Stored as `String?` on `HealthSnapshot` per metric family. Surfaced into the Claude prompt and the Glucose Detail view footer.

```swift
enum Reliability: String { case high, medium, low, insufficient }
```

`Utilities/DeviceProvenance.swift` holds bundle-ID lists per metric family — `continuousGlucoseMonitors` (Stelo, Dexcom G6/G7, Libre 2/3), `overnightPulseOximeters` (EMAY SleepO2, Wellue O2Ring, …), `medicalGradeBPCuffs`, `wearableSpotOximeters`, etc. New device = list-entry edit.

### Glucose (daily, 24h window)

| Tier | Rule |
|---|---|
| `high` | ≥ 80% of samples from a continuous-CGM bundle ID **and** ≥ 200 samples/day **and** ≥ 18h coverage |
| `medium` | CGM dominates but coverage 12–18h, OR mixed sources with ≥ 24 samples and ≥ 12h coverage |
| `low` | Only ambient/spot sources or < 24 samples |
| `insufficient` | < 1 sample (`bloodGlucoseAvg` would already be nil) |

### SpO₂ (overnight, noon-to-noon window)

| Tier | Rule |
|---|---|
| `high` | ≥ 80% of samples from an overnight pulse-ox bundle ID **and** ≥ 240 samples **and** ≥ 6h monitored |
| `medium` | Dedicated pulse-ox dominant, partial coverage (3–6h), OR mixed Apple Watch + dedicated with ≥ 60 samples |
| `low` | Apple Watch only, or < 60 samples |
| `insufficient` | < 5 samples |

### Heart rate / HRV / resting HR / respiratory rate

| Tier | Rule |
|---|---|
| `high` | Apple Watch source, ≥ 50 samples (HR) / ≥ 3 samples (HRV) / present (RHR) / ≥ 5 samples (RR) |
| `medium` | Apple Watch source with reduced coverage |
| `low` | Manual entry / unknown source |
| `insufficient` | 0 samples |

(Apple Watch is the de-facto medical-grade source for these; "low" is largely about the hand-entry case.)

### Body temperature / blood pressure / weight

| Tier | Rule |
|---|---|
| `high` | Source bundle on the medical-device list (Withings BP cuff, Omron, etc.) |
| `medium` | Apple Watch (wrist temp) or unknown medical device |
| `low` | Manual entry |
| `insufficient` | 0 samples |

## Architecture

### New files (iOS)

- **`AnxietyWatch/Models/QuantityHealthSample.swift`** — `@Model`. Fields: `id` (UUID = `HKSample.uuid` for idempotency), `timestamp`, `metricType` (raw String of `HKQuantityTypeIdentifier`), `value` (Double), `unitString`, `sourceBundleID`, `sourceName`, `deviceModel?`, `groupID?` (links the two rows of a BP reading), `syncedToServer`, `createdAt`. The `id` doubles as the server-side primary key, making sync end-to-end idempotent.
- **`AnxietyWatch/Models/SleepStageEvent.swift`** — `@Model`. Fields: `id`, `startTime`, `endTime`, `stage` (raw String of HKCategoryValueSleepAnalysis), `sourceBundleID`, `sourceName`, `deviceModel?`, `syncedToServer`, `createdAt`.
- **`AnxietyWatch/Utilities/DeviceProvenance.swift`** — bundle-ID classification lists, display-name lookup, `Reliability` enum + classifier helpers (one per metric family).
- **`AnxietyWatch/Utilities/SampleCaptureRegistry.swift`** — list of `(HKQuantityTypeIdentifier, HKUnit)` tuples that get sample-level capture, plus the sleep stage type. Single source of truth for what `HealthDataCoordinator` mirrors.
- **`AnxietyWatch/Views/Dashboard/GlucoseDetailView.swift`** — pushed from the dashboard glucose tile.
- **`AnxietyWatch/Views/Trends/GlucoseTrendChart.swift`** — replaces the existing same-named file with the HRV/RHR-style daily-avg line.
- **Tests:** `QuantityHealthSampleTests`, `SleepStageEventTests`, `DeviceProvenanceTests`, `SampleSyncTests`, `SnapshotAggregatorReliabilityTests`, `GlucoseDetailViewModelTests`, `GlucoseTrendChartTests`.

### Modified files (iOS)

- **`AnxietyWatch/Services/HealthKitDataSource.swift`** — protocol gains `quantitySamplesWithSource(...)` returning samples enriched with source/device, and `sleepStageEvents(...)` returning category samples.
- **`AnxietyWatch/Services/HealthKitManager.swift`** — implement both. Populate `sourceBundleID` (`HKSourceRevision.source.bundleIdentifier`), `sourceName` (`HKSourceRevision.source.name`), `deviceModel` (`HKDevice.model`).
- **`AnxietyWatch/Services/HealthDataCoordinator.swift`** — register one `HKAnchoredObjectQuery` per metric in `SampleCaptureRegistry`, plus one for sleep analysis, plus one per `groupID`-paired BP type. Anchors persisted in UserDefaults under `sampleAnchor.<identifier>`. New samples become `QuantityHealthSample` / `SleepStageEvent` rows, marked `syncedToServer = false`. The two BP rows produced from the same `HKCorrelation` share a generated `groupID`.
- **`AnxietyWatch/Services/SnapshotAggregator.swift`** — switch input source from "query HealthKit each day" to "query the local SwiftData mirror." Compute the existing aggregates **plus** reliability + source-summary per metric family. Emit JSON `[bundleID: count]` source summaries.
- **`AnxietyWatch/Models/HealthSnapshot.swift`** — adds reliability + source-summary string columns per metric family. To keep the column list manageable, store as JSON: `dataQuality: String?` containing `{glucose: {reliability, sources}, spo2: {...}, hr: {...}, hrv: {...}, ...}`. (Single column avoids ~20 schema additions.)
- **`AnxietyWatch/Services/SyncService.swift`** — payload extension:
  - `quantitySamples: [...]` (un-synced, batched at 1000/payload)
  - `sleepStageEvents: [...]` (un-synced)
  - `syncSchemaVersion` 2 → 3 to extend the version-aware upsert from PR #122
  - Mark uploaded samples `syncedToServer = true` on success
- **`AnxietyWatch/Services/DataExporter.swift`** — adds `dataQuality` JSON column to CSV/JSON. Raw-sample export stays out (CSV row count would balloon).
- **`AnxietyWatch/Views/Dashboard/LiveMetricCard.swift`** — glucose tile becomes tap-pushable to `GlucoseDetailView`.

### Server (`server/`)

> **Single-user note:** the sync server is single-user — there is no `users`
> table or `user_id` scoping. The DDL examples below reflect what actually
> ships in `server/schema.sql` and the migration; earlier drafts of this spec
> showed `user_id` columns and `users` FKs that were never built.

- **`server/alembic/versions/0004_quantity_health_samples_provenance.py`** — new migration:
  - Creates `quantity_health_samples`:
    ```sql
    id UUID PRIMARY KEY,
    timestamp TIMESTAMPTZ NOT NULL,
    metric_type TEXT NOT NULL,
    value DOUBLE PRECISION NOT NULL,
    unit_string TEXT NOT NULL,
    source_bundle_id TEXT NOT NULL,
    source_name TEXT,
    device_model TEXT,
    group_id UUID,
    created_at TIMESTAMPTZ DEFAULT now()
    ```
    Indexes: `(metric_type, timestamp DESC)`, `(group_id)`.
    The `id` PK matches the iOS UUID (= `HKSample.uuid`), so `INSERT ... ON CONFLICT (id) DO UPDATE` is the dedupe path.
  - Creates `sleep_stage_events`:
    ```sql
    id UUID PRIMARY KEY,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    stage TEXT NOT NULL,
    source_bundle_id TEXT NOT NULL,
    source_name TEXT,
    device_model TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
    ```
    Index: `(start_time DESC)`.
  - Adds one column to `health_snapshots`: `data_quality JSONB` (mirror of the iOS field).
  - All `IF NOT EXISTS`. Clean downgrade.
- **`server/schema.sql`** — same additions to canonical schema.
- **`server/server.py`** — `/api/sync`:
  - Accept `quantitySamples` / `sleepStageEvents` arrays. Upsert `ON CONFLICT (id) DO UPDATE SET value=EXCLUDED.value, source_name=EXCLUDED.source_name, device_model=EXCLUDED.device_model` (replays + HealthKit retroactive corrections both safe).
  - Extend the existing version-aware `health_snapshots` upsert with the new `data_quality` column. `syncSchemaVersion ≥ 3` → unconditional `EXCLUDED.<col>`; older clients (≤ 2) → `COALESCE`.
- **`server/claude_analysis.py`** (or wherever the prompt is built) — the per-day data block becomes:
  ```
  glucose:
    avg: 142, sd: 38, cv: 27, min: 89, max: 218
    reliability: high
    sources: { Stelo: 287 }
  spo2_overnight:
    nadir: 88, t90_min: 12, desats: 14
    reliability: high
    sources: { "EMAY SleepO2": 462, "Apple Watch": 3 }
  hr:
    avg: 68, max: 142
    reliability: high
    sources: { Apple Watch: 1438 }
  hrv:
    avg_sdnn: 31
    reliability: high
    sources: { Apple Watch: 4 }
  resp_rate:
    avg: 14.2
    reliability: high
    sources: { Apple Watch: 38 }
  bp:
    systolic: 128, diastolic: 82  (1 reading)
    reliability: medium
    sources: { Manual: 1 }
  body_temp_wrist_delta: -0.31
    reliability: medium
    sources: { Apple Watch: 1 }
  ```
  Plus a prompt instruction:
  > Each metric is tagged with a reliability tier based on the writing-source device and sample density.
  > - `high`: dedicated continuous medical-grade device dominant. Treat as physiologically meaningful.
  > - `medium`: dedicated device present but partial coverage, or mixed sources. Useful but qualify temporal claims.
  > - `low`: spot/ambient sources only. Mention the source explicitly when citing the value; avoid clinical conclusions.
  > - `insufficient`: do not cite the metric.
  >
  > **Absence of data is not the same as a zero or low value.** When a metric is missing for a period, or marked `insufficient`, the most likely explanation is a capture or sync gap — the device wasn't worn, the sensor was offline, the companion app hasn't yet pushed to HealthKit, or the iOS sync to this server is lagged. Examples:
  > - SpO₂ silent overnight does **not** indicate apnea or hypoxia. The patient may simply not have worn the EMAY ring that night.
  > - HR silent for hours does **not** indicate cardiac arrest. The Apple Watch was probably off-wrist or charging.
  > - Glucose silent for an afternoon does **not** indicate hypoglycemia. The Stelo sensor may have been compressed, lost signal, or its app hasn't yet written the buffer to HealthKit.
  > - Sleep silent for a date range does **not** mean the patient stopped sleeping. The Watch may not have been worn to bed.
  >
  > When a metric is missing, say so explicitly ("no SpO₂ data captured this night") rather than imputing a value. Distinguish "we have data showing X" from "we have no data for this period." Do not draw clinical conclusions from absence.
  >
  > Full per-sample data is available server-side. If a specific clinical observation would be sharper with intraday samples (e.g., HR around an anxiety entry timestamp), request a windowed query rather than guessing from daily aggregates.
- **`server/tests/test_server.py`** — new pytest cases:
  - `quantity_health_samples` upsert (single + batch)
  - `sleep_stage_events` upsert
  - Idempotent re-sync (replaying = 0 new rows; updates only if values changed)
  - `data_quality` JSONB round-trip with `syncSchemaVersion = 3` (clear-on-conflict) and `≤ 2` (preserve)
  - Prompt construction for representative day shapes

## View changes

### Trends — Glucose card

Before: vertical bars min→max with overlapping labels.
After:
- ChartCard "Glucose"
- Subtitle: `Daily avg · CV X% over 7 days`
- LineMark + PointMark on `bloodGlucoseAvg` per day, smooth interpolation matching HRV/RHR
- Horizontal dashed reference at the user's 7-day mean (`avg` line, mirroring the HRV chart)
- Anxiety-entry vertical markers
- CV% mini-bar row beneath, color from `ClinicalSeverity.glucoseCVSeverity`
- Days with `glucoseDailyReliability == "low"` get a small visual marker (asterisk in the data label) so the user knows the avg is built on sparse data

### Dashboard — Glucose tile

Tap pushes to `GlucoseDetailView`. Existing tile content (current value + SD/CV/min/max grid + freshness) unchanged.

### Glucose Detail view (new)

```
┌─────────────────────────────────────┐
│  Glucose                          ✕ │
│  111 mg/dL · stable · 3 m ago        │
│                                      │
│  [T28][W29][T30][F1][S2][S3][M4][T5]│  ← horizontal day pills (last 14d)
│  [1h][3h][6h][12h][24h]              │  ← window picker
│                                      │
│  ┌─────────────────────────────────┐│
│  │      ●●●                        ││
│  │     ●   ●●●                     ││  ← line chart
│  │    ●       ●●●                  ││     target band 70–140 (green)
│  │── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ 140 ││     sleep band (semi-transparent)
│  │                  ●●●            ││     anxiety entry markers
│  │── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  70 ││
│  │                       ●●●●●●    ││
│  └─────────────────────────────────┘│
│                                      │
│  287 samples from Stelo over 24 h    │  ← provenance footer
│  Reliability: high                   │
└─────────────────────────────────────┘
```

Tap-to-inspect: a Charts gesture overlay snaps a vertical rule + dot to the nearest sample and shows `Mon 4:32 AM · 142 mg/dL`. Drag to scrub.

## Test plan

iOS:
- `QuantityHealthSampleTests`, `SleepStageEventTests` — model invariants, hash-based idempotency.
- `DeviceProvenanceTests` — bundle-ID classification (Stelo, EMAY, Apple Watch, manual); reliability boundaries (just over/just under each threshold).
- `SnapshotAggregatorReliabilityTests` — assert the reliability tier and source summary match mocked input across all metric families.
- `HealthDataCoordinatorTests` — anchored-query bookkeeping (anchor advances; replay produces no duplicates; sleep stage events captured).
- `SyncServiceTests` — payload includes `quantitySamples` + `sleepStageEvents`, version flips to 3.
- `GlucoseTrendChartTests` — daily-avg line builds the expected `[ChartDatum]` from snapshots; low-reliability marker rendered when expected.
- `GlucoseDetailViewModelTests` — window/day filter math; sample-bucket count assertions; provenance-footer string formatting.

Server:
- Sample upsert round-trips (single, batch, replay, updates).
- Sleep stage event round-trips.
- `data_quality` JSONB round-trip under both schema versions.
- Prompt construction includes reliability + sources for representative day shapes.

End-to-end:
- Manual: sync a real day's data; confirm `quantity_health_samples` row count matches HealthKit (`SELECT metric_type, COUNT(*) ... GROUP BY`); inspect the next Claude analysis for the new reliability section.

## Internal commit boundaries

The PR is large but logically ordered:

1. `Reliability` enum + `DeviceProvenance` constants + `SampleCaptureRegistry` + tests
2. `QuantityHealthSample` + `SleepStageEvent` models + tests
3. `HealthKitManager` + protocol gain `quantitySamplesWithSource` and `sleepStageEvents`
4. `HealthDataCoordinator` anchored queries (one per registry entry) + tests
5. `HealthSnapshot.dataQuality` field + `SnapshotAggregator` switches to local-mirror input + reliability/source-summary computation + tests
6. Server migration 0004 + `schema.sql` + tests
7. `server.py` sync endpoint extensions + tests
8. `SyncService` payload extension + version bump + tests
9. Server Claude prompt augmentation (reliability + source breakdown + drill-down note) + tests
10. `GlucoseTrendChart` rewrite + tests
11. `GlucoseDetailView` + tests
12. Dashboard tile tap-to-push wiring

## Future work

- **Time-in-range / time-below-70 metrics** for glucose. ~20 lines once samples exist; surface in Trends and PDF.
- **Daily-max-glucose in psychiatrist PDF.** One-line `ReportGenerator.swift` addition.
- **Detail views for HR, HRV, respiratory rate, SpO₂.** The data is already there from this PR; only the views are missing.
- **Per-event sample drill-down in Claude prompts.** The server has the data; wire up tool/query calls so Claude can inspect "the 2 hours around journal entry X" without re-prompting.
- **Generalize to ECG and continuous BP** when those devices arrive. Pattern is `(metric type, capture rule, reliability rule)` in the registry.
- **Detail-view context overlays** — journal entries, dose markers, BP, HR. Brainstormed; deferred until lived experience identifies which overlays matter.
- **Glucose / SpO₂ alerts** on excursions or hypoglycemic / desaturation events.
