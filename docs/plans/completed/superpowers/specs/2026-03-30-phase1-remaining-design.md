# Phase 1 Remaining Work — Design Spec

**Date:** 2026-03-30
**Status:** Approved
**Scope:** Complete remaining Phase 1 items from PROJECT_FUTURE_PLAN.md

---

## Overview

Six independent workstreams covering HealthKit additions, baseline improvements, #Preview blocks, CI hardening, CapRx pipeline completion, and PrescriptionImporter extraction. All are additive changes with no cross-workstream dependencies.

---

## 1. HealthKit Additions (`timeInDaylight`, `physicalEffort`)

Add two new HealthKit types that the user's Apple Watch Series 8 already collects.

### Changes

**`HealthKitManager.swift`** — Add to `allReadTypes`:
- `HKQuantityTypeIdentifier.timeInDaylight` (iOS 17+ / watchOS 10+) — minutes of outdoor daylight exposure. High anxiety-correlation value via circadian rhythm disruption.
- `HKQuantityTypeIdentifier.physicalEffort` (iOS 17+) — real-time effort level. Better than exercise minutes alone for distinguishing exercise HR from anxiety HR.

**`HealthSnapshot.swift`** — Add two optional fields:
- `timeInDaylightMin: Int?` — total daylight minutes for the day
- `physicalEffortAvg: Double?` — average physical effort score for the day

**`SnapshotAggregator.swift`** — Add aggregation:
- `timeInDaylight`: sum of daily samples (like steps)
- `physicalEffort`: daily average (like respiratory rate)

**`ModelFactory.swift`** — Add two new optional parameters with `nil` defaults to `healthSnapshot()`.

No UI changes — data collection only. Phase 2/3 surfaces these.

---

## 2. Baseline Wiring + Outlier Trimming

### Outlier Trimming

The existing `baseline()` helper computes mean/stddev from raw values, but a single extreme outlier (e.g., 2-hour sleep from a red-eye) skews both, contaminating the baseline.

