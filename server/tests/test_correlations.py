"""Tests for the correlation engine."""

import hashlib
import os
import sys
from datetime import datetime, timedelta

import psycopg2
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from server import create_app  # noqa: E402
from correlations import correlations_are_stale  # noqa: E402

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get(
        "DATABASE_URL",
        "postgresql://anxietywatch:anxietywatch@localhost:5432/anxietywatch_test",
    ),
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
        # settings is included because the staleness fingerprint
        # (correlations_fingerprint) lives there and must not leak across tests.
        cur.execute(
            "TRUNCATE anxiety_entries, health_snapshots, correlations, "
            "api_keys, sync_log, settings RESTART IDENTITY CASCADE"
        )
        cur.execute(
            "INSERT INTO api_keys (key_hash, key_prefix, label) "
            "VALUES (%s, %s, %s)",
            (TEST_API_KEY_HASH, TEST_API_KEY[:8], "test"),
        )
        db.commit()
    yield


def auth_header():
    return {
        "Authorization": f"Bearer {TEST_API_KEY}",
        "Content-Type": "application/json",
    }


def _insert_paired_data(app, days=20, base_hrv=45.0, base_severity=5):
    """Insert paired health snapshots + anxiety entries."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        for i in range(days):
            date = f"2026-01-{i + 1:02d}"
            hrv = base_hrv + (i % 5) * 3
            severity = base_severity + (4 - i % 5)
            resting_hr = 65.0 - (i % 5)
            cur.execute(
                "INSERT INTO health_snapshots "
                "(date, hrv_avg, resting_hr, sleep_duration_min, steps) "
                "VALUES (%s, %s, %s, %s, %s) "
                "ON CONFLICT (date) DO NOTHING",
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
    assert data["minimum_required"] == 12


def test_correlations_insufficient_data(client, app):
    """Returns empty when fewer than 12 paired days."""
    _insert_paired_data(app, days=10)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    assert data["correlations"] == []
    assert data["paired_days"] == 10


def test_correlations_boundary_below(client, app):
    """Returns empty at exactly 11 paired days (one below threshold)."""
    _insert_paired_data(app, days=11)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    assert data["correlations"] == []
    assert data["paired_days"] == 11


def test_correlations_boundary_exact(client, app):
    """Returns correlations at exactly 12 paired days (threshold)."""
    _insert_paired_data(app, days=12)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    assert data["paired_days"] == 12
    assert len(data["correlations"]) > 0


def test_correlations_computed(client, app):
    """Computes correlations with sufficient paired data."""
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    assert data["paired_days"] == 20
    assert len(data["correlations"]) > 0

    hrv = next(
        (c for c in data["correlations"] if c["signal_name"] == "hrv_avg"),
        None,
    )
    assert hrv is not None
    assert hrv["correlation"] < 0
    assert hrv["sample_count"] == 20
    assert hrv["p_value"] < 1.0


def test_correlations_include_severity_buckets(client, app):
    """Results include mean severity when normal vs abnormal."""
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    hrv = next(
        c for c in data["correlations"] if c["signal_name"] == "hrv_avg"
    )
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
    assert data["minimum_required"] == 12
    assert len(data["correlations"]) > 0


def test_correlations_sorted_by_strength(client, app):
    """Results sorted by absolute correlation strength."""
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    corrs = resp.get_json()["correlations"]
    abs_values = [abs(c["correlation"]) for c in corrs]
    assert abs_values == sorted(abs_values, reverse=True)


# ---------------------------------------------------------------------------
# Staleness fingerprint (F-069)
# ---------------------------------------------------------------------------


def test_stale_when_never_computed(app):
    with app.app_context():
        cur = app.get_db().cursor()
        assert correlations_are_stale(cur) is True


def test_not_stale_when_nothing_changed(client, app):
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    assert len(resp.get_json()["correlations"]) > 0
    with app.app_context():
        cur = app.get_db().cursor()
        assert correlations_are_stale(cur) is False


def test_backfilled_entry_marks_correlations_stale(client, app):
    """An entry dated BEFORE the newest existing row must still trigger a
    recompute. The old MAX-watermark check could never fire for backfills, so
    correlations silently kept ignoring imported history (F-069)."""
    _insert_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    assert len(resp.get_json()["correlations"]) > 0
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        assert correlations_are_stale(cur) is False
        # 2025-12-15 predates every 2026-01-* row: MAX(timestamp) is unmoved,
        # only the row count changes.
        cur.execute(
            "INSERT INTO anxiety_entries (timestamp, severity) VALUES (%s, %s)",
            ("2025-12-15 12:00:00+00", 9),
        )
        db.commit()
        assert correlations_are_stale(cur) is True


def test_backfilled_snapshot_marks_correlations_stale(client, app):
    """Same as above, but for the health_snapshots side of the fingerprint."""
    _insert_paired_data(app, days=20)
    client.get("/api/correlations", headers=auth_header())
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        assert correlations_are_stale(cur) is False
        cur.execute(
            "INSERT INTO health_snapshots (date, hrv_avg) VALUES (%s, %s)",
            ("2025-12-15", 50.0),
        )
        db.commit()
        assert correlations_are_stale(cur) is True


# ---------------------------------------------------------------------------
# Local-day bucketing of evening entries (F-091)
# ---------------------------------------------------------------------------


def _insert_evening_paired_data(app, days=20, start=datetime(2026, 1, 1)):
    """Snapshots on day D with anxiety entries at 04:00 UTC on D+1 — which is
    20:00 (or 21:00 in PDT) on day D in the default US/Pacific analysis
    timezone. severity is a perfect linear function of the SAME day's hrv, so
    only correct local-day pairing yields r == -1."""
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        for i in range(days):
            snap_date = (start + timedelta(days=i)).date()
            entry_ts = start + timedelta(days=i + 1, hours=4)  # 04:00 UTC next day
            hrv = 40.0 + (i % 7) * 3
            severity = 10 - (i % 7)  # perfectly anti-correlated with same-day hrv
            cur.execute(
                "INSERT INTO health_snapshots (date, hrv_avg) VALUES (%s, %s) "
                "ON CONFLICT (date) DO NOTHING",
                (snap_date.isoformat(), hrv),
            )
            cur.execute(
                "INSERT INTO anxiety_entries (timestamp, severity) VALUES (%s, %s) "
                "ON CONFLICT (timestamp) DO NOTHING",
                (entry_ts.strftime("%Y-%m-%d %H:%M:%S+00"), severity),
            )
        db.commit()


def test_evening_entries_bucket_to_local_day(client, app):
    """A 9 PM Pacific entry (04:00 UTC next day) must pair with THAT Pacific
    day's snapshot. Under the old session-timezone (UTC) cast, every entry
    paired with the NEXT day's snapshot and the last one paired with nothing
    (F-091)."""
    _insert_evening_paired_data(app, days=20)
    resp = client.get("/api/correlations", headers=auth_header())
    data = resp.get_json()
    # UTC bucketing would yield 19 (the last entry falls past the last snapshot).
    assert data["paired_days"] == 20

    hrv = next(c for c in data["correlations"] if c["signal_name"] == "hrv_avg")
    assert hrv["sample_count"] == 20
    # severity was constructed as a perfect linear function of the same
    # Pacific day's hrv; day-shifted (UTC) pairing scrambles the cyclic
    # pattern and cannot reach -1.
    assert hrv["correlation"] == pytest.approx(-1.0)


def test_backfilled_evening_entry_recomputed_with_local_bucketing(client, app):
    """F-069 and F-091 compose: a backfilled evening pair marks correlations
    stale, and the recompute buckets it onto the correct Pacific day."""
    _insert_evening_paired_data(app, days=19)
    resp = client.get("/api/correlations", headers=auth_header())
    hrv = next(
        c for c in resp.get_json()["correlations"] if c["signal_name"] == "hrv_avg"
    )
    assert hrv["sample_count"] == 19

    # Backfill one pair EARLIER than everything above: snapshot 2025-12-01,
    # entry 2025-12-02 04:00 UTC (= 20:00 Pacific on 2025-12-01). Neither MAX
    # watermark moves — only the counts change.
    with app.app_context():
        db = app.get_db()
        cur = db.cursor()
        cur.execute(
            "INSERT INTO health_snapshots (date, hrv_avg) VALUES (%s, %s)",
            ("2025-12-01", 61.0),
        )
        cur.execute(
            "INSERT INTO anxiety_entries (timestamp, severity) VALUES (%s, %s)",
            ("2025-12-02 04:00:00+00", 3),
        )
        db.commit()

    resp = client.get("/api/correlations", headers=auth_header())
    hrv = next(
        c for c in resp.get_json()["correlations"] if c["signal_name"] == "hrv_avg"
    )
    # The recompute picked up the backfilled pair on its Pacific day.
    assert hrv["sample_count"] == 20
