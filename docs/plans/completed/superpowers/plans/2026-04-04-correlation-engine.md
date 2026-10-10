# Physiological Correlation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a server-side correlation engine that analyzes physiological-mood relationships, syncs results to the iOS app for display as insight cards with scatter plots, and provides an on-device predictor foundation for Phase 3 smart prompting.

**Architecture:** Server computes Pearson correlations (SciPy) between 7 physiological signals and anxiety severity from paired daily data. Results stored in Postgres `correlations` table, included in sync response. iOS stores in SwiftData `PhysiologicalCorrelation` model, displays in `CorrelationInsightsView`, and feeds a lightweight `AnxietyPredictor` scorer.

**Tech Stack:** Python/Flask/SciPy (server), Swift/SwiftUI/SwiftData/Swift Charts (iOS)

**Spec:** `docs/superpowers/specs/2026-04-04-correlation-engine-design.md`

---

## File Structure

### New files
- `server/correlations.py` — correlation computation logic
- `server/tests/test_correlations.py` — server tests for correlation engine
- `AnxietyWatch/Models/PhysiologicalCorrelation.swift` — SwiftData model
- `AnxietyWatch/Views/Trends/CorrelationInsightsView.swift` — insight cards list
- `AnxietyWatch/Views/Trends/CorrelationCardView.swift` — individual card
- `AnxietyWatch/Views/Trends/CorrelationChartView.swift` — scatter plot
- `AnxietyWatch/Utilities/AnxietyPredictor.swift` — on-device risk scorer
- `AnxietyWatchTests/AnxietyPredictorTests.swift` — predictor unit tests

### Modified files
- `server/schema.sql` — add correlations table
- `server/server.py` — add /api/correlations endpoint, add correlations to sync response, add migration
- `server/docker-compose.yml` — expose Postgres port
- `server/requirements.txt` — add scipy
- `AnxietyWatch/App/AnxietyWatchApp.swift` — add PhysiologicalCorrelation to schema
- `AnxietyWatch/Services/SyncService.swift` — parse correlations from sync response
- `AnxietyWatch/Views/Trends/TrendsView.swift` — add Insights navigation link
- `AnxietyWatchTests/Helpers/TestHelpers.swift` — add PhysiologicalCorrelation to test schema
- `AnxietyWatchTests/Helpers/ModelFactory.swift` — add correlation factory method

---

### Task 1: Docker port + scipy dependency

**Files:**
- Modify: `server/docker-compose.yml`
- Modify: `server/requirements.txt`

- [ ] **Step 1: Expose Postgres port to network**

In `server/docker-compose.yml`, change line 11:

```yaml
    ports:
      - "5439:5432"
```

- [ ] **Step 2: Add scipy to requirements**

In `server/requirements.txt`, add:

```
scipy>=1.12
```

- [ ] **Step 3: Commit**

```bash
git add server/docker-compose.yml server/requirements.txt
git commit -m "chore: expose Postgres port and add scipy dependency

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Server correlation engine + schema

**Files:**
- Modify: `server/schema.sql`
- Create: `server/correlations.py`
- Modify: `server/server.py`
- Create: `server/tests/test_correlations.py`

- [ ] **Step 1: Add correlations table to schema.sql**

Add before the `-- Indexes` section at the end of `server/schema.sql`:

```sql
CREATE TABLE IF NOT EXISTS correlations (
    id              SERIAL PRIMARY KEY,
    signal_name     TEXT NOT NULL,
    correlation     DOUBLE PRECISION NOT NULL,
    p_value         DOUBLE PRECISION NOT NULL,
    sample_count    INTEGER NOT NULL,
    mean_severity_when_abnormal DOUBLE PRECISION,
    mean_severity_when_normal   DOUBLE PRECISION,
    computed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(signal_name)
);
```

- [ ] **Step 2: Create server/correlations.py**

```python
"""Correlation engine — computes Pearson correlations between physiological signals and anxiety severity."""

from datetime import datetime, timezone

import numpy as np
from scipy import stats

# Signals to correlate: (name, SQL expression, nullable columns needed)
SIGNALS = [
    ("hrv_avg", "h.hrv_avg", ["h.hrv_avg"]),
    ("resting_hr", "h.resting_hr", ["h.resting_hr"]),
    ("sleep_duration_min", "h.sleep_duration_min", ["h.sleep_duration_min"]),
    (
        "sleep_quality_ratio",
        "CASE WHEN h.sleep_duration_min > 0 "
        "THEN (COALESCE(h.sleep_deep_min, 0) + COALESCE(h.sleep_rem_min, 0))::float "
        "/ h.sleep_duration_min ELSE NULL END",
        ["h.sleep_duration_min"],
    ),
    ("steps", "h.steps", ["h.steps"]),
    ("cpap_ahi", "h.cpap_ahi", ["h.cpap_ahi"]),
    ("barometric_pressure_change_kpa", "h.barometric_pressure_change_kpa", ["h.barometric_pressure_change_kpa"]),
]