Add a trimming step before computing the baseline: remove values beyond 2.5 standard deviations from the **median** (median is robust to the outliers we're trying to remove). Applied once, not iteratively. The trimmed set feeds into the existing mean/stddev computation. This is a standard median absolute deviation approach.

### Wiring Sleep + Respiratory Baselines

**`DashboardViewModel`** — Currently computes `hrvBaseline` and `rhrBaseline`. Add the same pattern for:
- `sleepBaseline` — from `BaselineCalculator.sleepBaseline(snapshots:)`
- `respiratoryBaseline` — from `BaselineCalculator.respiratoryRateBaseline(snapshots:)`

**`DashboardView`** — The `baselineAlert` section currently checks HRV and RHR deviations. Extend to also check:
- Sleep duration (last night's `sleepDurationMin` vs baseline)
- Respiratory rate (latest `respiratoryRate` vs baseline)

Same visual treatment as existing baseline alerts — alert card with deviation percentage and contextual color.

### Tests

Add test cases to `BaselineCalculatorTests` for outlier trimming: a set with one extreme value should produce a baseline that excludes it.

---

## 3. #Preview Blocks

Add `#Preview` to 5 views using existing `SampleData.makeSeededContainer()`.

### Target Views

1. **DashboardView** — seeded container with snapshots, entries, doses, prescriptions
2. **MedicationsHubView** — medication definitions, doses, prescriptions, pharmacies
3. **AddJournalEntryView** — medication definitions for dose-trigger picker
4. **TrendsView** — 30 days of snapshots and entries for charts
5. **PrescriptionDetailView** — prescription with linked medication and pharmacy

### Shared Code Access

Move `SampleData.swift`, `ModelFactory.swift`, and `TestHelpers.swift` to be compiled in both the app and test targets. Guard with `#if DEBUG` so they're stripped from release builds. This avoids duplicating the seeding logic. (`SampleData` depends on `TestHelpers.makeFullContainer()`.)

### Preview Pattern

Each preview wraps the view in `.modelContainer()` from `SampleData.makeSeededContainer()`. Views needing specific records (e.g., `PrescriptionDetailView`) fetch the first matching record from the seeded container.

---

## 4. CI Hardening

### SwiftLint Step

Add to `ios-ci.yml` before the test step:

```yaml
- name: Run SwiftLint
  continue-on-error: true  # Remove once existing violations are cleaned up
  run: |
    brew install swiftlint
    swiftlint lint --reporter github-actions-logging
```

`github-actions-logging` reporter produces inline annotations on PR diffs. The existing `.swiftlint.yml` already scopes to `AnxietyWatch` and `AnxietyWatchTests`.

`continue-on-error: true` on just the lint step (not the whole job) so existing violations don't block PRs. Remove once cleaned up.

### watchOS Build Step

Add after the iOS test step:

```yaml
- name: Build watchOS app
  run: |
    xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator' -quiet
```

Build-only — no tests (watchOS target has no test bundle). Catches compile errors in the watch target.

Both steps use the same path filters as the existing job (exclude `server/`, `docs/`, `*.md`).

---

## 5. CapRx Pipeline

### Database Schema

Add 5 columns to `prescriptions` table (nullable/defaulted so existing rows are unaffected):

| Column | Type | Default | Source |
|--------|------|---------|--------|
| `days_supply` | `INTEGER` | NULL | PBM days supply |
| `patient_pay` | `DOUBLE PRECISION` | NULL | Copay amount |
| `plan_pay` | `DOUBLE PRECISION` | NULL | Insurance portion |
| `dosage_form` | `TEXT` | `''` | tablet, capsule, etc. |
| `drug_type` | `TEXT` | `''` | brand, generic, etc. |

### `caprx_client.py`

`normalize_claim()` already extracts these fields — pass them through in the returned dict instead of discarding.

Additionally:
- Log the **full raw claim keys** (not values — may contain PII) at `INFO` level on first sync: `logger.info("CapRx claim fields: %s", sorted(claim.keys()))`. This documents the API response shape.
- Check for any status-like field (`status`, `claim_status`, `reversal_indicator`, etc.). If found, filter reversed/rejected claims. If not, log the gap and move on.
- Populate the existing `rx_status` column if a status field is discovered.

### API Response Documentation

Create `docs/caprx-api-fields.md` documenting known fields from the raw API response. Updated after examining the logged output.

### Server Import Logic

Persist the new fields during upsert. The API endpoint already does `SELECT *`, so new columns are automatically included in responses.

### iOS Model (`Prescription.swift`)

Add fields:
- `daysSupply: Int?`
- `patientPay: Double?`
- `planPay: Double?`
- `dosageForm: String = ""`
- `drugType: String = ""`

### SyncService

Map new server fields to new model properties during prescription fetch.

### PrescriptionSupplyCalculator

When `daysSupply` is non-nil, use it as primary input for run-out date estimation. Fall back to current quantity-based heuristic when `nil`.

---

## 6. PrescriptionImporter Extraction

### Current Problem

`SyncService.fetchPrescriptions()` mixes network concerns (HTTP, auth, URLs) with data mapping (JSON parsing, type conversion, defaults). Untestable without a network mock.

### Solution

Create `AnxietyWatch/Services/PrescriptionImporter.swift`:

- Pure function: takes decoded JSON dictionary, returns `Prescription` model
- No network, no `ModelContext`
- Handles: field name mapping, type conversions (string dates to Date), nullable fields, defaults
- Moves `estimatedRunOutDate` computation via `PrescriptionSupplyCalculator` here

`SyncService` becomes thinner: HTTP request, pass response to `PrescriptionImporter`, insert into `ModelContext`.

### Tests

`PrescriptionImporterTests.swift` with sample JSON payloads:
- Complete CapRx claim (all fields present including new ones)
- Minimal claim (missing optional fields like `daysSupply`, cost fields)
- Manual-source prescription (no CapRx-specific fields)
- Verify `daysSupply` takes priority over quantity-based run-out calculation

This extraction pairs naturally with the CapRx pipeline work — extract first, then add new fields to the clean importer.

---

## Execution Order

These are independent and can be parallelized, but if done sequentially:

1. **PrescriptionImporter extraction** (do before CapRx changes)
2. **CapRx pipeline** (adds fields to the clean importer)
3. **HealthKit additions** (independent)
4. **Baseline wiring + outlier trimming** (independent)
5. **#Preview blocks** (independent, benefits from all model changes being done)
6. **CI hardening** (independent, can go anytime)

---

## Out of Scope

- `HKCorrelation` for blood pressure (no BP cuff reporting to HealthKit)
- `generate-version.sh` Xcode build phase (minor convenience, CI handles it)
- UI surfacing of new HealthKit fields (Phase 2/3)
- CPAP-sleep-anxiety correlation (Phase 3 intelligence layer)
