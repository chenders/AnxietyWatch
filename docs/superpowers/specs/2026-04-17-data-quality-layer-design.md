# Health Data Quality Layer — Design Spec

## Goal

Prevent obviously wrong health data from polluting AI analysis conclusions. A server-side layer between data gathering and prompt construction that flags physiologically impossible values, trims the stated date range to match actual data, and always communicates the CPAP usage assumption.

## Problem

The AI analysis currently receives raw health data with no validation. This leads to conclusions like "April 4 sleep duration of 1,277 minutes (21.3 hours) is a major outlier suggesting catch-up sleep" — when in reality 21.3 hours of sleep is a tracking error, not a medical event.

Additionally:
- When the user selects a date range that extends beyond the actual data (e.g., Dec 29 to Apr 17 but first data is Jan 15), the prompt says "Analyze from Dec 29" and Claude may infer significance from the gap.
- Missing CPAP data is sometimes interpreted as "user didn't wear CPAP," when it always means the data hasn't been manually imported yet.

## Architecture

Three components, all in `server/analysis.py`, sitting between `gather_analysis_data()` and `build_prompt()`:

```
gather_analysis_data(date_from, date_to)
        │
        ▼
  flag_outliers(data)  →  list of warning strings
        │
        ▼
  compute_effective_dates(data, date_from, date_to)  →  (effective_from, effective_to)
        │
        ▼
  build_prompt(data, effective_from, effective_to, outlier_warnings, ...)
```

No new database columns. No schema changes. No iOS changes. No new UI elements.

## Component 1: Outlier Detection — `flag_outliers(data)`

A pure function. Input: the data dict from `gather_analysis_data()`. Output: a list of human-readable warning strings.

### Hard Physiological Limits

| Field | Min | Max | Unit |
|-------|-----|-----|------|
| `sleep_duration_min` | 0 | 960 | minutes (16h cap) |
| `sleep_deep_min` | 0 | `sleep_duration_min` | minutes |
| `sleep_rem_min` | 0 | `sleep_duration_min` | minutes |
| `sleep_core_min` | 0 | `sleep_duration_min` | minutes |
| `resting_hr` | 30 | 130 | bpm |
| `hrv_avg` | 1 | 300 | milliseconds |
| `spo2_avg` | 70 | 100 | percent |
| `respiratory_rate` | 6 | 40 | breaths/min |
| `bp_systolic` | 60 | 250 | mmHg |
| `bp_diastolic` | 30 | 150 | mmHg |
| `blood_glucose_avg` | 30 | 500 | mg/dL |
| `steps` | 0 | 100000 | count |
| `active_calories` | 0 | 5000 | kcal |
| `exercise_minutes` | 0 | 480 | minutes (8h cap) |
| `skin_temp_deviation` | -5.0 | 5.0 | Celsius |

### Internal Consistency Check

Flag days where `sleep_deep_min + sleep_rem_min + sleep_core_min + sleep_awake_min` exceeds `sleep_duration_min`. This catches HealthKit stitching errors where overlapping sleep sessions are double-counted.

### Fields NOT checked

- `barometric_pressure_avg_kpa`, `barometric_pressure_change_kpa` — varies by altitude
- `environmental_sound_avg` — too contextual
- `cpap_ahi`, `cpap_usage_minutes` — comes from a reliable medical device

### Output Format

Each warning is a string like:
```
"2026-04-04: sleep_duration_min of 1277 exceeds 16h (960 min) limit — likely tracking error"
"2026-03-15: sleep stages total (680 min) exceeds sleep_duration_min (420 min) — likely HealthKit stitching error"
```

### Null Handling

Fields with `None`/null values are skipped — absence of data is not an outlier. Only present numeric values are checked.

## Component 2: Date Range Trimming — `compute_effective_dates(data, date_from, date_to)`

Scans all dated records in the data dict (health_snapshots by `date`, anxiety_entries by `timestamp`, medication_doses by `timestamp`, cpap_sessions by `date`, barometric_readings by `timestamp`) and returns the earliest and latest dates that actually have data.