MINIMUM_PAIRED_DAYS = 14


def compute_correlations(cur):
    """Compute Pearson correlations for all signals. Returns list of result dicts."""
    results = []

    for signal_name, sql_expr, required_cols in SIGNALS:
        # Build WHERE clause requiring non-null signal + non-null severity
        not_null = " AND ".join(f"{col} IS NOT NULL" for col in required_cols)

        cur.execute(f"""
            SELECT {sql_expr} AS signal_value, AVG(a.severity) AS avg_severity
            FROM health_snapshots h
            JOIN anxiety_entries a ON a.timestamp::date = h.date
            WHERE {not_null}
            GROUP BY h.date, {sql_expr}
            ORDER BY h.date
        """)
        rows = cur.fetchall()

        if len(rows) < MINIMUM_PAIRED_DAYS:
            continue

        signal_values = np.array([r[0] for r in rows], dtype=float)
        severity_values = np.array([r[1] for r in rows], dtype=float)

        # Pearson correlation
        r, p = stats.pearsonr(signal_values, severity_values)

        # Split into normal vs abnormal using mean +/- 1 stddev
        mean = np.mean(signal_values)
        std = np.std(signal_values, ddof=1)
        if std > 0:
            abnormal_mask = np.abs(signal_values - mean) > std
            normal_mask = ~abnormal_mask
            mean_sev_abnormal = float(np.mean(severity_values[abnormal_mask])) if abnormal_mask.any() else None
            mean_sev_normal = float(np.mean(severity_values[normal_mask])) if normal_mask.any() else None
        else:
            mean_sev_abnormal = None
            mean_sev_normal = None

        results.append({
            "signal_name": signal_name,
            "correlation": float(r),
            "p_value": float(p),
            "sample_count": len(rows),
            "mean_severity_when_abnormal": mean_sev_abnormal,
            "mean_severity_when_normal": mean_sev_normal,
        })

    return results


def store_correlations(cur, results):
    """Upsert correlation results into the database."""
    for r in results:
        cur.execute(
            """INSERT INTO correlations
                   (signal_name, correlation, p_value, sample_count,
                    mean_severity_when_abnormal, mean_severity_when_normal, computed_at)
               VALUES (%s, %s, %s, %s, %s, %s, NOW())
               ON CONFLICT (signal_name) DO UPDATE SET
                   correlation = EXCLUDED.correlation,
                   p_value = EXCLUDED.p_value,
                   sample_count = EXCLUDED.sample_count,
                   mean_severity_when_abnormal = EXCLUDED.mean_severity_when_abnormal,
                   mean_severity_when_normal = EXCLUDED.mean_severity_when_normal,
                   computed_at = EXCLUDED.computed_at""",
            (
                r["signal_name"], r["correlation"], r["p_value"],
                r["sample_count"], r["mean_severity_when_abnormal"],
                r["mean_severity_when_normal"],
            ),
        )


def get_correlations(cur):
    """Fetch all stored correlations."""
    cur.execute(
        """SELECT signal_name, correlation, p_value, sample_count,
                  mean_severity_when_abnormal, mean_severity_when_normal, computed_at
           FROM correlations ORDER BY ABS(correlation) DESC"""
    )
    return [
        {
            "signal_name": r[0],
            "correlation": r[1],
            "p_value": r[2],
            "sample_count": r[3],
            "mean_severity_when_abnormal": r[4],
            "mean_severity_when_normal": r[5],
            "computed_at": r[6].isoformat() if r[6] else None,
        }
        for r in cur.fetchall()
    ]


def get_paired_day_count(cur):
    """Count days that have both a health snapshot and an anxiety entry."""
    cur.execute("""
        SELECT COUNT(DISTINCT h.date)
        FROM health_snapshots h
        JOIN anxiety_entries a ON a.timestamp::date = h.date
    """)
    return cur.fetchone()[0]


def correlations_are_stale(cur):
    """Check if correlations need recomputing (older than newest anxiety entry)."""
    cur.execute("SELECT MAX(computed_at) FROM correlations")
    last_computed = cur.fetchone()[0]
    if last_computed is None:
        return True

    cur.execute("SELECT MAX(timestamp) FROM anxiety_entries")
    last_entry = cur.fetchone()[0]
    if last_entry is None:
        return False

    return last_entry > last_computed
```

- [ ] **Step 3: Add migration, /api/correlations endpoint, and sync integration to server.py**

In `server/server.py`, add the import at the top (after existing imports):

```python
from correlations import (
    compute_correlations, store_correlations, get_correlations,
    get_paired_day_count, correlations_are_stale, MINIMUM_PAIRED_DAYS,
)
```

In `init_db()`, add the correlations table migration after the snapshot migrations block:

```python
            # Migrate: add correlations table
            cur.execute("""
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
                )
            """)
