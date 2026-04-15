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
        cur.execute(
            "TRUNCATE anxiety_entries, health_snapshots, correlations, "
            "api_keys, sync_log RESTART IDENTITY CASCADE"
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