If no records exist at all, returns the original `(date_from, date_to)` unchanged (the analysis will fail for other reasons, and this function shouldn't mask that).

The effective dates are used in the prompt text only. The database query still uses the UI-selected range.

## Component 3: Prompt Integration

### Data Quality Notes

If `flag_outliers()` returned any warnings, inject a `## Data Quality Notes` section into the system prompt (same pattern as the dose tracking caveat). Content:

```
## Data Quality Notes

**The following values are flagged as physiologically implausible — likely tracking or sensor errors.
Do NOT use these values for pattern analysis, correlations, or conclusions. Note their existence
if relevant but treat the underlying data as unreliable for those dates/fields.**

- 2026-04-04: sleep_duration_min of 1277 exceeds 16h (960 min) limit — likely tracking error
- ...
```

If both dose tracking caveat warnings AND outlier warnings exist, they share the same `## Data Quality Notes` section — dose caveat text first, then outlier warnings.

### CPAP Assumption

Always inject (regardless of whether CPAP data exists in the range):

```
**CPAP usage:** The user wears a CPAP every night. If CPAP session data is absent for any dates
in this range, it means the data has not been imported yet — do NOT interpret missing CPAP data
as non-compliance or skipped therapy.
```

This goes inside the `## Data Quality Notes` section. If no other quality notes exist, the section is still created for just this note.

### Timezone (Admin-Configurable)

The user's timezone is stored in the existing `settings` table (`key = 'timezone'`). If not set, defaults to `US/Pacific`. Always include in the Data Quality Notes:

```
**Timezone:** All timestamps are in {timezone} time.
```

#### Admin Setting

The timezone setting lives on the existing admin Settings page (or a new `/admin/settings` page if one doesn't exist yet). A simple text input pre-populated with the current value, saved to `settings` table with `key = 'timezone'`. Uses IANA timezone names (e.g., `US/Pacific`, `US/Eastern`, `America/Chicago`).

#### Read at Analysis Time

`_create_pending_analysis` reads the timezone from the `settings` table and passes it to `build_prompt` as a `timezone: str` parameter (default `'US/Pacific'`).

### Therapy Schedule (Database-Driven)

Therapy sessions are stored in a `therapy_sessions` table and read at analysis time. If any active sessions exist, inject a natural-language summary into the Data Quality Notes:

```
**Therapy schedule:** The patient has the following recurring appointments:
- Mondays at 2:30 PM (virtual/Zoom)
- Thursdays at 1:00 PM (in-person, ~30 min commute)
- Fridays at 2:00 PM (in-person, ~30 min commute)
Notes: Patient is often 5-10 minutes late.
Factor this into temporal pattern analysis — anxiety may spike before sessions,
shift after sessions, or correlate with commute days.
```

If no therapy sessions are configured, this block is omitted entirely.

#### Database Table

```sql
CREATE TABLE IF NOT EXISTS therapy_sessions (
    id SERIAL PRIMARY KEY,
    frequency TEXT NOT NULL DEFAULT 'weekly'
        CHECK (frequency IN ('weekly', 'monthly')),
    day_of_week INTEGER CHECK (day_of_week BETWEEN 0 AND 6),
    day_of_month INTEGER CHECK (day_of_month BETWEEN 1 AND 31),
    time_of_day TIME NOT NULL,
    session_type TEXT NOT NULL DEFAULT 'in-person'
        CHECK (session_type IN ('in-person', 'virtual')),
    commute_minutes INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

- `frequency`: `'weekly'` or `'monthly'`
- `day_of_week`: 0=Monday through 6=Sunday (used when frequency is weekly)
- `day_of_month`: 1-31 (used when frequency is monthly)
- `session_type`: `'in-person'` or `'virtual'`
- `commute_minutes`: commute time in minutes (typically 0 for virtual)
- `notes`: free-text for anything else (e.g., "patient is often 5-10 minutes late")
- `is_active`: soft delete

#### Admin Page: `/admin/therapy-schedule`

- Lists all active sessions in a table
- Form to add a new session: frequency (select), day (select — weekday names for weekly, 1-31 for monthly), time (time input), type (select: in-person/virtual), commute minutes (number), notes (textarea)
- Delete button per row (sets `is_active = FALSE`)
- Linked from the admin nav

#### Prompt Builder Integration

`_create_pending_analysis` reads active therapy sessions from the DB and passes them to `build_prompt` as a list of dicts. `build_prompt` accepts a new `therapy_sessions: list[dict] | None = None` parameter. If sessions are present, it formats a natural-language summary and appends it to the Data Quality Notes section.

### Effective Date Range

The prompt opener changes from:
```
Analyze this health tracking data from {date_from} to {date_to}.
```
to:
```
Analyze this health tracking data from {effective_from} to {effective_to}.
```

## Integration Point

In `analysis.py`, the call chain changes:

**Before:**
```python
data = gather_analysis_data(cur, date_from, date_to)
system, user_msg = build_prompt(data, date_from, date_to, ...)
```

**After:**
```python
data = gather_analysis_data(cur, date_from, date_to)
outlier_warnings = flag_outliers(data)
effective_from, effective_to = compute_effective_dates(data, date_from, date_to)
therapy_sessions = read_active_therapy_sessions(cur)
timezone = read_setting(cur, 'timezone', default='US/Pacific')
system, user_msg = build_prompt(
    data, effective_from, effective_to,
    outlier_warnings=outlier_warnings,
    therapy_sessions=therapy_sessions,
    timezone=timezone,
    ...
)
```

`build_prompt` gains new parameters: `outlier_warnings: list[str] | None = None`, `therapy_sessions: list[dict] | None = None`, and `timezone: str = 'US/Pacific'`. The Data Quality Notes section is built from the combination of `dose_tracking_incomplete`, `outlier_warnings`, the always-present CPAP note, timezone, and therapy schedule (if configured).

## Testing

### `flag_outliers` tests
- Each limit type triggers correctly (sleep over 960, HR over 130, etc.)
- Internal consistency check fires when sleep stages exceed total
- Null/missing fields are skipped without error
- Clean data returns empty list
- Multiple outliers on different days all reported

### `compute_effective_dates` tests
- Trims to actual data range when UI range is wider
- Returns original range when no data exists
- Handles data in only some tables (e.g., anxiety entries but no health snapshots)
- Single-day data returns same date for both from and to

### Prompt integration tests
- Outlier warnings appear in Data Quality Notes section
- CPAP note always present even with no outliers
- Dose tracking caveat and outlier warnings coexist in same section
- Effective dates used in prompt text, not UI dates
- No Data Quality Notes header duplication when multiple note types present
- Timezone from settings appears in prompt (default and custom)
- Therapy sessions formatted correctly when present
- No therapy section when no active sessions exist

### Admin page tests
- Therapy schedule CRUD: add, list, delete
- Timezone setting: read default, update, read updated value

### Existing tests
- All 26 existing analysis tests continue to pass (no regressions)