```

Add the `_clean_tables` truncation — in the test file, add `correlations` to the TRUNCATE list (covered in test step).

Add the `/api/correlations` endpoint after the sync endpoint:

```python
    # ---------------------------------------------------------------------------
    # GET /api/correlations
    # ---------------------------------------------------------------------------

    @app.route("/api/correlations", methods=["GET"])
    @require_api_key
    def api_correlations():
        db = get_db()
        cur = db.cursor()

        paired_days = get_paired_day_count(cur)

        # Recompute if stale or missing
        if paired_days >= MINIMUM_PAIRED_DAYS and correlations_are_stale(cur):
            results = compute_correlations(cur)
            store_correlations(cur, results)
            db.commit()

        correlations = get_correlations(cur)
        return jsonify({
            "correlations": correlations,
            "paired_days": paired_days,
            "minimum_required": MINIMUM_PAIRED_DAYS,
        })
```

In the `sync()` function, add correlations to the response. Replace the return line:

```python
        # Before:
        return jsonify({"status": "ok", "counts": counts})

        # After:
        # Include latest correlations in sync response
        correlation_data = {}
        try:
            cur2 = db.cursor()
            paired_days = get_paired_day_count(cur2)
            if paired_days >= MINIMUM_PAIRED_DAYS and correlations_are_stale(cur2):
                results = compute_correlations(cur2)
                store_correlations(cur2, results)
                db.commit()
            correlation_data = {
                "correlations": get_correlations(cur2),
                "paired_days": paired_days,
                "minimum_required": MINIMUM_PAIRED_DAYS,
            }
        except Exception:
            app.logger.exception("Correlation computation failed (non-fatal)")

        return jsonify({"status": "ok", "counts": counts, **correlation_data})
```

- [ ] **Step 4: Write server tests**

Create `server/tests/test_correlations.py`:

```python
"""Tests for the correlation engine."""

import hashlib
import os
import sys

import psycopg2
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from server import create_app  # noqa: E402

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get("DATABASE_URL", "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test"),
)

TEST_API_KEY = "test-key-for-pytest-12345678"
TEST_API_KEY_HASH = hashlib.sha256(TEST_API_KEY.encode()).hexdigest()


@pytest.fixture(scope="session")
def _init_db():
    conn = psycopg2.connect(DATABASE_URL)
    conn.autocommit = True
    cur = conn.cursor()
    schema_path = os.path.join(os.path.dirname(__file__), "..", "schema.sql")
    with open(schema_path) as f:
        cur.execute(f.read())
    # Ensure correlations table exists
    cur.execute("""
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
        )
    """)
    conn.close()


@pytest.fixture()
def app(_init_db):
    app = create_app({"TESTING": True, "DATABASE_URL": DATABASE_URL})
    yield app


@pytest.fixture()
def client(app):
    return app.test_client()


@pytest.fixture(autouse=True)
def _clean_tables(app):
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "TRUNCATE anxiety_entries, health_snapshots, correlations, "
            "api_keys, sync_log RESTART IDENTITY CASCADE"
        )
        cur.execute(
            "INSERT INTO api_keys (key_hash, key_prefix, label) VALUES (%s, %s, %s)",
            (TEST_API_KEY_HASH, TEST_API_KEY[:8], "test"),
        )
        db.commit()
    yield


def auth_header():
    return {"Authorization": f"Bearer {TEST_API_KEY}", "Content-Type": "application/json"}


