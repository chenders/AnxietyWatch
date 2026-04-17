# Health Data Quality Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a server-side data quality layer that flags physiologically implausible health values, trims the analysis date range to match actual data, and always communicates the CPAP usage and timezone assumptions to Claude.

**Architecture:** Three pure functions (`flag_outliers`, `compute_effective_dates`, and an expanded `build_prompt`) in `server/analysis.py`. The functions sit between `gather_analysis_data()` and `build_prompt()` in the analysis pipeline. This work also introduces a `therapy_sessions` table, admin routes/templates for therapy schedule management and timezone settings, and reads from the existing `settings` table. No iOS changes.

**Tech Stack:** Python 3.12, Flask, PostgreSQL, pytest

---

### Task 1: `flag_outliers()` function

**Files:**
- Modify: `server/analysis.py` (add function and limits constant after `gather_analysis_data`, around line 82)
- Test: `server/tests/test_analysis.py` (add tests after existing `test_build_prompt_dose_caveat_removes_medication_goal`)

- [ ] **Step 1: Write the failing tests**

Add these tests to `server/tests/test_analysis.py` after the existing `test_build_prompt_dose_caveat_removes_medication_goal` test (after line 213):

```python
# ---------------------------------------------------------------------------
# Tests for flag_outliers
# ---------------------------------------------------------------------------


def test_flag_outliers_clean_data():
    """flag_outliers returns empty list for data within physiological limits."""
    from analysis import flag_outliers
    data = {
        "health_snapshots": [
            {"date": "2026-01-10", "sleep_duration_min": 480, "resting_hr": 65,
             "hrv_avg": 45, "spo2_avg": 97, "steps": 8000},
        ],
    }
    assert flag_outliers(data) == []


def test_flag_outliers_sleep_over_limit():
    """flag_outliers flags sleep duration exceeding 16 hours."""
    from analysis import flag_outliers
    data = {
        "health_snapshots": [
            {"date": "2026-04-04", "sleep_duration_min": 1277},
        ],
    }
    warnings = flag_outliers(data)
    assert len(warnings) == 1
    assert "sleep_duration_min" in warnings[0]
    assert "1277" in warnings[0]
    assert "2026-04-04" in warnings[0]


def test_flag_outliers_hr_out_of_range():
    """flag_outliers flags resting HR outside 30-130 bpm."""
    from analysis import flag_outliers
    data = {
        "health_snapshots": [
            {"date": "2026-01-10", "resting_hr": 185},
            {"date": "2026-01-11", "resting_hr": 15},
        ],
    }
    warnings = flag_outliers(data)
    assert len(warnings) == 2
    assert any("185" in w for w in warnings)
    assert any("15" in w for w in warnings)


def test_flag_outliers_sleep_stage_inconsistency():
    """flag_outliers flags when sleep stages total exceeds sleep duration."""
    from analysis import flag_outliers
    data = {
        "health_snapshots": [
            {"date": "2026-01-10", "sleep_duration_min": 420,
             "sleep_deep_min": 200, "sleep_rem_min": 150,
             "sleep_core_min": 200, "sleep_awake_min": 30},
        ],
    }
    warnings = flag_outliers(data)
    assert len(warnings) == 1
    assert "sleep stages total" in warnings[0].lower() or "exceeds" in warnings[0].lower()


def test_flag_outliers_skips_null_fields():
    """flag_outliers ignores None/missing fields without error."""
    from analysis import flag_outliers
    data = {
        "health_snapshots": [
            {"date": "2026-01-10", "sleep_duration_min": None, "resting_hr": None,
             "hrv_avg": None, "steps": None},
        ],
    }
    assert flag_outliers(data) == []


def test_flag_outliers_multiple_days_multiple_fields():
    """flag_outliers reports all outliers across days and fields."""
    from analysis import flag_outliers
    data = {
        "health_snapshots": [
            {"date": "2026-01-10", "sleep_duration_min": 1400, "bp_systolic": 300},
            {"date": "2026-01-11", "blood_glucose_avg": 600},
        ],
    }
    warnings = flag_outliers(data)
    assert len(warnings) == 3


def test_flag_outliers_no_health_snapshots():
    """flag_outliers handles data dict with no health_snapshots key."""
    from analysis import flag_outliers
    data = {"anxiety_entries": [], "medication_doses": []}
    assert flag_outliers(data) == []


def test_flag_outliers_all_limit_types():
    """flag_outliers checks all configured physiological limits."""
    from analysis import flag_outliers
    # One violation per limit type
    data = {
        "health_snapshots": [
            {"date": "2026-01-10", "hrv_avg": 0},
            {"date": "2026-01-11", "spo2_avg": 50},
            {"date": "2026-01-12", "respiratory_rate": 2},
            {"date": "2026-01-13", "bp_diastolic": 200},
            {"date": "2026-01-14", "blood_glucose_avg": 5},
            {"date": "2026-01-15", "steps": 200000},
            {"date": "2026-01-16", "active_calories": 10000},
            {"date": "2026-01-17", "exercise_minutes": 600},
            {"date": "2026-01-18", "skin_temp_deviation": -10.0},
        ],
    }
    warnings = flag_outliers(data)
    assert len(warnings) == 9
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python -m pytest tests/test_analysis.py::test_flag_outliers_clean_data -v`
Expected: FAIL with `ImportError` (function doesn't exist yet)

- [ ] **Step 3: Write the implementation**

Add the following to `server/analysis.py`, between the `gather_analysis_data` function (ends at line 81) and `build_prompt` (starts at line 84). Insert after line 82:

```python
# Hard physiological limits for outlier detection.
# Values outside these ranges are flagged as likely tracking/sensor errors.
PHYSIOLOGICAL_LIMITS = {
    "sleep_duration_min": (0, 960),
    "resting_hr": (30, 130),
    "hrv_avg": (1, 300),
    "spo2_avg": (70, 100),
    "respiratory_rate": (6, 40),
    "bp_systolic": (60, 250),
    "bp_diastolic": (30, 150),
    "blood_glucose_avg": (30, 500),
    "steps": (0, 100_000),
    "active_calories": (0, 5000),
    "exercise_minutes": (0, 480),
    "skin_temp_deviation": (-5.0, 5.0),
}

# Sleep stage fields — their sum should not exceed sleep_duration_min.
SLEEP_STAGE_FIELDS = ["sleep_deep_min", "sleep_rem_min", "sleep_core_min", "sleep_awake_min"]


def flag_outliers(data: dict) -> list[str]:
    """Check health snapshots for physiologically implausible values.

    Returns a list of human-readable warning strings, one per flagged value.
    """
    warnings = []
    for snapshot in data.get("health_snapshots", []):
        day = snapshot.get("date", "unknown")

        for field, (lo, hi) in PHYSIOLOGICAL_LIMITS.items():
            value = snapshot.get(field)
            if value is None:
                continue
            if value < lo:
                warnings.append(
                    f"{day}: {field} of {value} is below minimum {lo} — likely tracking/sensor error"
                )
            elif value > hi:
                warnings.append(
                    f"{day}: {field} of {value} exceeds maximum {hi} — likely tracking/sensor error"
                )

        # Sleep stage internal consistency
        duration = snapshot.get("sleep_duration_min")
        if duration is not None:
            stage_values = [snapshot.get(f) for f in SLEEP_STAGE_FIELDS]
            present = [v for v in stage_values if v is not None]
            if present:
                stage_total = sum(present)
                if stage_total > duration:
                    warnings.append(
                        f"{day}: sleep stages total ({stage_total} min) exceeds "
                        f"sleep_duration_min ({duration} min) — likely HealthKit stitching error"
                    )

    return warnings
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && python -m pytest tests/test_analysis.py -k "flag_outliers" -v`
Expected: All 9 `flag_outliers` tests PASS

- [ ] **Step 5: Lint**

Run: `flake8 server/ --max-line-length=120 --exclude=__pycache__`
Expected: Clean

- [ ] **Step 6: Commit**

```bash
git add server/analysis.py server/tests/test_analysis.py
git commit -m "feat: add flag_outliers() with hard physiological limits"
```

---

### Task 2: `compute_effective_dates()` function

**Files:**
- Modify: `server/analysis.py` (add function after `flag_outliers`)
- Test: `server/tests/test_analysis.py` (add tests after `flag_outliers` tests)

- [ ] **Step 1: Write the failing tests**

Add these tests to `server/tests/test_analysis.py` after the `flag_outliers` tests:

```python
# ---------------------------------------------------------------------------
# Tests for compute_effective_dates
# ---------------------------------------------------------------------------


def test_compute_effective_dates_trims_to_data():
    """compute_effective_dates narrows range to actual data span."""
    from analysis import compute_effective_dates
    data = {
        "anxiety_entries": [
            {"timestamp": "2026-01-15T12:00:00"},
            {"timestamp": "2026-03-20T08:00:00"},
        ],
        "health_snapshots": [
            {"date": "2026-01-20"},
            {"date": "2026-03-15"},
        ],
        "medication_doses": [],
        "cpap_sessions": [],
        "barometric_readings": [],
    }
    eff_from, eff_to = compute_effective_dates(
        data, date(2025, 12, 1), date(2026, 4, 30)
    )
    assert eff_from == date(2026, 1, 15)
    assert eff_to == date(2026, 3, 20)


def test_compute_effective_dates_no_data_returns_original():
    """compute_effective_dates returns original range when no data exists."""
    from analysis import compute_effective_dates
    data = {
        "anxiety_entries": [],
        "health_snapshots": [],
        "medication_doses": [],
        "cpap_sessions": [],
        "barometric_readings": [],
    }
    eff_from, eff_to = compute_effective_dates(
        data, date(2026, 1, 1), date(2026, 1, 31)
    )
    assert eff_from == date(2026, 1, 1)
    assert eff_to == date(2026, 1, 31)


def test_compute_effective_dates_single_day():
    """compute_effective_dates returns same date for single-day data."""
    from analysis import compute_effective_dates
    data = {
        "anxiety_entries": [],
        "health_snapshots": [{"date": "2026-02-14"}],
        "medication_doses": [],
        "cpap_sessions": [],
        "barometric_readings": [],
    }
    eff_from, eff_to = compute_effective_dates(
        data, date(2026, 1, 1), date(2026, 3, 31)
    )
    assert eff_from == date(2026, 2, 14)
    assert eff_to == date(2026, 2, 14)


def test_compute_effective_dates_mixed_sources():
    """compute_effective_dates considers all data source types."""
    from analysis import compute_effective_dates
    data = {
        "anxiety_entries": [],
        "health_snapshots": [],
        "medication_doses": [{"timestamp": "2026-02-01T10:00:00"}],
        "cpap_sessions": [{"date": "2026-03-01"}],
        "barometric_readings": [{"timestamp": "2026-02-15T14:30:00"}],
    }
    eff_from, eff_to = compute_effective_dates(
        data, date(2026, 1, 1), date(2026, 4, 1)
    )
    assert eff_from == date(2026, 2, 1)
    assert eff_to == date(2026, 3, 1)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python -m pytest tests/test_analysis.py::test_compute_effective_dates_trims_to_data -v`
Expected: FAIL with `ImportError`

- [ ] **Step 3: Write the implementation**

Add to `server/analysis.py` after the `flag_outliers` function:

```python
def compute_effective_dates(data: dict, date_from: date, date_to: date) -> tuple[date, date]:
    """Determine the actual date range covered by the data.

    Scans all dated records and returns (earliest_date, latest_date).
    Falls back to the original (date_from, date_to) if no data exists.
    """
    all_dates = []

    # Tables with a 'date' field (YYYY-MM-DD string)
    for source in ("health_snapshots", "cpap_sessions"):
        for row in data.get(source, []):
            d = row.get("date")
            if d:
                all_dates.append(date.fromisoformat(str(d)))

    # Tables with a 'timestamp' field (ISO datetime string)
    for source in ("anxiety_entries", "medication_doses", "barometric_readings"):
        for row in data.get(source, []):
            ts = row.get("timestamp")
            if ts:
                all_dates.append(datetime.fromisoformat(str(ts)).date())

    if not all_dates:
        return date_from, date_to

    return min(all_dates), max(all_dates)
```

Note: `datetime` is already imported at the top of `analysis.py` (line 7).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && python -m pytest tests/test_analysis.py -k "compute_effective_dates" -v`
Expected: All 4 tests PASS

- [ ] **Step 5: Lint**

Run: `flake8 server/ --max-line-length=120 --exclude=__pycache__`
Expected: Clean

- [ ] **Step 6: Commit**

```bash
git add server/analysis.py server/tests/test_analysis.py
git commit -m "feat: add compute_effective_dates() for date range trimming"
```

---

### Task 3: Expand `build_prompt()` with outlier warnings, CPAP note, timezone

**Files:**
- Modify: `server/analysis.py:84-215` (`build_prompt` function)
- Test: `server/tests/test_analysis.py` (add and modify prompt tests)

- [ ] **Step 1: Write the failing tests**

Add these tests to `server/tests/test_analysis.py` after the `compute_effective_dates` tests:

```python
# ---------------------------------------------------------------------------
# Tests for build_prompt data quality integration
# ---------------------------------------------------------------------------

EMPTY_DATA = {
    "anxiety_entries": [], "health_snapshots": [], "medication_doses": [],
    "cpap_sessions": [], "barometric_readings": [], "correlations": [],
}


def test_build_prompt_always_includes_cpap_note():
    """build_prompt always includes the CPAP assumption note."""
    from analysis import build_prompt
    system, _ = build_prompt(EMPTY_DATA, date(2026, 1, 1), date(2026, 1, 7))
    assert "wears a CPAP every night" in system
    assert "not yet imported" in system.lower() or "not been imported" in system.lower()


def test_build_prompt_always_includes_timezone():
    """build_prompt always includes timezone note."""
    from analysis import build_prompt
    system, _ = build_prompt(EMPTY_DATA, date(2026, 1, 1), date(2026, 1, 7))
    assert "US/Pacific" in system


def test_build_prompt_always_includes_therapy_schedule():
    """build_prompt always includes the therapy schedule note."""
    from analysis import build_prompt
    system, _ = build_prompt(EMPTY_DATA, date(2026, 1, 1), date(2026, 1, 7))
    assert "Mondays at 2:30" in system
    assert "Thursdays at 1:00" in system
    assert "Fridays at 2:00" in system
    assert "Zoom" in system


def test_build_prompt_with_outlier_warnings():
    """build_prompt includes outlier warnings in Data Quality Notes."""
    from analysis import build_prompt
    warnings = [
        "2026-04-04: sleep_duration_min of 1277 exceeds maximum 960 — likely tracking/sensor error",
    ]
    system, _ = build_prompt(
        EMPTY_DATA, date(2026, 1, 1), date(2026, 1, 7),
        outlier_warnings=warnings,
    )
    assert "Data Quality Notes" in system
    assert "sleep_duration_min of 1277" in system
    assert "Do NOT use these values" in system


def test_build_prompt_outliers_and_dose_caveat_coexist():
    """build_prompt combines dose tracking caveat and outlier warnings in one section."""
    from analysis import build_prompt
    warnings = ["2026-01-10: resting_hr of 185 exceeds maximum 130 — likely tracking/sensor error"]
    system, _ = build_prompt(
        EMPTY_DATA, date(2026, 1, 1), date(2026, 1, 7),
        dose_tracking_incomplete=True,
        outlier_warnings=warnings,
    )
    assert system.count("## Data Quality Notes") == 1
    assert "dose log is incomplete" in system
    assert "resting_hr of 185" in system
    assert "wears a CPAP every night" in system


def test_build_prompt_uses_effective_dates_in_user_message():
    """build_prompt uses the provided dates in the user message opener."""
    from analysis import build_prompt
    system, user_msg = build_prompt(
        EMPTY_DATA, date(2026, 2, 1), date(2026, 3, 15),
    )
    assert "2026-02-01" in user_msg
    assert "2026-03-15" in user_msg
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python -m pytest tests/test_analysis.py::test_build_prompt_always_includes_cpap_note -v`
Expected: FAIL (CPAP note not in prompt yet)

- [ ] **Step 3: Modify `build_prompt()` implementation**

In `server/analysis.py`, modify the `build_prompt` function signature and the Data Quality Notes section. The full updated function:

**Signature change** (line 84-89): Add `outlier_warnings` parameter:

```python
def build_prompt(
    data: dict,
    date_from: date,
    date_to: date,
    dose_tracking_incomplete: bool = False,
    outlier_warnings: list[str] | None = None,
) -> tuple[str, str]:
```

**Replace the existing Data Quality Notes block** (lines 117-126, the `if dose_tracking_incomplete:` block) with this unified section that is always appended:

```python
    # -- Data Quality Notes (always present) --
    dq_parts = []

    if dose_tracking_incomplete:
        dq_parts.append(
            "**Medication dose tracking is incomplete.** The user's dose log has unreliable"
            " timestamps and may be missing entries. The dose log is incomplete — do NOT analyze"
            " dose-response timing or any correlation that depends on when a dose was taken"
            " relative to other events. You may note which medications appear in the data and their"
            " approximate daily frequency, but treat all intraday dose timing as unreliable and do"
            " not draw conclusions from it."
        )

    if outlier_warnings:
        dq_parts.append(
            "**The following values are flagged as physiologically implausible — likely tracking"
            " or sensor errors. Do NOT use these values for pattern analysis, correlations, or"
            " conclusions. Note their existence if relevant but treat the underlying data as"
            " unreliable for those dates/fields.**\n\n"
            + "\n".join(f"- {w}" for w in outlier_warnings)
        )

    dq_parts.append(
        "**CPAP usage:** The user wears a CPAP every night. If CPAP session data is absent"
        " for any dates in this range, it means the data has not been imported yet — do NOT"
        " interpret missing CPAP data as non-compliance or skipped therapy."
    )

    dq_parts.append("**Timezone:** All timestamps are in US/Pacific time.")

    dq_parts.append(
        "**Therapy schedule:** The patient sees their provider on Mondays at 2:30 PM"
        " (Zoom), Thursdays at 1:00 PM (in-person), and Fridays at 2:00 PM (in-person)."
        " The commute to the provider takes about 30 minutes, and the patient is often"
        " 5-10 minutes late. Factor this into temporal pattern analysis — anxiety may"
        " spike before sessions, shift after sessions, or correlate with commute days."
    )

    parts.append("\n## Data Quality Notes\n\n" + "\n\n".join(dq_parts))
```

- [ ] **Step 4: Update existing test expectation**

The test `test_build_prompt_default_includes_medication_goal` (line 180-191) currently asserts `"Data Quality Notes" not in system`. Since Data Quality Notes is now always present (CPAP + timezone), update this assertion:

Change line 191 from:
```python
    assert "Data Quality Notes" not in system
```
to:
```python
    assert "dose log is incomplete" not in system
```

This still validates the core intent: without the dose caveat, the dose-specific text isn't present.

- [ ] **Step 5: Run all analysis tests**

Run: `cd server && python -m pytest tests/test_analysis.py -v`
Expected: All tests PASS (existing + new)

- [ ] **Step 6: Lint**

Run: `flake8 server/ --max-line-length=120 --exclude=__pycache__`
Expected: Clean

- [ ] **Step 7: Commit**

```bash
git add server/analysis.py server/tests/test_analysis.py
git commit -m "feat: always-present Data Quality Notes with CPAP, timezone, and outlier warnings"
```

---

### Task 4: Wire into `_create_pending_analysis()`

**Files:**
- Modify: `server/analysis.py:327-346` (`_create_pending_analysis` function)
- Test: `server/tests/test_analysis.py` (add integration test)

- [ ] **Step 1: Write the failing test**

Add to `server/tests/test_analysis.py` after the build_prompt data quality tests:

```python
def test_run_analysis_flags_outliers_in_prompt(app):
    """run_analysis includes outlier warnings in the stored request payload."""
    with app.app_context():
        from analysis import run_analysis, get_analysis
        db = app.get_db()
        cur = db.cursor()
        # Insert a health snapshot with an implausible sleep value
        cur.execute(
            "INSERT INTO health_snapshots (date, sleep_duration_min, resting_hr) "
            "VALUES ('2026-01-10', 1277, 65)"
        )
        db.commit()

        mock_client = MagicMock()
        mock_client.messages.create.return_value = _mock_anthropic_response()

        with patch("analysis.anthropic.Anthropic", return_value=mock_client):
            analysis_id = run_analysis(db, date(2026, 1, 10), date(2026, 1, 10))

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        result = get_analysis(cur, analysis_id)

    payload = result["request_payload"]
    system_prompt = payload["system"]
    assert "sleep_duration_min" in system_prompt
    assert "1277" in system_prompt
    assert "wears a CPAP every night" in system_prompt


def test_run_analysis_trims_date_range_in_prompt(app):
    """run_analysis uses effective dates in the user message, not UI dates."""
    with app.app_context():
        from analysis import run_analysis, get_analysis
        db = app.get_db()
        cur = db.cursor()
        # Only insert data for Jan 15
        cur.execute(
            "INSERT INTO health_snapshots (date, resting_hr) VALUES ('2026-01-15', 65)"
        )
        db.commit()

        mock_client = MagicMock()
        mock_client.messages.create.return_value = _mock_anthropic_response()

        with patch("analysis.anthropic.Anthropic", return_value=mock_client):
            # UI selects wide range: Jan 1 to Jan 31
            analysis_id = run_analysis(db, date(2026, 1, 1), date(2026, 1, 31))

        cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        result = get_analysis(cur, analysis_id)

    payload = result["request_payload"]
    user_msg = payload["messages"][0]["content"]
    # Should use effective date (Jan 15), not UI date (Jan 1)
    assert "2026-01-15" in user_msg
    assert "2026-01-01" not in user_msg
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python -m pytest tests/test_analysis.py::test_run_analysis_flags_outliers_in_prompt -v`
Expected: FAIL (outlier not in prompt because `_create_pending_analysis` doesn't call `flag_outliers` yet)

- [ ] **Step 3: Update `_create_pending_analysis()`**

In `server/analysis.py`, modify `_create_pending_analysis` (currently lines 327-346). Replace the body with:

```python
def _create_pending_analysis(db, date_from: date, date_to: date, dose_tracking_incomplete: bool = False):
    cur = db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    data = gather_analysis_data(cur, date_from, date_to)
    outlier_warnings = flag_outliers(data)
    effective_from, effective_to = compute_effective_dates(data, date_from, date_to)
    system_prompt, user_message = build_prompt(
        data, effective_from, effective_to,
        dose_tracking_incomplete=dose_tracking_incomplete,
        outlier_warnings=outlier_warnings,
    )

    request_payload = {
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}],
    }
    cur.execute(
        "INSERT INTO analyses (date_from, date_to, status, model, request_payload, "
        "dose_tracking_incomplete, created_at) "
        "VALUES (%s, %s, 'pending', %s, %s, %s, NOW()) RETURNING id",
        (date_from, date_to, MODEL, json.dumps(request_payload), dose_tracking_incomplete),
    )
    analysis_id = cur.fetchone()["id"]
    db.commit()
    return analysis_id, system_prompt, user_message
```

Key changes from the original:
- Added `outlier_warnings = flag_outliers(data)` call
- Added `effective_from, effective_to = compute_effective_dates(data, date_from, date_to)` call
- `build_prompt` now receives `effective_from`/`effective_to` instead of `date_from`/`date_to`
- `build_prompt` now receives `outlier_warnings=outlier_warnings`
- The `INSERT` still stores the original `date_from`/`date_to` (UI-selected range) in the DB

- [ ] **Step 4: Run all analysis tests**

Run: `cd server && python -m pytest tests/test_analysis.py -v`
Expected: All tests PASS

- [ ] **Step 5: Lint**

Run: `flake8 server/ --max-line-length=120 --exclude=__pycache__`
Expected: Clean

- [ ] **Step 6: Run full server test suite**

Run: `cd server && python -m pytest tests/ -v`
Expected: All tests pass (1 pre-existing failure in `test_resmed_settings_get` is OK)

- [ ] **Step 7: Commit**

```bash
git add server/analysis.py server/tests/test_analysis.py
git commit -m "feat: wire flag_outliers and compute_effective_dates into analysis pipeline"
```