def _insert_paired_data(app, days=20, base_hrv=45.0, base_severity=5):
    """Insert N days of health snapshots + anxiety entries with controllable values."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        for i in range(days):
            date = f"2026-01-{i + 1:02d}"
            # Vary HRV inversely with severity for a detectable correlation
            hrv = base_hrv + (i % 5) * 3
            severity = base_severity + (4 - i % 5)  # higher when HRV is lower
            resting_hr = 65.0 - (i % 5)  # lower when severity is higher
            cur.execute(
                "INSERT INTO health_snapshots (date, hrv_avg, resting_hr, sleep_duration_min, steps) "
                "VALUES (%s, %s, %s, %s, %s) ON CONFLICT (date) DO NOTHING",
                (date, hrv, resting_hr, 400 + i * 5, 5000 + i * 200),
            )
            cur.execute(
                "INSERT INTO anxiety_entries (timestamp, severity) "
                "VALUES (%s, %s) ON CONFLICT (timestamp) DO NOTHING",
                (f"{date} 12:00:00+00", severity),
            )
        db.commit()


def test_correlations_empty(client):
    """Returns empty when no paired data."""
    resp = client.get("/api/correlations", headers=auth_header())
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["correlations"] == []
    assert data["paired_days"] == 0
    assert data["minimum_required"] == 14


def test_correlations_insufficient_data(client, app):
    """Returns empty when fewer than 14 paired days."""
    _insert_paired_data(app, days=10)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    assert data["correlations"] == []
    assert data["paired_days"] == 10


def test_correlations_computed(client, app):
    """Computes correlations with sufficient paired data."""
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    assert data["paired_days"] == 20
    assert len(data["correlations"]) > 0

    # HRV should have a negative correlation (inverse relationship)
    hrv = next((c for c in data["correlations"] if c["signal_name"] == "hrv_avg"), None)
    assert hrv is not None
    assert hrv["correlation"] < 0
    assert hrv["sample_count"] == 20
    assert hrv["p_value"] < 1.0


def test_correlations_include_severity_buckets(client, app):
    """Correlation results include mean severity when normal vs abnormal."""
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()

    hrv = next(c for c in data["correlations"] if c["signal_name"] == "hrv_avg")
    assert hrv["mean_severity_when_abnormal"] is not None
    assert hrv["mean_severity_when_normal"] is not None


def test_correlations_in_sync_response(client, app):
    """Sync response includes correlations."""
    _insert_paired_data(app, days=20)
    payload = {"anxietyEntries": [], "healthSnapshots": []}
    resp = client.post("/api/sync", json=payload, headers=auth_header())
    data = resp.get_json()
    assert "correlations" in data
    assert data["paired_days"] == 20
    assert len(data["correlations"]) > 0


def test_correlations_sorted_by_strength(client, app):
    """Results are sorted by absolute correlation strength (strongest first)."""
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    corrs = resp.get_json()["correlations"]
    abs_values = [abs(c["correlation"]) for c in corrs]
    assert abs_values == sorted(abs_values, reverse=True)
```

- [ ] **Step 5: Run server tests**

Run:
```bash
cd server && python -m pytest tests/test_correlations.py -v
```
Expected: All tests pass

- [ ] **Step 6: Lint**

Run:
```bash
cd server && flake8 . --max-line-length=120 --exclude=__pycache__
```
Expected: No errors

- [ ] **Step 7: Commit**

```bash
git add server/schema.sql server/correlations.py server/server.py server/tests/test_correlations.py
git commit -m "feat: add server-side correlation engine with 7 physiological signals

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: iOS data model + sync integration

**Files:**
- Create: `AnxietyWatch/Models/PhysiologicalCorrelation.swift`
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift`
- Modify: `AnxietyWatch/Services/SyncService.swift`
- Modify: `AnxietyWatchTests/Helpers/TestHelpers.swift`
- Modify: `AnxietyWatchTests/Helpers/ModelFactory.swift`

- [ ] **Step 1: Create PhysiologicalCorrelation model**

```swift
// AnxietyWatch/Models/PhysiologicalCorrelation.swift
import Foundation
import SwiftData

@Model
final class PhysiologicalCorrelation {
    #Unique<PhysiologicalCorrelation>([\.signalName])

    var id: UUID
    var signalName: String
    var correlation: Double
    var pValue: Double
    var sampleCount: Int
    var meanSeverityWhenAbnormal: Double?
    var meanSeverityWhenNormal: Double?
    var computedAt: Date

    /// Human-readable display name for the signal.
    var displayName: String {
        switch signalName {
        case "hrv_avg": return "Heart Rate Variability"
        case "resting_hr": return "Resting Heart Rate"
        case "sleep_duration_min": return "Sleep Duration"
        case "sleep_quality_ratio": return "Sleep Quality"
        case "steps": return "Daily Steps"
        case "cpap_ahi": return "CPAP AHI"
        case "barometric_pressure_change_kpa": return "Barometric Change"
        default: return signalName
        }
    }

    /// Strength category based on |r|.
    var strength: String {
        let absR = abs(correlation)
        if absR > 0.5 { return "Strong" }
        if absR > 0.3 { return "Moderate" }
        return "Weak"
    }

    /// Direction label.
    var direction: String {
        correlation > 0 ? "positive" : "inverse"
    }

    /// Whether this correlation is statistically significant.
    var isSignificant: Bool { pValue < 0.05 }

    init(
        signalName: String,
        correlation: Double,
        pValue: Double,
        sampleCount: Int,
        meanSeverityWhenAbnormal: Double? = nil,
        meanSeverityWhenNormal: Double? = nil,
        computedAt: Date = .now
    ) {
        self.id = UUID()
        self.signalName = signalName
        self.correlation = correlation
        self.pValue = pValue
        self.sampleCount = sampleCount
        self.meanSeverityWhenAbnormal = meanSeverityWhenAbnormal
        self.meanSeverityWhenNormal = meanSeverityWhenNormal
        self.computedAt = computedAt
    }
}
```

- [ ] **Step 2: Add to app schema**

In `AnxietyWatch/App/AnxietyWatchApp.swift`, add `PhysiologicalCorrelation.self` to the schema array:

```swift
        let schema = Schema([
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
            Pharmacy.self,
            Prescription.self,
            PharmacyCallLog.self,
            HealthSample.self,
            PhysiologicalCorrelation.self,
        ])
```

- [ ] **Step 3: Add to test helpers**

In `AnxietyWatchTests/Helpers/TestHelpers.swift`, add `PhysiologicalCorrelation.self` to the schema:

```swift
        let schema = Schema([
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
            Pharmacy.self,
            Prescription.self,
            PharmacyCallLog.self,
            HealthSample.self,
            PhysiologicalCorrelation.self,
        ])
```

- [ ] **Step 4: Add ModelFactory method**

In `AnxietyWatchTests/Helpers/ModelFactory.swift`, add:

```swift
    // MARK: - Correlations

    static func correlation(
        signalName: String = "hrv_avg",
        correlation: Double = -0.5,
        pValue: Double = 0.01,
        sampleCount: Int = 30,
        meanSeverityWhenAbnormal: Double? = 6.0,
        meanSeverityWhenNormal: Double? = 3.5,
        computedAt: Date = referenceDate
    ) -> PhysiologicalCorrelation {
        PhysiologicalCorrelation(
            signalName: signalName,
            correlation: correlation,
            pValue: pValue,
            sampleCount: sampleCount,
            meanSeverityWhenAbnormal: meanSeverityWhenAbnormal,
            meanSeverityWhenNormal: meanSeverityWhenNormal,
            computedAt: computedAt
        )
    }
```

- [ ] **Step 5: Update SyncService to parse correlations**

In `AnxietyWatch/Services/SyncService.swift`, add a method to parse and store correlations from the sync response. In the `sync()` method, after `lastSyncDate = .now`, add:

```swift
            // Parse correlations from sync response if present
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let correlationList = json["correlations"] as? [[String: Any]] {
                upsertCorrelations(correlationList, modelContext: modelContext)
            }
```

Add the helper method:

```swift
    // MARK: - Correlations

    private func upsertCorrelations(_ correlations: [[String: Any]], modelContext: ModelContext) {
        for c in correlations {
            guard let signalName = c["signal_name"] as? String,
                  let corr = c["correlation"] as? Double,
                  let pValue = c["p_value"] as? Double,
                  let sampleCount = c["sample_count"] as? Int else { continue }

            let descriptor = FetchDescriptor<PhysiologicalCorrelation>(
                predicate: #Predicate { $0.signalName == signalName }
            )
            let existing = try? modelContext.fetch(descriptor).first

            if let existing {
                existing.correlation = corr
                existing.pValue = pValue
                existing.sampleCount = sampleCount
                existing.meanSeverityWhenAbnormal = c["mean_severity_when_abnormal"] as? Double
                existing.meanSeverityWhenNormal = c["mean_severity_when_normal"] as? Double
                existing.computedAt = .now
            } else {
                let record = PhysiologicalCorrelation(
                    signalName: signalName,
                    correlation: corr,
                    pValue: pValue,
                    sampleCount: sampleCount,
                    meanSeverityWhenAbnormal: c["mean_severity_when_abnormal"] as? Double,
                    meanSeverityWhenNormal: c["mean_severity_when_normal"] as? Double
                )
                modelContext.insert(record)
            }
        }
        try? modelContext.save()
    }
```

- [ ] **Step 6: Build and test**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add AnxietyWatch/Models/PhysiologicalCorrelation.swift AnxietyWatch/App/AnxietyWatchApp.swift AnxietyWatch/Services/SyncService.swift AnxietyWatchTests/Helpers/TestHelpers.swift AnxietyWatchTests/Helpers/ModelFactory.swift
git commit -m "feat: add PhysiologicalCorrelation model and sync integration

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: AnxietyPredictor + tests

**Files:**
- Create: `AnxietyWatch/Utilities/AnxietyPredictor.swift`
- Create: `AnxietyWatchTests/AnxietyPredictorTests.swift`

- [ ] **Step 1: Create AnxietyPredictor**

```swift
// AnxietyWatch/Utilities/AnxietyPredictor.swift
import Foundation

/// Produces a real-time anxiety risk score from server-computed correlations
/// and current physiological data. Foundation for Phase 3 smart prompting.
enum AnxietyPredictor {

    struct PredictionResult {
        let score: Double // 0.0 = calm, 1.0 = high anxiety likelihood
        let contributingSignals: [(name: String, direction: String, weight: Double)]
    }

    /// Compute anxiety risk score from correlations and today's snapshot vs baseline.
    /// Returns nil if no significant correlations exist.
    static func predict(
        correlations: [PhysiologicalCorrelation],
        todaySnapshot: HealthSnapshot?,
        baselineSnapshots: [HealthSnapshot]
    ) -> PredictionResult? {
        let significant = correlations.filter { $0.isSignificant }
        guard !significant.isEmpty, let today = todaySnapshot else { return nil }

        var contributions: [(name: String, direction: String, weight: Double)] = []
        var totalWeight = 0.0

        for corr in significant {
            guard let (todayValue, baselineMean, baselineStd) = signalValues(
                for: corr.signalName, today: today, baselines: baselineSnapshots
            ), baselineStd > 0 else { continue }

            // Z-score: how many stddevs from baseline
            let z = (todayValue - baselineMean) / baselineStd

            // Weight: z-score * correlation coefficient
            // Positive weight means "this signal suggests higher anxiety"
            let weight = z * corr.correlation
            totalWeight += weight

            let direction = weight > 0 ? "elevated risk" : "reduced risk"
            contributions.append((corr.displayName, direction, abs(weight)))
        }

        guard !contributions.isEmpty else { return nil }

        // Normalize to 0-1 using sigmoid
        let score = 1.0 / (1.0 + exp(-totalWeight))

        // Sort by weight descending
        let sorted = contributions.sorted { $0.weight > $1.weight }

        return PredictionResult(score: score, contributingSignals: sorted)
    }

    /// Extract today's value, baseline mean, and baseline stddev for a signal.
    private static func signalValues(
        for signalName: String,
        today: HealthSnapshot,
        baselines: [HealthSnapshot]
    ) -> (todayValue: Double, mean: Double, std: Double)? {
        let keyPath: KeyPath<HealthSnapshot, Double?>

        switch signalName {
        case "hrv_avg": keyPath = \.hrvAvg
        case "resting_hr": keyPath = \.restingHR
        case "sleep_duration_min":
            // Convert Int? to Double? via manual extraction
            guard let todayVal = today.sleepDurationMin else { return nil }
            let values = baselines.compactMap(\.sleepDurationMin).map(Double.init)
            return computeStats(todayValue: Double(todayVal), baselineValues: values)
        case "steps":
            guard let todayVal = today.steps else { return nil }
            let values = baselines.compactMap(\.steps).map(Double.init)
            return computeStats(todayValue: Double(todayVal), baselineValues: values)
        case "cpap_ahi": keyPath = \.cpapAHI
        case "barometric_pressure_change_kpa": keyPath = \.barometricPressureChangeKPa
        case "sleep_quality_ratio":
            guard let duration = today.sleepDurationMin, duration > 0 else { return nil }
            let deep = today.sleepDeepMin ?? 0
            let rem = today.sleepREMMin ?? 0
            let todayRatio = Double(deep + rem) / Double(duration)
            let ratios = baselines.compactMap { snap -> Double? in
                guard let d = snap.sleepDurationMin, d > 0 else { return nil }
                return Double((snap.sleepDeepMin ?? 0) + (snap.sleepREMMin ?? 0)) / Double(d)
            }
            return computeStats(todayValue: todayRatio, baselineValues: ratios)
        default: return nil
        }

        guard let todayVal = today[keyPath: keyPath] else { return nil }
        let values = baselines.compactMap { $0[keyPath: keyPath] }
        return computeStats(todayValue: todayVal, baselineValues: values)
    }

    private static func computeStats(
        todayValue: Double,
        baselineValues: [Double]
    ) -> (Double, Double, Double)? {
        guard baselineValues.count >= 7 else { return nil }
        let mean = baselineValues.reduce(0, +) / Double(baselineValues.count)
        let variance = baselineValues.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
            / Double(baselineValues.count - 1)
        let std = variance.squareRoot()
        guard std > 0 else { return nil }
        return (todayValue, mean, std)
    }
}
```

- [ ] **Step 2: Write tests**

```swift
// AnxietyWatchTests/AnxietyPredictorTests.swift
import Foundation
import Testing

@testable import AnxietyWatch

struct AnxietyPredictorTests {

    private let referenceDate = ModelFactory.referenceDate

    private func makeBaselines(count: Int, hrvAvg: Double, restingHR: Double) -> [HealthSnapshot] {
        (0..<count).map { day in
            ModelFactory.healthSnapshot(
                date: ModelFactory.daysAgo(day + 1),
                hrvAvg: hrvAvg + Double(day % 3) * 2, // slight variance
                restingHR: restingHR + Double(day % 3)
            )
        }
    }

    @Test("Returns nil when no significant correlations")
    func nilWithoutSignificant() {
        let corr = ModelFactory.correlation(pValue: 0.5) // not significant
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result == nil)
    }

    @Test("Returns nil when no today snapshot")
    func nilWithoutSnapshot() {
        let corr = ModelFactory.correlation(pValue: 0.01)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: nil, baselineSnapshots: baselines
        )
        #expect(result == nil)
    }

    @Test("Score is between 0 and 1")
    func scoreInRange() {
        let corr = ModelFactory.correlation(
            signalName: "hrv_avg", correlation: -0.6, pValue: 0.01
        )
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0) // low HRV
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result != nil)
        #expect(result!.score >= 0.0 && result!.score <= 1.0)
    }

    @Test("Low HRV with negative correlation produces higher score")
    func lowHRVHigherScore() {
        let corr = ModelFactory.correlation(
            signalName: "hrv_avg", correlation: -0.6, pValue: 0.01
        )
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)

        let todayLow = ModelFactory.healthSnapshot(hrvAvg: 30.0)
        let todayNormal = ModelFactory.healthSnapshot(hrvAvg: 45.0)

        let lowResult = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: todayLow, baselineSnapshots: baselines
        )!
        let normalResult = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: todayNormal, baselineSnapshots: baselines
        )!

        #expect(lowResult.score > normalResult.score)
    }

    @Test("Contributing signals are sorted by weight")
    func signalsSortedByWeight() {
        let correlations = [
            ModelFactory.correlation(signalName: "hrv_avg", correlation: -0.6, pValue: 0.01),
            ModelFactory.correlation(signalName: "resting_hr", correlation: 0.3, pValue: 0.03),
        ]
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0, restingHR: 75.0)
        let baselines = makeBaselines(count: 14, hrvAvg: 45.0, restingHR: 62.0)
        let result = AnxietyPredictor.predict(
            correlations: correlations, todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result != nil)
        let weights = result!.contributingSignals.map(\.weight)
        #expect(weights == weights.sorted(by: >))
    }

    @Test("Insufficient baseline data returns nil")
    func insufficientBaselines() {
        let corr = ModelFactory.correlation(pValue: 0.01)
        let today = ModelFactory.healthSnapshot(hrvAvg: 30.0)
        let baselines = makeBaselines(count: 3, hrvAvg: 45.0, restingHR: 62.0) // too few
        let result = AnxietyPredictor.predict(
            correlations: [corr], todaySnapshot: today, baselineSnapshots: baselines
        )
        #expect(result == nil)
    }
}
```

- [ ] **Step 3: Build and run tests**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests/AnxietyPredictorTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Utilities/AnxietyPredictor.swift AnxietyWatchTests/AnxietyPredictorTests.swift
git commit -m "feat: add AnxietyPredictor on-device risk scorer with tests

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Insights UI

**Files:**
- Create: `AnxietyWatch/Views/Trends/CorrelationInsightsView.swift`
- Create: `AnxietyWatch/Views/Trends/CorrelationCardView.swift`
- Create: `AnxietyWatch/Views/Trends/CorrelationChartView.swift`
- Modify: `AnxietyWatch/Views/Trends/TrendsView.swift`

- [ ] **Step 1: Create CorrelationCardView**

```swift
// AnxietyWatch/Views/Trends/CorrelationCardView.swift
import SwiftUI

struct CorrelationCardView: View {
    let correlation: PhysiologicalCorrelation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(correlation.displayName)
                    .font(.headline)
                Spacer()
                Text("\(correlation.strength) \(correlation.direction)")
                    .font(.caption)
                    .foregroundStyle(strengthColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(strengthColor.opacity(0.15), in: .capsule)
            }

            if let abnormal = correlation.meanSeverityWhenAbnormal,
               let normal = correlation.meanSeverityWhenNormal {
                Text(insightText(abnormal: abnormal, normal: normal))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("r = \(correlation.correlation, specifier: "%.2f")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Based on \(correlation.sampleCount) days")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .opacity(correlation.isSignificant ? 1.0 : 0.5)
        .overlay(alignment: .topTrailing) {
            if !correlation.isSignificant {
                Text("Insufficient data")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(6)
            }
        }
    }

    private var strengthColor: Color {
        let absR = abs(correlation.correlation)
        if absR > 0.5 { return .red }
        if absR > 0.3 { return .orange }
        return .gray
    }

    private func insightText(abnormal: Double, normal: Double) -> String {
        let signalLabel: String
        switch correlation.signalName {
        case "hrv_avg": signalLabel = "low HRV"
        case "resting_hr": signalLabel = "elevated heart rate"
        case "sleep_duration_min": signalLabel = "poor sleep"
        case "sleep_quality_ratio": signalLabel = "low sleep quality"
        case "steps": signalLabel = "low activity"
        case "cpap_ahi": signalLabel = "high AHI"
        case "barometric_pressure_change_kpa": signalLabel = "pressure changes"
        default: signalLabel = "abnormal \(correlation.displayName)"
        }
        return String(
            format: "Anxiety averages %.1f on days with %@ vs %.1f normally",
            abnormal, signalLabel, normal
        )
    }
}
```

- [ ] **Step 2: Create CorrelationChartView**

```swift
// AnxietyWatch/Views/Trends/CorrelationChartView.swift
import Charts
import SwiftData
import SwiftUI

struct CorrelationChartView: View {
    let correlation: PhysiologicalCorrelation
    @Query(sort: \HealthSnapshot.date) private var snapshots: [HealthSnapshot]
    @Query(sort: \AnxietyEntry.timestamp) private var entries: [AnxietyEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(correlation.displayName)
                .font(.title3.bold())

            Text("\(correlation.strength) \(correlation.direction) correlation (r = \(correlation.correlation, specifier: "%.2f"))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if pairedData.isEmpty {
                ContentUnavailableView("No Paired Data", systemImage: "chart.dots.scatter")
            } else {
                Chart {
                    ForEach(pairedData, id: \.date) { point in
                        PointMark(
                            x: .value(correlation.displayName, point.signalValue),
                            y: .value("Severity", point.severity)
                        )
                        .foregroundStyle(.blue.opacity(0.6))
                    }
                }
                .chartYScale(domain: 1...10)
                .chartYAxisLabel("Anxiety Severity")
                .chartXAxisLabel(correlation.displayName)
                .frame(height: 250)
            }

            if let abnormal = correlation.meanSeverityWhenAbnormal,
               let normal = correlation.meanSeverityWhenNormal {
                HStack(spacing: 16) {
                    StatBox(label: "Normal days", value: String(format: "%.1f", normal), color: .green)
                    StatBox(label: "Abnormal days", value: String(format: "%.1f", abnormal), color: .red)
                }
            }

            Text("Based on \(correlation.sampleCount) paired days  ·  p = \(correlation.pValue, specifier: "%.3f")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .navigationTitle("Correlation Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct PairedPoint {
        let date: Date
        let signalValue: Double
        let severity: Double
    }

    private var pairedData: [PairedPoint] {
        let calendar = Calendar.current
        let entriesByDate = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.timestamp) }

        return snapshots.compactMap { snap in
            guard let dayEntries = entriesByDate[snap.date], !dayEntries.isEmpty else { return nil }
            let avgSeverity = Double(dayEntries.map(\.severity).reduce(0, +)) / Double(dayEntries.count)
            guard let value = signalValue(from: snap) else { return nil }
            return PairedPoint(date: snap.date, signalValue: value, severity: avgSeverity)
        }
    }

    private func signalValue(from snap: HealthSnapshot) -> Double? {
        switch correlation.signalName {
        case "hrv_avg": return snap.hrvAvg
        case "resting_hr": return snap.restingHR
        case "sleep_duration_min": return snap.sleepDurationMin.map(Double.init)
        case "sleep_quality_ratio":
            guard let d = snap.sleepDurationMin, d > 0 else { return nil }
            return Double((snap.sleepDeepMin ?? 0) + (snap.sleepREMMin ?? 0)) / Double(d)
        case "steps": return snap.steps.map(Double.init)
        case "cpap_ahi": return snap.cpapAHI
        case "barometric_pressure_change_kpa": return snap.barometricPressureChangeKPa
        default: return nil
        }
    }
}

private struct StatBox: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}
```

- [ ] **Step 3: Create CorrelationInsightsView**

```swift
// AnxietyWatch/Views/Trends/CorrelationInsightsView.swift
import SwiftData
import SwiftUI

struct CorrelationInsightsView: View {
    @Query(sort: \PhysiologicalCorrelation.computedAt)
    private var correlations: [PhysiologicalCorrelation]

    @Query private var entries: [AnxietyEntry]
    @Query private var snapshots: [HealthSnapshot]

    private var pairedDayCount: Int {
        let calendar = Calendar.current
        let entryDates = Set(entries.map { calendar.startOfDay(for: $0.timestamp) })
        let snapshotDates = Set(snapshots.map(\.date))
        return entryDates.intersection(snapshotDates).count
    }

    private var sortedCorrelations: [PhysiologicalCorrelation] {
        correlations.sorted { abs($0.correlation) > abs($1.correlation) }
    }

    var body: some View {
        Group {
            if correlations.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedCorrelations) { corr in
                        NavigationLink {
                            CorrelationChartView(correlation: corr)
                        } label: {
                            CorrelationCardView(correlation: corr)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Insights")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.dots.scatter")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Keep logging check-ins")
                .font(.headline)

            Text("Insights will appear after ~2 weeks of paired data (mood entries + health data on the same days).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ProgressView(value: Double(min(pairedDayCount, 14)), total: 14)
                .tint(.blue)

            Text("\(pairedDayCount) / 14 paired days")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}
```

- [ ] **Step 4: Add navigation link in TrendsView**

In `AnxietyWatch/Views/Trends/TrendsView.swift`, add a NavigationLink to CorrelationInsightsView inside the ScrollView VStack, after the chart views. Find the closing braces of the chart section and add:

```swift
                    // Insights link
                    NavigationLink {
                        CorrelationInsightsView()
                    } label: {
                        HStack {
                            Image(systemName: "chart.dots.scatter")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text("Correlation Insights")
                                    .font(.headline)
                                Text("See how your physiology relates to anxiety")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
```

- [ ] **Step 5: Build**

Run:
```bash
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add AnxietyWatch/Views/Trends/CorrelationCardView.swift AnxietyWatch/Views/Trends/CorrelationChartView.swift AnxietyWatch/Views/Trends/CorrelationInsightsView.swift AnxietyWatch/Views/Trends/TrendsView.swift
git commit -m "feat: add correlation insights UI with cards and scatter plots

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Final verification and PR

- [ ] **Step 1: Run server tests**

Run:
```bash
cd server && python -m pytest tests/ -v
```
Expected: All tests pass

- [ ] **Step 2: Lint server**

Run:
```bash
cd server && flake8 . --max-line-length=120 --exclude=__pycache__
```
Expected: No errors

- [ ] **Step 3: Run iOS tests**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Push and create PR**

```bash
git push -u origin feature/correlation-engine
```

Create PR targeting `main` with title: "feat: physiological correlation engine with insights UI"
